import Foundation

// Transient UI receipts only: never written to cache files, logs or settings.
// Automation exposes no returned message GUID. Match a new outgoing row in the exact chat,
// beyond the pre-send boundary, with identical text. Unmatched submissions stay unconfirmed.
final class OutgoingReceipts {
    struct Receipt {
        let token: String
        let chat: String
        let text: String
        let boundary: Int64
        let submitted: Date
        var seen: Date
        var guid: String?
        var delivery: DeliveryStatus = .submitted
    }
    private let lock = NSLock()
    private var receipts: [String: Receipt] = [:]
    func record(token: String, chat: String, text: String, boundary: Int64) {
        lock.lock(); defer { lock.unlock() }
        prune()
        receipts[token] = Receipt(token: token, chat: chat, text: text, boundary: boundary, submitted: Date(), seen: Date())
    }
    func expire() { lock.lock(); defer { lock.unlock() }; prune() }
    var hasReceipts: Bool { lock.lock(); defer { lock.unlock() }; return !receipts.isEmpty }
    func clear() { lock.lock(); defer { lock.unlock() }; receipts.removeAll() }
    private func prune() { receipts = receipts.filter { Date().timeIntervalSince($0.value.seen) < 120 } }
    func reconcile(chat: String, reader: Reader, database: Database) throws {
        lock.lock(); defer { lock.unlock() }
        prune()
        let active = receipts.values.filter { $0.chat == chat }.sorted { $0.submitted < $1.submitted }
        guard let boundary = active.map(\.boundary).min() else { return }
        let rows = try reader.outgoingCandidates(chatID: chat, after: boundary, database: database)
        var claimed = Set(receipts.values.compactMap(\.guid))
        for var receipt in active {
            let match = rows.first { row in
                let guid = row["guid"] as? String ?? ""
                if let known = receipt.guid { return guid == known }
                let body = row["text"] as? String ?? ""
                let text = body.isEmpty ? ((row["attributedBody"] as? Data).flatMap(Reader.attributedText) ?? "") : body
                return !guid.isEmpty && !claimed.contains(guid) && (row["rowid"] as? Int64 ?? 0) > receipt.boundary && text == receipt.text
            }
            if let row = match {
                receipt.guid = row["guid"] as? String
                if let guid = receipt.guid { claimed.insert(guid) }
                receipt.delivery = Reader.delivery(row) ?? .submitted
            }
            receipts[receipt.token] = receipt
        }
    }
    func overlay(_ chat: Conversation, limit: Int) -> Conversation {
        lock.lock(); defer { lock.unlock() }
        prune()
        var result = chat
        let active = receipts.values.filter { $0.chat == chat.id && $0.guid == nil }.sorted { $0.submitted < $1.submitted }
        for receipt in active {
            result.messages.append(Message(guid: "local:"+receipt.token, sender: "Me", date: receipt.submitted, text: receipt.text, delivery: .submitted))
        }
        result.messages = Array(result.messages.suffix(limit))
        return result
    }
    func status(token: String, chat: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        prune()
        guard var receipt = receipts[token], receipt.chat == chat else { return nil }
        receipt.seen = Date(); receipts[token] = receipt
        switch receipt.delivery {
        case .delivered: return "Messages reports delivered."
        case .failed: return "Messages reports a send failure; check Messages before retrying."
        case .sent: return "Sent; waiting for delivery confirmation."
        case .submitted: return receipt.guid == nil ? "Submitted to Messages; waiting for local history." : "Submitted to Messages; waiting for delivery confirmation."
        }
    }
}
