import AppKit
import Foundation
import CoreGraphics

let macRuntime = MacRuntime()

func controlStore() throws -> ControlStore {
    let override = ProcessInfo.processInfo.environment["IPHONE_CT_CONTROL_DIR"]
    let path = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iphone-ct/control", isDirectory: true)
    return try ControlStore(directory: path)
}

func executor() throws -> ActionExecutor { ActionExecutor(runtime: macRuntime, store: try controlStore()) }

func temporaryImage(_ label: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("iphone-ct-\(label)-\(UUID().uuidString).png").path
}

func pixelPoint(_ x: CGFloat, _ y: CGFloat, frame: Frame, scale: Scale) throws -> CGPoint {
    guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < frame.width * scale.x, y < frame.height * scale.y else {
        throw AppError.message("坐标超出镜像窗口截图")
    }
    return CGPoint(x: frame.x + x / scale.x, y: frame.y + y / scale.y)
}

func click(pixelX: CGFloat, pixelY: CGFloat, snapshotID: String? = nil) throws -> [String: Any] {
    guard pixelX.isFinite, pixelY.isFinite, pixelX >= 0, pixelY >= 0 else {
        throw AppError.message("点击坐标必须是有限的非负截图像素")
    }
    return try executor().execute { context in
        let scale = try captureScale(context: context, snapshotID: snapshotID)
        let point = try pixelPoint(pixelX, pixelY, frame: context.frame, scale: scale)
        try context.position(point)
        try context.wait(60)
        try context.mouseDown(point)
        try context.wait(40)
        try context.mouseUp(point)
        try context.wait(30)
        return ["ok": true, "pixel": ["x": pixelX, "y": pixelY],
                "screen": ["x": point.x, "y": point.y], "scale": scale.json]
    }
}

func swipe(direction: String, amount: CGFloat, pixelY: CGFloat?, snapshotID: String? = nil) throws -> [String: Any] {
    guard ["left", "right", "up", "down"].contains(direction) else { throw AppError.message("direction 只能是 up、down、left、right") }
    guard direction == "left" || direction == "right" else {
        throw AppError.unsupportedGesture("垂直拖动暂不支持；列表上下滚动请使用 scroll up/down --x 截图像素 --y 截图像素。")
    }
    guard amount.isFinite, amount > 0, amount <= 8192, let pixelY, pixelY.isFinite, pixelY >= 0 else {
        throw AppError.message("左右滑需要有效 --y，amount 必须大于 0 且不超过 8192 截图像素")
    }
    return try executor().execute { context in
        let frame = context.frame, scale = try captureScale(context: context, snapshotID: snapshotID)
        let y = try pixelPoint(0, pixelY, frame: frame, scale: scale).y
        let travel = amount / scale.x
        let start = CGPoint(x: frame.x + frame.width * (direction == "left" ? 0.82 : 0.18), y: y)
        let end = CGPoint(x: direction == "left" ? max(frame.x + 24, start.x - travel) : min(frame.x + frame.width - 24, start.x + travel), y: y)
        try context.position(start)
        try context.wait(20)
        try context.mouseDown(start)
        try context.wait(12)
        for index in 1...8 {
            let t = CGFloat(index) / 8
            try context.mouseDrag(CGPoint(x: start.x + (end.x - start.x) * t, y: y))
            try context.wait(8)
        }
        try context.mouseUp(end)
        try context.wait(80)
        return ["ok": true, "direction": direction, "coordinate_space": "screen_points",
                "from": ["x": start.x, "y": start.y], "to": ["x": end.x, "y": end.y]]
    }
}

struct MenuShortcut {
    var code: CGKeyCode
    var flags: CGEventFlags
    var title: String
    var shortcut: String
}

func menuShortcuts() -> [String: MenuShortcut] {
    let command = CGEventFlags.maskCommand
    return [
        "home": MenuShortcut(code: 18, flags: command, title: "主屏幕", shortcut: "command-1"),
        "switcher": MenuShortcut(code: 19, flags: command, title: "App切换器", shortcut: "command-2"),
        "spotlight": MenuShortcut(code: 20, flags: command, title: "聚焦", shortcut: "command-3"),
        "larger": MenuShortcut(code: 24, flags: [command, .maskShift], title: "调大", shortcut: "command-shift-="),
        "smaller": MenuShortcut(code: 27, flags: command, title: "调小", shortcut: "command--"),
        "actual": MenuShortcut(code: 29, flags: command, title: "实际大小", shortcut: "command-0"),
        "settings": MenuShortcut(code: 43, flags: command, title: "设置", shortcut: "command-,"),
        "cut": MenuShortcut(code: 7, flags: command, title: "剪切", shortcut: "command-x"),
        "copy": MenuShortcut(code: 8, flags: command, title: "拷贝", shortcut: "command-c"),
        "select-all": MenuShortcut(code: 0, flags: command, title: "全选", shortcut: "command-a"),
        "undo": MenuShortcut(code: 6, flags: command, title: "撤销", shortcut: "command-z"),
        "redo": MenuShortcut(code: 6, flags: [command, .maskShift], title: "重做", shortcut: "command-shift-z"),
        "emoji": MenuShortcut(code: 14, flags: .maskSecondaryFn, title: "表情与符号", shortcut: "fn-e"),
    ]
}

func menuCommand(_ name: String) throws -> [String: Any] {
    guard let item = menuShortcuts()[name] else { throw AppError.message("未知菜单命令 \(name)") }
    let transition = ["larger", "smaller", "actual", "settings", "emoji"].contains(name)
    return try executor().execute(allowTransition: transition) { context in
        try context.key(item.code, flags: item.flags, toPID: true)
        return ["ok": true, "command": name, "title": item.title, "shortcut": item.shortcut]
    }
}

func paste(text: String) throws -> [String: Any] {
    guard !text.isEmpty else { throw AppError.message("paste 需要 text") }
    return try executor().execute { context in
        try context.key(0, unicode: Array(text.utf16))
        return ["ok": true, "typed": text]
    }
}

func key(name: String) throws -> [String: Any] {
    let codes: [String: CGKeyCode] = ["return": 36, "escape": 53, "delete": 51, "space": 49, "tab": 48]
    guard let code = codes[name] else { throw AppError.message("key 只能是 return、escape、delete、space、tab") }
    return try executor().execute { context in
        try context.key(code)
        return ["ok": true, "key": name]
    }
}

func connect() throws -> [String: Any] {
    try executor().execute(allowBlocked: true, allowTransition: true) { context in
        let pressed = try context.connect()
        return ["ok": true, "state": pressed ? "pressed-connect" : "ready", "confirmed": false]
    }
}

func openApp(_ name: String) throws -> [String: Any] {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AppError.message("open 需要 App 名字") }
    return try executor().execute { context in
        let item = menuShortcuts()["spotlight"]!
        try context.key(item.code, flags: item.flags, toPID: true)
        try context.wait(500)
        try context.key(0, unicode: Array(trimmed.utf16))
        try context.wait(700)
        try context.validate()
        let path = temporaryImage("open")
        let scale = try capture(path, frame: context.frame)
        try context.validate()
        let metadata = try recordCapture(frame: context.frame, scale: scale, store: context.store)
        return ["ok": true, "typed": trimmed, "confirmed": false, "path": path,
                "snapshot_id": metadata.id, "scale": scale.json, "window": context.frame.json,
                "pixels": ["width": context.frame.width * scale.x, "height": context.frame.height * scale.y],
                "next": "看截图。调用方选择 key return 或 key escape"]
    }
}

func status() throws -> [String: Any] {
    let snapshot = try macRuntime.session(windowID: nil)
    let store = try controlStore(), state = try store.state()
    var result: [String: Any] = ["ok": true, "bundle": bundleID, "state": snapshot.state.rawValue,
                               "paused": state.paused, "busy": try store.busy(), "permissions": macRuntime.permissions().json]
    if let frame = snapshot.frame {
        result["window"] = frame.json
        result["frontmost"] = (try? macRuntime.isFocused(frame)) as Any? ?? NSNull()
    } else { result["frontmost"] = false }
    if !snapshot.detail.isEmpty { result["detail"] = snapshot.detail }
    return result
}

func doctor() throws -> [String: Any] {
    var result = try status()
    let permission = macRuntime.permissions()
    result["ok"] = permission.accessibility && permission.postEvents && permission.listenEvents && permission.screenRecording && result["state"] as? String == "ready"
    result["note"] = "只检查已有权限和 Mac 镜像状态，不申请权限、不操作手机"
    return result
}

func controlCommand(_ command: String) throws -> [String: Any] {
    let state = try controlStore().update(command)
    return ["ok": true, "command": command, "paused": state.paused, "generation": state.generation, "event_sent": false]
}

func shot(path: String) throws -> [String: Any] {
    let store = try controlStore(), lock = try store.lease()
    defer { withExtendedLifetime(lock) {} }
    let before = try macRuntime.session(windowID: nil)
    guard let frame = before.frame else { throw ControlFailure(code: "session_unavailable", message: "没有可截图的镜像窗口") }
    let scale = try capture(path, frame: frame)
    let after = try macRuntime.session(windowID: frame.id)
    guard after.frame == frame else { throw ControlFailure(code: "window_changed", message: "截图期间镜像窗口已改变，请重新截图") }
    let metadata = try recordCapture(frame: frame, scale: scale, store: store)
    return ["ok": true, "path": path, "state": before.state.rawValue,
            "snapshot_id": metadata.id,
            "pixels": ["width": frame.width * scale.x, "height": frame.height * scale.y],
            "scale": scale.json, "window": frame.json, "capture_method": "window", "event_sent": false]
}
