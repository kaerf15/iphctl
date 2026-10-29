import AppKit
import CoreGraphics
import Foundation
import ImageIO

private let inputTag: Int64 = Int64.random(in: 1...Int64.max)

private func axValue(_ element: AXUIElement, _ key: String) throws -> CFTypeRef {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success, let value else {
        throw ControlFailure(code: "session_unknown", message: "无法读取镜像的辅助功能属性")
    }
    return value
}

private func axText(_ element: AXUIElement, _ key: String) -> String {
    (try? axValue(element, key)) as? String ?? ""
}

private func axRect(_ element: AXUIElement) -> CGRect? {
    guard let position = try? axValue(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = try? axValue(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &p),
          AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

private func axWindow(_ frame: Frame) throws -> AXUIElement {
    let app = AXUIElementCreateApplication(frame.pid)
    guard let windows = try axValue(app, kAXWindowsAttribute) as? [AXUIElement],
          let window = windows.first(where: { element in
              guard let r = axRect(element) else { return false }
              return abs(r.minX - frame.x) < 4 && abs(r.minY - frame.y) < 4 &&
                  abs(r.width - frame.width) < 4 && abs(r.height - frame.height) < 4
          }) else { throw ControlFailure(code: "session_unknown", message: "无法匹配镜像的辅助功能窗口") }
    return window
}

private func nativeNodes(_ frame: Frame) throws -> [(NativeNode, AXUIElement)] {
    var result: [(NativeNode, AXUIElement)] = []
    func walk(_ element: AXUIElement, depth: Int) throws {
        guard depth < 40 else { throw ControlFailure(code: "session_unknown", message: "镜像辅助功能层级异常") }
        let role = axText(element, kAXRoleAttribute)
        let subrole = axText(element, kAXSubroleAttribute)
        if role == "AXToolbar" || ["AXCloseButton", "AXMinimizeButton", "AXZoomButton"].contains(subrole) { return }
        if ["AXStaticText", "AXButton", "AXTextField", "AXSecureTextField", "AXCheckBox", "AXSheet"].contains(role) {
            // Do not read secure input values.
            let text = role == "AXSecureTextField" ? "" :
                [axText(element, kAXValueAttribute), axText(element, kAXTitleAttribute), axText(element, kAXDescriptionAttribute)]
                .filter { !$0.isEmpty }.joined(separator: " ")
            result.append((NativeNode(role: role, text: text), element))
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return }
        guard status == .success, let children = value as? [AXUIElement] else {
            throw ControlFailure(code: "session_unknown", message: "镜像辅助功能树不可用，拒绝猜测连接状态")
        }
        for child in children { try walk(child, depth: depth + 1) }
    }
    try walk(axWindow(frame), depth: 0)
    return result
}

final class MacInterruptionMonitor: InterruptionMonitor {
    private let lock = NSLock()
    private var cancelled = false
    private var stopped = false
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var port: CFMachPort?
    var interrupted: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func mark() { lock.lock(); cancelled = true; lock.unlock() }
    init() throws {
        let mask: CGEventMask = [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown,
                                .otherMouseUp, .otherMouseDragged, .keyDown, .keyUp, .flagsChanged, .scrollWheel]
            .reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }
        let ready = DispatchSemaphore(value: 0)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<MacInterruptionMonitor>.fromOpaque(info).takeUnretainedValue()
            if shouldCancelInput(type: type, sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                                 userData: event.getIntegerValueField(.eventSourceUserData), ownPID: Int64(getpid()),
                                 ownTag: inputTag, stopped: monitor.shouldStop) { monitor.mark() }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: pointer) else {
            throw ControlFailure(code: "input_monitor_unavailable", message: "无法监听其他键鼠输入；请用 doctor 检查输入监听权限")
        }
        self.port = port
        let worker = Thread { [weak self, port] in
            let loop = CFRunLoopGetCurrent()!
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
            self?.lock.lock(); self?.runLoop = loop; self?.lock.unlock()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            while self?.shouldStop == false {
                CFRunLoopRunInMode(.defaultMode, 0.05, false)
            }
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            self?.lock.lock(); self?.runLoop = nil; self?.lock.unlock()
        }
        thread = worker
        worker.start()
        guard ready.wait(timeout: .now() + 2) == .success else {
            stop()
            throw ControlFailure(code: "input_monitor_unavailable", message: "输入监听启动超时")
        }
    }
    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() {
        lock.lock(); stopped = true; let loop = runLoop; let port = port; lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let loop { CFRunLoopStop(loop) }
        // The tap owns an unretained callback context: join before deallocation.
        while let thread, !thread.isFinished { Thread.sleep(forTimeInterval: 0.001) }
    }
    deinit { stop() }
}

final class MacRuntime: MirrorRuntime {
    func permissions() -> PermissionSnapshot {
        PermissionSnapshot(accessibility: AXIsProcessTrusted(), postEvents: CGPreflightPostEventAccess(),
                           listenEvents: CGPreflightListenEventAccess(), screenRecording: CGPreflightScreenCaptureAccess())
    }
    func session(windowID: CGWindowID? = nil) throws -> SessionSnapshot {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return SessionSnapshot(state: .notRunning)
        }
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            throw ControlFailure(code: "session_unknown", message: "无法读取镜像窗口列表")
        }
        let frames = windows.compactMap { window -> Frame? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  windowID == nil || windowID == id,
                  let dict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary), rect.width > 50, rect.height > 50 else { return nil }
            return Frame(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, id: id, pid: app.processIdentifier)
        }
        guard let frame = frames.max(by: { $0.height < $1.height }) else { return SessionSnapshot(state: .noWindow) }
        guard AXIsProcessTrusted() else { return SessionSnapshot(frame: frame, state: .unknown, detail: "缺少辅助功能权限") }
        do {
            let nodes = try nativeNodes(frame).map(\.0)
            return SessionSnapshot(frame: frame, state: classifySession(nodes), detail: nodes.map(\.text).filter { !$0.isEmpty }.joined(separator: " "))
        } catch {
            return SessionSnapshot(frame: frame, state: .unknown, detail: String(describing: error))
        }
    }
    func isFocused(_ frame: Frame) throws -> Bool {
        let app = AXUIElementCreateApplication(frame.pid)
        guard let front = try axValue(app, kAXFrontmostAttribute) as? Bool, front else { return false }
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              let top = windows.first(where: { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
                  ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0 }) else { return false }
        return (top[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frame.pid &&
            (top[kCGWindowNumber as String] as? NSNumber)?.uint32Value == frame.id
    }
    func focus(_ frame: Frame) throws {
        if try isFocused(frame) { return }
        guard let app = NSRunningApplication(processIdentifier: frame.pid) else {
            throw ControlFailure(code: "session_changed", message: "镜像进程已退出")
        }
        let window = try axWindow(frame)
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           minimized as? Bool == true {
            guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                throw ControlFailure(code: "focus_failed", message: "无法恢复镜像窗口")
            }
        }
        let deadline = Date().addingTimeInterval(2)
        repeat {
            app.activate(options: [.activateAllWindows])
            // Some Mirroring windows reject AXRaise even when activation
            // succeeds. Accept only the measured focus/z-order result below.
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(frame.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            let current = try session(windowID: frame.id)
            if let now = current.frame, try isFocused(now) { return }
        } while Date() < deadline
        throw ControlFailure(code: "focus_failed", message: "两秒内未能确认镜像的前台焦点；没有发送输入")
    }
    func verifyTarget(_ point: CGPoint, frame: Frame) throws {
        guard frame.rect.contains(point), let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            throw ControlFailure(code: "target_unavailable", message: "目标不在可见镜像窗口内")
        }
        var found = false
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let dict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary), rect.contains(point) else { continue }
            found = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == frame.id && rect == frame.rect
            break
        }
        guard found else { throw ControlFailure(code: "target_occluded", message: "镜像目标被其他窗口遮挡") }
        // A Dock layer-20 window covers the display structurally. AX checks the
        // actual hit instead of treating its full bounds as an opaque overlay.
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { throw ControlFailure(code: "target_unknown", message: "无法确认接收目标输入的 App") }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid == frame.pid else {
            throw ControlFailure(code: "target_occluded", message: "目标被其他 App 或系统窗口遮挡")
        }
    }
    func cursor() throws -> CGPoint {
        guard let event = CGEvent(source: nil) else { throw ControlFailure(code: "input_failed", message: "无法读取指针位置") }
        return event.location
    }
    func position(_ point: CGPoint) throws {
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw ControlFailure(code: "event_creation_failed", message: "无法创建指针定位事件")
        }
        move.setIntegerValueField(.eventSourceUserData, value: inputTag)
        guard CGWarpMouseCursorPosition(point) == .success else { throw ControlFailure(code: "input_failed", message: "指针定位失败") }
        move.post(tap: .cghidEventTap)
    }
    func prepare(_ spec: InputEvent, frame: Frame, cleanup: Bool) throws -> () -> Void {
        let event: CGEvent?
        var toPID = cleanup
        switch spec {
        case .mouse(let type, let point):
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        case .key(let code, let flags, let down, let unicode, let targeted):
            guard let source = CGEventSource(stateID: .hidSystemState) else {
                throw ControlFailure(code: "event_creation_failed", message: "无法创建键盘事件源")
            }
            event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            if !unicode.isEmpty {
                unicode.withUnsafeBufferPointer { p in
                    if let base = p.baseAddress { event?.keyboardSetUnicodeString(stringLength: p.count, unicodeString: base) }
                }
            }
            toPID = targeted || cleanup
        case .wheel(let delta, let point):
            event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0)
            event?.location = point
        }
        guard let event else { throw ControlFailure(code: "event_creation_failed", message: "无法创建输入事件") }
        event.setIntegerValueField(.eventSourceUserData, value: inputTag)
        return { if toPID { event.postToPid(frame.pid) } else { event.post(tap: .cghidEventTap) } }
    }
    func monitor() throws -> InterruptionMonitor { try MacInterruptionMonitor() }
    func sleep(milliseconds: Int) { Thread.sleep(forTimeInterval: Double(milliseconds) / 1000) }
    func pressConnect(_ frame: Frame) throws -> Bool {
        let nodes = try nativeNodes(frame)
        let state = classifySession(nodes.map(\.0))
        if state == .ready { return false }
        guard state != .authenticationRequired, state != .unknown, state != .connecting else {
            throw ControlFailure(code: "session_unavailable", message: "请先处理镜像状态：\(state.rawValue)")
        }
        let buttons = nodes.filter { $0.0.role == "AXButton" }
        guard buttons.count == 1 else { throw ControlFailure(code: "ambiguous_connect", message: "没有唯一的连接按钮；请在 Mac 上确认") }
        let label = buttons[0].0.text.lowercased()
        guard state == .inUse || state == .disconnected ||
              ["connect", "连接", "try again", "重试", "再试一次"].contains(where: label.contains) else {
            throw ControlFailure(code: "ambiguous_connect", message: "无法确认该按钮用于连接；请在 Mac 上处理")
        }
        guard AXUIElementPerformAction(buttons[0].1, kAXPressAction as CFString) == .success else {
            throw ControlFailure(code: "input_failed", message: "连接按钮执行失败")
        }
        return true
    }
}

func pngSize(_ path: String) throws -> (CGFloat, CGFloat) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
        throw ControlFailure(code: "capture_failed", message: "无法读取截图尺寸")
    }
    return (CGFloat(truncating: width), CGFloat(truncating: height))
}

@discardableResult
func capture(_ path: String, frame: Frame) throws -> Scale {
    guard CGPreflightScreenCaptureAccess() else { throw ControlFailure(code: "permission_denied", message: "截图需要运行环境已有的录屏权限") }
    let directory = (path as NSString).deletingLastPathComponent
    if !directory.isEmpty { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", String(frame.id), path]
    task.standardError = Pipe()
    do { try task.run() } catch { throw ControlFailure(code: "capture_failed", message: "无法启动截图进程") }
    let deadline = Date().addingTimeInterval(5)
    while task.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if task.isRunning {
        task.terminate()
        throw ControlFailure(code: "capture_timeout", message: "窗口截图超时")
    }
    guard task.terminationStatus == 0 else { throw ControlFailure(code: "capture_failed", message: "按窗口截图失败；没有改用可能包含其他 App 的屏幕区域截图") }
    let (width, height) = try pngSize(path)
    let scale = Scale(x: width / frame.width, y: height / frame.height)
    guard scale.x.isFinite, scale.y.isFinite, scale.x > 0, scale.y > 0 else {
        throw ControlFailure(code: "capture_failed", message: "截图比例无效")
    }
    return scale
}
