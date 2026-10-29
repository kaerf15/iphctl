import Foundation
import CoreGraphics

let bundleID = "com.apple.ScreenContinuity"

struct Frame: Equatable, Codable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var id: CGWindowID
    var pid: pid_t
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var json: [String: Any] { ["x": x, "y": y, "width": width, "height": height, "id": id] }
}

struct Scale: Codable {
    var x: CGFloat
    var y: CGFloat
    var json: [String: Any] { ["x": x, "y": y] }
}

enum AppError: Error, CustomStringConvertible {
    case message(String)
    case unsupportedGesture(String)
    var description: String {
        switch self {
        case .message(let text), .unsupportedGesture(let text): return text
        }
    }
}

struct ControlFailure: Error, CustomStringConvertible {
    var code: String
    var message: String
    var events = 0
    var reports = 0
    var cleanupEvents = 0
    var description: String { message }
}

func errorResponse(_ error: Error) -> [String: Any] {
    var result: [String: Any] = ["ok": false, "error": String(describing: error), "verified": false,
                               "event_sent": false, "events_sent": 0, "reports": 0, "cleanup_events": 0]
    if let failure = error as? ControlFailure {
        result["code"] = failure.code
        result["event_sent"] = failure.events > 0
        result["events_sent"] = failure.events
        result["reports"] = failure.reports
        result["cleanup_events"] = failure.cleanupEvents
    } else if case AppError.unsupportedGesture = error {
        result["code"] = "unsupported_gesture"
    } else {
        result["code"] = "invalid_request"
    }
    return result
}

enum MirrorState: String {
    case ready, connecting, disconnected, blocked, unknown
    case inUse = "in_use"
    case authenticationRequired = "authentication_required"
    case notRunning = "not_running"
    case noWindow = "no_window"
}

struct SessionSnapshot {
    var frame: Frame?
    var state: MirrorState
    var detail: String = ""
}

struct PermissionSnapshot {
    var accessibility: Bool
    var postEvents: Bool
    var listenEvents: Bool
    var screenRecording: Bool
    var json: [String: Any] {
        ["accessibility": accessibility, "post_events": postEvents,
         "listen_events": listenEvents, "screen_recording": screenRecording]
    }
}

struct NativeNode {
    var role: String
    var text: String
}

// This reads Mac-side connection UI, never OCR or the phone's video content.
func classifySession(_ nodes: [NativeNode]) -> MirrorState {
    if nodes.isEmpty { return .ready }
    let text = nodes.map(\.text).joined(separator: " ").lowercased()
    if nodes.contains(where: { $0.role == "AXSecureTextField" }) ||
        ["touch id", "password", "密码", "认证"].contains(where: text.contains) { return .authenticationRequired }
    if ["connecting", "正在连接", "连接中"].contains(where: text.contains) { return .connecting }
    if ["in use", "lock your iphone", "使用中", "正在使用", "锁定 iphone"].contains(where: text.contains) { return .inUse }
    if ["ended", "timed out", "not found", "disconnected", "已结束", "未找到", "中断", "超时"].contains(where: text.contains) { return .disconnected }
    return .blocked
}

enum InputEvent {
    case mouse(CGEventType, CGPoint)
    case key(CGKeyCode, CGEventFlags, Bool, [UniChar], Bool)
    case wheel(Int32, CGPoint)
    var point: CGPoint? {
        switch self { case .mouse(_, let p), .wheel(_, let p): return p; default: return nil }
    }
    var isWheel: Bool { if case .wheel = self { return true }; return false }
}

protocol InterruptionMonitor: AnyObject {
    var interrupted: Bool { get }
    func stop()
}

func shouldCancelInput(type: CGEventType, sourcePID: Int64, userData: Int64,
                       ownPID: Int64, ownTag: Int64, stopped: Bool) -> Bool {
    if stopped { return false }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return true }
    return sourcePID != ownPID && userData != ownTag
}

protocol MirrorRuntime: AnyObject {
    func permissions() -> PermissionSnapshot
    func session(windowID: CGWindowID?) throws -> SessionSnapshot
    func focus(_ frame: Frame) throws
    func isFocused(_ frame: Frame) throws -> Bool
    func verifyTarget(_ point: CGPoint, frame: Frame) throws
    func cursor() throws -> CGPoint
    func position(_ point: CGPoint) throws
    func prepare(_ event: InputEvent, frame: Frame, cleanup: Bool) throws -> () -> Void
    func monitor() throws -> InterruptionMonitor
    func sleep(milliseconds: Int)
    func pressConnect(_ frame: Frame) throws -> Bool
}

struct CaptureMetadata: Codable {
    var id: String
    var frame: Frame
    var scale: Scale
    var displays: String
    var created: Date
    func matches(frame current: Frame, displaySignature: String, now: Date, maxAge: TimeInterval?) -> Bool {
        guard frame == current, displays == displaySignature, scale.x.isFinite, scale.y.isFinite,
              scale.x > 0, scale.y > 0 else { return false }
        if let maxAge { return now.timeIntervalSince(created) >= 0 && now.timeIntervalSince(created) <= maxAge }
        return true
    }
}

