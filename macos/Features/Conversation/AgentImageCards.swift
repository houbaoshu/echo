import AppKit
import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// What a generate_image card says: one line with the prompt, the saved file's name and size once
/// opened, and the image to show under the card; when no image came, why, in the person's language.
struct AgentImageCard {
    let tool: AgentToolRecord

    static func applies(to tool: AgentToolRecord) -> Bool { tool.tool == GenerateImageTool.toolName }

    let icon = "photo"

    /// "已生成图片 · 提示词"; a card that did not finish says how it ended first, and an undone one says so.
    var title: String {
        if tool.state == .finished && tool.undo != .undone { return String(localized: "已生成图片 · \(tool.command)") }
        let action = String(localized: "生成图片 · \(tool.command)")
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

/// A generated image in the chat, under its card: at its own aspect ratio, left on the text's edge,
/// no wider than `bounds` allows. A click opens it in Quick Look; its context menu also copies the
/// image and shows the file in Finder; it drags out as the file itself, copy only, as a file in the
/// file tree does. While it loads, a box of its shape holds its place; once the file is gone, a short note
/// says so instead.
struct AgentImageView: View {
    let url: URL
    /// The image's size in pixels, for its shape before it has been read.
    let pixels: CGSize
    /// The most it may take: `bounds(column:window:)` of the chat it is in.
    let bounds: CGSize
    /// Half the text column's width, and six tenths of the window's height.
    static let widthShare: CGFloat = 0.5, heightShare: CGFloat = 0.6
    static let cornerRadius: CGFloat = 12
    enum Load {
        case loading
        /// The image, decoded to `pixels` on its longer side.
        case loaded(NSImage, pixels: CGFloat)
        case missing
        /// The file at `url`, decoded no larger than `maxPixels` on its longer side; missing when it cannot be read.
        nonisolated static func read(_ url: URL, maxPixels: CGFloat) -> Load {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { return .missing }
            return .loaded(NSImage(cgImage: image, size: .zero), pixels: maxPixels)
        }
    }
    @State private var load = Load.loading
    @State private var preview: URL?
    @Environment(\.displayScale) private var scale

    /// The room an image has in a chat whose text column is `column` wide, in a window `window` high.
    static func bounds(column: CGFloat, window: CGFloat) -> CGSize {
        CGSize(width: (column * widthShare).rounded(), height: (window * heightShare).rounded())
    }

    /// An image of `pixels` shown whole within `bounds`, stopping at whichever limit it reaches
    /// first; an image of unknown size is a square.
    static func size(pixels: CGSize, bounds: CGSize) -> CGSize {
        let pixels = pixels.width > 0 && pixels.height > 0 ? pixels : CGSize(width: 1, height: 1)
        let factor = min(bounds.width / pixels.width, bounds.height / pixels.height)
        return CGSize(width: max(1, (pixels.width * factor).rounded()), height: max(1, (pixels.height * factor).rounded()))
    }

    private var size: CGSize { Self.size(pixels: pixels, bounds: bounds) }
    /// What to decode the file to: the longer side on screen, in 256-pixel steps so that resizing
    /// the window reads the file again only now and then.
    private var neededPixels: CGFloat { (max(size.width, size.height) * scale / 256).rounded(.up) * 256 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.cornerRadius) }

    var body: some View {
        Group {
            switch load {
            case .loading:
                shape.fill(.quaternary).frame(width: size.width, height: size.height)
            case .loaded(let image, _):
                Image(nsImage: image).resizable().scaledToFit().frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .contentShape(shape)
                    .onTapGesture(perform: openPreview)
                    .modifier(ProjectFileDrag(url: url) { [url] })
                    .contextMenu {
                        Button("快速查看", action: openPreview)
                        Button("拷贝图像", action: copyImage)
                        Button("在访达中显示", action: reveal)
                    }
                    .quickLookPreview($preview)
                    .help(url.lastPathComponent)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits([.isImage, .isButton])
                    .accessibilityLabel(url.lastPathComponent)
                    .accessibilityAction(.default, openPreview)
                    .accessibilityIdentifier("tool.image")
            case .missing:
                Label("图片文件已移走或删除", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("tool.image.missing")
            }
        }.task(id: neededPixels) {
            if case .loaded(_, let pixels) = load, pixels >= neededPixels { return }
            let needed = neededPixels, url = url
            load = await Task.detached { Load.read(url, maxPixels: needed) }.value
        }
    }

    /// Quick Look, unless the file has gone since it was read.
    private func openPreview() {
        guard FileManager.default.fileExists(atPath: url.path) else { load = .missing; return }
        preview = url
    }

    private func copyImage() {
        if !Self.copy(url, to: .general) { load = .missing }
    }

    private func reveal() {
        guard FileManager.default.fileExists(atPath: url.path) else { load = .missing; return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Puts the image at `url` on `pasteboard` as an image, not a file: its own encoding for apps
    /// that take it, and TIFF for those that take only that. False when it cannot be read.
    @discardableResult static func copy(_ url: URL, to pasteboard: NSPasteboard) -> Bool {
        guard let data = try? Data(contentsOf: url), let tiff = NSImage(data: data)?.tiffRepresentation else { return false }
        let item = NSPasteboardItem()
        if let type = UTType(filenameExtension: url.pathExtension), type != .tiff {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
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
            if let file = AgentImageCard(tool: record).file {
                AgentImageView(url: file, pixels: AgentImageCard(tool: record).pixels,
                               bounds: AgentImageView.bounds(column: 520, window: 700))
            }
        }
        AgentImageView(url: URL(fileURLWithPath: "/nonexistent.jpeg"), pixels: CGSize(width: 1728, height: 2304),
                       bounds: AgentImageView.bounds(column: 520, window: 700))
    }.padding().frame(width: 520)
}
