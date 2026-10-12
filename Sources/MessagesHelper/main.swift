import Foundation
import Darwin
import MessagesCore
import ApplicationServices

let env = ProcessInfo.processInfo.environment
let root = URL(fileURLWithPath: env["MESSAGES_STATE_ROOT"] ?? NSHomeDirectory() + "/Library/Application Support/AlfredMessages")
let database = env["MESSAGES_DATABASE"] ?? NSHomeDirectory() + "/Library/Messages/chat.db"
let args = Array(CommandLine.arguments.dropFirst())
let operation = args.first ?? "diagnostics"
func emit(_ object: [String: Any]) { if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) } }
if operation == "live-self-test" {
    do { try liveDriverTests() } catch { print("Live driver self-test failed: " + String(describing: error)); exit(1) }
} else if operation == "watch-view" {
    let settings = Settings(mode: CacheMode(rawValue: env["cache_mode"] ?? "disk") ?? .off, conversations: Int(env["conversation_limit"] ?? "8") ?? 8, messages: Int(env["message_limit"] ?? "10") ?? 10, sendKey: env["send_key"] ?? "return")
    liveDriver(args.dropFirst().first ?? "", chat: args.dropFirst(2).first ?? "", settings: settings)
} else if operation == "accessibility" || (operation == "admin" && args.dropFirst().first == "accessibility") {
    let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    let message = trusted ? "Automatic updates have Accessibility access. Reopen the conversation to start." : "Allow Messages Helper in System Settings → Privacy & Security → Accessibility, then reopen the conversation."
    if operation == "admin" { print(message) } else { emit(["trusted": trusted, "executable": CommandLine.arguments[0], "status": message]) }
} else if operation == "tools" {
    let tools = [("clear", "Clear cache", "Delete retained transcripts, names and avatars"), ("refresh", "Refresh", "Reconcile cached data"), ("diagnostics", "Cache status", "Counts, mode and permissions; no message content"), ("configure", "Apply settings", "Apply mode, send key and limits now"), ("benchmark", "Benchmark all modes", "Compare reader/render latency while respecting active persistence policy"), ("accessibility", "Automatic refresh access", "Enable Messages Helper Accessibility access for in-place updates")]
    let query = args.dropFirst().first?.lowercased() ?? ""
    emit(["items": tools.filter { query.isEmpty || $0.1.lowercased().contains(query) }.map { ["title": $0.1, "subtitle": $0.2, "arg": $0.0, "valid": true] as [String: Any] }])
} else if operation == "daemon" {
    do { let service = try Service(root: root, database: database); try Transport.serve(service.handle) }
    catch { FileHandle.standardError.write(Data(("Helper startup failed: " + String(describing: error) + "\n").utf8)); exit(1) } // Startup errors contain no message/contact content.
} else if operation == "permissions" {
    do { _ = try Database(path: database); emit(["database": "accessible", "name_lookup": "Messages Automation; no Contacts permission required"]) }
    catch { emit(["error": String(describing: error)]) }
} else {
    let settings = Settings(mode: CacheMode(rawValue: env["cache_mode"] ?? "disk") ?? .off, conversations: Int(env["conversation_limit"] ?? "8") ?? 8, messages: Int(env["message_limit"] ?? "10") ?? 10, sendKey: env["send_key"] ?? "return")
    var actualOperation = operation == "admin" ? (args.dropFirst().first ?? "diagnostics") : operation
    let argument = args.dropFirst().first ?? ""
    let automatic = LiveInput.containsRefresh(argument)
    if !automatic && actualOperation == "view" && env["view_action"] == "history" { LiveDispatchGuard.clearInactive() }
    let sendAction = env["view_action"] ?? "history"
    // An independent metadata guard survives helper restart and field replacement. If an
    // unmarked execution overlaps dispatch, fail closed rather than treating it as a send.
    if liveSendBlocked(operation: actualOperation, action: sendAction, argument: argument) {
        emit(["footer": "Automatic refresh paused; reopen the conversation if this persists.", "behaviour": ["inputfield": "select"], "variables": ["view_action": ""]])
        exit(0)
    }
    if automatic { actualOperation = "auto-fetch" }
    let request = Request(operation: actualOperation, settings: settings, query: automatic ? "" : argument, chat: env["chat_id"] ?? "", draft: !automatic && ["view", "send"].contains(actualOperation) ? argument : "", token: env["submission_token"] ?? UUID().uuidString, action: actualOperation == "view" && env["view_action"] == "" ? "return-send" : (env["view_action"] ?? "history"), viewSession: env["view_session"], refreshToken: automatic ? LiveInput.refreshToken(argument) : nil)
    do {
        var data = try Transport.call(request)
        if automatic, !liveRefreshVisible(request.viewSession ?? "", token: request.refreshToken ?? "") {
            // Never apply an old view's chat variables/history to a newly selected conversation.
            _ = try? Transport.call(Request(operation: "auto-fault", settings: settings, chat: request.chat, action: "frontend-result-discarded", viewSession: request.viewSession), seconds: 2)
            emit(["behaviour": ["inputfield": "select"]])
            _ = try? Transport.call(Request(operation: "auto-finish", settings: settings, chat: request.chat, action: "reject", viewSession: request.viewSession, refreshToken: request.refreshToken), seconds: 2)
            exit(0)
        }
        if actualOperation == "diagnostics", var value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            value["automatic_accessibility_trusted"] = AXIsProcessTrusted()
            data = try JSONSerialization.data(withJSONObject: value)
        }
        if operation == "view" || operation == "send" {
            if var value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let variables = value["variables"] as? [String: String], let session = variables["view_session"], !automatic {
                if AXIsProcessTrusted() { startLiveDriver(session, chat: request.chat) }
                else if let footer = value["footer"] as? String {
                    value["footer"] = footer + " · Auto updates need Messages Helper access in System Settings → Accessibility"
                    data = try JSONSerialization.data(withJSONObject: value)
                }
            }
        }
        if operation == "admin" {
            if let object = try? JSONSerialization.jsonObject(with: data), let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let text = String(data: pretty, encoding: .utf8) { print("# Messages cache\n\n```json\n" + text + "\n```") }
        } else { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
        if automatic {
            _ = try? Transport.call(Request(operation: "auto-finish", settings: settings, chat: request.chat, action: "accept", viewSession: request.viewSession, refreshToken: request.refreshToken), seconds: 2)
        }
    } catch {
        let message = String(describing: error)
        if operation == "list" { emit(["skipknowledge": true, "items": [["title": "Messages helper unavailable", "subtitle": message, "valid": false]]]) }
        else if actualOperation == "auto-fetch" { emit(["footer": "Automatic update unavailable; history retained." + LiveInput.refreshMarker(request.refreshToken ?? ""), "behaviour": ["inputfield": "select"], "variables": ["view_action": ""]]) }
        else if operation == "view" { emit(["response": "Messages helper unavailable.", "footer": message, "behaviour": ["inputfield": "select", "scroll": "end"], "variables": ["view_action": "", "chat_id": request.chat, "submission_token": request.token]]) }
        else { emit(["error": message]) }
        if actualOperation == "auto-fetch" {
            _ = try? Transport.call(Request(operation: "auto-finish", settings: settings, chat: request.chat, action: "reject", viewSession: request.viewSession, refreshToken: request.refreshToken), seconds: 2)
        }
        if actualOperation != "auto-fetch" { exit(1) }
    }
}
