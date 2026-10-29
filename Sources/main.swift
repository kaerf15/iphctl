import AppKit
import Foundation
import CoreGraphics

func capabilities() -> [String: Any] {
    [
        "ok": true,
        "coordinate_space": "window_screenshot_pixels",
        "origin": "top_left",
        "success_semantics": "动作返回 ok 只表示已执行；手机画面是否变化由调用方看 shot 确认。",
        "input_coordination": ["cross_process_lock": true, "external_input_cancels": true, "pause_resume_cancel": true],
        "capabilities": [
            "click": ["status": "conditional"],
            "paste": ["status": "conditional", "note": "直接输入文字，需要先由调用方确认输入框。"],
            "menus": ["status": "conditional", "commands": menuShortcuts().keys.sorted()],
            "connect": ["status": "conditional", "note": "按镜像窗口的连接按钮；连接结果由调用方看截图确认。"],
            "open": ["status": "conditional", "note": "只在聚焦输入名字并截图，不确认搜索结果。"],
            "swipe_horizontal": ["status": "conditional", "requires": ["y"], "note": "快速鼠标拖动，已在主屏幕页面圆点处验证翻页；其他界面需要调用方验证。"],
            "swipe_vertical": ["status": "unsupported", "note": "垂直鼠标拖动无效；列表上下滚动请使用 scroll。"],
            "scroll_vertical": ["status": "conditional", "requires": ["x", "y"], "amount_unit": "window_screenshot_pixels", "note": "移动真实指针后发送像素滚轮；已在本机小红书验证两个方向。无须管理员认证，效果和方向由调用方看截图确认。"],
        ] as [String: Any],
    ]
}

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func perform(_ command: String, _ args: [String: Any]) throws -> [String: Any] {
    switch command {
    case "capabilities":
        return capabilities()
    case "status":
        return try status()
    case "doctor":
        return try doctor()
    case "pause", "resume", "cancel":
        return try controlCommand(command)
    case "shot":
        return try shot(path: args["out"] as? String ?? temporaryImage("shot"))
    case "click":
        return try click(pixelX: try number(args["x"]), pixelY: try number(args["y"]), snapshotID: try snapshotArgument(args))
    case "swipe":
        let direction = args["direction"] as? String ?? ""
        let amount = try args["amount"].map { try number($0) } ?? 280
        let pixelY = try args["y"].map { try number($0) }
        return try swipe(direction: direction, amount: amount, pixelY: pixelY, snapshotID: try snapshotArgument(args))
    case "scroll":
        return try performScroll(args)
    case "paste":
        guard let text = args["text"] as? String, !text.isEmpty else {
            throw AppError.message("paste 需要 text")
        }
        return try paste(text: text)
    case "key":
        return try key(name: args["name"] as? String ?? "")
    case "home", "switcher", "spotlight", "larger", "smaller", "actual", "settings",
         "cut", "copy", "select-all", "undo", "redo", "emoji":
        return try menuCommand(command)
    case "connect":
        return try connect()
    case "open":
        let name = (args["name"] as? String) ?? (args["text"] as? String) ?? ""
        return try openApp(name)
    default:
        throw AppError.message("未知命令 \(command)。可用 capabilities、status、shot、click、swipe、scroll、paste、key、connect、open，以及菜单命令 \(menuShortcuts().keys.sorted().joined(separator: "、"))")
    }
}

func runAgent() {
    while let line = readLine() {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        var requestID: Any?
        do {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw AppError.message("每行需要一个 JSON，例如 {\"cmd\":\"status\"}") }
            requestID = object["id"]
            guard let command = object["cmd"] as? String else {
                throw AppError.message("请求需要 cmd 命令名")
            }
            var response = try perform(command, object)
            if let requestID { response["id"] = requestID }
            emitLine(response)
        } catch {
            var response = errorResponse(error)
            if let requestID { response["id"] = requestID }
            emitLine(response)
        }
        fflush(stdout)
    }
}

func emitLine(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func usage(exitCode: Int32 = 2) -> Never {
    let text = """
    iphctl  给有视觉的 agent 用的 iPhone 镜像控制端

    命令只做动作。看画面、对坐标、决定是否确认，都由调用方完成。
    坐标是 shot 截图的像素，原点在窗口左上角。
    左右滑要带 --y。主屏幕滑页面圆点那一行，避免按在图标上。
    垂直拖动不支持；scroll 上下滚动使用像素滚轮，无须管理员认证。
    scroll 的 up/down 表示查看列表上方/下方，amount 是输入量，不保证页面移动同样距离。
    ok 表示动作已执行，画面效果由调用方看 shot 验证。
    下面这些命令走 iPhone 镜像自己的菜单快捷键。

      iphctl capabilities         查看已实现能力和限制，不操作手机
      iphctl status               连接、焦点、暂停和权限状态
      iphctl doctor               只读诊断
      iphctl pause                暂停输入并取消当前动作
      iphctl resume               恢复输入
      iphctl cancel               取消当前动作，不持久暂停
      iphctl shot [--out 路径]     按窗口截图，不抢前台
      iphctl click <x> <y> [--snapshot 截图ID]
      iphctl swipe <left|right> --y 截图像素 [--amount 像素距离] [--snapshot 截图ID]
      iphctl scroll <up|down> --x 截图像素 --y 截图像素 [--amount 像素输入量] [--snapshot 截图ID] [--invert]
      iphctl home                  主屏幕          Command-1
      iphctl switcher              App 切换器      Command-2
      iphctl spotlight             聚焦            Command-3
      iphctl larger                调大            Command-Shift-=
      iphctl smaller               调小            Command--
      iphctl actual                实际大小        Command-0
      iphctl settings              设置            Command-,
      iphctl cut                   剪切            Command-X
      iphctl copy                  拷贝            Command-C
      iphctl select-all            全选            Command-A
      iphctl undo                  撤销            Command-Z
      iphctl redo                  重做            Command-Shift-Z
      iphctl emoji                 表情与符号      Fn-E
      iphctl connect               点「连接」。手机使用中导致镜像结束时用
      iphctl open <App 名字>       聚焦里打上名字并截图，不回车
      iphctl paste <文本>          把文字打进当前输入框
      iphctl key <return|escape|delete|space|tab>
      iphctl agent     stdin/stdout 一行一个 JSON；可传 id，响应原样带回

    """
    FileHandle.standardError.write(Data(text.utf8))
    exit(exitCode)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty { usage() }
if ["help", "--help", "-h"].contains(arguments[0]) { usage(exitCode: 0) }
if arguments[0] == "agent" {
    guard arguments.count == 1 else { usage() }
    runAgent()
} else {
    do {
        let (command, args) = try parseCLI(arguments)
        let response = try perform(command, args)
        emit(response)
        if response["ok"] as? Bool == false { exit(1) }
    } catch {
        emit(errorResponse(error))
        exit(1)
    }
}
