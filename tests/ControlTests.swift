import Foundation
import CoreGraphics

final class FakeMonitor: InterruptionMonitor {
    var interrupted = false
    var stopped = false
    func stop() { stopped = true }
}

final class FakeRuntime: MirrorRuntime {
    var permission = PermissionSnapshot(accessibility: true, postEvents: true, listenEvents: true, screenRecording: true)
    var snapshot = SessionSnapshot(frame: Frame(x: 10, y: 20, width: 300, height: 650, id: 42, pid: 7), state: .ready)
    var focused = true
    var focusFails = false
    var focusCalls = 0
    var posted: [(InputEvent, Bool, Frame)] = []
    var pointer = CGPoint(x: 1000, y: 900)
    let watcher = FakeMonitor()
    var prepareFailure: ((InputEvent) -> Bool)?
    var onPost: (() -> Void)?
    var onSleep: (() -> Void)?
    var occluded = false
    func permissions() -> PermissionSnapshot { permission }
    func session(windowID: CGWindowID?) throws -> SessionSnapshot { snapshot }
    func focus(_ frame: Frame) throws {
        focusCalls += 1
        if focusFails { throw ControlFailure(code: "focus_failed", message: "fake focus failed") }
    }
    func isFocused(_ frame: Frame) throws -> Bool { focused }
    func verifyTarget(_ point: CGPoint, frame: Frame) throws {
        if occluded { throw ControlFailure(code: "target_occluded", message: "fake target covered") }
    }
    func cursor() throws -> CGPoint { pointer }
    func position(_ point: CGPoint) throws { pointer = point }
    func prepare(_ event: InputEvent, frame: Frame, cleanup: Bool) throws -> () -> Void {
        if prepareFailure?(event) == true { throw ControlFailure(code: "event_creation_failed", message: "fake creation failed") }
        return { [self] in
            posted.append((event, cleanup, frame))
            if let point = event.point { pointer = point }
            if !cleanup { onPost?() }
        }
    }
    func monitor() throws -> InterruptionMonitor { watcher }
    func sleep(milliseconds: Int) { onSleep?() }
    func pressConnect(_ frame: Frame) throws -> Bool { true }
}

@main struct ControlTests {
    static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
    static func test(_ name: String, _ body: (FakeRuntime, ControlStore, ActionExecutor) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-ct-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = FakeRuntime(), store = try ControlStore(directory: folder)
        try body(runtime, store, ActionExecutor(runtime: runtime, store: store))
        count += 1
        print("PASS \(name)")
    }
    static func fails(_ executor: ActionExecutor, code: String, events: Int = 0, reports: Int = 0, cleanup: Int = 0,
                      _ action: (ActionContext) throws -> [String: Any]) throws {
        do { _ = try executor.execute(action); fatalError("Expected \(code)") }
        catch let failure as ControlFailure {
            expect(failure.code == code, "Expected \(code), got \(failure.code)")
            expect(failure.events == events && failure.reports == reports && failure.cleanupEvents == cleanup, "Incorrect partial receipt")
        }
    }
    static func main() throws {
        try test("missing permissions sends nothing") { runtime, _, executor in
            runtime.permission.postEvents = false
            try fails(executor, code: "permission_denied") { _ in fatalError("body ran") }
            expect(runtime.focusCalls == 0 && runtime.posted.isEmpty, "Focused despite permission denial")
        }
        try test("blocked or unknown sessions send nothing") { runtime, _, executor in
            for state in [MirrorState.disconnected, .connecting, .authenticationRequired, .blocked, .unknown] {
                runtime.snapshot.state = state
                try fails(executor, code: "session_unavailable") { _ in fatalError("body ran") }
            }
            expect(runtime.focusCalls == 0, "Focused blocked session")
        }
        try test("focus failure sends nothing") { runtime, _, executor in
            runtime.focusFails = true
            try fails(executor, code: "focus_failed") { _ in fatalError("body ran") }
        }
        try test("unconfirmed focus sends nothing and stops monitoring") { runtime, _, executor in
            runtime.focused = false
            try fails(executor, code: "focus_lost") { _ in fatalError("body ran") }
            expect(runtime.watcher.stopped, "Monitor leaked")
        }
        try test("resize cancels remaining wheel reports") { runtime, _, executor in
            runtime.onPost = { runtime.snapshot.frame!.width += 1 }
            try fails(executor, code: "window_changed", events: 1, reports: 1) { context in
                try context.send(.wheel(10, CGPoint(x: 100, y: 200)))
                try context.send(.wheel(10, CGPoint(x: 100, y: 200)))
                return [:]
            }
        }
        try test("disconnect after input reports partial execution") { runtime, _, executor in
            runtime.onPost = { runtime.snapshot.state = .disconnected }
            try fails(executor, code: "session_unavailable", events: 1, reports: 1) { context in
                try context.send(.wheel(10, CGPoint(x: 100, y: 200)))
                return [:]
            }
        }
        try test("window identity change is rejected") { runtime, _, executor in
            runtime.onPost = { runtime.snapshot.frame!.id = 43 }
            try fails(executor, code: "session_changed", events: 1, reports: 1) { context in
                try context.send(.wheel(10, CGPoint(x: 100, y: 200)))
                return [:]
            }
        }
        try test("occlusion sends no event") { runtime, _, executor in
            runtime.occluded = true
            try fails(executor, code: "target_occluded") { context in
                try context.send(.wheel(10, CGPoint(x: 100, y: 200)))
                return [:]
            }
        }
        try test("event creation failure does not claim delivery") { runtime, _, executor in
            runtime.prepareFailure = { _ in true }
            try fails(executor, code: "event_creation_failed") { context in
                try context.send(.wheel(10, CGPoint(x: 100, y: 200)))
                return [:]
            }
        }
        try test("key release is prepared before key down") { runtime, _, executor in
            runtime.prepareFailure = { event in if case .key(_, _, false, _, _) = event { return true }; return false }
            try fails(executor, code: "event_creation_failed") { context in
                try context.key(36)
                return [:]
            }
            expect(runtime.posted.isEmpty, "Key down escaped")
        }
        try test("external input cleans up mouse at original target") { runtime, _, executor in
            runtime.onPost = { runtime.watcher.interrupted = true }
            try fails(executor, code: "user_interrupted", events: 2, cleanup: 1) { context in
                try context.mouseDown(CGPoint(x: 100, y: 200))
                try context.wait(20)
                return [:]
            }
            expect(runtime.posted.count == 2 && runtime.posted.last!.1 && runtime.posted.last!.2.id == 42, "Wrong cleanup target")
        }
        try test("user pointer is not restored after interference") { runtime, _, executor in
            runtime.onSleep = { runtime.pointer = CGPoint(x: 900, y: 800); runtime.watcher.interrupted = true }
            try fails(executor, code: "user_interrupted") { context in
                try context.position(CGPoint(x: 100, y: 200))
                try context.wait(20)
                return [:]
            }
            expect(runtime.pointer == CGPoint(x: 900, y: 800), "Restoration overwrote user pointer")
        }
        try test("cancel during held key releases it") { runtime, store, executor in
            runtime.onSleep = { _ = try! store.update("cancel") }
            try fails(executor, code: "cancelled", events: 2, cleanup: 1) { context in
                try context.key(36)
                return [:]
            }
        }
        try test("pause prevents focus; resume enables input") { runtime, store, executor in
            _ = try store.update("pause")
            try fails(executor, code: "paused") { _ in fatalError("body ran") }
            expect(runtime.focusCalls == 0, "Paused action focused")
            _ = try store.update("resume")
            let result = try executor.execute { context in try context.key(53); return ["ok": true] }
            expect(result["events_sent"] as? Int == 2 && result["verified"] as? Bool == false, "Wrong resumed receipt")
        }
        try test("pause during input is observed before next report") { runtime, store, executor in
            runtime.onPost = { _ = try! store.update("pause") }
            try fails(executor, code: "paused", events: 1, reports: 1) { context in
                try context.send(.wheel(10, CGPoint(x: 100, y: 200)))
                try context.send(.wheel(10, CGPoint(x: 100, y: 200)))
                return [:]
            }
        }
        try test("resume is idempotent for an already running action") { runtime, store, executor in
            runtime.onPost = { _ = try! store.update("resume") }
            let result = try executor.execute { context in
                try context.send(.wheel(10, CGPoint(x: 100, y: 200)))
                return ["ok": true]
            }
            expect(result["events_sent"] as? Int == 1, "Resume interrupted active input")
        }
        try test("lease blocks another controller but permits cancellation") { runtime, store, executor in
            let held = try store.lease()
            try fails(executor, code: "busy") { _ in fatalError("body ran") }
            _ = try store.update("cancel")
            expect(runtime.focusCalls == 0, "Busy action focused")
            withExtendedLifetime(held) {}
        }
        try test("lease is released after an error") { _, store, executor in
            try fails(executor, code: "input_failed") { _ in throw AppError.message("fake body error") }
            let held = try store.lease()
            withExtendedLifetime(held) {}
        }
        try test("successful gesture restores pointer and has no cleanup") { runtime, _, executor in
            let original = runtime.pointer
            let result = try executor.execute { context in
                let point = CGPoint(x: 100, y: 200)
                try context.position(point)
                try context.mouseDown(point)
                try context.mouseUp(point)
                return ["ok": true]
            }
            expect(runtime.pointer == original && result["cursor_restored"] as? Bool == true, "Pointer not restored")
            expect(result["events_sent"] as? Int == 2 && result["cleanup_events"] as? Int == 0, "Wrong success receipt")
        }
        expect(classifySession([]) == .ready, "Live video misclassified")
        expect(classifySession([NativeNode(role: "AXButton", text: "untranslated")]) == .blocked, "Unknown UI treated as live")
        expect(classifySession([NativeNode(role: "AXSecureTextField", text: "")]) == .authenticationRequired, "Password field misclassified")
        expect(classifySession([NativeNode(role: "AXStaticText", text: "iPhone 使用中")]) == .inUse, "In-use state misclassified")
        let frame = Frame(x: 10, y: 20, width: 300, height: 650, id: 42, pid: 7)
        let now = Date()
        let capture = CaptureMetadata(id: "shot", frame: frame, scale: Scale(x: 2, y: 2), displays: "display-1", created: now)
        expect(capture.matches(frame: frame, displaySignature: "display-1", now: now, maxAge: 60), "Fresh geometry cache rejected")
        var resized = frame; resized.width += 1
        expect(!capture.matches(frame: resized, displaySignature: "display-1", now: now, maxAge: 60), "Resize did not invalidate cache")
        expect(!capture.matches(frame: frame, displaySignature: "display-2", now: now, maxAge: 60), "Display change did not invalidate cache")
        expect(!capture.matches(frame: frame, displaySignature: "display-1", now: now.addingTimeInterval(61), maxAge: 60), "Expired cache accepted")
        expect(!shouldCancelInput(type: .mouseMoved, sourcePID: 7, userData: 0, ownPID: 7, ownTag: 42, stopped: false), "Own event cancelled input")
        expect(!shouldCancelInput(type: .mouseMoved, sourcePID: 0, userData: 42, ownPID: 7, ownTag: 42, stopped: false), "Tagged event cancelled input")
        expect(shouldCancelInput(type: .keyDown, sourcePID: 0, userData: 0, ownPID: 7, ownTag: 42, stopped: false), "External event ignored")
        expect(shouldCancelInput(type: .tapDisabledByTimeout, sourcePID: 7, userData: 42, ownPID: 7, ownTag: 42, stopped: false), "Lost monitor ignored")
        expect(!shouldCancelInput(type: .tapDisabledByUserInput, sourcePID: 0, userData: 0, ownPID: 7, ownTag: 42, stopped: true), "Own monitor shutdown treated as interruption")
        print("\(count) control scenarios, session classification and capture invalidation checks passed")
    }
}
