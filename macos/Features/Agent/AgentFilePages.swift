import Darwin
import Foundation
import FoundationModels
import ImageIO
import PDFKit
import Synchronization
import UniformTypeIdentifiers

// read_file on a PDF or an image. A PDF's pages are drawn on this Mac at about 100 dpi and go to the
// model as JPEG images, at most 20 a call; an image file goes as it is, unless it is too large for
// either service, carries a rotation or is HEIF, which neither reads, when a scaled, upright JPEG
// goes instead. The images live in a folder of the turn's own and only for the turn that read
// them: when it ends they leave the transcript, and their result says so. Only a model that sees
// images gets any; for any other the call says why it read nothing (`AgentVisionLimits`).

/// A file read_file reads as images, told by how it starts; any other file is read as text. A text
/// file can start the same way, so the file is only taken for one once it opens as one.
enum AgentDocumentKind: Equatable, Sendable {
    case pdf
    case image(AgentImageFormat)
    /// HEIF, as iPhone photos are: neither service reads it, so it always goes as JPEG.
    case heif

    /// How much of a file's start is read to tell: WebP's and HEIF's signatures, the longest, take 12 bytes.
    static let sniffLength = 12

    /// The major brands of HEIF images and image sequences, HEVC-coded or not; AVIF has its own.
    static let heifBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1"]

    init?(start data: Data) {
        if let format = AgentImageFormat.of(data) { self = .image(format); return }
        if data.starts(with: Data("%PDF-".utf8)) { self = .pdf; return }
        // An ISO media file: a box size, "ftyp", then the major brand.
        let bytes = [UInt8](data.prefix(Self.sniffLength))
        guard bytes.count == Self.sniffLength, bytes[4..<8].elementsEqual("ftyp".utf8),
              Self.heifBrands.contains(String(decoding: bytes[8..<12], as: UTF8.self)) else { return nil }
        self = .heif
    }

    /// Larger files of this kind are not read.
    var maxBytes: Int { self == .pdf ? 512 << 20 : 64 << 20 }
}

/// What a read_file call returns: its result for the model, then each image as an attachment.
struct AgentFileRead: Sendable, PromptRepresentable {
    var text: String
    var images: [URL] = []

    var promptRepresentation: Prompt {
        Prompt {
            text
            for image in images { Attachment<ImageAttachmentContent>(imageURL: image) }
        }
    }
}

/// The folder a turn's page images are written to, made on first use and removed with all it holds
/// when the turn ends. A read that finishes later finds no folder and writes nothing.
final class AgentPageFolder: Sendable {
    private let state = Mutex<(url: URL?, closed: Bool)>((nil, false))
    private let base: URL

    /// Where every turn's folder goes, in a folder of each process's own named by its process ID:
    /// Echo and a test host can run at once. The first folder a process makes there removes those
    /// of processes that are no longer running.
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-agent-pages", isDirectory: true)
    private static let clearRoot: Void = removeLeftovers(in: root)

    init(parent: URL = AgentPageFolder.root) { base = parent }

    /// Removes the folders in `parent` that no running process owns: those named after a process
    /// that is gone, and anything else left there.
    static func removeLeftovers(in parent: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names {
            // kill(_, 0) only asks: EPERM means the process runs as someone else.
            if let pid = pid_t(name), pid > 0, pid == getpid() || kill(pid, 0) == 0 || errno == EPERM { continue }
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    /// The folder, made now if it is not yet; nil once the turn ended, or when it cannot be made.
    func url() -> URL? {
        state.withLock { state in
            guard !state.closed else { return nil }
            if let url = state.url { return url }
            if base == Self.root { _ = Self.clearRoot }
            let url = base.appendingPathComponent(String(getpid()), isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil else { return nil }
            state.url = url
            return url
        }
    }

    /// The turn ended: the folder goes, and no later read makes another.
    func close() {
        let url = state.withLock { state -> URL? in
            state.closed = true
            defer { state.url = nil }
            return state.url
        }
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

/// How a turn's read_file calls read PDFs and images: whether the model sees images, where the
/// images go, and the input that ends a PDF's pages early.
struct AgentPageReader: Sendable {
    let vision: Bool
    let folder: AgentPageFolder
    var steering = AgentSteeringSignal()
    /// A model that sees no images, as for a call made without a turn.
    static let noVision = AgentPageReader(vision: false, folder: AgentPageFolder())
    /// A Stop or newer input came: the pages not drawn yet are not.
    var stopped: Bool { Task.isCancelled || steering.isPending }
}

enum AgentFilePages {
    static let pageDPI: CGFloat = 100
    static let maxPagesPerRead = 20
    /// A page larger than this on its longer side is drawn at a lower resolution.
    static let maxPageSide: CGFloat = 2048
    /// An image goes as it is within these, which both services take in any number.
    static let maxSentImageBytes = 10_000_000
    static let maxSentImageSide = 4096
    /// What both services scale an image down to anyway; a larger one is scaled to it here first.
    static let scaledImagePixels = 2_260_000
    static let minImageSide = 15
    static let maxAspectRatio = 150.0

    /// What a call that read a PDF or an image would have read, for a model that sees no images.
    static func noVision(name: String, kind: AgentDocumentKind) -> String {
        let what = kind == .pdf ? "a PDF" : "an image"
        let models = AgentVisionLimits.modelNames.joined(separator: " or ")
        return AgentToolResult.failed(reason: "no_vision",
            "\(name) is \(what), and the chat model in use cannot see images, so it was not read. With \(models) as the chat model, read_file reads PDFs and images.")
    }

    // MARK: Reading

    /// What reading a file that starts like a PDF or an image came to.
    enum Outcome {
        case read(AgentFileRead)
        /// The reader stopped it, or the turn ended, before it was done.
        case stopped
        /// It does not open as the kind it starts like: it may be text that merely starts that way.
        case notThisKind
    }

    /// Reads `data`, the whole of a file whose start showed it may be `kind`. Read into memory
    /// rather than mapped: a file changed on disk while it is read would take Echo down with it.
    static func read(_ data: Data, kind: AgentDocumentKind, name: String, pages: String?, reader: AgentPageReader) -> Outcome {
        switch kind {
        case .pdf: readPDF(data, name: name, pages: pages, reader: reader)
        case .image(let format): readImage(data, format: format, name: name, reader: reader)
        case .heif: readImage(data, format: nil, name: name, reader: reader)
        }
    }

    /// Why a call's pages cannot be read, as its result.
    private struct PagesRefused: Error {
        let result: String
        init(_ reason: String, _ detail: String, count: Int? = nil) {
            result = AgentToolResult.failed(reason: reason, detail, count.map { ["page_count": $0] } ?? [:])
        }
    }

    /// The pages a call asks for, in a PDF of `count` pages.
    private static func pageRange(_ raw: String?, count: Int, name: String) -> Result<ClosedRange<Int>, PagesRefused> {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            guard count <= maxPagesPerRead else {
                return .failure(.init("pages_needed", "\(name) has \(count) pages, and read_file reads at most \(maxPagesPerRead) at a time. Pass pages, such as 1-\(maxPagesPerRead), and read the rest in later calls.", count: count))
            }
            return .success(1...count)
        }
        let parts = raw.split(whereSeparator: { "-–—~".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count), raw.filter({ "-–—~".contains($0) }).count == parts.count - 1,
              let first = Int(parts[0]), let last = parts.count == 2 ? Int(parts[1]) : first else {
            return .failure(.init("invalid_pages", "pages must be one page or a range, such as 3 or 1-\(maxPagesPerRead): \(raw)"))
        }
        guard first <= last else {
            return .failure(.init("invalid_pages", "pages must go from the lower page to the higher, such as \(last)-\(first): \(raw)"))
        }
        guard first >= 1, last <= count else {
            return .failure(.init("invalid_pages", "\(name) has \(count) pages, numbered 1-\(count): \(raw) is outside them", count: count))
        }
        guard last - first + 1 <= maxPagesPerRead else {
            return .failure(.init("invalid_pages", "read_file reads at most \(maxPagesPerRead) pages at a time, and \(raw) is \(last - first + 1). Read them in several calls.", count: count))
        }
        return .success(first...last)
    }

    private static func readPDF(_ data: Data, name: String, pages: String?, reader: AgentPageReader) -> Outcome {
        guard let document = PDFDocument(data: data) else { return .notThisKind }
        // A PDF locked only against changes opens without a password.
        let locked = document.isLocked && !document.unlock(withPassword: "")
        // PDFKit opens some text that merely starts like a PDF, as one without pages.
        guard locked || document.pageCount > 0 else { return .notThisKind }
        guard reader.vision else { return .read(AgentFileRead(text: noVision(name: name, kind: .pdf))) }
        guard !locked else {
            return .read(AgentFileRead(text: AgentToolResult.failed(reason: "password", "\(name) is protected by a password, so it was not read")))
        }
        let count = document.pageCount
        let range: ClosedRange<Int>
        switch pageRange(pages, count: count, name: name) {
        case .failure(let failure): return .read(AgentFileRead(text: failure.result))
        case .success(let pages): range = pages
        }
        guard let folder = reader.folder.url() else { return .stopped }
        var images: [URL] = []
        for number in range {
            if reader.stopped { return .stopped }
            guard let page = document.page(at: number - 1), let image = render(page), let jpeg = AgentImageEncoding.jpeg(image) else {
                return .read(AgentFileRead(text: AgentToolResult.failed("page \(number) of \(name) could not be drawn")))
            }
            let url = folder.appendingPathComponent("\(UUID().uuidString)-p\(number).jpg")
            // The folder is gone once the turn ended: nothing is written for a turn that is over.
            guard (try? jpeg.write(to: url)) != nil else { return .stopped }
            images.append(url)
        }
        let shown = range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
        let note = range.count == 1 ? "The image after this result is page \(shown)." : "The \(range.count) images after this result are pages \(shown), in order."
        return .read(AgentFileRead(text: AgentToolResult.object(["kind": "pdf", "page_count": count, "pages": shown, "images": images.count, "note": note]),
                                   images: images))
    }

    /// A page as it shows, rotation included, on white at about 100 dpi; a large page at less.
    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(pageDPI / 72, maxPageSide / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = whiteCanvas(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        // PDFKit draws the box in its own coordinates, turned by the page's rotation.
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    /// An image in `format`; with none, a HEIF image, which always goes as JPEG.
    private static func readImage(_ data: Data, format: AgentImageFormat?, name: String, reader: AgentPageReader) -> Outcome {
        // A HEIF file can hold several images, one of them the photo.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              case let index = CGImageSourceGetPrimaryImageIndex(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return .notThisKind
        }
        guard reader.vision else { return .read(AgentFileRead(text: noVision(name: name, kind: format.map(AgentDocumentKind.image) ?? .heif))) }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // As it shows: an orientation from 5 to 8 turns it a quarter.
        let (shownWidth, shownHeight) = orientation >= 5 ? (height, width) : (width, height)
        guard min(shownWidth, shownHeight) >= minImageSide,
              Double(max(shownWidth, shownHeight)) / Double(min(shownWidth, shownHeight)) <= maxAspectRatio else {
            return .read(AgentFileRead(text: AgentToolResult.failed(reason: "image_size", "\(name) is \(shownWidth)×\(shownHeight) pixels, too small or too narrow for the model to read")))
        }
        var result: [String: Any] = ["kind": "image", "images": 1, "note": "The image after this result is \(name)."]
        let sent: Data, sentFormat: AgentImageFormat
        if let format, data.count <= maxSentImageBytes, max(width, height) <= maxSentImageSide, orientation == 1 {
            (sent, sentFormat) = (data, format)
            result.merge(["width": width, "height": height]) { $1 }
        } else {
            // Too large for one service or the other, turned, or HEIF: scaled to what the services
            // would scale it to anyway, upright, on white, as JPEG.
            let pixels = Double(shownWidth * shownHeight)
            let scale = min(1, Double(maxSentImageSide) / Double(max(shownWidth, shownHeight)), (Double(scaledImagePixels) / pixels).squareRoot())
            let longest = max(1, Int((Double(max(shownWidth, shownHeight)) * scale).rounded(.down)))
            guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, index, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: longest] as CFDictionary),
                  let flat = onWhite(scaled), let jpeg = AgentImageEncoding.jpeg(flat) else {
                return .read(AgentFileRead(text: AgentToolResult.failed("\(name) could not be read as an image")))
            }
            (sent, sentFormat) = (jpeg, .jpeg)
            result.merge(["width": flat.width, "height": flat.height]) { $1 }
            if flat.width != shownWidth || flat.height != shownHeight { result["scaled_from"] = "\(shownWidth)×\(shownHeight)" }
        }
        result["format"] = sentFormat.rawValue
        // The folder is gone once the turn ended: nothing is written for a turn that is over.
        guard let url = reader.folder.url()?.appendingPathComponent("\(UUID().uuidString).\(sentFormat.rawValue)"),
              (try? sent.write(to: url)) != nil else { return .stopped }
        return .read(AgentFileRead(text: AgentToolResult.object(result), images: [url]))
    }

    /// The image drawn on white, so transparency does not turn black in JPEG.
    private static func onWhite(_ image: CGImage) -> CGImage? {
        guard let context = whiteCanvas(width: image.width, height: image.height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// An opaque sRGB bitmap of that size, filled white.
    private static func whiteCanvas(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    // MARK: After the turn

    static func removedNote(count: Int) -> String {
        let n = AgentImageCount(count)
        return "The \(n.images) this call returned \(n.were) shown only during the turn that read \(n.them). Call read_file again to see \(n.them)."
    }

    /// `entries` with the images of every tool result taken out, and each such result saying so:
    /// what a turn leaves behind, and what is saved.
    static func droppingImages(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        entries.map { entry in
            guard case .toolOutput(var output) = entry else { return entry }
            let count = output.segments.count { if case .attachment = $0 { true } else { false } }
            guard count > 0 else { return entry }
            let text = AgentHarness.text(output.segments)
            let note = removedNote(count: count)
            let amended: String
            if var value = AgentToolResult.jsonObject(text) {
                value["images_removed"] = note
                amended = AgentToolResult.object(value)
            } else {
                amended = text + "\n\n" + note
            }
            output.segments = [.text(.init(content: amended))]
            return .toolOutput(output)
        }
    }
}
