import Foundation
import AppKit
import CSQLite
import CryptoKit

public final class Database {
    private var db: OpaquePointer?
    public init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; db = nil
            throw Failure("Messages database unavailable. Grant Full Disk Access to Messages Helper, then restart it.")
        }
        sqlite3_busy_timeout(db, 1500)
        _ = try rows("PRAGMA query_only=ON")
    }
    deinit { sqlite3_close(db) }
    public func rows(_ sql: String, _ values: [String] = []) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure("Unsupported Messages schema or query failure.") }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() { _ = value.withCString { sqlite3_bind_text(statement, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
        var result: [[String: Any]] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, i))
                case SQLITE_BLOB:
                    if let ptr = sqlite3_column_blob(statement, i) { row[name] = Data(bytes: ptr, count: Int(sqlite3_column_bytes(statement, i))) }
                default: break
                }
            }
            result.append(row); step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw Failure("Messages read interrupted or database busy. Refresh to try again.") }
        return result
    }
    func columns(_ table: String) throws -> Set<String> { Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"] as? String }) }
}
public final class Reader {
    public let path: String
    let lookupNames: ([Conversation]) -> [String: String]
    public init(path: String = NSHomeDirectory() + "/Library/Messages/chat.db", nameLookup: @escaping ([Conversation]) -> [String: String] = { _ in [:] }) {
        self.path = path; self.lookupNames = nameLookup
    }
    public func names(for conversations: [Conversation]) -> [String: String] { lookupNames(conversations) }
    public static func date(_ raw: Int64) -> Date { Date(timeIntervalSince1970: 978307200 + (abs(raw) > 100_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw))) }
    public static func attributedText(_ data: Data) -> String? {
        // Modern NSKeyedArchiver bodies. Legacy typedstreams are decoded below without executing archived classes.
        if let object = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) { return object.string }
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard let found = data.range(of: Data(marker)) else { return nil }
        let start = found.lowerBound - data.startIndex
        // Typedstream NSString payload starts at + after its class/object descriptors.
        let end = min(bytes.count, start + 100)
        guard let plus = (start + marker.count..<end).first(where: { bytes[$0] == 0x2b }), plus + 1 < bytes.count else { return nil }
        var index = plus + 1
        var count = Int(bytes[index]); index += 1
        if count == 0x81 { guard index + 2 <= bytes.count else { return nil }; count = Int(bytes[index]) | Int(bytes[index + 1]) << 8; index += 2 }
        else if count == 0x82 { guard index + 4 <= bytes.count else { return nil }; count = (0..<4).reduce(0) { $0 | Int(bytes[index + $1]) << (8 * $1) }; index += 4 }
        guard count >= 0, index + count <= bytes.count else { return nil }
        return String(data: Data(bytes[index..<index + count]), encoding: .utf8)
    }
    public static func delivery(_ row: [String: Any]) -> DeliveryStatus? {
        guard (row["is_from_me"] as? Int64) == 1 else { return nil }
        if (row["error"] as? Int64 ?? 0) != 0 { return .failed }
        if (row["is_delivered"] as? Int64 ?? 0) == 1 || (row["date_delivered"] as? Int64 ?? 0) > 0 || (row["date_read"] as? Int64 ?? 0) > 0 { return .delivered }
        if (row["is_sent"] as? Int64 ?? 0) == 1 { return .sent }
        return nil
    }
    static let reactionLabels = ["Loved", "Liked", "Disliked", "Laughed", "Emphasized", "Questioned"]
    public static func reaction(type: Int, emoji: String?) -> String? {
        let emoji = emoji.flatMap { $0.isEmpty ? nil : $0 }
        if (2000...2005).contains(type) { return reactionLabels[type - 2000] }
        if (3000...3005).contains(type) { return "Removed " + reactionLabels[type - 3000].lowercased() + " reaction" }
        // Emoji tapbacks store the emoji in a separate column.
        if type == 2006, let emoji { return "Reacted " + emoji }
        if type == 3006, let emoji { return "Removed " + emoji + " reaction" }
        return type >= 2000 ? "Reaction (\(type))" : nil
    }
    public func outgoingBoundary(chatID: String) throws -> Int64 {
        let db = try Database(path: path)
        return try db.rows("SELECT MAX(m.ROWID) AS boundary FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id WHERE c.guid=?", [chatID]).first?["boundary"] as? Int64 ?? 0
    }
    // Identity candidates are independent of the visible history limit, so a burst cannot hide a receipt.
    public func outgoingCandidates(chatID: String, after boundary: Int64, database: Database? = nil) throws -> [[String: Any]] {
        let db = try database ?? Database(path: path)
        let columns = try db.columns("message")
        let optional = ["attributedBody", "is_sent", "is_delivered", "date_delivered", "date_read", "error"].filter(columns.contains).map { "m.\($0)" }.joined(separator: ",")
        return try db.rows("SELECT m.ROWID AS rowid,m.guid,m.text,m.is_from_me\(optional.isEmpty ? "" : "," + optional) FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id WHERE c.guid=? AND m.ROWID>? AND m.is_from_me=1 ORDER BY m.ROWID", [chatID, String(boundary)])
    }
    public func read(_ settings: Settings, contacts: Bool = true, chatID: String? = nil, offset: Int = 0, limit: Int? = nil, onRead: ((Database) throws -> Void)? = nil) throws -> Snapshot {
        let db = try Database(path: path)
        _ = try db.rows("BEGIN DEFERRED TRANSACTION")
        defer { _ = try? db.rows("ROLLBACK") }
        let columns = try db.columns("message")
        guard ["guid", "date", "text", "is_from_me", "handle_id"].allSatisfy(columns.contains) else { throw Failure("Unsupported Messages message schema.") }
        // Modern schemas denormalize message dates into the join table; avoid touching every message row.
        let joinDate = try db.columns("chat_message_join").contains("message_date")
        let chats = try db.rows("""
          SELECT c.ROWID AS rowid, c.guid, c.display_name, \(joinDate ? "MAX(j.message_date)" : "MAX(m.date)") AS activity
          FROM chat c LEFT JOIN chat_message_join j ON j.chat_id=c.ROWID \(joinDate ? "" : "LEFT JOIN message m ON m.ROWID=j.message_id")
          \(chatID == nil ? "" : "WHERE c.guid=?")
          GROUP BY c.ROWID ORDER BY activity DESC, c.ROWID DESC LIMIT \(chatID == nil ? max(1, limit ?? settings.conversations) : 1) OFFSET \(chatID == nil ? max(0, offset) : 0)
          """, chatID.map { [$0] } ?? [])
        var result: [Conversation] = []
        for c in chats {
            guard let rowID = c["rowid"] as? Int64, let guid = c["guid"] as? String else { continue }
            let participants = try db.rows("SELECT h.id FROM handle h JOIN chat_handle_join j ON j.handle_id=h.ROWID WHERE j.chat_id=? ORDER BY h.id", [String(rowID)]).compactMap { $0["id"] as? String }
            let optional = ["attributedBody", "associated_message_type", "associated_message_guid", "associated_message_emoji", "is_sent", "is_delivered", "date_delivered", "date_read", "error"].filter(columns.contains).map { "m.\($0)" }.joined(separator: ",")
            let rows = try db.rows("SELECT m.ROWID AS rowid,m.guid,m.text,m.date,m.is_from_me,h.id AS sender\(optional.isEmpty ? "" : "," + optional) FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID LEFT JOIN handle h ON h.ROWID=m.handle_id WHERE j.chat_id=? ORDER BY m.date DESC,m.ROWID DESC LIMIT \(settings.messages)", [String(rowID)])
            // One attachment query per chat rather than per message.
            let ids = rows.map { String($0["rowid"] as? Int64 ?? 0) }
            var attachmentsByMessage: [Int64: [String]] = [:]
            if !ids.isEmpty {
                for a in try db.rows("SELECT j.message_id AS message_id,a.transfer_name,a.mime_type FROM attachment a JOIN message_attachment_join j ON j.attachment_id=a.ROWID WHERE j.message_id IN (\(ids.map { _ in "?" }.joined(separator: ","))) ORDER BY j.message_id,a.ROWID", ids) {
                    attachmentsByMessage[a["message_id"] as? Int64 ?? 0, default: []].append((a["transfer_name"] as? String) ?? (a["mime_type"] as? String) ?? "Attachment")
                }
            }
            var messages: [Message] = []
            for m in rows.reversed() {
                let attachments = attachmentsByMessage[m["rowid"] as? Int64 ?? 0] ?? []
                let reaction = Self.reaction(type: Int(m["associated_message_type"] as? Int64 ?? 0), emoji: m["associated_message_emoji"] as? String)
                let rawTarget = m["associated_message_guid"] as? String
                let target = rawTarget?.split(separator: "/").last.map(String.init)
                let plain = m["text"] as? String ?? ""
                let body = plain.isEmpty ? ((m["attributedBody"] as? Data).flatMap(Self.attributedText) ?? "") : plain
                messages.append(Message(guid: m["guid"] as? String ?? "", sender: (m["is_from_me"] as? Int64) == 1 ? "Me" : (m["sender"] as? String ?? "Unknown"), date: Self.date(m["date"] as? Int64 ?? 0), text: body, attachments: attachments, reaction: reaction, target: target, delivery: Self.delivery(m)))
            }
            result.append(Conversation(rowID: rowID, id: guid, title: c["display_name"] as? String ?? "", participants: participants, messages: messages, activity: Self.date(c["activity"] as? Int64 ?? 0)))
        }
        try onRead?(db)
        _ = try db.rows("COMMIT")
        return Snapshot(conversations: result, names: contacts ? names(for: result) : [:])
    }
}
public enum MessagesNameResolver {
    private static let queue = DispatchQueue(label: "messages.names.automation")
    public static func normalize(_ value: String) -> String { value.contains("@") ? value.lowercased() : value.filter { $0.isNumber } }
    public static func match(_ pairs: [(String, String)], handles: Set<String>) -> [String: String] {
        let wanted = Dictionary(grouping: handles.filter { $0 != "Me" && $0 != "Unknown" }, by: normalize)
        var names: [String: String] = [:]
        for (address, name) in pairs where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = normalize(address)
            guard !key.isEmpty else { continue }
            for handle in wanted[key] ?? [] { names[handle] = name }
        }
        return names
    }
    private static let metricsLock = NSLock()
    private static var metrics: [String: Int] = [:]
    private static func count(_ label: String, _ amount: Int = 1) {
        metricsLock.lock(); metrics[label, default: 0] += amount; metricsLock.unlock()
    }
    public static func diagnostics() -> [String: Int] {
        metricsLock.lock(); defer { metricsLock.unlock() }; return metrics
    }
    public static func merge(_ retained: [String: String], _ fresh: [String: String]) -> [String: String] {
        var result = retained.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for (handle, name) in fresh where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result[handle] = name }
        return result
    }
    public static func missing(_ conversations: [Conversation], names: [String: String]) -> Set<String> {
        Set(conversations.flatMap { $0.participants + $0.messages.map(\.sender) }).filter {
            $0 != "Me" && $0 != "Unknown" && (names[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
    public struct Batch {
        public var pairs: [(String, String)]
        public var participantFailures: Int
        public var malformedPairs: Int
        public init(_ pairs: [(String, String)], participantFailures: Int = 0, malformedPairs: Int = 0) {
            self.pairs = pairs; self.participantFailures = participantFailures; self.malformedPairs = malformedPairs
        }
    }
    public static func messagesRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").isEmpty
    }
    // Chats whose lookup recently resolved no name (unsaved numbers, timeouts, denial) are
    // skipped briefly so repeated reads do not repeat slow Apple events. Keys are hashed chat IDs;
    // no names or handles are retained here.
    private static let missLock = NSLock()
    private static var misses: [String: Date] = [:]
    static let missInterval: TimeInterval = 60
    private static func missKey(_ id: String) -> String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func resetMisses() { missLock.lock(); misses.removeAll(); missLock.unlock() }
    public static func throttled(_ conversations: [Conversation], now: Date = Date(), lookup: ([Conversation]) -> [String: String]) -> [String: String] {
        missLock.lock()
        misses = misses.filter { now.timeIntervalSince($0.value) < missInterval }
        let due = conversations.filter { misses[missKey($0.id)] == nil }
        missLock.unlock()
        guard !due.isEmpty else { count("throttled_chats", conversations.count); return [:] }
        count("throttled_chats", conversations.count - due.count)
        let names = lookup(due)
        missLock.lock()
        // Only chats that yielded no name at all are skipped; partial groups keep their resolved names.
        for chat in due {
            let wanted = missing([chat], names: [:])
            if wanted.isEmpty || wanted.contains(where: { names[$0] != nil }) { misses.removeValue(forKey: missKey(chat.id)) } else { misses[missKey(chat.id)] = now }
        }
        missLock.unlock()
        return names
    }
    public static func resolve(_ conversations: [Conversation]) -> [String: String] {
        throttled(conversations) { resolveNow($0) }
    }
    static func resolveNow(_ conversations: [Conversation]) -> [String: String] {
        resolve(conversations, lookup: { conversation in
            let result = try Automation.descriptor(namesScript, chat: conversation.id)
            guard let list = result.atIndex(1) else { return Batch([], malformedPairs: 1) }
            var batch = Batch([], participantFailures: Int(result.atIndex(2)?.int32Value ?? 0))
            if list.numberOfItems > 0 {
                for i in 1...list.numberOfItems {
                    guard let pair = list.atIndex(i), let address = pair.atIndex(1)?.stringValue,
                          let name = pair.atIndex(2)?.stringValue else { batch.malformedPairs += 1; continue }
                    batch.pairs.append((address, name))
                }
            }
            return batch
        })
    }
    public static func resolve(_ conversations: [Conversation], lookup: (Conversation) throws -> Batch) -> [String: String] {
        queue.sync {
            count("lookups")
            var pairs: [(String, String)] = []
            for conversation in conversations {
                count("chats_attempted")
                do {
                    let batch = try lookup(conversation)
                    pairs.append(contentsOf: batch.pairs)
                    count("chats_completed"); count("participant_failures", batch.participantFailures); count("malformed_pairs", batch.malformedPairs)
                    if batch.pairs.isEmpty { count("empty_chats") }
                } catch {
                    if let error = error as? AutomationFailure {
                        if error.code == -1743 { count("permission_denied"); break }
                        count(error.code == -1712 ? "timeouts" : (error.code == -1728 ? "unavailable_chats" : "automation_errors"))
                    } else { count("other_errors") }
                    // A chat-specific error must not suppress unrelated conversations.
                    continue
                }
            }
            let handles = Set(conversations.flatMap { $0.participants + $0.messages.map(\.sender) })
            let names = match(pairs, handles: handles)
            count("handles_resolved", names.count); count("handles_unresolved", missing(conversations, names: names).count)
            return names
        }
    }
    static let namesScript = """
    on perform(chatID, unused)
      with timeout of 3 seconds
        tell application "Messages"
          set matches to every chat whose id is chatID
          if (count of matches) is not 1 then error "Exact chat unavailable" number -1728
          set namePairs to {}
          set participantFailures to 0
          repeat with person in participants of item 1 of matches
            try
              set personHandle to handle of person
              set personName to full name of person
              if personName is not missing value and personName is not "" then set end of namePairs to {personHandle, personName}
            on error
              set participantFailures to participantFailures + 1
            end try
          end repeat
          return {namePairs, participantFailures}
        end tell
      end timeout
    end perform
    """
}
