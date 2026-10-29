import Foundation
import CoreGraphics

private func displaySignature() throws -> String {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
        throw ControlFailure(code: "capture_failed", message: "无法确认显示器配置")
    }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
        throw ControlFailure(code: "capture_failed", message: "无法确认显示器配置")
    }
    return displays.prefix(Int(count)).sorted().map { id in
        let bounds = CGDisplayBounds(id), mode = CGDisplayCopyDisplayMode(id)
        return "\(id):\(bounds):\(CGDisplayPixelsWide(id)):\(CGDisplayPixelsHigh(id)):\(mode?.pixelWidth ?? 0):\(mode?.pixelHeight ?? 0)"
    }.joined(separator: "|")
}

private func metadataURL(_ store: ControlStore) -> URL { store.directory.appendingPathComponent("last-capture.json") }

func recordCapture(frame: Frame, scale: Scale, store: ControlStore) throws -> CaptureMetadata {
    let metadata = CaptureMetadata(id: UUID().uuidString, frame: frame, scale: scale, displays: try displaySignature(), created: Date())
    try JSONEncoder().encode(metadata).write(to: metadataURL(store), options: .atomic)
    return metadata
}

func captureScale(context: ActionContext, snapshotID: String?) throws -> Scale {
    let metadata = try? JSONDecoder().decode(CaptureMetadata.self, from: Data(contentsOf: metadataURL(context.store)))
    let signature = try displaySignature()
    if let snapshotID {
        guard let metadata, metadata.id == snapshotID,
              metadata.matches(frame: context.frame, displaySignature: signature, now: Date(), maxAge: nil) else {
            throw ControlFailure(code: "stale_snapshot", message: "截图 ID 不匹配，或窗口/显示器配置已改变；请重新截图")
        }
        try context.validate()
        return metadata.scale
    }
    if let metadata, metadata.matches(frame: context.frame, displaySignature: signature, now: Date(), maxAge: 60) {
        try context.validate()
        return metadata.scale
    }
    let path = temporaryImage("geometry")
    defer { try? FileManager.default.removeItem(atPath: path) }
    let scale = try capture(path, frame: context.frame)
    try context.validate()
    return scale
}

func snapshotArgument(_ args: [String: Any]) throws -> String? {
    guard let value = args["snapshot_id"] else { return nil }
    guard let value = value as? String, !value.isEmpty else { throw AppError.message("snapshot_id 必须是非空字符串") }
    return value
}
