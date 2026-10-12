import Foundation
import AppKit
import CryptoKit
import Darwin

public final class CacheStore {
    public let root: URL
    public var directory: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public init(root: URL) { self.root = root }
    public func purge() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("snapshot.json")) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    public static func atomic(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure("Cannot create private cache file.") }
        defer { try? FileManager.default.removeItem(at: temp) }
        guard rename(temp.path, url.path) == 0 else { throw Failure("Cannot atomically update cache.") }
    }
    public func save(_ snapshot: Snapshot) throws {
        try Self.atomic(JSONEncoder().encode(snapshot), to: directory.appendingPathComponent("snapshot.json"))
        let icons = directory.appendingPathComponent("avatars", isDirectory: true)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var retained = Set<String>()
        for chat in snapshot.conversations {
            // Chats without a contact name or group title use the bundled icon instead.
            guard let filename = Self.iconName(chat, snapshot.names) else { continue }
            let initials = Self.initials(chat, snapshot.names); retained.insert(filename)
            let target = icons.appendingPathComponent(filename)
            // The file name covers the initials, so a resolved name produces a new avatar.
            if FileManager.default.fileExists(atPath: target.path) { continue }
            // Avatars contain initials only and exist only in disk mode.
            let image = NSImage(size: NSSize(width: 128, height: 128))
            image.lockFocus()
            NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 124, height: 124)).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .semibold), .foregroundColor: NSColor.white]
            let text = NSAttributedString(string: initials, attributes: attrs)
            let size = text.size(); text.draw(at: NSPoint(x: (128-size.width)/2, y: (128-size.height)/2))
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try Self.atomic(png, to: target) }
        }
        for url in (try? FileManager.default.contentsOfDirectory(at: icons, includingPropertiesForKeys: nil)) ?? [] where !retained.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
    }
    // Initials come from the group title or resolved contact names only; raw phone numbers and
    // addresses would give initials like "+(".
    public static func initials(_ chat: Conversation, _ names: [String: String]) -> String {
        let source = chat.title.isEmpty ? chat.participants.compactMap { names[$0] }.joined(separator: ", ") : chat.title
        return source.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap(\.first).filter { $0.isLetter || $0.isNumber }.prefix(2).map(String.init).joined().uppercased()
    }
    public static func avatarName(_ id: String, initials: String) -> String { SHA256.hash(data: Data((id + "\u{0}" + initials).utf8)).map { String(format: "%02x", $0) }.joined() + ".png" }
    public static func iconName(_ chat: Conversation, _ names: [String: String]) -> String? { let value = initials(chat, names); return value.isEmpty ? nil : avatarName(chat.id, initials: value) }
}

public final class Engine {
    private let lock = NSRecursiveLock()
    private let work = DispatchQueue(label: "messages.reader", qos: .utility)
    public let reader: Reader; public let store: CacheStore
    private var settings: Settings; private var snapshot: Snapshot?
    private var generation = 0; private var refreshing = false; private var refreshRequested = false; private var lastError: String?
    private var lastFullNameLookup = Date.distantPast
    /// Background refreshes resolve missing names only when this allows it, so they do not launch Messages.
    public var backgroundNameLookup: () -> Bool = MessagesNameResolver.messagesRunning
    public init(reader: Reader, store: CacheStore, settings: Settings) throws {
        self.reader = reader; self.store = store; self.settings = settings
        if settings.mode == .disk {
            snapshot = store.load(); snapshot?.trim(settings)
            // A failed rewrite leaves the in-memory snapshot usable, as in publish().
            if let snapshot { do { try store.save(snapshot) } catch { lastError = "Cache write failed. Data is available in memory." } }
        }
        else { try store.purge() }
    }
    public func retainedNames() -> [String: String] { lock.lock(); defer { lock.unlock() }; return settings.mode == .off ? [:] : (snapshot?.names ?? [:]) }
    /// Retained names plus those found for older pages; for display and lookups of a selected chat.
    public func knownNames() -> [String: String] { lock.lock(); defer { lock.unlock() }; return settings.mode == .off ? [:] : MessagesNameResolver.merge(pageNames, snapshot?.names ?? [:]) }
    // Older pages are read on demand and never stored. Names found for them stay in memory only,
    // and seed the snapshot if one of those chats becomes recent.
    private var pageNames: [String: String] = [:]
    public struct Page { public var conversations: [Conversation]; public var names: [String: String]; public var hasMore: Bool }
    /// Page 2 onward of the recency list, returned with names already resolved so the page appears once.
    /// Names are looked up only while Messages is running (as for background refreshes), so paging never
    /// launches it; chats that recently resolved no name are skipped by the resolver's miss throttle.
    public func page(_ number: Int) throws -> Page {
        let current = configuration(); let size = current.conversations
        let off = current.mode == .off
        // One extra chat tells whether another page exists.
        let value = try reader.read(current, contacts: off, offset: (max(1, number) - 1) * size, limit: size + 1)
        let chats = Array(value.conversations.prefix(size)); let hasMore = value.conversations.count > size
        // Off mode keeps no names between requests, so it resolves synchronously as the first page does.
        if off { return Page(conversations: chats, names: value.names, hasMore: hasMore) }
        lock.lock(); var names = MessagesNameResolver.merge(pageNames, snapshot?.names ?? [:]); let revision = generation; lock.unlock()
        let due = chats.filter { !MessagesNameResolver.missing([$0], names: names).isEmpty }
        if !due.isEmpty, backgroundNameLookup() {
            let found = reader.names(for: due)
            names = MessagesNameResolver.merge(names, found)
            lock.lock(); if revision == generation, settings.mode != .off { pageNames = MessagesNameResolver.merge(pageNames, found) }; lock.unlock()
        }
        return Page(conversations: chats, names: names, hasMore: hasMore)
    }
    public func configuration() -> Settings { lock.lock(); defer { lock.unlock() }; return settings }
    public func configure(_ next: Settings) throws {
        lock.lock(); defer { lock.unlock() }
        guard next != settings else { return }
        generation += 1
        if next.mode != .disk { try store.purge() }
        if next.mode != settings.mode { snapshot = nil; pageNames = [:] }
        settings = next; snapshot?.trim(next)
        if next.mode == .disk, let snapshot { try store.save(snapshot) }
        try CacheStore.atomic(JSONEncoder().encode(next), to: store.root.appendingPathComponent("settings.json"))
        lastError = nil
    }
    public func clear() throws {
        lock.lock(); defer { lock.unlock() }; generation += 1; snapshot = nil; lastError = nil; pageNames = [:]; try store.purge()
    }
    /// `namesOnly` reuses the cached chats instead of reading the database (the caller saw no database
    /// change), so only the background name pass runs. It falls back to a full read without a good snapshot.
    public func refresh(namesOnly: Bool = false) {
        lock.lock()
        guard settings.mode != .off else { lock.unlock(); return }
        // A request during a scan is remembered, so a change seen mid-scan gets its own read.
        guard !refreshing else { if !namesOnly { refreshRequested = true }; lock.unlock(); return }
        refreshing = true; refreshRequested = false
        let current = settings; let revision = generation
        let cached = namesOnly && lastError == nil ? snapshot : nil
        lock.unlock()
        work.async { [self] in
            do {
                var value: Snapshot
                if let cached { value = cached; value.names = [:] }
                else { value = try reader.read(current, contacts: false); publish(value, revision: revision) }
                // Look up only chats with handles still lacking a retained name, plus an
                // occasional full pass so renamed contacts are picked up.
                let known = retainedNames()
                lock.lock()
                let full = Date().timeIntervalSince(lastFullNameLookup) >= 900
                lock.unlock()
                let wanted = full ? value.conversations : value.conversations.filter { !MessagesNameResolver.missing([$0], names: known).isEmpty }
                if !wanted.isEmpty, backgroundNameLookup() {
                    if full { lock.lock(); lastFullNameLookup = Date(); lock.unlock() }
                    value.names = reader.names(for: wanted)
                    if !value.names.isEmpty { publish(value, revision: revision) }
                }
            } catch {
                lock.lock(); if revision == generation { lastError = String(describing: error) }; lock.unlock()
            }
            lock.lock(); refreshing = false; let changed = revision != generation || refreshRequested; lock.unlock()
            if changed { refresh() }
        }
    }
    private func publish(_ value: Snapshot, revision: Int) {
        lock.lock(); defer { lock.unlock() }
        guard revision == generation, settings.mode != .off else { return }
        var merged = value
        merged.names = MessagesNameResolver.merge(MessagesNameResolver.merge(pageNames, snapshot?.names ?? [:]), value.names)
        merged.trim(settings)
        // Rewrite the disk cache only when its content changed (or the last write failed).
        let unchanged = lastError == nil && snapshot.map { $0.conversations == merged.conversations && $0.names == merged.names } == true
        snapshot = merged; lastError = nil
        if settings.mode == .disk, !unchanged { do { try store.save(merged) } catch { lastError = "Cache write failed. Data is available in memory." } }
    }
    public func refreshNow() throws {
        lock.lock()
        let current = settings
        generation += 1; let revision = generation
        lock.unlock()
        guard current.mode != .off else { return }
        let value = try reader.read(current)
        publish(value, revision: revision)
    }
    public func get() throws -> Snapshot? {
        lock.lock(); let current = settings; let value = snapshot; let error = lastError; lock.unlock()
        if current.mode == .off { return try reader.read(current) }
        if value == nil { refresh(); if let error { throw Failure(error) } }
        return value
    }
    public func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["mode": settings.mode.rawValue, "conversations": snapshot?.conversations.count ?? 0, "messages": snapshot?.conversations.reduce(0) { $0 + $1.messages.count } ?? 0, "refreshing": refreshing, "updated": snapshot.map { ISO8601DateFormatter().string(from: $0.updated) } ?? "never", "disk_cache_exists": FileManager.default.fileExists(atPath: store.directory.path), "error": lastError ?? ""]
    }
    public func benchmark(iterations: Int = 20) throws -> [[String: Any]] {
        // Isolated cache simulations. Never change the active engine, drafts, watcher or privacy policy.
        // Runs without the engine lock and without name lookups, so it measures reader/render only.
        let config = configuration()
        var reports: [[String: Any]] = []
        for mode in CacheMode.allCases {
            var retained: Snapshot?
            var times: [Double] = []
            let start = CFAbsoluteTimeGetCurrent()
            let cold = try reader.read(config, contacts: false)
            _ = cold.conversations.map { Render.history($0, names: cold.names) }
            var coldMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let file = store.directory.appendingPathComponent("benchmark.json")
            defer { try? FileManager.default.removeItem(at: file) }
            if mode != .off { retained = cold }
            let actualDisk = mode == .disk && config.mode == .disk
            if actualDisk {
                // Hold the lock only for the file, so a concurrent switch away from disk cannot race the write.
                lock.lock(); defer { lock.unlock() }
                guard settings.mode == .disk else { throw Failure("Cache mode changed during benchmark.") }
                try CacheStore.atomic(JSONEncoder().encode(cold), to: file); retained = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file)); coldMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
                try? FileManager.default.removeItem(at: file)
            }
            for _ in 0..<iterations {
                let t = CFAbsoluteTimeGetCurrent()
                let value = try retained ?? reader.read(config, contacts: false)
                let payload = value.conversations.map { Render.history($0, names: value.names) }
                _ = try JSONEncoder().encode(payload)
                times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            }
            times.sort()
            reports.append(["mode": mode.rawValue, "cold_ms": coldMS, "warm_p50_ms": times[times.count/2], "warm_p95_ms": times[min(times.count-1, Int(Double(times.count)*0.95))], "iterations": iterations, "disk_io": actualDisk, "note": mode == .disk && !actualDisk ? "Disk persistence simulated in memory to respect active policy" : "Helper reader/render timings; IPC and Alfred excluded", "conversation_limit": config.conversations, "message_limit": config.messages])
        }
        return reports
    }
}
