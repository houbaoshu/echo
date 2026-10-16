import AppKit
import ImageIO
import SwiftUI

/// What a generate_image card says: the prompt folded, the saved file's name and size, and the
/// image itself as a thumbnail that drags out like a file in the file tree; when no image came,
/// why, in the person's language.
struct AgentImageCard {
    let tool: AgentToolRecord

    static func applies(to tool: AgentToolRecord) -> Bool { tool.tool == GenerateImageTool.toolName }

    let icon = "photo"

    /// "生成图片 · 提示词"; a card that did not finish says how it ended first, and an undone one says so.
    var title: String {
        let action = String(localized: "生成图片 · \(tool.command)")
        if tool.state == .finished && tool.undo != .undone { return action }
        return (tool.undo == .undone ? String(localized: "已撤销") : tool.state.label) + " · " + action
    }

    private var result: [String: Any]? {
        tool.result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
    }

    /// The saved image's size in pixels; zero when unknown.
    var pixels: CGSize {
        CGSize(width: result?["width"] as? Int ?? 0, height: result?["height"] as? Int ?? 0)
    }

    /// The image file the call saved, while its change has not been undone.
    var file: URL? {
        guard tool.undo != .undone, let result, result["action"] as? String == "created",
              let path = result["path"] as? String, let directory = tool.directory else { return nil }
        return URL(fileURLWithPath: directory).appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// The lines an opened card shows: the file's name and size once saved, why when there is no image.
    var lines: [String]? {
        guard let result else { return nil }
        if result["action"] as? String == "created" {
            let name = ((result["path"] as? String ?? "") as NSString).lastPathComponent
            let width = result["width"] as? Int ?? 0, height = result["height"] as? Int ?? 0
            return ["\(name) · \(width) × \(height)"]
        }
        guard result["status"] as? String == "failed", let reason = (result["reason"] as? String).flatMap(AgentImageResult.Reason.init) else {
            return (result["detail"] as? String).map { [$0] }
        }
        let code = result["code"] as? String ?? "", message = result["message"] as? String ?? ""
        switch reason {
        case .key:
            return [String(localized: "图片服务不接受这个 API Key（\(code)）。请在设置的模型页检查火山方舟的 API Key。")]
        case .service:
            return [String(localized: "图片服务返回错误：\(message)（\(code)）")]
        case .http:
            return [String(localized: "图片服务返回 HTTP \(result["http_status"] as? Int ?? 0)。")]
        case .timeout:
            return [String(localized: "图片服务没有在 \(Int(ArkImageGenerator.timeout)) 秒内完成。")]
        case .network:
            return [String(localized: "无法连接图片服务：\(message)")]
        case .response:
            return [String(localized: "图片服务的返回无法识别。")]
        case .save:
            return [String(localized: "图片已生成，但没能保存：\(message)")]
        }
    }
}

/// A generated image on its card, scaled down; it drags out as the file itself, copy only, as a
/// file in the file tree does. While it loads, a box of its shape holds its place; once the file is
/// gone, nothing shows.
struct AgentImageThumbnail: View {
    let url: URL
    /// The image's size in pixels, for the box that holds its place while it loads.
    let pixels: CGSize
    static let side: CGFloat = 220
    private enum Load { case loading, loaded(NSImage), missing }
    @State private var load = Load.loading
    @Environment(\.displayScale) private var scale

    private var size: CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: Self.side, height: Self.side) }
        let factor = min(Self.side / pixels.width, Self.side / pixels.height)
        return CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
    }

    var body: some View {
        Group {
            switch load {
            case .loading:
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: size.width, height: size.height)
            case .loaded(let image):
                Image(nsImage: image).resizable().scaledToFit().frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .modifier(ProjectFileDrag(url: url) { [url] })
                    .help(url.lastPathComponent)
                    .accessibilityLabel(url.lastPathComponent)
                    .accessibilityIdentifier("tool.image")
            case .missing:
                EmptyView()
            }
        }.task(id: url) {
            let pixels = Self.side * scale, url = url
            let image = await Task.detached { Self.thumbnail(url, maxPixels: pixels) }.value
            load = image.map(Load.loaded) ?? .missing
        }
    }

    /// The image at `url` no larger than `maxPixels` on its longer side; nil when it cannot be read.
    nonisolated static func thumbnail(_ url: URL, maxPixels: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

@MainActor private enum ImagePreview {
    /// A stand-in for a generated image, drawn into a temporary folder: the card reads it from disk.
    static let folder: String = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("echo-image-preview")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 1024, height: 768), flipped: false) { rect in
            NSGradient(starting: .systemOrange, ending: .systemTeal)?.draw(in: rect, angle: 35)
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("2026-10-16 23.45.12 一只橘猫坐在木窗台上.jpeg"))
        }
        return folder.path
    }()
    static let prompt = "一只橘猫坐在木窗台上，午后阳光，写实摄影"
    static func record(_ id: String, result: String?, state: AgentToolRecord.State, undo: AgentToolRecord.Undo? = nil) -> AgentToolRecord {
        .init(callID: id, entryID: 1, turnID: 1, command: prompt, result: result, state: state, directory: folder,
              tool: GenerateImageTool.toolName, undo: undo)
    }
    static var cards: [AgentToolRecord] {
        let made = AgentGeneratedImage(data: Data(count: 412_000), format: .jpeg, width: 2304, height: 1728)
        let saved = AgentImageResult.saved(made, path: "~/Pictures/Echo/2026-10-16 23.45.12 一只橘猫坐在木窗台上.jpeg")
        return [
            record("1", result: nil, state: .running),
            record("2", result: saved, state: .finished, undo: .available),
            record("3", result: AgentToolResult.undone(saved, tool: GenerateImageTool.toolName), state: .finished, undo: .undone),
            record("4", result: AgentImageResult.failed(.service(status: 400, code: "OutputImageSensitiveContentDetected",
                                                                 message: "The request failed because the output image may contain sensitive information.")),
                   state: .failed),
            record("5", result: AgentImageResult.failed(.timeout), state: .failed),
        ]
    }
}

#Preview("工具卡片 · 生成图片") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(ImagePreview.cards) { record in
            AgentToolView(tool: record, expanded: record.state == .failed,
                          undo: record.undo == nil || record.undo == .undone ? nil : {}, canUndo: true)
        }
    }.padding().frame(width: 520)
}
