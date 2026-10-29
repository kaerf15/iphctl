import Foundation
import CoreGraphics

func parseScrollArguments(_ arguments: [String]) throws -> [String: Any] {
    guard let direction = arguments.first else { throw AppError.message("scroll 需要 up 或 down，以及 --x/--y") }
    var result: [String: Any] = ["direction": direction]
    var index = 1
    while index < arguments.count {
        let flag = arguments[index]
        if flag == "--invert", result["invert"] == nil { result["invert"] = true; index += 1; continue }
        let key = flag == "--snapshot" ? "snapshot_id" : String(flag.dropFirst(2))
        guard ["--x", "--y", "--amount", "--snapshot"].contains(flag), index + 1 < arguments.count,
              result[key] == nil else { throw AppError.message("scroll 参数无效或重复：\(flag)") }
        result[key] = arguments[index + 1]
        index += 2
    }
    return result
}

func performScroll(_ args: [String: Any]) throws -> [String: Any] {
    let direction = args["direction"] as? String ?? ""
    let x = try number(args["x"]), y = try number(args["y"])
    let amount = try args["amount"].map { try number($0) } ?? 120
    guard args["invert"] == nil || args["invert"] is Bool else { throw AppError.message("invert 必须是布尔值") }
    let invert = args["invert"] as? Bool ?? false
    let snapshotID = try snapshotArgument(args)
    guard ["up", "down"].contains(direction), x.isFinite, y.isFinite, x >= 0, y >= 0,
          amount.isFinite, amount > 0, amount <= 8192 else {
        throw AppError.message("scroll 需要 up/down、有限非负 x/y，以及大于 0 至 8192 的 amount")
    }
    return try executor().execute { context in
        let scale = try captureScale(context: context, snapshotID: snapshotID)
        let point = try pixelPoint(x, y, frame: context.frame, scale: scale)
        let input = (amount / scale.y).rounded()
        guard input >= 1, input <= CGFloat(Int32.max) else { throw AppError.message("amount 换算后不能小于一个屏幕点或超过滚轮范围") }
        try context.position(point)
        try context.wait(100)
        // Pointer + mouse-move + pixel-wheel ordering, verified after reading
        // phone-harness at a80f884. Signs still require caller verification.
        let total = Int32(input) * (direction == "up" ? -1 : 1) * (invert ? -1 : 1)
        var previous: Int32 = 0
        for index in 1...6 {
            let cumulative = Int32((Double(total) * Double(index) / 6).rounded())
            let delta = cumulative - previous
            previous = cumulative
            if delta == 0 { continue }
            try context.send(.wheel(delta, point))
            try context.wait(30)
        }
        try context.wait(150)
        return ["ok": true, "backend": "cg_event", "direction": direction, "direction_semantics": "reveal_content",
                "amount": amount, "amount_unit": "window_screenshot_pixels", "wheel_delta_screen_points": total,
                "invert": invert,
                "coordinate_space": "window_screenshot_pixels", "pixel": ["x": x, "y": y],
                "screen": ["x": point.x, "y": point.y], "scale": scale.json]
    }
}
