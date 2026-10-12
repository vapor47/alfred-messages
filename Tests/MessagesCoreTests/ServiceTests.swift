import Foundation
import MessagesCore
import CSQLite

func serviceTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("am-service-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dbpath = root.appendingPathComponent("fixture.db").path
    var db: OpaquePointer?; sqlite3_open(dbpath, &db)
    defer { sqlite3_close(db) }
    let schema = """
    PRAGMA journal_mode=WAL;
    CREATE TABLE chat(guid TEXT,display_name TEXT);
    CREATE TABLE handle(id TEXT);
    CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
    CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER,handle_id INTEGER,attributedBody BLOB,associated_message_type INTEGER,associated_message_guid TEXT);
    CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
    CREATE TABLE attachment(transfer_name TEXT,mime_type TEXT);
    CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
    CREATE INDEX chat_message_chat ON chat_message_join(chat_id);
    CREATE INDEX attachment_message ON message_attachment_join(message_id);
    CREATE INDEX handle_chat ON chat_handle_join(chat_id);
    """
    XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
    for c in 1...35 {
        let sql = "INSERT INTO chat VALUES('iMessage;+;synthetic-\(c)','Synthetic group \(c) 👋'); INSERT INTO handle VALUES('test-\(c)@example.invalid'); INSERT INTO chat_handle_join VALUES(\(c),\(c));"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        for m in 0..<40 {
            let row = (c-1)*40+m+1
            let sql = "INSERT INTO message VALUES('message-\(row)','Synthetic Unicode 世界 reply \(m)',\((800_000_000 + c*100+m)*1_000_000_000),\(m%2),\(c),NULL,0,NULL); INSERT INTO chat_message_join VALUES(\(c),\(row));"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
    }
    let state = root.appendingPathComponent("state")
    let service = try Service(root: state, database: dbpath, nameLookup: { _ in [:] })
    let safeStartup = service.handle(Request(operation: "diagnostics", settings: Settings(mode: .off)))
    XCTAssertEqual(safeStartup["watchers"] as? Int, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("cache").path))
    var settings = Settings()
    func call(_ operation: String, action: String = "", draft: String = "", chat: String = "iMessage;+;synthetic-35") throws -> [String: Any] {
        // Exercise the real request codec, handler, response renderer and serialization, without a socket.
        let encoded = try JSONEncoder().encode(Request(operation: operation, settings: settings, chat: chat, draft: draft, token: "fixture-token", action: action))
        let request = try JSONDecoder().decode(Request.self, from: encoded)
        let response = service.handle(request)
        let data = try JSONSerialization.data(withJSONObject: response)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func ready() throws {
        _ = try call("configure")
        for _ in 0..<200 {
            let result = try call("list")
            if let items = result["items"] as? [[String: Any]], items.filter({ $0["uid"] != nil }).count == settings.conversations { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw Failure("Handler fixture timed out")
    }
    var timings: [[String: Any]] = []
    for mode in CacheMode.allCases {
        settings = Settings(mode: mode)
        let cold = CFAbsoluteTimeGetCurrent(); try ready()
        let coldMS = (CFAbsoluteTimeGetCurrent() - cold)*1000
        var samples: [Double] = []
        for _ in 0..<50 {
            let tick = CFAbsoluteTimeGetCurrent()
            let result = try call("list")
            samples.append((CFAbsoluteTimeGetCurrent()-tick)*1000)
            XCTAssertTrue(result["skipknowledge"] as? Bool == true)
            let items = result["items"] as! [[String: Any]]
            XCTAssertEqual(items.filter { $0["uid"] != nil }.count, 8)
            XCTAssertEqual(items.last?["autocomplete"] as? String, "»2 ")
            XCTAssertEqual(items.first?["uid"] as? String, "iMessage;+;synthetic-35")
            if mode != .disk { XCTAssertTrue(items.filter { $0["uid"] != nil }.allSatisfy { ($0["icon"] as? [String: String])?["path"] == "icon.png" }) }
        }
        samples.sort()
        timings.append(["mode": mode.rawValue, "configure_to_ready_ms": coldMS, "list_warm_p50_ms": samples[25], "list_warm_p95_ms": samples[47], "samples": 50])
        let initial = try call("view", action: "history", draft: "Never send initial input")
        XCTAssertEqual((initial["behaviour"] as? [String: String])?["inputfield"], "select")
        XCTAssertTrue((initial["response"] as? String)?.contains("Synthetic group 35") == true)
        settings.sendKey = "command-return"
        let plain = try call("view", draft: "Never send on plain Return")
        XCTAssertEqual((plain["behaviour"] as? [String: String])?["inputfield"], "select")
        XCTAssertTrue((plain["footer"] as? String)?.contains("preserves draft") == true)
        if mode != .disk { XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("cache").path)) }
        if mode == .off {
            let diagnostics = try call("diagnostics")
            XCTAssertEqual(diagnostics["watchers"] as? Int, 0)
            XCTAssertEqual((diagnostics["cache"] as? [String: Any])?["conversations"] as? Int, 0)
            let benchmark = try call("benchmark")
            let reports = benchmark["benchmark"] as! [[String: Any]]
            XCTAssertTrue(reports.allSatisfy { $0["disk_io"] as? Bool == false })
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("cache").path))
        }
    }
    settings = Settings(mode: .memory); try ready()
    let tick = CFAbsoluteTimeGetCurrent()
    XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET text='Updated synthetic fixture' WHERE ROWID=1400", nil, nil, nil), SQLITE_OK)
    var updated = false
    for _ in 0..<200 {
        let items = try call("list")["items"] as! [[String: Any]]
        if (items.first?["subtitle"] as? String)?.hasPrefix("Updated synthetic fixture") == true { updated = true; break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertTrue(updated)
    let freshness = (CFAbsoluteTimeGetCurrent()-tick)*1000
    XCTAssertTrue(freshness < 2000)
    // Remove the DB before exercising send paths. No external Messages automation can be reached.
    let moved = dbpath + ".unavailable"
    try FileManager.default.moveItem(atPath: dbpath, toPath: moved)
    for (sendKey, action) in [("return", "return-send"), ("command-return", "command-send")] {
        settings.sendKey = sendKey
        let failed = try call("view", action: action, draft: "Draft survives failed submission")
        XCTAssertEqual((failed["behaviour"] as? [String: String])?["inputfield"], "select")
        XCTAssertTrue((failed["response"] as? String)?.contains("Synthetic group 35") == true)
        XCTAssertTrue((failed["footer"] as? String)?.contains("database unavailable") == true)
    }
    try FileManager.default.moveItem(atPath: moved, toPath: dbpath)
    let refresh = try call("view", action: "refresh", draft: "Retained draft")
    XCTAssertEqual((refresh["behaviour"] as? [String: String])?["inputfield"], "select")
    XCTAssertEqual((refresh["variables"] as? [String: String])?["submission_token"], "fixture-token")
    settings.conversations = 5; settings.messages = 3; _ = try call("configure")
    XCTAssertEqual((try call("list")["items"] as? [[String: Any]])?.filter { $0["uid"] != nil }.count, 5)
    let history = try call("view", action: "history")["response"] as! String
    XCTAssertEqual(history.components(separatedBy: "**").count - 1, 6)
    _ = try call("clear")
    XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("cache").path))
    let noMatches = service.handle(Request(operation: "list", settings: settings, query: "no-synthetic-conversation-can-match-this"))
    XCTAssertTrue(noMatches["skipknowledge"] as? Bool == true)
    XCTAssertFalse(((noMatches["items"] as! [[String: Any]])[0]["valid"] as? Bool) ?? true)
    var received: [(String, String)] = []
    let fakeService = try Service(root: root.appendingPathComponent("fake-send-state"), database: dbpath, sender: { chat, draft in
        received.append((chat, draft))
        if draft == "Ambiguous failure" { throw Failure("Ambiguous failure; check Messages") }
    }, nameLookup: { conversations in
        Dictionary(uniqueKeysWithValues: conversations.flatMap { $0.participants }.map { ($0, "Fixture named participant") })
    })
    let chatID = "iMessage;+;synthetic-35"
    func fakeCall(draft: String, token: String, sendKey: String = "return", action: String = "return-send") -> [String: Any] {
        fakeService.handle(Request(operation: "view", settings: Settings(mode: .memory, sendKey: sendKey), chat: chatID, draft: draft, token: token, action: action))
    }
    _ = fakeCall(draft: "", token: "init", action: "refresh")
    _ = fakeCall(draft: "A nonempty automatic draft must never submit", token: "safe", action: "")
    _ = fakeCall(draft: "A nonempty initial draft must never submit", token: "safe", action: "history")
    XCTAssertEqual(received.count, 0)
    let success = fakeCall(draft: "Successful synthetic reply 👋", token: "success")
    XCTAssertEqual(received.last?.0, chatID)
    XCTAssertEqual(received.last?.1, "Successful synthetic reply 👋")
    XCTAssertEqual((success["behaviour"] as? [String: String])?["inputfield"], "clear")
    XCTAssertTrue((success["response"] as? String)?.contains("Synthetic group 35") == true)
    let namedHistory = fakeCall(draft: "", token: "named", action: "history")
    XCTAssertTrue((namedHistory["response"] as? String)?.contains("Fixture named participant") == true)
    XCTAssertTrue((success["footer"] as? String)?.contains("waiting for local history") == true)
    _ = fakeCall(draft: "Successful synthetic reply 👋", token: "success")
    XCTAssertEqual(received.count, 1)
    _ = fakeCall(draft: "Command only", token: "command", sendKey: "command-return")
    XCTAssertEqual(received.count, 1)
    let commandSuccess = fakeCall(draft: "Command only", token: "command", sendKey: "command-return", action: "command-send")
    XCTAssertEqual(received.count, 2)
    XCTAssertEqual((commandSuccess["behaviour"] as? [String: String])?["inputfield"], "clear")
    let ambiguous = fakeCall(draft: "Ambiguous failure", token: "ambiguous")
    XCTAssertEqual((ambiguous["behaviour"] as? [String: String])?["inputfield"], "select")
    _ = fakeCall(draft: "Ambiguous failure", token: "ambiguous")
    XCTAssertEqual(received.count, 3)
    let ambiguousRefresh = fakeCall(draft: "Ambiguous failure", token: "ambiguous", action: "refresh")
    XCTAssertEqual((ambiguousRefresh["variables"] as? [String: String])?["submission_token"], "ambiguous")
    _ = fakeCall(draft: "Ambiguous failure", token: "ambiguous")
    XCTAssertEqual(received.count, 3)
    // Reopen the fixture writer after the deliberate database rename above.
    sqlite3_close(db); db = nil
    XCTAssertEqual(sqlite3_open(dbpath, &db), SQLITE_OK)
    // Fresh exact-chat history is independent of list eviction and observes committed edits immediately.
    settings = Settings(mode: .memory, conversations: 1, messages: 3)
    let outside = try call("view", action: "history", chat: "iMessage;+;synthetic-1")
    XCTAssertTrue((outside["response"] as? String)?.contains("Synthetic group 1") == true)
    XCTAssertTrue(outside["rerun"] == nil)
    XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET text='Fresh exact committed edit' WHERE ROWID=40", nil, nil, nil), SQLITE_OK)
    let edited = try call("view", action: "refresh", draft: "Retain draft", chat: "iMessage;+;synthetic-1")
    XCTAssertTrue((edited["response"] as? String)?.contains("Fresh exact committed edit") == true)
    _ = fakeCall(draft: "A different deliberate draft", token: "ambiguous")
    XCTAssertEqual(received.count, 4)
    _ = fakeCall(draft: "A different deliberate draft", token: "ambiguous")
    XCTAssertEqual(received.count, 4)
    var lookupCalls = 0
    let lookupService = try Service(root: root.appendingPathComponent("lookup-state"), database: dbpath, sender: { _, _ in }, nameLookup: { _ in lookupCalls += 1; return [:] })
    let immediate = lookupService.handle(Request(operation: "view", settings: Settings(mode: .off), chat: chatID, draft: "No names after submission", token: "fast", action: "return-send"))
    XCTAssertEqual(lookupCalls, 0)
    XCTAssertEqual((immediate["behaviour"] as? [String: String])?["inputfield"], "clear")
    // Sending must reuse names in the active off-mode view without synchronous lookup.
    let offNames = try Service(root: root.appendingPathComponent("off-names"), database: dbpath, sender: { _, _ in }, nameLookup: { _ in ["test-35@example.invalid": "Off-mode retained name"] })
    let namedOpen = offNames.handle(Request(operation: "view", settings: Settings(mode: .off), chat: chatID, action: "history"))
    let namedVars = namedOpen["variables"] as! [String: String]
    let namedSend = offNames.handle(Request(operation: "view", settings: Settings(mode: .off), chat: chatID, draft: "Synthetic named send", token: namedVars["submission_token"]!, action: "return-send", viewSession: namedVars["view_session"]))
    XCTAssertTrue((namedSend["response"] as! String).contains("Off-mode retained name"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("off-names/cache").path))
    // An unrelated cached name cannot suppress exact-chat lookup. Background bulk lookup
    // deliberately returns partial names; the selected-chat request supplies its missing name.
    let partialRoot = root.appendingPathComponent("partial-names")
    var partial = try Reader(path: dbpath).read(Settings(mode: .disk), contacts: false)
    partial.names = ["test-34@example.invalid": "Unrelated cached name"]
    try CacheStore(root: partialRoot).save(partial)
    try CacheStore.atomic(JSONEncoder().encode(Settings(mode: .disk)), to: partialRoot.appendingPathComponent("settings.json"))
    let partialService = try Service(root: partialRoot, database: dbpath, sender: { _, _ in }, nameLookup: { chats in
        chats.count == 1 ? Dictionary(uniqueKeysWithValues: chats[0].participants.map { ($0, "Selected missing name") }) : [:]
    })
    let selected = partialService.handle(Request(operation: "view", settings: Settings(mode: .disk), chat: chatID, action: "history"))
    XCTAssertTrue((selected["response"] as! String).contains("Selected missing name"))
    let selectedVars = selected["variables"] as! [String: String]
    let selectedSend = partialService.handle(Request(operation: "view", settings: Settings(mode: .disk), chat: chatID, draft: "Synthetic partial-name send", token: selectedVars["submission_token"]!, action: "return-send", viewSession: selectedVars["view_session"]))
    XCTAssertTrue((selectedSend["response"] as! String).contains("Selected missing name"))
    XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET text='Synthetic naming update' WHERE guid='message-1400'", nil, nil, nil), SQLITE_OK)
    let namedSession = selectedVars["view_session"]!
    var nameFrame: [String: Any] = [:]
    for _ in 0..<250 {
        let state = partialService.handle(Request(operation: "auto-prepare", settings: Settings(mode: .disk), chat: chatID, viewSession: namedSession))
        if let token = state["refresh_token"] as? String {
            nameFrame = partialService.handle(Request(operation: "auto-fetch", settings: Settings(mode: .disk), chat: chatID, viewSession: namedSession, refreshToken: token))
            if let text = nameFrame["response"] as? String { XCTAssertTrue(text.contains("Selected missing name")) }
            break
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertTrue((nameFrame["response"] as? String)?.contains("Selected missing name") == true)
    let namedOutside = partialService.handle(Request(operation: "view", settings: Settings(mode: .disk), chat: "iMessage;+;synthetic-1", action: "history"))
    XCTAssertTrue((namedOutside["response"] as! String).contains("Selected missing name"))
    print("PASS: exact-chat missing-name lookup, active names across off/cached sends and automatic preparation")
    // A mock acceptance deliberately commits no row until the test advances Messages' DB.
    // This reproduces the one-message-behind bug without a real send or timing-dependent sleeps.
    XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE message ADD COLUMN is_sent INTEGER DEFAULT 0; ALTER TABLE message ADD COLUMN is_delivered INTEGER DEFAULT 0; ALTER TABLE message ADD COLUMN date_delivered INTEGER DEFAULT 0; ALTER TABLE message ADD COLUMN date_read INTEGER DEFAULT 0; ALTER TABLE message ADD COLUMN error INTEGER DEFAULT 0;", nil, nil, nil), SQLITE_OK)
    var accepted = 0
    var rejectSubmission = false
    let receiptState = root.appendingPathComponent("receipt-state")
    let receiptService = try Service(root: receiptState, database: dbpath, sender: { _, _ in
        if rejectSubmission { throw Failure("Rejected explicit attempt") }
        accepted += 1
    }, nameLookup: { _ in [:] })
    func receiptCall(_ draft: String, _ token: String, action: String = "return-send", chat: String = chatID) -> [String: Any] {
        receiptService.handle(Request(operation: "view", settings: Settings(mode: .off), chat: chat, draft: draft, token: token, action: action))
    }
    func returnedToken(_ value: [String: Any]) -> String { (value["variables"] as! [String: String])["submission_token"]! }
    func occurrences(_ value: [String: Any], _ text: String) -> Int { (value["response"] as! String).components(separatedBy: text).count-1 }
    func commitOutgoing(_ guid: String, _ text: String, chatRow: Int = 35, delivered: Bool = false) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO message(guid,text,date,is_from_me,handle_id,is_sent,is_delivered) VALUES(?,?,900000000000000000,1,0,1,?)"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        _ = guid.withCString { sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        _ = text.withCString { sqlite3_bind_text(stmt, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_bind_int(stmt, 3, delivered ? 1 : 0)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO chat_message_join VALUES(\(chatRow),\(sqlite3_last_insert_rowid(db)))", nil, nil, nil), SQLITE_OK)
    }
    // An old identical delivered message cannot be mistaken for the new submission.
    commitOutgoing("old-identical", "Receipt regression repeat", delivered: true)
    let first = receiptCall("Receipt regression repeat", "receipt-first")
    XCTAssertEqual(occurrences(first, "Receipt regression repeat"), 2)
    XCTAssertTrue((first["footer"] as! String).contains("waiting for local history"))
    XCTAssertEqual((first["behaviour"] as! [String: String])["inputfield"], "clear")
    XCTAssertNil(first["rerun"])
    let firstToken = returnedToken(first)
    let second = receiptCall("Receipt regression second", firstToken)
    let secondToken = returnedToken(second)
    XCTAssertEqual(occurrences(second, "Receipt regression second"), 1)
    XCTAssertEqual(occurrences(second, "Receipt regression repeat"), 2)
    XCTAssertEqual(accepted, 2)
    // A same-text row in a different chat must not acknowledge the selected group's receipt.
    commitOutgoing("wrong-chat", "Receipt regression second", chatRow: 1, delivered: true)
    let wrongChat = receiptCall("Draft must not send", secondToken, action: "refresh")
    XCTAssertTrue((wrongChat["footer"] as! String).contains("waiting for local history"))
    XCTAssertEqual(accepted, 2)
    commitOutgoing("first-new", "Receipt regression repeat", delivered: true)
    commitOutgoing("second-new", "Receipt regression second")
    let committed = receiptCall("Preserve unsent text", secondToken, action: "refresh")
    XCTAssertEqual(occurrences(committed, "Receipt regression repeat"), 2)
    XCTAssertEqual(occurrences(committed, "Receipt regression second"), 1)
    XCTAssertTrue((committed["footer"] as! String).contains("waiting for delivery confirmation"))
    XCTAssertEqual((committed["behaviour"] as! [String: String])["inputfield"], "select")
    XCTAssertEqual(returnedToken(committed), secondToken)
    // Delivery transitions update on explicit refresh, without another submission or a timer.
    XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET date_delivered=900000001000000000 WHERE guid='second-new'", nil, nil, nil), SQLITE_OK)
    let delivered = receiptCall("", secondToken, action: "refresh")
    XCTAssertTrue((delivered["footer"] as! String).contains("Messages reports delivered"))
    XCTAssertEqual(occurrences(delivered, "Receipt regression second"), 1)
    XCTAssertNil(delivered["rerun"])
    XCTAssertEqual(accepted, 2)
    // Separate identical pending submissions each consume a distinct new row.
    let repeatA = receiptCall("Identical pending regression", secondToken)
    let repeatB = receiptCall("Identical pending regression", returnedToken(repeatA))
    XCTAssertEqual(occurrences(repeatB, "Identical pending regression"), 2)
    commitOutgoing("repeat-a", "Identical pending regression", delivered: true)
    let halfway = receiptCall("", returnedToken(repeatB), action: "refresh")
    XCTAssertEqual(occurrences(halfway, "Identical pending regression"), 2)
    XCTAssertTrue((halfway["footer"] as! String).contains("waiting for local history"))
    commitOutgoing("repeat-b", "Identical pending regression", delivered: true)
    let repeatsDone = receiptCall("", returnedToken(repeatB), action: "refresh")
    XCTAssertEqual(occurrences(repeatsDone, "Identical pending regression"), 2)
    XCTAssertTrue((repeatsDone["footer"] as! String).contains("Messages reports delivered"))
    XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET error=7 WHERE guid='repeat-b'", nil, nil, nil), SQLITE_OK)
    let deliveryFailure = receiptCall("", returnedToken(repeatB), action: "refresh")
    XCTAssertTrue((deliveryFailure["footer"] as! String).contains("send failure"))
    XCTAssertEqual(accepted, 4)
    XCTAssertFalse(FileManager.default.fileExists(atPath: receiptState.appendingPathComponent("cache").path))
    rejectSubmission = true
    let rejected = receiptCall("Rejected reply regression", returnedToken(repeatB))
    XCTAssertTrue((rejected["footer"] as! String).contains("Rejected explicit attempt"))
    XCTAssertEqual((rejected["behaviour"] as! [String: String])["inputfield"], "select")
    XCTAssertEqual(occurrences(rejected, "Rejected reply regression"), 0)
    XCTAssertEqual(accepted, 4)
    rejectSubmission = false
    let failedSession = (rejected["variables"] as! [String: String])["view_session"]!
    XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET text='Incoming during rejected send' WHERE ROWID=1399", nil, nil, nil), SQLITE_OK)
    var failureUpdated = false
    for _ in 0..<250 {
        let check = receiptService.handle(Request(operation: "auto-check", settings: Settings(mode: .off), chat: chatID, viewSession: failedSession))
        if check["changed"] as? Bool == true { failureUpdated = true; break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertTrue(failureUpdated)
    let failurePrepared = receiptService.handle(Request(operation: "auto-prepare", settings: Settings(mode: .off), chat: chatID, viewSession: failedSession))
    let failureFrame = receiptService.handle(Request(operation: "auto-fetch", settings: Settings(mode: .off), chat: chatID, viewSession: failedSession, refreshToken: failurePrepared["refresh_token"] as? String))
    XCTAssertTrue((failureFrame["footer"] as? String)?.contains("Rejected explicit attempt") == true)
    XCTAssertEqual(accepted, 4)
    let reopened = receiptCall("", "fresh-view-token", action: "history")
    XCTAssertTrue((reopened["footer"] as! String).contains("Latest outgoing message: Failed"))
    let uncommitted = receiptCall("Clear transient receipt regression", "clear-receipt")
    XCTAssertEqual(occurrences(uncommitted, "Clear transient receipt regression"), 1)
    _ = receiptService.handle(Request(operation: "clear", settings: Settings(mode: .off)))
    let afterClear = receiptCall("", returnedToken(uncommitted), action: "history")
    XCTAssertEqual(occurrences(afterClear, "Clear transient receipt regression"), 0)
    XCTAssertEqual(Reader.delivery(["is_from_me": Int64(1), "is_sent": Int64(1)]), .sent)
    XCTAssertEqual(Reader.delivery(["is_from_me": Int64(1), "date_read": Int64(42)]), .delivered)
    XCTAssertNil(Reader.delivery(["is_from_me": Int64(0), "is_delivered": Int64(1)]))
    print("PASS: immediate send echo, delayed commit, no duplicate rows, identical submissions, exact-chat receipts, delivery/error refresh and no reruns")
    // Production automatic refresh uses prepared frames and is read-only, including restart/fault paths.
    var automaticSends = 0
    let liveState = root.appendingPathComponent("live-state")
    let liveService = try Service(root: liveState, database: dbpath, sender: { _, _ in automaticSends += 1; throw Failure("Automatic execution attempted a send") }, nameLookup: { _ in [:] })
    let openedLive = liveService.handle(Request(operation: "view", settings: Settings(mode: .off), chat: chatID, draft: "Initial draft must never send", token: "live-submission", action: "history"))
    let liveSession = (openedLive["variables"] as! [String: String])["view_session"]!
    XCTAssertTrue((openedLive["response"] as! String).contains(LiveInput.viewMarker(liveSession)))
    XCTAssertTrue((openedLive["response"] as! String).hasPrefix("# ["))
    XCTAssertFalse((openedLive["response"] as! String).contains("View " + liveSession))
    func liveCall(_ operation: String, chat: String = chatID, token: String? = nil, settings: Settings = Settings(mode: .off), action: String = "") -> [String: Any] {
        liveService.handle(Request(operation: operation, settings: settings, chat: chat, token: "live-submission", action: action, viewSession: liveSession, refreshToken: token))
    }
    XCTAssertEqual(liveCall("auto-check")["changed"] as? Bool, false)
    XCTAssertNil(liveCall("auto-prepare")["refresh_token"])
    // Polling an old driver's settings cannot switch the global privacy policy back to disk.
    _ = liveCall("auto-check", settings: Settings(mode: .disk))
    XCTAssertFalse(FileManager.default.fileExists(atPath: liveState.appendingPathComponent("cache").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: liveState.appendingPathComponent("settings.json").path))
    XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET text='Prepared automatic edit regression' WHERE guid='repeat-b'", nil, nil, nil), SQLITE_OK)
    var changed = false
    for _ in 0..<250 {
        if liveCall("auto-check")["changed"] as? Bool == true { changed = true; break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertTrue(changed)
    // A recovered pre-dispatch failure is counted but leaves the view refreshable.
    XCTAssertEqual(liveCall("auto-note", action: "dispatch-annotation-readback-stale-buffered-0-posted-0")["paused"] as? Bool, false)
    XCTAssertEqual(liveCall("auto-check")["unavailable"] as? Bool, false)
    let noted = (liveService.handle(Request(operation: "diagnostics", settings: Settings(mode: .off)))["automatic_updates"] as! [String: Any])["failures"] as! [String: Int]
    XCTAssertEqual(noted["retried-dispatch-annotation-readback-stale-buffered-0-posted-0"], 1)
    let preparedLive = liveCall("auto-prepare")
    let refreshToken = preparedLive["refresh_token"] as! String
    let suffix = LiveInput.refreshMarker(refreshToken)
    XCTAssertEqual(LiveInput.refreshToken("Unicode 👋 unsent draft" + suffix), refreshToken)
    XCTAssertTrue(LiveInput.containsRefresh("new text" + LiveInput.refreshPrefix))
    XCTAssertNil(LiveInput.refreshToken(LiveInput.refreshPrefix + "malformed"))
    let rejectedWrongChat = liveCall("auto-fetch", chat: "iMessage;+;synthetic-1", token: refreshToken)
    XCTAssertNil(rejectedWrongChat["response"])
    // Even a return-send request carrying a marked nonempty draft can only fetch a frame.
    let automaticFrame = liveService.handle(Request(operation: "view", settings: Settings(mode: .off), chat: chatID, draft: "Unicode 👋 unsent draft"+suffix, token: "live-submission", action: "return-send", viewSession: liveSession))
    XCTAssertTrue((automaticFrame["response"] as? String)?.contains("Prepared automatic edit regression") == true)
    XCTAssertTrue((automaticFrame["response"] as? String)?.contains(LiveInput.viewMarker(liveSession)) == true)
    XCTAssertFalse((automaticFrame["response"] as! String).contains("View " + liveSession))
    XCTAssertFalse((automaticFrame["response"] as? String)?.contains("unsent draft") == true)
    XCTAssertNil(automaticFrame["rerun"])
    XCTAssertEqual((automaticFrame["behaviour"] as! [String: String])["inputfield"], "select")
    XCTAssertEqual((automaticFrame["behaviour"] as! [String: String])["response"], "replace")
    XCTAssertTrue(liveCall("auto-check")["changed"] as? Bool == true)
    XCTAssertFalse(liveCall("auto-result", token: refreshToken)["finalized"] as? Bool == true)
    XCTAssertFalse(liveCall("auto-finish", chat: "wrong-chat", token: refreshToken, action: "accept")["success"] as? Bool == true)
    XCTAssertFalse(liveCall("auto-finish", token: refreshToken, action: "reject")["success"] as? Bool == true)
    XCTAssertTrue(liveCall("auto-check")["changed"] as? Bool == true)
    let retryToken = liveCall("auto-prepare")["refresh_token"] as! String
    XCTAssertTrue((liveCall("auto-fetch", token: retryToken)["response"] as? String)?.contains("Prepared automatic edit regression") == true)
    XCTAssertTrue(liveCall("auto-check")["changed"] as? Bool == true)
    XCTAssertTrue(liveCall("auto-finish", token: retryToken, action: "accept")["success"] as? Bool == true)
    XCTAssertTrue(liveCall("auto-result", token: retryToken)["success"] as? Bool == true)
    XCTAssertTrue(liveCall("auto-result", token: retryToken)["finalized"] as? Bool == true)
    XCTAssertTrue(liveCall("auto-finish", token: retryToken, action: "accept")["success"] as? Bool == true)
    XCTAssertFalse(liveCall("auto-finish", token: refreshToken, action: "accept")["success"] as? Bool == true)
    XCTAssertEqual(automaticSends, 0)
    let duplicateFrame = liveCall("auto-fetch", token: refreshToken)
    XCTAssertNil(duplicateFrame["response"])
    XCTAssertTrue(duplicateFrame["update_failed"] as? Bool == true)
    XCTAssertEqual(liveCall("auto-check")["changed"] as? Bool, false)
    let malformedRefresh = liveService.handle(Request(operation: "send", settings: Settings(mode: .off), chat: chatID, draft: "Unsaved draft"+LiveInput.refreshPrefix, token: "live-submission", action: "command-send", viewSession: liveSession))
    XCTAssertNil(malformedRefresh["response"])
    XCTAssertEqual(automaticSends, 0)
    // A fresh helper has no old lease: marked input remains read-only and leaves existing history alone.
    let restartedLive = try Service(root: root.appendingPathComponent("live-restart"), database: dbpath, sender: { _, _ in automaticSends += 1 }, nameLookup: { _ in [:] })
    let afterRestart = restartedLive.handle(Request(operation: "view", settings: Settings(mode: .off), chat: chatID, draft: "Never send after restart"+suffix, token: "live-submission", action: "return-send", viewSession: liveSession))
    XCTAssertNil(afterRestart["response"])
    let restartFinish = restartedLive.handle(Request(operation: "auto-finish", settings: Settings(mode: .off), chat: chatID, action: "reject", viewSession: liveSession, refreshToken: refreshToken))
    XCTAssertFalse(restartFinish["success"] as? Bool == true)
    let restartResult = restartedLive.handle(Request(operation: "auto-result", settings: Settings(mode: .off), chat: chatID, viewSession: liveSession, refreshToken: refreshToken))
    XCTAssertTrue(restartResult["finalized"] as? Bool == true)
    XCTAssertFalse(restartResult["success"] as? Bool == true)
    XCTAssertEqual(automaticSends, 0)
    _ = liveService.handle(Request(operation: "clear", settings: Settings(mode: .off)))
    XCTAssertTrue(liveCall("auto-check")["error"] != nil)
    XCTAssertNil(liveCall("auto-fetch", token: refreshToken)["response"])
    XCTAssertEqual(automaticSends, 0)
    print("PASS: prepared production refresh, active off-mode reads, stale-policy guard, Unicode marker routing, wrong-chat/duplicate rejection, clear and helper-restart no-send safety")
    let report: [String: Any] = ["fixture": "35 conversations × 40 messages; 9/10 default limits", "boundary": "Real handler plus request/response JSON codec; socket, process startup and Alfred excluded", "timings": timings, "wal_freshness_ms": freshness, "handler_checks": "exact IDs, activity order, both send keys, initial-input guard, failure draft/history retention, refresh token, reduced limits, off watchers, non-disk artifacts, benchmark policy, mocked submission success, exact group routing, ambiguous failure and duplicate suppression, immediate submitted echoes, delayed commits, delivery/error refresh, receipt reconciliation and no reruns, prepared automatic refresh and restart no-send safety"]
    let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/fixture-results.json")
    try reportData.write(to: destination)
    print("PASS: real handler privacy, draft, routing, refresh and limits; benchmark saved to docs/fixture-results.json")
}
