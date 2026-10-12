import Foundation
import Darwin
import CSQLite
import MessagesCore

func check(_ value: Bool, _ message: String, file: StaticString, line: UInt) {
    guard value else {
        FileHandle.standardError.write(Data("FAIL: \(file):\(line): \(message)\n".utf8))
        exit(1)
    }
}
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { check(value, "Expected true", file: file, line: line) }
func XCTAssertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { check(!value, "Expected false", file: file, line: line) }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { check(value == nil, "Expected nil", file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { check(a == b, "Expected \(a) == \(b)", file: file, line: line) }
func XCTAssertThrowsError(_ expression: @autoclosure () throws -> Any, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression(); preconditionFailure("Expected error", file: file, line: line) } catch {}
}
final class CoreTests {
    var root: URL!
    func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("messages-tests-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func fixture() throws -> String {
        let path = root.appendingPathComponent("chat-" + UUID().uuidString + ".db").path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE chat(guid TEXT,display_name TEXT);
        CREATE TABLE handle(id TEXT);
        CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
        CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER,handle_id INTEGER,attributedBody BLOB,associated_message_type INTEGER,associated_message_guid TEXT);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
        CREATE TABLE attachment(transfer_name TEXT,mime_type TEXT);
        CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
        INSERT INTO chat VALUES('iMessage;+;group-exact','Friends 👋');
        INSERT INTO chat VALUES('iMessage;-;person','');
        INSERT INTO handle VALUES('+15551234567'),('person@example.com');
        INSERT INTO chat_handle_join VALUES(1,1),(1,2),(2,1);
        INSERT INTO message VALUES('a','Hello 世界 **bold**',1000000000000000,0,1,NULL,0,NULL);
        INSERT INTO message VALUES('b','',2000000000000000,1,0,NULL,0,NULL);
        INSERT INTO message VALUES('c','',3000000000000000,0,2,NULL,2001,'p:0/a');
        INSERT INTO message VALUES('d','',500000000000000,0,1,NULL,0,NULL);
        INSERT INTO chat_message_join VALUES(1,1),(1,2),(1,3),(2,4);
        INSERT INTO attachment VALUES('Photo 🐈.heic','image/heic');
        INSERT INTO message_attachment_join VALUES(2,1);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return path
    }
    func testReadOnlyUnicodeGroupsAttachmentsReactionsChronology() throws {
        let path = try fixture(); let value = try Reader(path: path).read(Settings(), contacts: false)
        XCTAssertEqual(value.conversations.count, 2)
        let chat = value.conversations[0]
        XCTAssertEqual(chat.id, "iMessage;+;group-exact")
        XCTAssertEqual(chat.participants.count, 2)
        XCTAssertTrue(Render.searchText(chat, names: ["+15551234567": "Alice"]).contains("alice"))
        XCTAssertEqual(chat.messages.map(\.guid), ["a", "b", "c"])
        XCTAssertEqual(chat.messages[1].attachments, ["Photo 🐈.heic"])
        XCTAssertEqual(chat.messages[2].reaction, "Liked")
        let markdown = Render.history(chat, names: [:])
        XCTAssertTrue(markdown.contains("Hello 世界 \\*\\*bold\\*\\*"))
        XCTAssertTrue(markdown.contains("Liked to “Hello 世界"))
        XCTAssertTrue(markdown.contains("**Me**"))
        let db = try Database(path: path)
        XCTAssertThrowsError(try db.rows("DELETE FROM message"))
        XCTAssertEqual(try Reader(path: path).read(Settings(conversations: 1, messages: 2), contacts: false).conversations[0].messages.count, 2)
    }
    func testSchemaFailureAndMissingDatabase() throws {
        XCTAssertThrowsError(try Reader(path: root.appendingPathComponent("missing.db").path).read(Settings()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing.db").path))
        let path = try fixture(); var db: OpaquePointer?; sqlite3_open(path, &db); sqlite3_exec(db, "ALTER TABLE message RENAME TO unsupported", nil, nil, nil); sqlite3_close(db)
        XCTAssertThrowsError(try Reader(path: path).read(Settings()))
    }
    func testAttributedBodyAndDates() throws {
        let expected = "👩🏽‍💻 café 日本語"
        let data = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: expected), requiringSecureCoding: true)
        XCTAssertEqual(Reader.attributedText(data), expected)
        let legacy = Data(Array("streamtyped NSString".utf8) + [0x84, 0x01, 0x2b, UInt8(expected.utf8.count)] + Array(expected.utf8))
        XCTAssertEqual(Reader.attributedText(legacy), expected)
        XCTAssertNil(Reader.attributedText(Data([1,2,3])))
        XCTAssertEqual(Reader.date(1_000_000_000_000).timeIntervalSince1970, Reader.date(1000).timeIntervalSince1970)
    }
    func waitForSnapshot(_ engine: Engine) throws -> Snapshot {
        engine.refresh()
        for _ in 0..<200 { if let value = try engine.get() { return value }; Thread.sleep(forTimeInterval: 0.01) }
        throw Failure("Fixture refresh timed out")
    }
    func testPrivacyTransitionsLimitsAndAtomicPermissions() throws {
        let store = CacheStore(root: root.appendingPathComponent("state"))
        let engine = try Engine(reader: Reader(path: fixture()), store: store, settings: Settings())
        _ = try waitForSnapshot(engine)
        // Snapshot publication precedes asynchronous persistence completion; synchronize through status.
        _ = engine.status()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("snapshot.json").path))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("snapshot.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try engine.configure(Settings(conversations: 1, messages: 1))
        XCTAssertEqual(try engine.get()?.conversations.count, 1)
        XCTAssertEqual(try engine.get()?.conversations.first?.messages.count, 1)
        try engine.configure(Settings(mode: .memory))
        _ = try waitForSnapshot(engine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        try engine.configure(Settings(mode: .off))
        XCTAssertEqual(try engine.get()?.conversations.count, 2)
        XCTAssertEqual(engine.status()["conversations"] as? Int, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        let reports = try engine.benchmark(iterations: 2)
        XCTAssertEqual(reports.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertTrue(reports.allSatisfy { $0["disk_io"] as? Bool == false })
        try engine.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
    func testRestartPoliciesAndGenerationRace() throws {
        let store = CacheStore(root: root.appendingPathComponent("state"))
        let engine = try Engine(reader: Reader(path: fixture()), store: store, settings: Settings())
        engine.refresh(); try engine.configure(Settings(mode: .off))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        _ = try waitForSnapshot(try Engine(reader: Reader(path: fixture()), store: store, settings: Settings(mode: .memory)))
        XCTAssertNil(store.load())
    }
    func testSendFailureDuplicateAndExactID() throws {
        let guarder = SubmissionGuard(); var calls = 0
        XCTAssertThrowsError(try guarder.submit(chat: "group-exact", draft: "Hi 👋", token: "one") { calls += 1; throw Failure("ambiguous") })
        XCTAssertThrowsError(try guarder.submit(chat: "group-exact", draft: "Hi 👋", token: "one") { calls += 1 })
        XCTAssertEqual(calls, 1)
        try guarder.submit(chat: "group-exact", draft: "Hi 👋", token: "two") {
            calls += 1
            XCTAssertThrowsError(try guarder.submit(chat: "group-exact", draft: "Other", token: "three") { calls += 1 })
        }
        XCTAssertEqual(calls, 2)
        XCTAssertThrowsError(try guarder.submit(chat: "", draft: "Hi", token: "four") {})
        XCTAssertThrowsError(try guarder.submit(chat: "group", draft: "  \n", token: "five") {})
        XCTAssertTrue(Automation.sendScript.contains("every chat whose id is chatID"))
        // Compile only; perform is never invoked, so nothing is sent.
        for source in [Automation.sendScript, Automation.openScript] {
            var error: NSDictionary?
            XCTAssertTrue(NSAppleScript(source: source)?.compileAndReturnError(&error) == true)
        }
        XCTAssertFalse(Automation.sendScript.contains("participant"))
    }
    func testAppleEventArguments() throws {
        let source = """
        on perform(chatID, draft)
          return chatID & ":" & draft
        end perform
        """
        let draft = "Hello 世界 \"quoted\" \n `$(touch /tmp/no)`"
        XCTAssertEqual(try Automation.run(source, chat: "iMessage;+;exact-group", text: draft), "iMessage;+;exact-group:" + draft)
    }
    func testContactFallbackAndEscaping() {
        XCTAssertEqual(Render.name("person@example.com", [:]), "person@example.com")
        let names = MessagesNameResolver.match([("+1 (555) 123-4567", "Alex 👋"), ("PERSON@EXAMPLE.COM", "Taylor"), ("unknown", "")], handles: ["+15551234567", "person@example.com", "Me"])
        XCTAssertEqual(names["+15551234567"], "Alex 👋")
        XCTAssertEqual(names["person@example.com"], "Taylor")
        XCTAssertNil(names["Me"])
        XCTAssertEqual(MessagesNameResolver.normalize("+1 (555) 123-4567"), "15551234567")
        XCTAssertEqual(Render.escape("[link](https://x) <script> wow!"), "[link]\u{200c}(https://x) <script> wow!")
    }
    func testSearchRanking() throws {
        func chat(_ id: String, _ title: String = "", with participants: [String]) -> Conversation {
            Conversation(rowID: 0, id: id, title: title, participants: participants, messages: [], activity: Date())
        }
        let names = ["+1": "Alice Wong", "+2": "José Núñez", "+3": "Bob", "+4": "Hal", "+5": "Sally", "+6": "Mary Ann May", "+7": "Alice"]
        func level(_ c: Conversation, _ q: String) -> Int? { Render.matchRank(c, names: names, query: Render.fold(q))?.level }
        let alice = chat("alice", with: ["+1"])
        XCTAssertEqual(level(alice, "alice wong"), 0)
        XCTAssertEqual(level(alice, "alice w"), 1)
        XCTAssertEqual(level(alice, "wong"), 2)
        XCTAssertEqual(level(chat("mary", with: ["+6"]), "ann m"), 2)
        XCTAssertEqual(level(alice, "wong al"), 3)
        XCTAssertEqual(level(alice, "ong"), 4)
        XCTAssertEqual(level(alice, "+1"), 5)
        XCTAssertNil(level(alice, "zed"))
        XCTAssertEqual(level(chat("jose", with: ["+2"]), "jose nunez"), 0)
        XCTAssertEqual(level(chat("jose", with: ["+2"]), "  JOSÉ   n "), 1)
        XCTAssertEqual(Render.fold("   "), "")
        // Chat name is tried first; participants are the fallback.
        let party = chat("party", "Al's Party", with: ["+3", "+4"])
        XCTAssertEqual(Render.matchRank(party, names: names, query: "al")?.source, 0)
        XCTAssertEqual(Render.matchRank(party, names: names, query: "bob")?.source, 1)
        // Through the list handler: rank, then chat name before participant, then recency.
        let path = root.appendingPathComponent("search.db").path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE chat(guid TEXT,display_name TEXT);
        CREATE TABLE handle(id TEXT);
        CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
        CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER,handle_id INTEGER);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
        CREATE TABLE attachment(transfer_name TEXT,mime_type TEXT);
        CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
        INSERT INTO chat VALUES('bob',''),('sally',''),('party','Al''s Party'),('alice',''),('hal','');
        INSERT INTO handle VALUES('+3'),('+5'),('+4'),('+7');
        INSERT INTO chat_handle_join VALUES(1,1),(2,2),(3,1),(3,3),(4,4),(5,3);
        INSERT INTO message VALUES('m1','x',5000,0,1),('m2','x',4000,0,2),('m3','x',3000,0,3),('m4','x',2000,0,4),('m5','x',1000,0,3);
        INSERT INTO chat_message_join VALUES(1,1),(2,2),(3,3),(4,4),(5,5);
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let service = try Service(root: root.appendingPathComponent("search-state"), database: path, nameLookup: { _ in names })
        func ids(_ query: String) throws -> [String] {
            for _ in 0..<500 {
                let items = service.handle(Request(operation: "list", settings: Settings(mode: .off), query: query))["items"] as? [[String: Any]] ?? []
                if items.first?["uid"] != nil { return items.compactMap { $0["uid"] as? String } }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return []
        }
        XCTAssertEqual(try ids(""), ["bob", "sally", "party", "alice", "hal"])
        XCTAssertEqual(try ids("al"), ["party", "alice", "sally", "hal"])
        XCTAssertEqual(try ids("  ÀL "), ["party", "alice", "sally", "hal"])
    }
    func testIdleRefreshAvoidsReadsAndWrites() throws {
        let path = try fixture()
        let engine = try Engine(reader: Reader(path: path, nameLookup: { chats in
            Dictionary(uniqueKeysWithValues: Set(chats.flatMap(\.participants)).map { ($0, "Name " + $0) })
        }), store: CacheStore(root: root), settings: Settings(mode: .disk))
        engine.backgroundNameLookup = { false }
        try engine.refreshNow()
        let file = root.appendingPathComponent("cache/snapshot.json").path
        func inode() -> UInt64 { var info = stat(); _ = stat(file, &info); return info.st_ino }
        func settle() { while engine.status()["refreshing"] as? Bool == true { Thread.sleep(forTimeInterval: 0.01) } }
        let written = inode()
        XCTAssertTrue(written != 0)
        // Unchanged content is not rewritten.
        try engine.refreshNow()
        XCTAssertEqual(inode(), written)
        // A names-only pass never touches the database, and identical names cause no write.
        try FileManager.default.moveItem(atPath: path, toPath: path + ".gone")
        engine.backgroundNameLookup = { true }
        engine.refresh(namesOnly: true); settle()
        XCTAssertEqual(engine.status()["error"] as? String, "")
        XCTAssertEqual(try engine.get()?.conversations.count, 2)
        XCTAssertEqual(try engine.get()?.names["+15551234567"], "Name +15551234567")
        XCTAssertEqual(inode(), written)
        // A full refresh reads, and reports the missing database.
        engine.refresh(); settle()
        XCTAssertFalse((engine.status()["error"] as? String ?? "").isEmpty)
        // Changed content is written.
        try FileManager.default.moveItem(atPath: path + ".gone", toPath: path)
        var db: OpaquePointer?; sqlite3_open(path, &db)
        sqlite3_exec(db, "INSERT INTO message VALUES('e','New',4000000000000000,0,1,NULL,0,NULL); INSERT INTO chat_message_join VALUES(2,5);", nil, nil, nil); sqlite3_close(db)
        try engine.refreshNow()
        XCTAssertTrue(inode() != written)
    }
    func testPaging() throws {
        // Five chats, newest first: c1 … c5, with handles h1@x … h5@x.
        let path = root.appendingPathComponent("paging.db").path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        var sql = """
        CREATE TABLE chat(guid TEXT,display_name TEXT); CREATE TABLE handle(id TEXT);
        CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
        CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER,handle_id INTEGER);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
        CREATE TABLE attachment(transfer_name TEXT,mime_type TEXT); CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
        """
        for i in 1...5 { sql += "INSERT INTO chat VALUES('c\(i)',''); INSERT INTO handle VALUES('h\(i)@x'); INSERT INTO chat_handle_join VALUES(\(i),\(i)); INSERT INTO message VALUES('m\(i)','hi',\(10 - i)000,0,\(i)); INSERT INTO chat_message_join VALUES(\(i),\(i));" }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let lookups = NSLock(); var lookupCount = 0
        let lookup: ([Conversation]) -> [String: String] = { chats in
            lookups.lock(); lookupCount += 1; lookups.unlock()
            return Dictionary(uniqueKeysWithValues: chats.flatMap(\.participants).map { ($0, "Name " + $0) })
        }
        // Engine: pages read on demand, never written, with names resolved before returning and kept in memory only.
        let settings = Settings(mode: .disk, conversations: 2)
        let engine = try Engine(reader: Reader(path: path, nameLookup: lookup), store: CacheStore(root: root.appendingPathComponent("paging-engine")), settings: settings)
        engine.backgroundNameLookup = { true }
        let second = try engine.page(2)
        XCTAssertEqual(second.conversations.map(\.id), ["c3", "c4"]); XCTAssertTrue(second.hasMore)
        XCTAssertEqual(second.names["h4@x"], "Name h4@x")
        XCTAssertEqual(engine.knownNames()["h3@x"], "Name h3@x")
        XCTAssertEqual(lookupCount, 1)
        // Known names are reused; no second lookup.
        XCTAssertEqual(try engine.page(2).names["h3@x"], "Name h3@x")
        XCTAssertEqual(lookupCount, 1)
        // While Messages is not running, a page shows handles rather than launching it.
        engine.backgroundNameLookup = { false }
        XCTAssertNil(try engine.page(3).names["h5@x"])
        XCTAssertEqual(lookupCount, 1)
        engine.backgroundNameLookup = { true }
        let third = try engine.page(3)
        XCTAssertEqual(third.conversations.map(\.id), ["c5"]); XCTAssertFalse(third.hasMore)
        XCTAssertTrue(try engine.page(4).conversations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("paging-engine/cache/snapshot.json").path))
        try engine.clear()
        XCTAssertNil(engine.knownNames()["h3@x"])
        // List handler: More row, page marker, last page, search within a page.
        let service = try Service(root: root.appendingPathComponent("paging-service"), database: path, nameLookup: lookup)
        let memory = Settings(mode: .memory, conversations: 2)
        func list(_ query: String) -> [[String: Any]] {
            for _ in 0..<500 {
                let items = service.handle(Request(operation: "list", settings: memory, query: query))["items"] as? [[String: Any]] ?? []
                if (items.first?["title"] as? String)?.hasPrefix("Loading") != true { return items }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return []
        }
        func uids(_ items: [[String: Any]]) -> [String] { items.compactMap { $0["uid"] as? String } }
        func moreRow(_ items: [[String: Any]]) -> String? { items.last.flatMap { $0["title"] as? String == "More conversations…" ? $0["autocomplete"] as? String : nil } }
        let first = list("")
        XCTAssertEqual(uids(first), ["c1", "c2"]); XCTAssertEqual(moreRow(first), "»2 ")
        XCTAssertEqual(first.last?["valid"] as? Bool, false); XCTAssertNil(first.last?["uid"])
        XCTAssertEqual((first.last?["icon"] as? [String: String])?["path"], "more.png")
        XCTAssertEqual(uids(list("»2")), ["c3", "c4"]); XCTAssertEqual(moreRow(list("»2 ")), "»3 ")
        XCTAssertEqual(uids(list("»3")), ["c5"]); XCTAssertNil(moreRow(list("»3")))
        XCTAssertEqual(list("»4").first?["title"] as? String, "No older conversations")
        XCTAssertEqual(uids(list("»2 h4")), ["c4"]); XCTAssertNil(moreRow(list("»2 h4")))
        XCTAssertEqual(uids(list("h2")), ["c2"]); XCTAssertNil(moreRow(list("h2")))
        XCTAssertEqual(list("»x").first?["title"] as? String, "No matching recent conversations")
    }
    func testNameLookupFailures() throws {
        let conversations = (1...3).map { n in Conversation(rowID: Int64(n), id: "synthetic-\(n)", title: "", participants: ["test-\(n)@example.invalid"], messages: [], activity: Date()) }
        var visited: [String] = []
        let before = MessagesNameResolver.diagnostics()
        let names = MessagesNameResolver.resolve(conversations, lookup: { chat in
            visited.append(chat.id)
            if chat.rowID == 1 { throw AutomationFailure(-1728) }
            if chat.rowID == 2 { throw AutomationFailure(-1712) }
            return MessagesNameResolver.Batch([(chat.participants[0], "Synthetic third name")], participantFailures: 1)
        })
        XCTAssertEqual(visited.count, 3)
        XCTAssertEqual(names["test-3@example.invalid"], "Synthetic third name")
        let after = MessagesNameResolver.diagnostics()
        XCTAssertEqual((after["unavailable_chats"] ?? 0) - (before["unavailable_chats"] ?? 0), 1)
        XCTAssertEqual((after["timeouts"] ?? 0) - (before["timeouts"] ?? 0), 1)
        XCTAssertEqual((after["participant_failures"] ?? 0) - (before["participant_failures"] ?? 0), 1)
        visited.removeAll()
        _ = MessagesNameResolver.resolve(conversations, lookup: { chat in visited.append(chat.id); throw AutomationFailure(-1743) })
        XCTAssertEqual(visited.count, 1)
        XCTAssertEqual(MessagesNameResolver.merge(["a": "Known"], ["a": "  ", "b": "New"]), ["a": "Known", "b": "New"])
    }
    func testNamePreservationDuringRefresh() throws {
        let db = try fixture()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var calls = 0
        let reader = Reader(path: db, nameLookup: { _ in
            calls += 1
            if calls == 1 { return ["+15551234567": "Known phone name"] }
            if calls == 2 { entered.signal(); _ = release.wait(timeout: .now()+3); return ["person@example.com": "New email name"] }
            return [:]
        })
        let store = CacheStore(root: root.appendingPathComponent("name-store"))
        let engine = try Engine(reader: reader, store: store, settings: Settings(mode: .disk))
        engine.backgroundNameLookup = { true }
        try engine.refreshNow()
        engine.refresh()
        XCTAssertTrue(entered.wait(timeout: .now()+3) == .success)
        XCTAssertEqual(engine.retainedNames()["+15551234567"], "Known phone name")
        XCTAssertEqual(store.load()?.names["+15551234567"], "Known phone name")
        release.signal()
        for _ in 0..<200 {
            if engine.retainedNames()["person@example.com"] != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(engine.retainedNames()["+15551234567"], "Known phone name")
        XCTAssertEqual(engine.retainedNames()["person@example.com"], "New email name")
        try engine.refreshNow()
        XCTAssertEqual(engine.retainedNames()["+15551234567"], "Known phone name")
        XCTAssertEqual(engine.retainedNames()["person@example.com"], "New email name")
    }
    func testReviewRegressions() throws {
        // Avatars follow resolved names instead of freezing on raw-handle initials.
        let path = try fixture()
        let store = CacheStore(root: root.appendingPathComponent("avatar-store"))
        var snapshot = try Reader(path: path).read(Settings(), contacts: false)
        let direct = snapshot.conversations.first { $0.id == "iMessage;-;person" }!
        try store.save(snapshot)
        let avatars = store.directory.appendingPathComponent("avatars")
        // An unnamed handle has no avatar, so the list shows the bundled icon.
        XCTAssertNil(CacheStore.iconName(direct, [:]))
        XCTAssertEqual(CacheStore.initials(direct, [:]), "")
        let unnamedFiles = try FileManager.default.contentsOfDirectory(atPath: avatars.path).count
        snapshot.names = ["+15551234567": "Alex Example"]
        try store.save(snapshot)
        XCTAssertEqual(CacheStore.initials(direct, snapshot.names), "AE")
        XCTAssertTrue(FileManager.default.fileExists(atPath: avatars.appendingPathComponent(CacheStore.iconName(direct, snapshot.names)!).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: avatars.path).count, unnamedFiles + 1)
        // Unnamed groups use named participants only; titles skip leading symbols.
        let group = Conversation(rowID: 9, id: "g", title: "", participants: ["+15550001111", "a@example.com", "+15552223333"], messages: [], activity: Date())
        XCTAssertEqual(CacheStore.initials(group, ["a@example.com": "alice smith"]), "AS")
        XCTAssertEqual(CacheStore.initials(group, ["+15552223333": "Bo", "a@example.com": "Al"]), "AB")
        XCTAssertNil(CacheStore.iconName(group, [:]))
        XCTAssertEqual(CacheStore.initials(Conversation(rowID: 9, id: "t", title: "🏠 Family (home)", participants: [], messages: [], activity: Date()), [:]), "F")

        // A refresh requested during a scan is rerun rather than dropped.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var lookups: [[String]] = []
        let blocking = Reader(path: path, nameLookup: { chats in
            lookups.append(chats.map(\.id))
            if lookups.count == 1 { entered.signal(); _ = release.wait(timeout: .now()+3) }
            return [:]
        })
        let engine = try Engine(reader: blocking, store: CacheStore(root: root.appendingPathComponent("dirty-store")), settings: Settings(mode: .memory))
        engine.backgroundNameLookup = { true }
        engine.refresh()
        XCTAssertTrue(entered.wait(timeout: .now()+3) == .success)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET text='Changed during scan' WHERE guid='d'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        engine.refresh()
        release.signal()
        var latest = ""
        for _ in 0..<300 {
            latest = (try engine.get())?.conversations.first { $0.id == "iMessage;-;person" }?.messages.last?.text ?? ""
            if latest == "Changed during scan" { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(latest, "Changed during scan")

        // Background lookups cover only chats missing names, and never run when disallowed.
        var asked: [[String]] = []
        let partial = Reader(path: path, nameLookup: { chats in asked.append(chats.map(\.id)); return ["+15551234567": "Alex Example"] })
        let named = try Engine(reader: partial, store: CacheStore(root: root.appendingPathComponent("named-store")), settings: Settings(mode: .memory))
        named.backgroundNameLookup = { false }
        _ = try waitForSnapshot(named)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(asked.count, 0)
        named.backgroundNameLookup = { true }
        named.refresh()
        for _ in 0..<300 where named.retainedNames()["+15551234567"] == nil { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(asked.first.map(Set.init), Set(["iMessage;+;group-exact", "iMessage;-;person"]))
        asked.removeAll()
        named.refresh()
        for _ in 0..<300 where asked.isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(asked.first, ["iMessage;+;group-exact"])

        // Chats yielding no name are skipped briefly; partially named chats are not.
        MessagesNameResolver.resetMisses()
        let chats = [Conversation(rowID: 1, id: "throttle-unknown", title: "", participants: ["+15550000000"], messages: [], activity: Date()),
                     Conversation(rowID: 2, id: "throttle-partial", title: "", participants: ["+15550000001", "+15550000002"], messages: [], activity: Date())]
        var seen: [String] = []
        let lookup: ([Conversation]) -> [String: String] = { list in seen += list.map(\.id); return ["+15550000001": "Known"] }
        let now = Date()
        _ = MessagesNameResolver.throttled(chats, now: now, lookup: lookup)
        XCTAssertEqual(seen, ["throttle-unknown", "throttle-partial"])
        seen.removeAll(); _ = MessagesNameResolver.throttled(chats, now: now.addingTimeInterval(10), lookup: lookup)
        XCTAssertEqual(seen, ["throttle-partial"])
        seen.removeAll(); _ = MessagesNameResolver.throttled(chats, now: now.addingTimeInterval(61), lookup: lookup)
        XCTAssertEqual(seen, ["throttle-unknown", "throttle-partial"])
        MessagesNameResolver.resetMisses()

        // The benchmark measures reader/render without Apple-event lookups.
        var benchmarkLookups = 0
        let quiet = try Engine(reader: Reader(path: path, nameLookup: { _ in benchmarkLookups += 1; return [:] }), store: CacheStore(root: root.appendingPathComponent("bench-store")), settings: Settings(mode: .off))
        _ = try quiet.benchmark(iterations: 2)
        XCTAssertEqual(benchmarkLookups, 0)

        // Decoded settings are clamped like constructed ones.
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"mode":"memory","conversations":-5,"messages":100000,"sendKey":"other"}"#.utf8))
        XCTAssertEqual(decoded, Settings(mode: .memory, conversations: 1, messages: 200, sendKey: "return"))

        // Alfred's Markdown dialect: no visible backslashes except Alfred's own \* escape.
        let w = "\u{200c}"
        XCTAssertEqual(Render.escape("Hi! #1 a|b <b> [x] ~y~ 3.5 - ok"), "Hi! #1 a|b <b> [x] ~y~ 3.5 - ok")
        XCTAssertEqual(Render.escape("- item\n+ plus\n1. first\n  2) second\n---\n> quote\n# head\n| pipe\n![i](x.png)\n\tTab\nplain"),
                       "\(w)- item  \n\(w)+ plus  \n\(w)1. first  \n\(w)  2) second  \n\(w)---  \n\(w)> quote  \n\(w)# head  \n\(w)| pipe  \n\(w)![i]\(w)(x.png)  \n\(w)\tTab  \nplain")
        XCTAssertEqual(Render.escape("a_b_c 5*3 `x` one_ lone\\"), "a\u{ff3f}b\u{ff3f}c 5*3 \u{ff40}x\u{ff40} one\u{ff3f} lone\\\(w)")
        XCTAssertEqual(Render.escape("solo_ \\*not"), "solo_ \\\(w)*not")
        XCTAssertEqual(Render.escape("```js\ncode\n\npara\r\nnext"), "\u{ff40}\u{ff40}\u{ff40}js  \ncode\n\npara  \nnext")
        // Web addresses keep their exact link target while their visible text is protected.
        XCTAssertEqual(Render.escape("see https://e.com/a_b_(c) now"), "see [https\(w)://e\(w).com/a\u{ff3f}b\u{ff3f}(c)](https://e.com/a_b_(c%29) now")
        XCTAssertEqual(Render.escape("one_ https://e.com/a_b"), "one\u{ff3f} [https\(w)://e\(w).com/a\u{ff3f}b](https://e.com/a_b)")
        XCTAssertEqual(Render.escape("https://e.com/a_b plain"), "https://e.com/a_b plain")
        XCTAssertEqual(Render.escape("<kbd>k</kbd> &#xFE0E;"), "<\(w)kbd>k</kbd> &\(w)#xFE0E;")
        // An unclosed fence or quote in one message cannot swallow later messages.
        let fenced = Conversation(rowID: 1, id: "c", title: "T", participants: ["a"], messages: [
            Message(guid: "1", sender: "a", date: Date(), text: "```\nopen"), Message(guid: "2", sender: "Me", date: Date(), text: "> q")], activity: Date())
        for line in Render.history(fenced, names: [:]).split(separator: "\n") where !line.hasPrefix("# ") && !line.hasPrefix("**") && line != "---" {
            XCTAssertFalse(line.hasPrefix("```") || line.hasPrefix(">"))
        }
        XCTAssertFalse(Render.history(fenced, names: [:]).contains("\\"))

        // Emoji tapbacks use their stored emoji.
        XCTAssertEqual(Reader.reaction(type: 2006, emoji: "🎉"), "Reacted 🎉")
        XCTAssertEqual(Reader.reaction(type: 3006, emoji: "🎉"), "Removed 🎉 reaction")
        XCTAssertEqual(Reader.reaction(type: 2006, emoji: nil), "Reaction (2006)")
        XCTAssertEqual(Reader.reaction(type: 2001, emoji: nil), "Liked")
        XCTAssertNil(Reader.reaction(type: 0, emoji: nil))

        // The denormalized join date orders chats the same way when present.
        let modern = try fixture()
        XCTAssertEqual(sqlite3_open(modern, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE chat_message_join ADD COLUMN message_date INTEGER; UPDATE chat_message_join SET message_date=(SELECT date FROM message WHERE ROWID=message_id);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let ordered = try Reader(path: modern).read(Settings(), contacts: false).conversations
        XCTAssertEqual(ordered.map(\.id), ["iMessage;+;group-exact", "iMessage;-;person"])
        XCTAssertEqual(ordered[0].messages[1].attachments, ["Photo 🐈.heic"])
    }
}

let suite = CoreTests()
let tests: [(String, () throws -> Void)] = [
    ("read-only, Unicode, exact groups, attachments, reactions, chronology", suite.testReadOnlyUnicodeGroupsAttachmentsReactionsChronology),
    ("schema failures and missing database", suite.testSchemaFailureAndMissingDatabase),
    ("attributed bodies and date formats", suite.testAttributedBodyAndDates),
    ("privacy transitions, reductions, atomic permissions and benchmarks", suite.testPrivacyTransitionsLimitsAndAtomicPermissions),
    ("restart privacy and stale refresh race", suite.testRestartPoliciesAndGenerationRace),
    ("send failures and duplicate submissions", suite.testSendFailureDuplicateAndExactID),
    ("Contacts fallback and Markdown escaping", suite.testContactFallbackAndEscaping),
    ("search ranking: name levels, chat name first, accents, spaces, recency ties", suite.testSearchRanking),
    ("idle refresh: no rewrite when unchanged, names-only pass skips the database", suite.testIdleRefreshAvoidsReadsAndWrites),
    ("paging: More row, page marker, last page, search within a page, names resolved before display", suite.testPaging),
    ("chat lookup isolation and privacy-safe name diagnostics", suite.testNameLookupFailures),
    ("preserve disk and memory names during raw and partial refresh", suite.testNamePreservationDuringRefresh),
    ("Apple event argument passing without sending", suite.testAppleEventArguments),
    ("review regressions: avatars, mid-scan refresh, name lookup scope/throttle, benchmark, settings, escaping, reactions", suite.testReviewRegressions)
]
for (name, test) in tests {
    try suite.setUpWithError()
    do { try test(); print("PASS: " + name) } catch { try suite.tearDownWithError(); throw error }
    try suite.tearDownWithError()
}
print("Passed \(tests.count) fixture tests")
try serviceTests()
