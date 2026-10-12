import Foundation
import Darwin
import MessagesCore

enum Transport {
    static var directory: String { ProcessInfo.processInfo.environment["MESSAGES_SOCKET_DIR"] ?? "/tmp/alfred-messages-v083-\(getuid())" }
    static var path: String { directory + "/helper.sock" }
    static func address() throws -> sockaddr_un {
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure("Socket path too long.") }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
    static func privateDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory) { guard mkdir(directory, 0o700) == 0 else { throw Failure("Cannot create private helper endpoint.") } }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw Failure("Helper endpoint directory is not private.") }
    }
    static func peer(_ fd: Int32) -> Bool { var uid: uid_t = 0; var gid: gid_t = 0; return getpeereid(fd, &uid, &gid) == 0 && uid == getuid() }
    static func write(_ data: Data, fd: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
                guard n > 0 else { throw Failure("Helper connection interrupted. Check Messages before resubmitting.") }; offset += n
            }
        }
    }
    static func read(fd: Int32) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n >= 0 else { throw Failure("Helper request timed out. Check Messages before resubmitting.") }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
            guard data.count <= 16_000_000 else { throw Failure("Helper payload exceeds bound.") }
        }
        return data
    }
    static func timeout(_ fd: Int32, seconds: Int = 65) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout.size(ofValue: time)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout.size(ofValue: time)))
        var enabled: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, 4)
    }
    static func call(_ request: Request, seconds: Int = 65) throws -> Data {
        try privateDirectory()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw Failure("Cannot connect to helper.") }; defer { close(fd) }
        var addr = try address()
        func connectOnly() -> Bool {
            withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        }
        if !connectOnly() {
            // Bootstrap before writing any request. Never retry an interrupted/ambiguous submission.
            let daemon = Process()
            daemon.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            daemon.arguments = ["daemon"]
            let allowed = Set(["HOME", "PATH", "TMPDIR", "MESSAGES_STATE_ROOT", "MESSAGES_DATABASE", "MESSAGES_SOCKET_DIR"])
            daemon.environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
            daemon.standardInput = FileHandle.nullDevice; daemon.standardOutput = FileHandle.nullDevice; daemon.standardError = FileHandle.nullDevice
            try daemon.run()
            var connected = false
            for _ in 0..<100 {
                if connectOnly() { connected = true; break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard connected else { throw Failure("Bundled helper could not start or expose its endpoint. Reopen the workflow; check macOS permissions. No request was submitted.") }
        }
        guard peer(fd) else { throw Failure("Helper endpoint belongs to a different user.") }
        timeout(fd, seconds: seconds)
        try write(JSONEncoder().encode(request), fd: fd); shutdown(fd, SHUT_WR)
        return try read(fd: fd)
    }
    static func serve(_ handler: @escaping (Request) -> [String: Any]) throws {
        try privateDirectory()
        // flock prevents a second daemon from unlinking the active daemon's socket.
        let lockFD = Darwin.open(directory + "/daemon.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Helper already running.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw Failure("Cannot create helper endpoint.") }
        unlink(path); var addr = try address()
        let status = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0, listen(fd, 16) == 0 else { throw Failure("Cannot listen on helper endpoint (errno \(errno)).") }
        chmod(path, 0o600)
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 {
                // Back off on resource exhaustion (EMFILE/ENFILE) instead of spinning.
                if errno != EINTR { Thread.sleep(forTimeInterval: 0.1) }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { close(connection) }
                guard peer(connection) else { return }; timeout(connection)
                do {
                    let request = try JSONDecoder().decode(Request.self, from: read(fd: connection))
                    let response = handler(request)
                    try write(JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]), fd: connection)
                } catch {
                    let response: [String: Any] = ["error": "Invalid or interrupted helper request. Check Messages before resubmitting."]
                    if let data = try? JSONSerialization.data(withJSONObject: response) { try? write(data, fd: connection) }
                }
            }
        }
    }
}
