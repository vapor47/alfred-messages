import Foundation

public enum CacheMode: String, Codable, CaseIterable { case disk, memory, off }
public struct Settings: Codable, Equatable {
    public var mode: CacheMode
    public var conversations: Int
    public var messages: Int
    public var sendKey: String
    public init(mode: CacheMode = .disk, conversations: Int = 8, messages: Int = 10, sendKey: String = "return") {
        self.mode = mode; self.conversations = max(1, min(200, conversations)); self.messages = max(1, min(200, messages))
        self.sendKey = sendKey == "command-return" ? sendKey : "return"
    }
    // Decoded settings (settings.json, IPC) get the same bounds as constructed ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try c.decode(CacheMode.self, forKey: .mode), conversations: try c.decode(Int.self, forKey: .conversations), messages: try c.decode(Int.self, forKey: .messages), sendKey: try c.decode(String.self, forKey: .sendKey))
    }
}
public enum DeliveryStatus: String, Codable { case submitted, sent, delivered, failed }
public struct Message: Codable, Equatable {
    public var guid: String; public var sender: String; public var date: Date; public var text: String
    public var attachments: [String]; public var reaction: String?; public var target: String?
    public var delivery: DeliveryStatus?
    public init(guid: String, sender: String, date: Date, text: String, attachments: [String] = [], reaction: String? = nil, target: String? = nil, delivery: DeliveryStatus? = nil) {
        self.guid = guid; self.sender = sender; self.date = date; self.text = text; self.attachments = attachments; self.reaction = reaction; self.target = target; self.delivery = delivery
    }
}
public struct Conversation: Codable, Equatable {
    public var rowID: Int64; public var id: String; public var title: String; public var participants: [String]; public var messages: [Message]; public var activity: Date
    public init(rowID: Int64, id: String, title: String, participants: [String], messages: [Message], activity: Date) {
        self.rowID = rowID; self.id = id; self.title = title; self.participants = participants; self.messages = messages; self.activity = activity
    }
}
public struct Snapshot: Codable {
    public var conversations: [Conversation]; public var names: [String: String]; public var updated: Date
    public init(conversations: [Conversation] = [], names: [String: String] = [:], updated: Date = Date()) { self.conversations = conversations; self.names = names; self.updated = updated }
    public mutating func trim(_ settings: Settings) {
        conversations = Array(conversations.prefix(settings.conversations))
        for i in conversations.indices { conversations[i].messages = Array(conversations[i].messages.suffix(settings.messages)) }
        let handles = Set(conversations.flatMap { $0.participants + $0.messages.map(\.sender) })
        names = names.filter { handles.contains($0.key) }
    }
}
public struct Failure: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
public enum Render {
    // Alfred's Text View Markdown is not CommonMark: its only backslash escape is \* (shown as ﹡),
    // so any other backslash escape is displayed literally. Block syntax is matched at line starts,
    // and a zero-width non-joiner there or inside inline syntax keeps the visible text unchanged.
    public static func escape(_ text: String) -> String {
        let joiner = "\u{200c}" // Zero width in Alfred; word joiner and similar format characters draw as a 6 pt space there.
        func count(_ c: Character, _ s: String) -> Int { s.reduce(0) { $1 == c ? $0 + 1 : $0 } }
        var result = text.replacingOccurrences(of: "\u{fffc}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[\r\u{85}\u{2028}\u{2029}]", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]+$"#, with: "", options: .regularExpression)
        // Alfred links web addresses itself, so substituted characters would cut the link short.
        // Such an address becomes an explicit link whose visible text Alfred does not detect again.
        var pieces: [(text: String, target: String?)] = []
        let source = result as NSString
        var last = 0
        let links = (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue))?.matches(in: result, range: NSRange(location: 0, length: source.length)) ?? []
        for link in links {
            guard let url = link.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let text = source.substring(with: link.range)
            guard text.rangeOfCharacter(from: CharacterSet(charactersIn: "_*`")) != nil, !text.contains("]"), !text.contains("\n") else { continue }
            let target = text.lowercased().hasPrefix("http") ? text : url.absoluteString
            pieces += [(source.substring(with: NSRange(location: last, length: link.range.location - last)), nil), (text, target.replacingOccurrences(of: ")", with: "%29"))]
            last = NSMaxRange(link.range)
        }
        pieces.append((source.substring(from: last), nil))
        let visible = pieces.map(\.text).joined()
        let stars = count("*", visible) > 1, underscores = count("_", visible) > 1, backticks = count("`", visible) > 1
        result = pieces.map { piece in
            // A literal backslash must not combine with a following asterisk, including the header's closing **.
            var text = piece.text.replacingOccurrences(of: #"\\(?=\*|$)"#, with: "\\\\" + joiner, options: .regularExpression)
            // Paired emphasis and code markers would restyle text and disappear; a single one is literal.
            if stars { text = text.replacingOccurrences(of: "*", with: "\\*") }
            if underscores { text = text.replacingOccurrences(of: "_", with: "\u{ff3f}") }
            if backticks { text = text.replacingOccurrences(of: "`", with: "\u{ff40}") }
            if let target = piece.target {
                guard text != piece.text else { return piece.text }
                return "[" + text.replacingOccurrences(of: ":", with: joiner + ":").replacingOccurrences(of: ".", with: joiner + ".") + "](" + target + ")"
            }
            return text.replacingOccurrences(of: "](", with: "]" + joiner + "(")
                .replacingOccurrences(of: "(?i)<(kbd>)", with: "<" + joiner + "$1", options: .regularExpression)
                .replacingOccurrences(of: "&#xFE0E;", with: "&" + joiner + "#xFE0E;")
        }.joined()
        // Headings, quotes, images, tables, fences, rules, lists and indented code start at line starts.
        result = result.replacingOccurrences(of: #"(?m)^(?=[ \t#>!|`*+_0-9-])"#, with: joiner, options: .regularExpression)
        // Single newlines are otherwise joined with a space; two trailing spaces force a line break.
        return result.replacingOccurrences(of: #"(?<=[^\n])\n(?=[^\n])"#, with: "  \n", options: .regularExpression)
    }
    public static func name(_ handle: String, _ names: [String: String]) -> String { handle == "Me" ? "Me" : (names[handle] ?? handle) }
    public static func title(_ chat: Conversation, _ names: [String: String]) -> String { chat.title.isEmpty ? chat.participants.map { name($0, names) }.joined(separator: ", ") : chat.title }
    public static func searchText(_ chat: Conversation, names: [String: String]) -> String {
        (title(chat, names) + " " + chat.participants.joined(separator: " ") + " " + chat.participants.map { name($0, names) }.joined(separator: " ")).lowercased()
    }
    // Case- and accent-insensitive, trimmed, with inner whitespace collapsed. Queries and names are compared in this form.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func isSeparator(_ c: Character) -> Bool { c.isWhitespace || "-'’(),.&/".contains(c) }
    // Lower is better: exact, prefix, later word starts the phrase, every query word starts a name word, substring.
    static func nameLevel(_ name: String, _ query: String, _ words: [Substring]) -> Int? {
        let name = fold(name)
        guard !name.isEmpty else { return nil }
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.indices.dropFirst().contains(where: { isSeparator(name[name.index(before: $0)]) && !isSeparator(name[$0]) && name[$0...].hasPrefix(query) }) { return 2 }
        let nameWords = name.split(whereSeparator: isSeparator)
        if words.count > 1, words.allSatisfy({ w in nameWords.contains { $0.hasPrefix(w) } }) { return 3 }
        return name.contains(query) ? 4 : nil
    }
    // Search rank for a folded, non-empty query; nil means no match. The chat name is tried first and
    // participant names only as a fallback; a handle-only match ranks last. Lower sorts first.
    public static func matchRank(_ chat: Conversation, names: [String: String], query: String) -> (level: Int, source: Int)? {
        let words = query.split(whereSeparator: isSeparator)
        if !chat.title.isEmpty, let level = nameLevel(chat.title, query, words) { return (level, 0) }
        if let level = chat.participants.compactMap({ nameLevel(name($0, names), query, words) }).min() { return (level, 1) }
        return fold(searchText(chat, names: names)).contains(query) ? (5, 1) : nil
    }
    private static let timestampFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()
    public static func timestamp(_ date: Date) -> String { timestampFormatter.string(from: date) }
    public static func history(_ chat: Conversation, names: [String: String]) -> String {
        var blocks = ["# " + escape(title(chat, names))]
        for m in chat.messages {
            let status = m.delivery.map { " · " + ($0 == .submitted ? "Submitted to Messages" : $0.rawValue.capitalized) } ?? ""
            let header = "**\(escape(name(m.sender, names)))** · \(timestamp(m.date))" + status
            let body: String
            if let reaction = m.reaction {
                let target = chat.messages.first { $0.guid == m.target }
                body = escape(reaction + (target.map { " to “" + String($0.text.prefix(100)) + "”" } ?? " to an earlier message"))
            } else { body = escape(m.text.isEmpty && m.attachments.isEmpty ? "[Content unavailable]" : m.text) }
            let attachments = m.attachments.map { "Attachment: " + escape($0) }
            blocks.append(([header, body] + attachments).filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        if chat.messages.isEmpty { blocks.append("No messages available.") }
        return blocks.joined(separator: "\n\n---\n\n")
    }
}

public struct Request: Codable {
    public var operation: String; public var settings: Settings; public var query: String; public var chat: String; public var draft: String; public var token: String; public var action: String
    public var viewSession: String?
    public var refreshToken: String?
    public init(operation: String, settings: Settings, query: String = "", chat: String = "", draft: String = "", token: String = "", action: String = "", viewSession: String? = nil, refreshToken: String? = nil) {
        self.operation = operation; self.settings = settings; self.query = query; self.chat = chat; self.draft = draft; self.token = token; self.action = action; self.viewSession = viewSession; self.refreshToken = refreshToken
    }
}
