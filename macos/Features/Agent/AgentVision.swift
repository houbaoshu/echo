import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

// Images in tool results, for the chat models known to see them. read_file gives a PDF's pages and
// image files as images; the adapters send them to the model inside the tool's result. Other models
// accept images and then drop them without a word (deepseek-v4-pro, measured 2026-10-21), so only the
// models listed here get any.

/// A chat model that sees images in a tool result, and what its service takes in one request.
/// From DeepSeek's image understanding guide, Volcengine Ark's, and probes on 2026-10-20/21.
struct AgentVisionLimits: Sendable, Hashable {
    /// The whole request body, images in base64 included.
    var maxRequestBytes: Int
    var maxImages: Int
    /// One image as sent, before base64.
    var maxImageBytes: Int
    var contextTokens: Int
    /// What one image costs at most.
    var tokensPerImage: Int

    /// Left for the model's reasoning and reply.
    static let outputReserve = 32_000

    static let models: [String: AgentVisionLimits] = [
        // A larger image is scaled to about 1300×1300 pixels: at most 1024 tokens.
        "deepseek-flash": .init(maxRequestBytes: 48 << 20, maxImages: 600, maxImageBytes: 32 << 20,
                                contextTokens: 1_000_000, tokensPerImage: 1024),
        // Ark scales every image to about 2.26 million pixels: 1280 tokens each, about 1293 measured.
        // Its number of images is bounded by the context alone.
        "doubao-seed-2.0-mini": .init(maxRequestBytes: 64_000_000, maxImages: .max, maxImageBytes: 10_000_000,
                                      contextTokens: 256_000, tokensPerImage: 1300),
    ]

    /// The model by its name as the settings give it, whatever service answers to it.
    static func named(_ model: String) -> AgentVisionLimits? {
        models[model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
    /// The models that see images, for what the model and the person are told.
    static var modelNames: [String] { models.keys.sorted() }
}

/// The image formats both services read, told by what a file holds rather than by its name: both
/// services go by the content too.
enum AgentImageFormat: String, Sendable, CaseIterable {
    case jpeg, png, gif, webp

    var mimeType: String { "image/" + rawValue }
    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .gif: .gif
        case .webp: .webP
        }
    }

    /// The format whose signature `data` starts with; nil for anything else.
    static func of(_ data: Data) -> AgentImageFormat? {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return .gif }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return .webp }
        return nil
    }
}

/// The images a request's tool results carry, worked out before the request is built. The images
/// of one result go or stay together. When they would take a request past its model's limits, the
/// oldest results' images stay out first, and the result says so in their place; a model that sees
/// no images gets none, and is told too. Nothing is left out without a word.
struct AgentToolImages: Sendable {
    struct Image: Sendable {
        let data: Data
        let format: AgentImageFormat
        var dataURL: String { "data:\(format.mimeType);base64," + data.base64EncodedString() }
    }
    enum Group: Sendable {
        case send([Image])
        /// What the model reads in the images' place.
        case leftOut(String)
    }
    /// By the index of the tool output entry in the transcript; outputs without images have none.
    let groups: [Int: Group]

    static let none = AgentToolImages(groups: [:])

    static func leftOutNote(count: Int) -> String {
        let n = AgentImageCount(count)
        return "[Echo: the \(n.images) this result returned \(n.were) left out of this request to stay within the model's limits for one request. Call read_file again, with a narrower page range, if you need \(n.them).]"
    }
    static func noVisionNote(count: Int) -> String {
        let n = AgentImageCount(count)
        return "[Echo: the \(n.images) this result returned \(n.were) not sent: the chat model in use cannot see images.]"
    }
    static func unreadableNote(count: Int) -> String {
        let n = AgentImageCount(count)
        return "[Echo: the \(n.images) this result returned \(n.are) no longer available. Call read_file again if you need \(n.them).]"
    }

    /// What a request carries as the tool result at `index` whose text is `text`: the text alone,
    /// the text with a note in place of its images, or the text and its images as the parts
    /// `textPart` and `imagePart` make in the request's format.
    func result(at index: Int, text: String, textPart: (String) -> [String: Any], imagePart: (Image) -> [String: Any]) -> Any {
        switch groups[index] {
        case nil: text
        case .leftOut(let note)?: text + "\n\n" + note
        case .send(let images)?: [textPart(text)] + images.map(imagePart)
        }
    }

    /// Reads the images of every tool result in `transcript` and decides which go, for a model with
    /// `limits`, or none for a model that sees no images.
    init(_ transcript: Transcript, limits: AgentVisionLimits?) {
        let found = transcript.enumerated().compactMap { index, entry -> (index: Int, images: [Transcript.ImageAttachment])? in
            guard case .toolOutput(let output) = entry else { return nil }
            let images = output.segments.compactMap { segment -> Transcript.ImageAttachment? in
                if case .attachment(let attachment) = segment, case .image(let image) = attachment.content { image } else { nil }
            }
            return images.isEmpty ? nil : (index, images)
        }
        guard !found.isEmpty else { self.init(groups: [:]); return }
        guard let limits else {
            self.init(groups: Dictionary(uniqueKeysWithValues: found.map { ($0.index, .leftOut(Self.noVisionNote(count: $0.images.count))) }))
            return
        }

        var groups: [Int: Group] = [:]
        var loaded: [(index: Int, images: [Image])] = []
        for (index, attachments) in found {
            let images = attachments.compactMap(Self.load)
            if images.count < attachments.count || images.contains(where: { $0.data.count > limits.maxImageBytes }) {
                groups[index] = .leftOut(Self.unreadableNote(count: attachments.count))
            } else {
                loaded.append((index, images))
            }
        }
        // Newest first: what the model read last is what it needs most.
        let textBytes = Self.textBytes(transcript)
        var bytes = textBytes + 64 * 1024, tokens = textBytes / 3 + AgentVisionLimits.outputReserve, count = 0
        for (index, images) in loaded.reversed() {
            let groupBytes = images.reduce(0) { $0 + ($1.data.count + 2) / 3 * 4 + 128 }
            let fits = count + images.count <= limits.maxImages && bytes + groupBytes <= limits.maxRequestBytes
                && tokens + images.count * limits.tokensPerImage <= limits.contextTokens
            if fits {
                count += images.count; bytes += groupBytes; tokens += images.count * limits.tokensPerImage
                groups[index] = .send(images)
            } else {
                groups[index] = .leftOut(Self.leftOutNote(count: images.count))
            }
        }
        self.init(groups: groups)
    }

    private init(groups: [Int: Group]) { self.groups = groups }

    /// What the request's text adds up to, in UTF-8 bytes.
    private static func textBytes(_ transcript: Transcript) -> Int {
        func bytes(_ segments: [Transcript.Segment]) -> Int {
            segments.reduce(0) { total, segment in
                switch segment {
                case .text(let text): total + text.content.utf8.count
                case .structure(let structure): total + structure.content.jsonString.utf8.count
                default: total
                }
            }
        }
        return transcript.reduce(0) { total, entry in
            switch entry {
            case .instructions(let value): total + bytes(value.segments)
            case .prompt(let value): total + bytes(value.segments)
            case .response(let value): total + bytes(value.segments)
            case .reasoning(let value): total + bytes(value.segments)
            case .toolOutput(let value): total + bytes(value.segments)
            case .toolCalls(let calls): total + calls.reduce(0) { $0 + AgentCallArguments.text($1).utf8.count }
            @unknown default: total
            }
        }
    }

    /// An image as read_file wrote it to its file, in a format both services read; nil when it
    /// cannot be read.
    private static func load(_ image: Transcript.ImageAttachment) -> Image? {
        guard let url = image.url, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let format = AgentImageFormat.of(data) else { return nil }
        return Image(data: data, format: format)
    }
}

/// "3 images … were … them", or the singular, for the notes that stand in for images.
struct AgentImageCount {
    let count: Int
    init(_ count: Int) { self.count = count }
    var images: String { count == 1 ? "1 image" : "\(count) images" }
    var were: String { count == 1 ? "was" : "were" }
    var are: String { count == 1 ? "is" : "are" }
    var them: String { count == 1 ? "it" : "them" }
}

/// JPEG as Echo sends a page or a scaled image: quality 0.8, which keeps small print readable.
enum AgentImageEncoding {
    static let quality = 0.8
    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
