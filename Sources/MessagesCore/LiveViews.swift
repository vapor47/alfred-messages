import Foundation

// An invisible refresh suffix lets the existing Script Input distinguish driver-initiated
// execution from a physical send, even after helper restart. No content is encoded here.
public enum LiveInput {
    public static let refreshPrefix = "\u{2063}\u{2064}"
    private static let alphabet: [UnicodeScalar] = [0x200b, 0x200c, 0x200d, 0xfeff].map { UnicodeScalar($0)! }
    private static func encoded(_ token: String) -> String? {
        guard UUID(uuidString: token) != nil else { return nil }
        let hex = token.replacingOccurrences(of: "-", with: "").lowercased()
        return hex.map { char -> String in
            let value = Int(String(char), radix: 16)!
            return String(alphabet[value / 4]) + String(alphabet[value % 4])
        }.joined()
    }
    public static func refreshMarker(_ token: String) -> String { refreshPrefix + (encoded(token) ?? "") + "\u{2064}\u{2063}" }
    // A normal conversation heading carries session identity in its link destination,
    // not in visible text or zero-width characters that AX may omit.
    public static func viewMarker(_ session: String) -> String {
        "alfred-messages-view://" + session.lowercased()
    }
    public static func identifiedHistory(_ content: String, session: String) -> String {
        guard content.hasPrefix("# "), let end = content.firstIndex(of: "\n") else { return content }
        let title = String(content[content.index(content.startIndex, offsetBy: 2)..<end])
        return "# [" + title + "](" + viewMarker(session) + ")" + content[end...]
    }
    public static func containsRefresh(_ text: String) -> Bool { text.contains(refreshPrefix) }
    public static func refreshToken(_ text: String) -> String? {
        guard let start = text.range(of: refreshPrefix) else { return nil }
        let chars = Array(text[start.upperBound...].unicodeScalars.prefix(64))
        guard chars.count == 64 else { return nil }
        var hex = ""
        for i in stride(from: 0, to: 64, by: 2) {
            guard let a = alphabet.firstIndex(of: chars[i]), let b = alphabet.firstIndex(of: chars[i+1]) else { return nil }
            hex += String(a*4+b, radix: 16)
        }
        let c = Array(hex)
        let parts: [String] = [String(c[0..<8]), String(c[8..<12]), String(c[12..<16]), String(c[16..<20]), String(c[20..<32])]
        let formatted = parts.joined(separator: "-")
        return UUID(uuidString: formatted)?.uuidString
    }
}

struct LiveFrame: Equatable {
    var content: String
    var footer: String
}
final class LiveViews {
    struct View {
        let id: String
        let chat: String
        var settings: Settings
        var names: [String: String]
        var token: String
        var heartbeat: Date
        var generation = 0
        var revision = 0
        var displayed = 0
        var frame: LiveFrame
        var displayedFrame: LiveFrame
        var leases: [String: (frame: LiveFrame, revision: Int, expiry: Date)] = [:]
        var unavailable = false
        var lastNameAttempt = Date.distantPast
        var footerOverride: String?
    }
    private let lock = NSLock()
    private var views: [String: View] = [:]
    private var failures: [String: Int] = [:]
    private var published = 0
    private var fetched = 0
    private var accepted = 0
    private var pending: [String: (frame: LiveFrame, revision: Int, generation: Int)] = [:]
    private var acknowledgements: [String: (session: String, chat: String, success: Bool, finalized: Bool, expiry: Date)] = [:]
    func fault(session: String, label: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        failures[label, default: 0] += 1
        if var view = views[session] { view.unavailable = true; views[session] = view }
        return ["paused": true]
    }
    // A recovered cycle: count it without pausing the view, since nothing was dispatched.
    func note(label: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        failures["retried-" + label, default: 0] += 1
        return ["paused": false]
    }
    func diagnostics() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["active_views": views.count, "frames_prepared": published, "frames_returned": fetched, "frames_accepted": accepted, "failures": failures]
    }
    func reconfigure(_ settings: Settings) {
        lock.lock(); defer { lock.unlock() }
        for id in Array(views.keys) {
            if views[id]!.settings != settings { views[id]!.settings = settings; views[id]!.generation += 1; views[id]!.leases.removeAll() }
        }
    }
    func expire() {
        lock.lock(); defer { lock.unlock() }
        views = views.filter { Date().timeIntervalSince($0.value.heartbeat) < 6 }
        acknowledgements = acknowledgements.filter { $0.value.expiry > Date() }
        pending = pending.filter { acknowledgements[$0.key] != nil }
    }
    func register(session: String?, chat: String, settings: Settings, names: [String: String], token: String, frame: LiveFrame, footerOverride: String? = nil) -> (String, Int) {
        lock.lock(); defer { lock.unlock() }
        var view: View
        if let session, let old = views[session], old.chat == chat {
            view = old; view.generation += 1
            if view.frame != frame { view.revision += 1 }
            view.frame = frame; view.displayedFrame = frame; view.displayed = view.revision
            view.settings = settings; view.names = MessagesNameResolver.merge(view.names, names); view.token = token; view.heartbeat = Date(); view.unavailable = false
            view.leases.removeAll()
        } else {
            let id = UUID().uuidString
            view = View(id: id, chat: chat, settings: settings, names: names, token: token, heartbeat: Date(), frame: frame, displayedFrame: frame)
        }
        view.footerOverride = footerOverride
        views[view.id] = view
        return (view.id, view.revision)
    }
    func names(session: String?, chat: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard let session, let view = views[session], view.chat == chat else { return [:] }
        return view.names
    }
    func claimNameLookup(for expected: View) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var view = views[expected.id], view.generation == expected.generation,
              Date().timeIntervalSince(view.lastNameAttempt) >= 30 else { return false }
        view.lastNameAttempt = Date(); views[view.id] = view; return true
    }
    func rememberNames(_ names: [String: String], for expected: View) {
        lock.lock(); defer { lock.unlock() }
        guard var view = views[expected.id], view.generation == expected.generation else { return }
        view.names = MessagesNameResolver.merge(view.names, names); views[view.id] = view
    }
    func active() -> [View] {
        lock.lock(); defer { lock.unlock() }
        return views.values.filter { Date().timeIntervalSince($0.heartbeat) < 6 }
    }
    func publish(_ frame: LiveFrame?, for expected: View) {
        lock.lock(); defer { lock.unlock() }
        guard var current = views[expected.id], current.generation == expected.generation else { return }
        if let frame {
            if current.frame != frame { current.revision += 1; current.frame = frame; published += 1 }
            current.unavailable = false
        } else { current.unavailable = true }
        views[current.id] = current
    }
    func check(session: String, chat: String, prepare: Bool) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard var view = views[session], view.chat == chat else { return ["error": "Active view unavailable", "changed": false] }
        view.heartbeat = Date()
        view.leases = view.leases.filter { $0.value.expiry > Date() }
        var value: [String: Any] = ["changed": view.revision > view.displayed, "revision": view.revision, "unavailable": view.unavailable]
        if prepare && !view.unavailable && view.revision > view.displayed {
            let token = UUID().uuidString
            view.leases[token] = (view.frame, view.revision, Date().addingTimeInterval(3))
            value["refresh_token"] = token
        }
        views[session] = view
        return value
    }
    func result(session: String, chat: String, token: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let result = acknowledgements[token], result.session == session, result.chat == chat else { return ["success": false, "known": false] }
        return ["success": result.success && result.finalized, "known": true, "finalized": result.finalized]
    }
    func fetch(session: String, chat: String, token: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if UUID(uuidString: token) != nil, acknowledgements[token] == nil { acknowledgements[token] = (session, chat, false, false, Date().addingTimeInterval(35)) }
        guard var view = views[session], view.chat == chat,
              let lease = view.leases.removeValue(forKey: token), lease.expiry > Date(), !view.unavailable,
              lease.revision > view.displayed else {
            failures["frame-rejected", default: 0] += 1
            if var failed = views[session], failed.chat == chat {
                failed.leases.removeValue(forKey: token); views[session] = failed
            }
            return ["footer": "Automatic update unavailable; existing history retained." + LiveInput.refreshMarker(token),
                    "behaviour": ["inputfield": "select"], "variables": ["view_action": ""], "update_failed": true]
        }
        var result: [String: Any] = ["footer": lease.frame.footer + LiveInput.refreshMarker(token),
                                   "variables": ["view_session": session, "chat_id": chat, "submission_token": view.token, "view_action": "", "live_revision": String(lease.revision)]]
        // This view returns the complete bounded transcript, without an append segment.
        // Replace its contents in place; replacelast is for an explicitly appended segment.
        if lease.frame.content != view.displayedFrame.content {
            result["response"] = LiveInput.identifiedHistory(lease.frame.content, session: session)
            result["behaviour"] = ["response": "replace", "inputfield": "select"]
        } else { result["behaviour"] = ["inputfield": "select"] }
        fetched += 1
        acknowledgements[token] = (session, chat, true, false, Date().addingTimeInterval(35))
        pending[token] = (lease.frame, lease.revision, view.generation)
        view.heartbeat = Date()
        views[session] = view
        return result
    }
    func finish(session: String, chat: String, token: String, accept: Bool) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        // A frontend can reject after transport failure or helper restart. Record
        // completion of that parsed request without inventing a successful fetch.
        if acknowledgements[token] == nil, !accept, UUID(uuidString: token) != nil {
            acknowledgements[token] = (session, chat, false, true, Date().addingTimeInterval(35))
            failures["frontend-not-accepted", default: 0] += 1
        }
        guard var ack = acknowledgements[token], ack.session == session, ack.chat == chat else { return ["success": false] }
        if ack.finalized { return ["success": ack.success] }
        let frame = pending.removeValue(forKey: token)
        var applied = false
        if accept, ack.success, let frame, var view = views[session], view.chat == chat,
           view.generation == frame.generation, frame.revision > view.displayed {
            view.displayed = frame.revision; view.displayedFrame = frame.frame; view.heartbeat = Date()
            views[session] = view; accepted += 1; applied = true
        }
        ack.success = applied; ack.finalized = true; acknowledgements[token] = ack
        if !applied { failures["frontend-not-accepted", default: 0] += 1 }
        return ["success": applied]
    }
    func removeAll() { lock.lock(); defer { lock.unlock() }; views.removeAll(); acknowledgements.removeAll(); pending.removeAll() }
}
