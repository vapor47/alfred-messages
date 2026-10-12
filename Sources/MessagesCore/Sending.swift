import Foundation
import AppKit
import Carbon
import CryptoKit

public struct AutomationFailure: Error, CustomStringConvertible {
    public let code: Int
    public init(_ code: Int) { self.code = code }
    public var description: String {
        if code == -1743 { return "Messages Automation permission denied. Allow Messages Helper to control Messages in System Settings." }
        if code == -1728 { return "Selected chat could not be resolved exactly. No alternate recipient was used." }
        return "Messages automation failed (\(code)). Submission may be ambiguous; check Messages before trying again."
    }
}

public enum Automation {
    public static func run(_ source: String, chat: String, text: String = "") throws -> String {
        return try descriptor(source, chat: chat, text: text).stringValue ?? ""
    }
    static func descriptor(_ source: String, chat: String, text: String = "") throws -> NSAppleEventDescriptor {
        // Values are passed as Apple event parameters, never interpolated into executable script.
        var compileError: NSDictionary?
        guard let script = NSAppleScript(source: source), script.compileAndReturnError(&compileError) else { throw Failure("Messages automation could not compile.") }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "perform"), forKeyword: AEKeyword(keyASSubroutineName))
        let args = NSAppleEventDescriptor.list(); args.insert(NSAppleEventDescriptor(string: chat), at: 1); args.insert(NSAppleEventDescriptor(string: text), at: 2)
        event.setParam(args, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        guard error == nil else {
            let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
            throw AutomationFailure(code)
        }
        return result
    }
    public static let sendScript = """
    on perform(chatID, draft)
      -- Finish well inside the client's 65-second IPC timeout, so a late send cannot follow a reported failure.
      with timeout of 30 seconds
        tell application "Messages"
          set matches to every chat whose id is chatID
          if (count of matches) is not 1 then error "Exact chat unavailable" number -1728
          send draft to item 1 of matches
        end tell
      end timeout
      return "submitted"
    end perform
    """
    public static let openScript = """
    on perform(chatID, unused)
      tell application "Messages"
        set matches to every chat whose id is chatID
        if (count of matches) is not 1 then error "Exact chat unavailable" number -1728
        activate
      end tell
      return "Messages activated; select the conversation in Messages."
    end perform
    """
}
public final class SubmissionGuard {
    private let lock = NSLock()
    private var tokens: [String: Date] = [:]
    private var pendingChats = Set<String>()
    public init() {}
    public func isPending(chat: String) -> Bool { lock.lock(); defer { lock.unlock() }; return pendingChats.contains(chat) }
    public func submit(chat: String, draft: String, token: String, send: () throws -> Void) throws {
        guard !chat.isEmpty, !token.isEmpty, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("Choose a conversation and enter a reply.") }
        // A token is consumed even on ambiguous failure. The UI issues a new token only after success.
        // Same token + exact chat + same content is the same attempt. A changed explicit draft is distinct.
        let encoded = try JSONEncoder().encode([token, chat, draft])
        let attempt = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        tokens = tokens.filter { Date().timeIntervalSince($0.value) < 86400 }
        guard !pendingChats.contains(chat) else { lock.unlock(); throw Failure("A submission is still running for this chat. No additional reply was submitted; wait and check Messages.") }
        guard tokens[attempt] == nil else { lock.unlock(); throw Failure("This exact attempt was already submitted or failed ambiguously. Check Messages; it will not be retried automatically.") }
        tokens[attempt] = Date(); pendingChats.insert(chat); lock.unlock()
        defer { lock.lock(); pendingChats.remove(chat); lock.unlock() }
        try send()
    }
}
