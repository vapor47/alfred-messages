import Foundation
import AppKit
import Darwin

public final class Service {
    let engine: Engine
    let submissions = SubmissionGuard()
    let outgoing = OutgoingReceipts()
    let liveViews = LiveViews()
    let liveWork = DispatchQueue(label: "messages.active-history", qos: .userInitiated)
    var livePreparing = false
    let sendMessage: (String, String) throws -> Void
    let automation = DispatchQueue(label: "messages.automation")
    let control = NSLock()
    var watchers: [DispatchSourceFileSystemObject] = []
    var timer: DispatchSourceTimer?
    var debounce: DispatchWorkItem?
    var lastReconcile = Date.distantPast
    // Guarded by control: the database signature the last full refresh was scheduled from.
    var refreshedSignature = ""
    // Accessed only on liveWork: the database signature each active view was last prepared from.
    var prepared: [String: (signature: String, generation: Int, at: Date)] = [:]
    public init(root: URL, database: String, sender: ((String, String) throws -> Void)? = nil, nameLookup: @escaping ([Conversation]) -> [String: String] = MessagesNameResolver.resolve) throws {
        sendMessage = sender ?? { id, draft in _ = try Automation.run(Automation.sendScript, chat: id, text: draft) }
        let settings = (try? Data(contentsOf: root.appendingPathComponent("settings.json"))).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings(mode: .off)
        engine = try Engine(reader: Reader(path: database, nameLookup: nameLookup), store: CacheStore(root: root), settings: settings)
        updateWatchers()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "messages.reconciliation"))
        t.schedule(deadline: .now())
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t; t.resume(); engine.refresh()
    }
    static let reconcileInterval: TimeInterval = 15
    // Open conversations and pending send receipts need one-second ticks; otherwise only the
    // reconciliation pass runs, so an idle helper wakes every 15 seconds.
    func tick() {
        outgoing.expire()
        liveViews.expire()
        prepareLiveViews()
        control.lock(); defer { control.unlock() }
        if engine.configuration().mode != .off, Date().timeIntervalSince(lastReconcile) >= Self.reconcileInterval - 0.5 {
            lastReconcile = Date(); updateWatchers()
            // Watchers can miss events, so compare the database files; read only when they changed.
            let signature = databaseSignature()
            if signature != refreshedSignature { refreshedSignature = signature; engine.refresh() } else { engine.refresh(namesOnly: true) }
        }
        let busy = !liveViews.active().isEmpty || outgoing.hasReceipts
        timer?.schedule(deadline: .now() + (busy ? 1 : Self.reconcileInterval))
    }
    // Called after a view opens or a send is recorded, so fast ticks start without waiting out an idle interval.
    func wake() {
        control.lock(); defer { control.unlock() }
        timer?.schedule(deadline: .now() + 1)
    }
    func updateWatchers() {
        watchers.forEach { $0.cancel() }; watchers.removeAll()
        guard engine.configuration().mode != .off else { return }
        let path = engine.reader.path
        for file in [path, path + "-wal", URL(fileURLWithPath: path).deletingLastPathComponent().path] {
            let fd = Darwin.open(file, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                self?.scheduleRefresh()
                self?.prepareLiveViews()
            }
            source.setCancelHandler { close(fd) }; source.resume(); watchers.append(source)
        }
    }
    func scheduleRefresh() {
        control.lock(); defer { control.unlock() }
        debounce?.cancel()
        guard engine.configuration().mode != .off else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.control.lock(); self.refreshedSignature = self.databaseSignature(); self.control.unlock()
            self.engine.refresh()
        }
        debounce = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    func configure(_ request: Request) throws {
        control.lock(); defer { control.unlock() }
        let previous = engine.configuration()
        try engine.configure(request.settings)
        if previous != request.settings { liveViews.reconfigure(request.settings); updateWatchers(); engine.refresh() }
    }
    public func handle(_ request: Request) -> [String: Any] {
        if LiveInput.containsRefresh(request.draft) || LiveInput.containsRefresh(request.query) {
            var safe = request
            safe.refreshToken = LiveInput.refreshToken(request.draft) ?? LiveInput.refreshToken(request.query)
            safe.draft = ""; safe.query = ""; safe.operation = "auto-fetch"
            return handle(safe)
        }
        // Active-view polling must never reapply settings captured by an old driver.
        switch request.operation {
        case "auto-check", "auto-prepare":
            let pending = submissions.isPending(chat: request.chat)
            var state = liveViews.check(session: request.viewSession ?? "", chat: request.chat, prepare: request.operation == "auto-prepare" && !pending)
            if pending { state["changed"] = false; state["busy"] = true }
            return state
        case "auto-fetch": return liveViews.fetch(session: request.viewSession ?? "", chat: request.chat, token: request.refreshToken ?? "")
        case "auto-finish": return liveViews.finish(session: request.viewSession ?? "", chat: request.chat, token: request.refreshToken ?? "", accept: request.action == "accept")
        case "auto-result": return liveViews.result(session: request.viewSession ?? "", chat: request.chat, token: request.refreshToken ?? "")
        case "auto-fault": return liveViews.fault(session: request.viewSession ?? "", label: request.action)
        case "auto-note": return liveViews.note(label: request.action)
        default: break
        }
        do {
            try configure(request)
            switch request.operation {
            case "list":
                let (page, query) = Self.listQuery(request.query)
                var chats: [Conversation]; let names: [String: String]; let more: Bool
                if page == 1 {
                    guard let snapshot = try engine.get() else { return ["skipknowledge": true, "rerun": 0.5, "items": [["title": "Loading recent conversations…", "subtitle": "The helper is building the cache.", "valid": false]]] }
                    chats = snapshot.conversations; names = snapshot.names
                    more = chats.count >= engine.configuration().conversations
                } else {
                    let older = try engine.page(page)
                    chats = older.conversations; names = older.names; more = older.hasMore
                }
                // No query keeps recency order; a query orders by name match, then recency.
                if !query.isEmpty {
                    chats = chats.enumerated().compactMap { index, chat in
                        Render.matchRank(chat, names: names, query: query).map { (key: ($0.level, $0.source, index), chat: chat) }
                    }.sorted { $0.key < $1.key }.map(\.chat)
                }
                var items: [[String: Any]] = chats.map { chat in
                    var icon = "icon.png"
                    if request.settings.mode == .disk, let name = CacheStore.iconName(chat, names) {
                        let candidate = engine.store.directory.appendingPathComponent("avatars/" + name).path
                        if FileManager.default.fileExists(atPath: candidate) { icon = candidate }
                    }
                    let latest = chat.messages.last
                    let snippet = latest?.reaction ?? (latest?.text.isEmpty == false ? latest!.text : latest?.attachments.first ?? "Content unavailable")
                    return ["uid": chat.id, "title": Render.title(chat, names), "subtitle": String(snippet.prefix(160)).replacingOccurrences(of: "\n", with: " ") + " · " + Render.timestamp(chat.activity), "arg": "", "valid": true, "icon": ["path": icon], "variables": ["chat_id": chat.id, "submission_token": UUID().uuidString, "view_action": "history"], "mods": ["alt": ["subtitle": "Open Messages", "variables": ["chat_id": chat.id, "view_action": "open"]]]]
                }
                if items.isEmpty { items = [["title": page == 1 ? "No matching recent conversations" : (query.isEmpty ? "No older conversations" : "No matching conversations on this page"), "valid": false]] }
                // Paging rewrites Alfred's query to the next page marker; no uid, so Alfred never reorders it.
                if query.isEmpty && more {
                    let size = engine.configuration().conversations
                    items.append(["title": "More conversations…", "subtitle": "Show the next \(size) older conversations", "valid": false, "autocomplete": Self.pageMarker + String(page + 1) + " ", "icon": ["path": "more.png"]])
                }
                return ["skipknowledge": true, "items": items]
            case "history", "view": return try view(request)
            case "send":
                var sending = request; sending.action = "command-send"
                return try view(sending)
            case "open":
                var opening = request; opening.action = "open"
                return try view(opening)
            case "refresh": engine.refresh(); return ["status": "Refresh scheduled", "cache": engine.status()]
            case "configure": return ["cache": engine.status()]
            case "clear": try engine.clear(); outgoing.clear(); liveViews.removeAll(); MessagesNameResolver.resetMisses(); return ["status": "Cache cleared", "cache": engine.status()]
            case "diagnostics":
                control.lock(); let watcherCount = watchers.count; control.unlock()
                return ["cache": engine.status(), "watchers": watcherCount, "name_lookup": "Messages participant full names; raw handle fallback", "name_lookup_diagnostics": MessagesNameResolver.diagnostics(), "automatic_updates": liveViews.diagnostics()]
            case "benchmark": return ["benchmark": try engine.benchmark(), "cache": engine.status()]
            default: throw Failure("Unknown helper operation.")
            }
        } catch {
            if request.operation == "list" { return ["skipknowledge": true, "items": [["title": "Messages unavailable", "subtitle": String(describing: error), "valid": false]]] }
            if ["view", "history", "send", "open"].contains(request.operation) { return textResponse(request, content: "Unable to load history.", footer: String(describing: error), clear: false) }
            return ["error": String(describing: error)]
        }
    }
    static let pageMarker = "»"
    // "»N rest" selects page N of the recency list, and the rest searches within that page.
    // Anything else is page 1, so reopening msg always starts at the most recent chats.
    static func listQuery(_ raw: String) -> (page: Int, query: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(pageMarker) else { return (1, Render.fold(raw)) }
        let rest = text.dropFirst(pageMarker.count)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard let number = Int(digits.prefix(6)), number >= 1 else { return (1, Render.fold(raw)) }
        return (number, Render.fold(String(rest.dropFirst(digits.count))))
    }
    func controls(_ settings: Settings) -> String {
        (settings.sendKey == "return" ? "↩ Send" : "⌘↩ Send; ↩ preserves draft") + " · ⌥↩ Open Messages"
    }
    func prepareLiveViews() {
        control.lock()
        guard !livePreparing else { control.unlock(); return }
        livePreparing = true; control.unlock()
        liveWork.async { [weak self] in
            guard let self else { return }
            defer { self.control.lock(); self.livePreparing = false; self.control.unlock() }
            // Skip unchanged views; a periodic pass still picks up receipt expiry and name retries.
            let signature = self.databaseSignature()
            let views = self.liveViews.active()
            self.prepared = self.prepared.filter { entry in views.contains { $0.id == entry.key } }
            for view in views {
                if let last = self.prepared[view.id], last.signature == signature, last.generation == view.generation, Date().timeIntervalSince(last.at) < 5 { continue }
                self.prepared[view.id] = nil
                do {
                    let snapshot = try self.engine.reader.read(view.settings, contacts: false, chatID: view.chat, onRead: { db in
                        try self.outgoing.reconcile(chat: view.chat, reader: self.engine.reader, database: db)
                    })
                    guard let chat = snapshot.conversations.first else { throw Failure("Active chat unavailable") }
                    let retained = self.engine.knownNames()
                    var names = MessagesNameResolver.merge(view.names, retained)
                    if !MessagesNameResolver.missing([chat], names: names).isEmpty, self.liveViews.claimNameLookup(for: view) {
                        names = MessagesNameResolver.merge(names, self.engine.reader.names(for: [chat]))
                    }
                    self.liveViews.rememberNames(names, for: view)
                    let footer = self.outgoing.status(token: view.token, chat: view.chat).map { $0 + " " } ?? ""
                    let frame = LiveFrame(content: Render.history(self.outgoing.overlay(chat, limit: view.settings.messages), names: names), footer: view.footerOverride ?? (footer + self.controls(view.settings)))
                    self.liveViews.publish(frame, for: view)
                    self.prepared[view.id] = (signature, view.generation, Date())
                } catch { self.liveViews.publish(nil, for: view) }
            }
        }
    }
    func databaseSignature() -> String {
        [engine.reader.path, engine.reader.path + "-wal"].map { path -> String in
            var info = stat()
            guard stat(path, &info) == 0 else { return "-" }
            return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        }.joined(separator: "|")
    }
    func textResponse(_ request: Request, content: String, footer: String, clear: Bool, token: String? = nil) -> [String: Any] {
        ["response": content, "footer": footer, "behaviour": ["response": "replace", "scroll": "end", "inputfield": clear ? "clear" : "select"], "variables": ["chat_id": request.chat, "submission_token": token ?? request.token, "view_action": "", "view_loaded": "1"]]
    }
    func view(_ request: Request) throws -> [String: Any] {
        let controls = controls(request.settings)
        var footer = controls
        var clear = false; var token = request.token
        var sendFailed = false
        let action = request.action
        let retainedNames = MessagesNameResolver.merge(liveViews.names(session: request.viewSession, chat: request.chat), engine.knownNames())
        let wantsSend = action == "command-send" || (action == "return-send" && request.settings.sendKey == "return")
        if action == "refresh" { footer = "Fresh history requested. " + footer }
        if action == "open" { footer = try automation.sync { try Automation.run(Automation.openScript, chat: request.chat) } }
        if wantsSend && !request.draft.isEmpty {
            do {
                // Resolve the GUID in the read-only DB first; automation independently resolves the same exact ID.
                let db = try Database(path: engine.reader.path)
                guard try db.rows("SELECT guid FROM chat WHERE guid=?", [request.chat]).count == 1 else { throw Failure("Selected conversation no longer exists.") }
                let boundary = try engine.reader.outgoingBoundary(chatID: request.chat)
                try submissions.submit(chat: request.chat, draft: request.draft, token: request.token) {
                    try automation.sync { try sendMessage(request.chat, request.draft) }
                }
                clear = true; token = UUID().uuidString
                footer = "Submitted to Messages. " + footer
                outgoing.record(token: token, chat: request.chat, text: request.draft, boundary: boundary)
                engine.refresh()
            } catch { sendFailed = true; footer = String(describing: error) }
        }
        // A successful submission must clear the draft even if the subsequent history read fails.
        do {
            var snapshot = try engine.reader.read(request.settings, contacts: false, chatID: request.chat, onRead: { db in
                try self.outgoing.reconcile(chat: request.chat, reader: self.engine.reader, database: db)
            })
            snapshot.names = retainedNames
            if !wantsSend && !MessagesNameResolver.missing(snapshot.conversations, names: snapshot.names).isEmpty {
                snapshot.names = MessagesNameResolver.merge(snapshot.names, engine.reader.names(for: snapshot.conversations))
            }
            if let chat = snapshot.conversations.first(where: { $0.id == request.chat }) {
                if action != "open", (!wantsSend || clear), let status = outgoing.status(token: token, chat: request.chat) {
                    footer = status + " " + controls
                } else if action != "open", !wantsSend, let delivery = chat.messages.last(where: { $0.sender == "Me" })?.delivery {
                    footer = "Latest outgoing message: " + delivery.rawValue.capitalized + ". " + controls
                }
                let displayed = outgoing.overlay(chat, limit: request.settings.messages)
                let content = Render.history(displayed, names: snapshot.names)
                let (session, revision) = liveViews.register(session: request.viewSession, chat: request.chat, settings: request.settings, names: snapshot.names, token: token, frame: LiveFrame(content: content, footer: footer), footerOverride: sendFailed ? footer : nil)
                wake()
                var result = textResponse(request, content: LiveInput.identifiedHistory(content, session: session), footer: footer, clear: clear, token: token)
                var variables = result["variables"] as! [String: String]
                variables["view_session"] = session; variables["live_revision"] = String(revision)
                result["variables"] = variables
                return result
            }
            return textResponse(request, content: "Selected conversation no longer exists.", footer: footer, clear: clear, token: token)
        } catch {
            if let snapshot = try? engine.get(), let chat = snapshot.conversations.first(where: { $0.id == request.chat }) {
                return textResponse(request, content: Render.history(outgoing.overlay(chat, limit: request.settings.messages), names: snapshot.names), footer: footer + " · Fresh history unavailable: " + String(describing: error), clear: clear, token: token)
            }
            return ["footer": footer + " · History unavailable: " + String(describing: error), "behaviour": ["inputfield": clear ? "clear" : "select"], "variables": ["view_action": "", "chat_id": request.chat, "submission_token": token]]
        }
    }
}
