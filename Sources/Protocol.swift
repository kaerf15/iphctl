import Foundation
import CoreGraphics

func number(_ value: Any?) throws -> CGFloat {
    if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return CGFloat(truncating: n) }
    if let text = value as? String, let n = Double(text) { return CGFloat(n) }
    throw AppError.message("缺少有效数字参数，布尔值不能作为坐标")
}

func options(_ words: ArraySlice<String>, allowed: Set<String>) throws -> [String: Any] {
    let words = Array(words)
    var result: [String: Any] = [:]
    var i = 0
    while i < words.count {
        let flag = words[i]
        let key = flag == "--snapshot" ? "snapshot_id" : String(flag.dropFirst(2))
        guard allowed.contains(flag), i + 1 < words.count, result[key] == nil else {
            throw AppError.message("参数无效、重复或缺少值：\(flag)")
        }
        result[key] = words[i + 1]
        i += 2
    }
    return result
}

func parseCLI(_ words: [String]) throws -> (String, [String: Any]) {
    let command = words[0]
    switch command {
    case "click":
        guard words.count >= 3 else { throw AppError.message("click 需要 x 和 y") }
        var args = try options(words.dropFirst(3), allowed: ["--snapshot"])
        args["x"] = words[1]; args["y"] = words[2]
        return (command, args)
    case "swipe":
        guard words.count >= 2 else { throw AppError.message("swipe 需要方向") }
        var args = try options(words.dropFirst(2), allowed: ["--y", "--amount", "--snapshot"])
        args["direction"] = words[1]
        return (command, args)
    case "scroll": return (command, try parseScrollArguments(Array(words.dropFirst())))
    case "shot": return (command, try options(words.dropFirst(), allowed: ["--out"]))
    case "paste", "open":
        guard words.count >= 2 else { throw AppError.message("\(command) 需要文本") }
        return (command, [command == "paste" ? "text" : "name": words.dropFirst().joined(separator: " ")])
    case "key":
        guard words.count == 2 else { throw AppError.message("key 需要一个键名") }
        return (command, ["name": words[1]])
    default:
        guard words.count == 1 else { throw AppError.message("\(command) 不接受附加参数") }
        return (command, [:])
    }
}
