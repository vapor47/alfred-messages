import Foundation
import AppKit
import ApplicationServices
import MessagesCore
import Darwin
import Carbon

struct LiveDispatchGuard: Codable {
    let session: String
    let token: String
    let pid: Int32
    static var path: String { Transport.directory + "/refresh.guard" }
    static func exists() -> Bool { var info = stat(); return lstat(path, &info) == 0 }
    static func read() -> LiveDispatchGuard? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_size < 1024,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func arm() -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        let fd = Darwin.open(Self.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }; defer { close(fd) }
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == $0.count }
        if !wrote { unlink(Self.path) }
        return wrote
    }
    func clear() { if Self.read()?.token == token { unlink(Self.path) } }
    static func clearInactive() {
        guard (try? Transport.privateDirectory()) != nil else { return }
        if let guardState = read() {
            if kill(guardState.pid, 0) != 0 && errno == ESRCH { guardState.clear() }
        } else if exists() {
            // A partial metadata write cannot have dispatched a key. Clear it only on explicit
            // conversation opening and only when no refresh cycle is writing/using the guard.
            let fd = Darwin.open(Transport.directory + "/refresh-cycle.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return }; defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { unlink(path); flock(fd, LOCK_UN) }
        }
    }
}
func liveSendBlocked(operation: String, action: String, argument: String) -> Bool {
    let couldSend = operation == "send" || (operation == "view" && ["", "return-send", "command-send"].contains(action))
    return couldSend && !LiveInput.containsRefresh(argument) && LiveDispatchGuard.exists()
}
func liveSessionVisible(_ session: String) -> Bool {
    guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.runningwithcrayons.Alfred").first else { return false }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    return (liveRead(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains {
        liveContains(liveElements($0), LiveInput.viewMarker(session))
    }
}
func liveRefreshVisible(_ session: String, token: String) -> Bool {
    if liveSessionVisible(session) { return true }
    // The heading's link may be unavailable during execution. The still-annotated
    // field plus independent dispatch guard identifies this exact in-flight request.
    guard let state = LiveDispatchGuard.read(), state.session == session, state.token == token,
          UUID(uuidString: token) != nil, AXIsProcessTrusted(),
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.runningwithcrayons.Alfred").first else { return false }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    return (liveRead(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains { window in
        liveElements(window).contains { element in
            [kAXTextFieldRole, kAXTextAreaRole].contains(liveRead(element, kAXRoleAttribute) as? String ?? "") &&
            LiveInput.refreshToken(liveRead(element, kAXValueAttribute) as? String ?? "") == token
        }
    }
}
private func liveRead(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}
private func liveWritable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var flag = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success && flag.boolValue
}
private func liveElements(_ root: AXUIElement) -> [AXUIElement] {
    var queue = [root], next = 0, result: [AXUIElement] = []
    while next < queue.count && result.count < 1000 {
        let element = queue[next]; next += 1; result.append(element)
        queue.append(contentsOf: liveRead(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return result
}
private func liveContains(_ elements: [AXUIElement], _ marker: String) -> Bool {
    elements.contains { element in
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXURLAttribute] {
            let value = liveRead(element, attribute)
            if let text = value as? String, text.contains(marker) { return true }
            if let url = value as? URL, url.absoluteString == marker { return true }
        }
        // Native text views may expose link destinations only in attributed text.
        // Inspect attributes in memory; never log the text or destination.
        guard let text = liveRead(element, kAXValueAttribute) as? String, !text.isEmpty else { return false }
        var range = CFRange(location: 0, length: text.utf16.count)
        guard let input = AXValueCreate(.cfRange, &range) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString, input, &value) == .success,
              let attributed = value as? NSAttributedString else { return false }
        var found = false
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            let destination = (value as? URL)?.absoluteString ?? (value as? String)
            if destination == marker { found = true; stop.pointee = true }
        }
        return found
    }
}
private func liveDetectionLabel(_ session: String) -> String {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.runningwithcrayons.Alfred")
    guard apps.count == 1, let app = apps.first else { return "alfred-process-unavailable" }
    let windows = liveRead(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
    if windows.isEmpty { return "accessible-windows-unavailable" }
    for window in windows {
        let elements = liveElements(window)
        if liveContains(elements, LiveInput.viewMarker(session)) { return "reply-control-unavailable" }
    }
    return "view-link-unavailable"
}
private func liveRange(_ field: AXUIElement) -> CFRange? {
    guard let value = liveRead(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) ? range : nil
}
private struct LiveControl {
    let field: AXUIElement
    let window: AXUIElement
    let elements: [AXUIElement]
    let pid: pid_t
    let scroll: AXUIElement?
}
private func liveControl(_ session: String) -> LiveControl? {
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.runningwithcrayons.Alfred")
    guard applications.count == 1, let app = applications.first else { return nil }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    for window in liveRead(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        let elements = liveElements(window)
        guard liveContains(elements, LiveInput.viewMarker(session)) else { continue }
        let fields = elements.filter {
            [kAXTextFieldRole, kAXTextAreaRole].contains(liveRead($0, kAXRoleAttribute) as? String ?? "") &&
            liveWritable($0, kAXValueAttribute) && liveRange($0) != nil
        }
        guard fields.count == 1 else { return nil }
        var bars = elements.filter { (liveRead($0, kAXRoleAttribute) as? String) == kAXScrollBarRole && (liveRead($0, kAXOrientationAttribute) as? String) == kAXVerticalOrientationValue && liveWritable($0, kAXValueAttribute) }
        for area in elements where (liveRead(area, kAXRoleAttribute) as? String) == kAXScrollAreaRole {
            if let raw = liveRead(area, kAXVerticalScrollBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let bar = unsafeBitCast(raw, to: AXUIElement.self)
                if liveWritable(bar, kAXValueAttribute), !bars.contains(where: { CFEqual($0, bar) }) { bars.append(bar) }
            }
        }
        return LiveControl(field: fields[0], window: window, elements: elements, pid: app.processIdentifier, scroll: bars.count == 1 ? bars[0] : nil)
    }
    return nil
}
private func liveInputMethodActive() -> Bool {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return true }
    let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
    // The experiments covered ordinary layouts, not active IME composition.
    return (type as String) != (kTISTypeKeyboardLayout as String)
}
private func focused(_ view: LiveControl) -> Bool { liveRead(view.field, kAXFocusedAttribute) as? Bool == true }

private final class LiveKeyboardBuffer {
    static let replayTag: Int64 = 0x4D53474C495645
    private let lock = NSLock()
    private let pid: pid_t
    private var events: [CGEvent] = []
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var active = false
    private var failed = false
    private var cancelled = false
    private var editingChanged = false
    private(set) var captured = 0
    private(set) var posted = 0
    private(set) var postedAction = false
    init(pid: pid_t) { self.pid = pid }
    func start() -> Bool {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<LiveKeyboardBuffer>.fromOpaque(context).takeUnretainedValue().receive(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        port = tap
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            let loop = CFRunLoopGetCurrent()!
            lock.lock()
            if cancelled { lock.unlock(); ready.signal(); return }
            runLoop = loop; active = true; lock.unlock()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
            CFRunLoopAddSource(loop, source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal(); CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        if ready.wait(timeout: .now()+1) != .success { finish(); return false }
        return true
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock(); defer { lock.unlock() }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains(type) {
            editingChanged = true; return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { failed = true; active = false; return Unmanaged.passUnretained(event) }
        let decision = Self.captureDecision(active: active, tag: event.getIntegerValueField(.eventSourceUserData), queued: events.count)
        guard decision != 0 else { return Unmanaged.passUnretained(event) }
        guard decision == 1, let copy = event.copy() else { failed = true; active = false; return Unmanaged.passUnretained(event) }
        events.append(copy); captured += 1; return nil
    }
    static func captureDecision(active: Bool, tag: Int64, queued: Int) -> Int {
        if !active || tag == replayTag { return 0 }
        return queued < 256 ? 1 : -1
    }
    var editingUnchanged: Bool { lock.lock(); defer { lock.unlock() }; return !editingChanged }
    var healthy: Bool { lock.lock(); defer { lock.unlock() }; return !failed }
    func drain(while valid: () -> Bool, ready: () -> Bool = { true }) -> Bool {
        let began = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime-began < 4 {
            guard valid() else { suspend(); return false }
            if !ready() { Thread.sleep(forTimeInterval: 0.005); continue }
            lock.lock()
            if failed { lock.unlock(); suspend(); return false }
            if events.isEmpty { active = false; lock.unlock(); return true }
            let event = events.removeFirst(); lock.unlock()
            event.setIntegerValueField(.eventSourceUserData, value: Self.replayTag); event.postToPid(pid); posted += 1
            let action = event.type == .keyDown && [Int64(36), Int64(76)].contains(event.getIntegerValueField(.keyboardEventKeycode))
            if action { postedAction = true }
            // Let a physical send/refresh start before posting subsequent buffered typing.
            Thread.sleep(forTimeInterval: action ? 0.025 : 0.002)
        }
        suspend(); return false
    }
    // Suspension leaves failed queued input in bounded memory for recovery; it is not discarded here.
    func suspend() {
        lock.lock(); active = false; lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
    }
    func finish() {
        suspend()
        lock.lock(); cancelled = true; let loop = runLoop; lock.unlock()
        if let loop { CFRunLoopStop(loop) }
    }
    deinit { finish() }
}

func startLiveDriver(_ session: String, chat: String) {
    guard UUID(uuidString: session) != nil, !chat.isEmpty, AXIsProcessTrusted() else { return }
    let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = ["watch-view", session, chat]
    child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try? child.run()
}
func liveCycleSucceeded(parsed: Bool, restored: Bool, replayed: Bool) -> Bool {
    parsed && restored && replayed
}
// Window for the annotated draft to read back. Buffered typing is held during it.
let liveReadbackWindow: TimeInterval = 0.3
// Continuous history-read failure tolerated before pausing (e.g. a briefly busy database).
let liveUnavailableGrace: TimeInterval = 10
let liveMaxDispatchFailures = 5
// A pre-dispatch failure is retried only after the draft and every buffered key were restored.
func liveDispatchRetry(restored: Bool, replayed: Bool, failures: Int) -> Bool {
    restored && replayed && failures < liveMaxDispatchFailures
}
func liveShouldStop(unreachable: Int) -> Bool { unreachable >= 4 }
// Content-free classification of a failed annotation readback.
func liveReadbackFailure(observed: String?, draft: String, annotated: String, token: String, focused: Bool, healthy: Bool) -> String {
    if !healthy { return "buffer-failed" }
    if !focused { return "focus-lost" }
    guard let observed else { return "value-unreadable" }
    if observed == draft { return "stale" }
    if LiveInput.refreshToken(observed) == token { return observed.hasPrefix(draft) ? "extra-text" : "draft-changed" }
    if LiveInput.containsRefresh(observed) { return "marker-altered" }
    return "other"
}
func liveDriver(_ session: String, chat: String, settings: Settings) {
    guard UUID(uuidString: session) != nil, AXIsProcessTrusted() else { return }
    try? Transport.privateDirectory()
    let path = Transport.directory + "/view-" + session + ".lock"
    let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
    // Do not unlink the lock: an inode replacement could permit duplicate active drivers.
    func call(_ operation: String, token: String? = nil, label: String = "") -> [String: Any]? {
        let request = Request(operation: operation, settings: settings, chat: chat, action: label, viewSession: session, refreshToken: token)
        guard let data = try? Transport.call(request, seconds: 2) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func report(_ label: String) { _ = call("auto-fault", label: label) }
    func note(_ label: String) { _ = call("auto-note", label: label) }
    let started = ProcessInfo.processInfo.systemUptime
    var seen = false
    // Transient conditions are retried within bounds instead of ending the driver,
    // which would stop updates for this view until it is reopened or a reply is sent.
    var dispatchFailures = 0
    var unreachable = 0
    var unavailableSince: TimeInterval?
    // Returns false when the driver should stop; true to continue polling.
    func checked(_ state: [String: Any]?) -> Bool {
        guard let state else {
            unreachable += 1
            if liveShouldStop(unreachable: unreachable) { report("helper-unreachable"); return false }
            Thread.sleep(forTimeInterval: 0.25); return true
        }
        unreachable = 0
        if state["error"] != nil { report("view-expired"); return false }
        if state["unavailable"] as? Bool == true {
            let now = ProcessInfo.processInfo.systemUptime
            if unavailableSince == nil { unavailableSince = now; note("history-read-unavailable") }
            if now - unavailableSince! > liveUnavailableGrace { report("history-read-unavailable"); return false }
            Thread.sleep(forTimeInterval: 0.5); return true
        }
        unavailableSince = nil
        return true
    }
    while true {
        guard let view = liveControl(session) else {
            if seen {
                // Sending can temporarily disable or replace the input control. Keep the
                // existing driver and heartbeat while this exact conversation is visible;
                // a newly spawned driver may already have lost the per-session lock race.
                guard liveSessionVisible(session) else { return }
                let state = call("auto-check")
                guard checked(state) else { return }
                if state == nil || state?["unavailable"] as? Bool == true { continue }
                Thread.sleep(forTimeInterval: 0.1); continue
            }
            if ProcessInfo.processInfo.systemUptime-started > 3 { report(liveDetectionLabel(session)); return }
            Thread.sleep(forTimeInterval: 0.05); continue
        }
        seen = true
        let state = call("auto-check")
        guard checked(state) else { return }
        guard let check = state, check["unavailable"] as? Bool != true else { continue }
        if check["changed"] as? Bool != true || liveInputMethodActive() || !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn, .maskShift]).isEmpty || !focused(view) || liveRead(view.field, kAXEnabledAttribute) as? Bool != true {
            Thread.sleep(forTimeInterval: 0.5); continue
        }
        guard let prepared = call("auto-prepare"), let token = prepared["refresh_token"] as? String else { Thread.sleep(forTimeInterval: 0.1); continue }
        let cycleFD = Darwin.open(Transport.directory + "/refresh-cycle.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard cycleFD >= 0 else { report("cycle-lock-unavailable"); return }
        defer { close(cycleFD) }
        if flock(cycleFD, LOCK_EX | LOCK_NB) != 0 { Thread.sleep(forTimeInterval: 0.1); continue }
        defer { flock(cycleFD, LOCK_UN) }
        let buffer = LiveKeyboardBuffer(pid: view.pid)
        guard buffer.start() else { report("keyboard-buffer-unavailable"); return }
        defer { buffer.finish() }
        Thread.sleep(forTimeInterval: 0.025)
        guard let armed = liveControl(session), CFEqual(armed.field, view.field), focused(armed), liveRead(armed.field, kAXEnabledAttribute) as? Bool == true,
              let draft = liveRead(armed.field, kAXValueAttribute) as? String, let range = liveRange(armed.field), buffer.healthy else {
            _ = buffer.drain { liveControl(session).map { CFEqual($0.field, view.field) && focused($0) } ?? false }
            buffer.finish(); report("snapshot-unavailable-buffered-\(buffer.captured)-posted-\(buffer.posted)"); return
        }
        // A leftover marker from an earlier cycle must never become the restored draft.
        guard !LiveInput.containsRefresh(draft) else {
            _ = buffer.drain { liveControl(session).map { focused($0) && buffer.editingUnchanged } ?? false }
            buffer.finish(); report("draft-contains-marker"); return
        }
        let dispatchGuard = LiveDispatchGuard(session: session, token: token, pid: getpid())
        guard dispatchGuard.arm() else {
            _ = buffer.drain { liveControl(session).map { focused($0) && buffer.editingUnchanged } ?? false }
            buffer.finish(); report("dispatch-guard-unavailable"); return
        }
        let marker = LiveInput.refreshMarker(token)
        let annotated = draft + marker
        let scroll = armed.scroll.flatMap { liveRead($0, kAXValueAttribute) as? Double }
        var restored = false
        func restore(_ current: LiveControl, allowEmpty: Bool = false) -> Bool {
            guard focused(current), CFEqual(current.window, armed.window), buffer.editingUnchanged else { return false }
            guard let text = liveRead(current.field, kAXValueAttribute) as? String else { return false }
            if text.isEmpty && !allowEmpty && !draft.isEmpty { return false }
            if text != annotated && text != draft && !text.isEmpty {
                // A failed tap may have allowed newer input. Remove only our annotation; never overwrite it.
                let source = text as NSString
                let removed = source.range(of: marker)
                if removed.location != NSNotFound, let selected = liveRange(current.field) {
                    let cleaned = source.replacingCharacters(in: removed, with: "")
                    func position(_ p: Int) -> Int { p <= removed.location ? p : max(removed.location, p-removed.length) }
                    var adjusted = CFRange(location: position(selected.location), length: position(selected.location+selected.length)-position(selected.location))
                    if AXUIElementSetAttributeValue(current.field, kAXValueAttribute as CFString, cleaned as CFString) == .success, let value = AXValueCreate(.cfRange, &adjusted) {
                        _ = AXUIElementSetAttributeValue(current.field, kAXSelectedTextRangeAttribute as CFString, value)
                    }
                }
                return false
            }
            guard liveWritable(current.field, kAXValueAttribute), liveWritable(current.field, kAXSelectedTextRangeAttribute) else { return false }
            guard AXUIElementSetAttributeValue(current.field, kAXValueAttribute as CFString, draft as CFString) == .success else { return false }
            var safe = CFRange(location: min(max(0,range.location), draft.utf16.count), length: 0)
            safe.length = min(max(0,range.length), draft.utf16.count-safe.location)
            guard let value = AXValueCreate(.cfRange, &safe), AXUIElementSetAttributeValue(current.field, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
            return liveRead(current.field, kAXValueAttribute) as? String == draft
        }
        // AX setters may acknowledge before the next read reflects the new value.
        // Verify the exact annotated draft before posting any synthetic key.
        var dispatchFailure = "dispatch-focus-unavailable"
        var verified = false
        if focused(armed), buffer.healthy {
            let written = AXUIElementSetAttributeValue(armed.field, kAXValueAttribute as CFString, annotated as CFString)
            dispatchFailure = "dispatch-annotation-write-error-" + String(written.rawValue)
            if written == .success {
                let verifyStarted = ProcessInfo.processInfo.systemUptime
                var observed: String?
                repeat {
                    observed = liveRead(armed.field, kAXValueAttribute) as? String
                    if observed == annotated, LiveInput.refreshToken(observed ?? "") == token {
                        verified = true; break
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                } while buffer.healthy && focused(armed) && ProcessInfo.processInfo.systemUptime-verifyStarted < liveReadbackWindow
                if !verified {
                    dispatchFailure = "dispatch-annotation-readback-" + liveReadbackFailure(observed: observed, draft: draft, annotated: annotated, token: token, focused: focused(armed), healthy: buffer.healthy)
                }
            }
        } else if !buffer.healthy { dispatchFailure = "dispatch-keyboard-buffer-unavailable" }
        guard verified, focused(armed), buffer.healthy,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
            dispatchGuard.clear()
            if let current = liveControl(session) { restored = restore(current) }
            var replayed = false
            if restored { replayed = buffer.drain(while: { liveControl(session).map { focused($0) && buffer.editingUnchanged } ?? false }, ready: { liveControl(session).map { liveRead($0.field, kAXEnabledAttribute) as? Bool == true } ?? false }) }
            buffer.finish()
            let label = dispatchFailure + "-buffered-\(buffer.captured)-posted-\(buffer.posted)"
            // No key was dispatched; once the draft and buffered typing are restored, retry later.
            dispatchFailures += 1
            if liveDispatchRetry(restored: restored, replayed: replayed, failures: dispatchFailures) {
                note(label); Thread.sleep(forTimeInterval: 0.25 * Double(dispatchFailures)); continue
            }
            report(label); return
        }
        dispatchFailures = 0
        down.flags = []; up.flags = []
        down.setIntegerValueField(.eventSourceUserData, value: LiveKeyboardBuffer.replayTag); up.setIntegerValueField(.eventSourceUserData, value: LiveKeyboardBuffer.replayTag)
        down.postToPid(view.pid); up.postToPid(view.pid)
        var lastHeartbeat = ProcessInfo.processInfo.systemUptime
        func heartbeat() {
            let now = ProcessInfo.processInfo.systemUptime
            if now-lastHeartbeat >= 0.5, liveRefreshVisible(session, token: token) {
                _ = call("auto-check"); lastHeartbeat = now
            }
        }
        let before = ProcessInfo.processInfo.systemUptime
        var completed = false
        while ProcessInfo.processInfo.systemUptime-before < 2 {
            heartbeat()
            guard buffer.healthy else { break }
            guard let current = liveControl(session) else {
                // Alfred can temporarily remove AX controls while evaluating its script.
                // Wait without restoring or replaying into an unidentified destination.
                Thread.sleep(forTimeInterval: 0.01); continue
            }
            guard focused(current) else { break }
            if liveRead(current.field, kAXEnabledAttribute) as? Bool == true,
               call("auto-result", token: token)?["finalized"] as? Bool == true {
                completed = true; dispatchGuard.clear(); restored = restore(current); break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        // Never remove the annotation until the script has captured the posted refresh.
        // Otherwise a delayed Return could observe the original draft and submit it.
        var parsed = completed || call("auto-result", token: token)?["finalized"] as? Bool == true
        if parsed { dispatchGuard.clear() }
        if parsed, !restored, let current = liveControl(session), liveRead(current.field, kAXEnabledAttribute) as? Bool == true { restored = restore(current) }
        var replayed = false
        if restored { replayed = buffer.drain(while: { liveControl(session).map { focused($0) && buffer.editingUnchanged } ?? false }, ready: { liveControl(session).map { liveRead($0.field, kAXEnabledAttribute) as? Bool == true } ?? false }) }
        buffer.suspend()
        if !replayed {
            // Retain queued keys temporarily and only replay back into the exact unchanged draft.
            let recovery = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime-recovery < 30 {
                heartbeat()
                if let current = liveControl(session), focused(current), liveRead(current.field, kAXEnabledAttribute) as? Bool == true {
                    if !parsed {
                        parsed = call("auto-result", token: token)?["finalized"] as? Bool == true
                    }
                    if parsed { dispatchGuard.clear() }
                    if parsed && !restored { restored = restore(current, allowEmpty: false) }
                    let unchanged = liveRead(current.field, kAXValueAttribute) as? String == draft && liveRange(current.field)?.location == range.location && liveRange(current.field)?.length == range.length
                    let clearedAfterAction = buffer.postedAction && (liveRead(current.field, kAXValueAttribute) as? String)?.isEmpty == true
                    if restored && (unchanged || clearedAfterAction) {
                        replayed = buffer.drain(while: { liveControl(session).map { focused($0) && buffer.editingUnchanged } ?? false }, ready: { liveControl(session).map { liveRead($0.field, kAXEnabledAttribute) as? Bool == true } ?? false })
                        if replayed { break }
                    }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        buffer.finish()
        guard liveCycleSucceeded(parsed: parsed, restored: restored, replayed: replayed) else { report("refresh-paused-buffered-\(buffer.captured)-posted-\(buffer.posted)"); return }
        guard call("auto-result", token: token)?["success"] as? Bool == true else { report("frame-fetch-rejected"); return }
        if let position = scroll, !buffer.postedAction {
            let target = position >= 0.98 ? 1.0 : position
            let began = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime-began < 0.8 {
                guard let current = liveControl(session) else { return }
                if let bar = current.scroll {
                    _ = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: target))
                    Thread.sleep(forTimeInterval: 0.025)
                    if let value = liveRead(bar, kAXValueAttribute) as? Double, abs(value-target) < 0.03 {
                        Thread.sleep(forTimeInterval: 0.075)
                        if let settled = liveRead(bar, kAXValueAttribute) as? Double, abs(settled-target) < 0.03 { break }
                    }
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
}

func liveDriverTests() throws {
    // A cycle recovered after the initial wait is successful once capture, restore
    // and replay finish; it must not require completion in the first wait window.
    precondition(liveCycleSucceeded(parsed: true, restored: true, replayed: true))
    precondition(!liveCycleSucceeded(parsed: false, restored: true, replayed: true))
    precondition(!liveCycleSucceeded(parsed: true, restored: false, replayed: true))
    precondition(!liveCycleSucceeded(parsed: true, restored: true, replayed: false))
    precondition(liveDispatchRetry(restored: true, replayed: true, failures: 1))
    precondition(!liveDispatchRetry(restored: false, replayed: true, failures: 1))
    precondition(!liveDispatchRetry(restored: true, replayed: false, failures: 1))
    precondition(!liveDispatchRetry(restored: true, replayed: true, failures: liveMaxDispatchFailures))
    precondition(!liveShouldStop(unreachable: 3) && liveShouldStop(unreachable: 4))
    let probeToken = UUID().uuidString, marker = LiveInput.refreshMarker(probeToken)
    func readback(_ observed: String?, focused: Bool = true, healthy: Bool = true) -> String {
        liveReadbackFailure(observed: observed, draft: "Draft", annotated: "Draft" + marker, token: probeToken, focused: focused, healthy: healthy)
    }
    precondition(readback("Draft") == "stale")
    precondition(readback("Draft" + marker + "x") == "extra-text")
    precondition(readback("Other" + marker) == "draft-changed")
    precondition(readback("Draft" + LiveInput.refreshPrefix) == "marker-altered")
    precondition(readback(nil) == "value-unreadable")
    precondition(readback("Draft", focused: false) == "focus-lost")
    precondition(readback("Draft", healthy: false) == "buffer-failed")
    precondition(LiveKeyboardBuffer.captureDecision(active: true, tag: 0, queued: 255) == 1)
    precondition(LiveKeyboardBuffer.captureDecision(active: true, tag: 0, queued: 256) == -1)
    precondition(LiveKeyboardBuffer.captureDecision(active: true, tag: LiveKeyboardBuffer.replayTag, queued: 0) == 0)
    precondition(LiveKeyboardBuffer.captureDecision(active: false, tag: 0, queued: 0) == 0)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("messages-live-test-"+UUID().uuidString)
    let previous = ProcessInfo.processInfo.environment["MESSAGES_SOCKET_DIR"]
    setenv("MESSAGES_SOCKET_DIR", directory.path, 1)
    defer {
        if let previous { setenv("MESSAGES_SOCKET_DIR", previous, 1) } else { unsetenv("MESSAGES_SOCKET_DIR") }
        try? FileManager.default.removeItem(at: directory)
    }
    try Transport.privateDirectory()
    let state = LiveDispatchGuard(session: UUID().uuidString, token: UUID().uuidString, pid: getpid())
    precondition(state.arm())
    precondition(LiveDispatchGuard.read()?.token == state.token)
    precondition(!state.arm())
    for action in ["", "return-send", "command-send"] { precondition(liveSendBlocked(operation: "view", action: action, argument: "Unsubmitted draft")) }
    precondition(liveSendBlocked(operation: "send", action: "command-send", argument: "Unsubmitted draft"))
    precondition(!liveSendBlocked(operation: "view", action: "history", argument: ""))
    precondition(!liveSendBlocked(operation: "view", action: "", argument: "Draft"+LiveInput.refreshMarker(state.token)))
    LiveDispatchGuard.clearInactive(); precondition(LiveDispatchGuard.exists())
    let keys = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: LiveDispatchGuard.path))) as! [String: Any]
    precondition(Set(keys.keys) == Set(["session", "token", "pid"]))
    state.clear(); precondition(!LiveDispatchGuard.exists())
    // Malformed guard metadata must still block an unmarked execution, never fall through to send.
    FileManager.default.createFile(atPath: LiveDispatchGuard.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    precondition(LiveDispatchGuard.read() == nil)
    precondition(liveSendBlocked(operation: "view", action: "", argument: "Do not send"))
    LiveDispatchGuard.clearInactive(); precondition(!LiveDispatchGuard.exists())
    print("PASS: production keyboard capture policy, private dispatch guard, malformed-state no-send routing; no taps installed or native events posted")
}
