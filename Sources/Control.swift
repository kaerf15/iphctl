import Foundation
import CoreGraphics
import Darwin

final class FileLease {
    private let fd: Int32
    init(_ path: String, nonblocking: Bool = true) throws {
        fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ControlFailure(code: "control_unavailable", message: "无法打开控制锁") }
        var stat = Darwin.stat()
        guard fstat(fd, &stat) == 0, stat.st_uid == getuid(), stat.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw ControlFailure(code: "control_unavailable", message: "控制锁的所有者或类型无效")
        }
        if flock(fd, LOCK_EX | (nonblocking ? LOCK_NB : 0)) != 0 {
            close(fd)
            throw ControlFailure(code: "busy", message: "另一个 iphctl 正在执行动作；本次没有发送输入")
        }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

struct ControlState: Codable {
    var paused = false
    var generation: UInt64 = 0
}

final class ControlStore {
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        // mkdir sets the private mode atomically. Foundation creates then chmods,
        // which let another simultaneous first launch see a transient 0755 mode.
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
            throw ControlFailure(code: "control_unavailable", message: "无法创建控制目录")
        }
        var stat = Darwin.stat()
        guard lstat(directory.path, &stat) == 0, stat.st_uid == getuid(), stat.st_mode & S_IFMT == S_IFDIR,
              stat.st_mode & 0o077 == 0 else {
            throw ControlFailure(code: "control_unavailable", message: "控制目录必须是当前用户拥有的私有目录")
        }
    }
    func lease() throws -> FileLease { try FileLease(directory.appendingPathComponent("input.lock").path) }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let lock = try FileLease(directory.appendingPathComponent("state.lock").path, nonblocking: false)
        defer { withExtendedLifetime(lock) {} }
        return try body()
    }
    private func readUnlocked() throws -> ControlState {
        let path = directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return ControlState() }
        do { return try JSONDecoder().decode(ControlState.self, from: Data(contentsOf: path)) }
        catch { throw ControlFailure(code: "control_unavailable", message: "控制状态损坏；拒绝输入") }
    }
    func state() throws -> ControlState { try locked { try readUnlocked() } }
    func update(_ command: String) throws -> ControlState {
        try locked {
            var state = try readUnlocked()
            if command == "pause" { state.paused = true }
            if command == "resume" { state.paused = false }
            if command != "resume" { state.generation &+= 1 }
            try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
            return state
        }
    }
    func busy() throws -> Bool {
        do { let lock = try lease(); withExtendedLifetime(lock) {}; return false }
        catch let error as ControlFailure where error.code == "busy" { return true }
    }
}

final class ActionContext {
    let runtime: MirrorRuntime
    let store: ControlStore
    let frame: Frame
    private let generation: UInt64
    private let monitor: InterruptionMonitor
    private var release: (() -> Void)?
    private var savedCursor: CGPoint?
    private var expectedCursor: CGPoint?
    private(set) var events = 0
    private(set) var reports = 0
    private(set) var cleanupEvents = 0
    private(set) var cursorRestored = false

    init(runtime: MirrorRuntime, store: ControlStore, frame: Frame, generation: UInt64, monitor: InterruptionMonitor) {
        self.runtime = runtime; self.store = store; self.frame = frame
        self.generation = generation; self.monitor = monitor
    }
    func checkCancellation() throws {
        let state = try store.state()
        guard !state.paused else { throw ControlFailure(code: "paused", message: "手机控制已暂停") }
        guard state.generation == generation else { throw ControlFailure(code: "cancelled", message: "动作已取消") }
        guard !monitor.interrupted else { throw ControlFailure(code: "user_interrupted", message: "检测到其他鼠标或键盘输入，已取消后续动作") }
    }
    func validate(point: CGPoint? = nil, geometry: Bool = true, ready: Bool = true, focus: Bool = true) throws {
        try checkCancellation()
        let permission = runtime.permissions()
        guard permission.accessibility, permission.postEvents, permission.listenEvents else {
            throw ControlFailure(code: "permission_denied", message: "输入或输入监听权限不可用")
        }
        let current = try runtime.session(windowID: frame.id)
        guard let target = current.frame, target.id == frame.id, target.pid == frame.pid else {
            throw ControlFailure(code: "session_changed", message: "镜像窗口或进程已改变")
        }
        if geometry, target != frame { throw ControlFailure(code: "window_changed", message: "镜像窗口移动或缩放，已取消后续输入") }
        if ready, current.state != .ready { throw ControlFailure(code: "session_unavailable", message: "镜像不可用：\(current.state.rawValue)") }
        if focus, try !runtime.isFocused(target) { throw ControlFailure(code: "focus_lost", message: "镜像失去前台焦点，已取消后续输入") }
        if let point { try runtime.verifyTarget(point, frame: target) }
        if let expected = expectedCursor {
            let actual = try runtime.cursor()
            guard abs(actual.x - expected.x) <= 2, abs(actual.y - expected.y) <= 2 else {
                throw ControlFailure(code: "user_interrupted", message: "指针位置已改变，取消后续输入")
            }
        }
    }
    func wait(_ milliseconds: Int) throws {
        var remaining = milliseconds
        while remaining > 0 {
            try checkCancellation()
            let slice = min(20, remaining)
            runtime.sleep(milliseconds: slice)
            remaining -= slice
        }
        try checkCancellation()
    }
    func position(_ point: CGPoint) throws {
        try validate(point: point)
        if savedCursor == nil { savedCursor = try runtime.cursor() }
        try runtime.position(point)
        expectedCursor = point
    }
    func send(_ event: InputEvent) throws {
        try validate(point: event.point)
        let post = try runtime.prepare(event, frame: frame, cleanup: false)
        post(); events += 1
        if event.isWheel { reports += 1 }
        if let point = event.point, expectedCursor != nil { expectedCursor = point }
    }
    func mouseDown(_ point: CGPoint) throws {
        let up = try runtime.prepare(.mouse(.leftMouseUp, point), frame: frame, cleanup: true)
        try send(.mouse(.leftMouseDown, point))
        release = up
    }
    func mouseDrag(_ point: CGPoint) throws {
        let up = try runtime.prepare(.mouse(.leftMouseUp, point), frame: frame, cleanup: true)
        try send(.mouse(.leftMouseDragged, point))
        release = up
    }
    func mouseUp(_ point: CGPoint) throws {
        try send(.mouse(.leftMouseUp, point))
        release = nil
    }
    func key(_ code: CGKeyCode, flags: CGEventFlags = [], unicode: [UniChar] = [], toPID: Bool = false) throws {
        // Prepare both edges first. A creation failure must not leave a key down.
        let up = try runtime.prepare(.key(code, flags, false, unicode, toPID), frame: frame, cleanup: true)
        try send(.key(code, flags, true, unicode, toPID))
        release = up
        try wait(30)
        // Releases remain addressed to the original process if focus changes.
        up(); events += 1
        release = nil
    }
    func connect() throws -> Bool {
        try validate(ready: false)
        let pressed = try runtime.pressConnect(frame)
        if pressed { events += 1 }
        return pressed
    }
    func finish() {
        if let pending = release { pending(); events += 1; cleanupEvents += 1; release = nil }
        monitor.stop()
        if !monitor.interrupted, let saved = savedCursor, let expected = expectedCursor, let actual = try? runtime.cursor(),
           abs(actual.x - expected.x) <= 2, abs(actual.y - expected.y) <= 2 {
            do { try runtime.position(saved); cursorRestored = true } catch {}
        }
        savedCursor = nil
    }
    var receipt: [String: Any] {
        ["event_sent": events > 0, "events_sent": events, "reports": reports,
         "cleanup_events": cleanupEvents, "verified": false, "cursor_restored": cursorRestored]
    }
    func failure(_ error: Error) -> ControlFailure {
        var failure = error as? ControlFailure ?? ControlFailure(code: "input_failed", message: String(describing: error))
        failure.events = events; failure.reports = reports; failure.cleanupEvents = cleanupEvents
        return failure
    }
}

final class ActionExecutor {
    let runtime: MirrorRuntime
    let store: ControlStore
    init(runtime: MirrorRuntime, store: ControlStore) { self.runtime = runtime; self.store = store }
    func execute(allowBlocked: Bool = false, allowTransition: Bool = false,
                 _ body: (ActionContext) throws -> [String: Any]) throws -> [String: Any] {
        let lock = try store.lease()
        defer { withExtendedLifetime(lock) {} }
        let state = try store.state()
        guard !state.paused else { throw ControlFailure(code: "paused", message: "手机控制已暂停；执行 resume 后才能输入") }
        let permissions = runtime.permissions()
        guard permissions.accessibility, permissions.postEvents, permissions.listenEvents else {
            throw ControlFailure(code: "permission_denied", message: "需要运行环境已有的辅助功能、输入及输入监听权限；可执行 doctor 检查")
        }
        let before = try runtime.session(windowID: nil)
        guard let frame = before.frame else { throw ControlFailure(code: "session_unavailable", message: "镜像不可用：\(before.state.rawValue)") }
        guard allowBlocked || before.state == .ready else {
            throw ControlFailure(code: "session_unavailable", message: "镜像不可用：\(before.state.rawValue)")
        }
        try runtime.focus(frame)
        let focused = try runtime.session(windowID: frame.id)
        guard let target = focused.frame, target.pid == frame.pid else { throw ControlFailure(code: "session_changed", message: "聚焦时镜像窗口已改变") }
        let monitor = try runtime.monitor()
        let context = ActionContext(runtime: runtime, store: store, frame: target, generation: state.generation, monitor: monitor)
        do {
            try context.validate(ready: !allowBlocked)
            var result = try body(context)
            try context.validate(geometry: !allowTransition, ready: !allowBlocked && !allowTransition, focus: !allowTransition)
            context.finish()
            result.merge(context.receipt) { _, new in new }
            return result
        } catch {
            context.finish()
            throw context.failure(error)
        }
    }
}
