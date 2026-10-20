import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

// All entry inspection and reads run off the main actor. Descriptor-relative opens
// refuse links at every path component, including directories replaced after listing.
enum ProjectFileIO {
    static let previewLimit = 1_048_576
    static let imagePreviewLimit = 32 * 1_048_576
    private static func errorMessage(_ code: Int32) -> String {
        switch code {
        case ENOENT: return String(localized: "文件或文件夹已删除或不可用。")
        case EACCES, EPERM: return String(localized: "没有权限读取此文件或文件夹。")
        case ELOOP: return String(localized: "符号链接不跟随，请在 Finder 中查看。")
        case ENOTDIR: return String(localized: "文件夹不可用或已被替换。")
        default: return String(localized: "读取失败：\(String(cString: strerror(code)))")
        }
    }
    private struct ReadError: Error {
        let message: String
        /// The errno behind `message`, when there is one.
        var code: Int32?
        init(message: String) { self.message = message }
        init(code: Int32) { message = errorMessage(code); self.code = code }
    }
    private static func descriptor(root: String, path: String, directory: Bool) throws -> Int32 {
        do { return try ProjectPath.open(root: root, path: path, directory: directory) }
        catch .outsideProject { throw ReadError(message: String(localized: "路径不属于当前项目。")) }
        catch .system(let code) { throw ReadError(code: code) }
    }
    static func directory(root: String, path: String) -> ProjectDirectoryState {
        do {
            let fd = try descriptor(root: root, path: path, directory: true)
            guard let dir = fdopendir(fd) else { let code = errno; close(fd); throw ReadError(code: code) }
            defer { closedir(dir) }
            var entries: [ProjectFileEntry] = []
            while true {
                errno = 0
                guard let entry = readdir(dir) else {
                    if errno != 0 { throw ReadError(code: errno) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name.hasPrefix(".") { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }
                    throw ReadError(code: errno)
                }
                if info.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                let kind: ProjectFileEntry.Kind
                switch info.st_mode & S_IFMT {
                case S_IFDIR: kind = .directory
                case S_IFREG: kind = .file
                case S_IFLNK: kind = .symbolicLink
                default: kind = .other
                }
                entries.append(.init(path: path.isEmpty ? name : path + "/" + name, name: name, kind: kind))
            }
            return .loaded(entries.sorted {
                if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
            })
        } catch let error as ReadError { return .failed(error.message) }
        catch { return .failed(error.localizedDescription) }
    }
    static func preview(root: String, path: String) -> ProjectFilePreview {
        do {
            let fd = try descriptor(root: root, path: path, directory: false)
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw ReadError(code: errno) }
            guard info.st_mode & S_IFMT == S_IFREG else { return .information(String(localized: "仅支持预览普通文本和图片文件。")) }
            let ext = (path as NSString).pathExtension.lowercased()
            let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) == true
                || ["png", "jpg", "jpeg", "webp", "gif"].contains(ext)
            let limit = isImage ? imagePreviewLimit : previewLimit
            let sizeMessage = isImage ? String(localized: "图片超过 32 MiB，无法预览。") : String(localized: "文件超过 1 MiB，无法预览。")
            guard info.st_size <= limit else { return .information(sizeMessage) }
            // One byte past the limit catches a file that grew after fstat.
            let data = try read(fd, upTo: limit + 1)
            guard data.count <= limit else { return .information(sizeMessage) }
            return isImage ? image(from: data) : text(from: data)
        } catch let error as ReadError {
            // A link is not followed on purpose, so it is information rather than a failure.
            if error.code == ELOOP { return .information(error.message) }
            return .failed(error.message)
        } catch { return .failed(error.localizedDescription) }
    }
    /// Up to `capacity` bytes. Data's zeroed allocation leaves the pages a small file
    /// never reaches uncommitted.
    private static func read(_ fd: Int32, upTo capacity: Int) throws -> Data {
        var data = Data(count: capacity)
        var total = 0
        while total < capacity {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: total), capacity - total)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadError(code: errno)
            }
            if count == 0 { break }
            total += count
        }
        data.count = total
        return data
    }
    /// Decodes off the main actor, applies orientation and bounds decoded memory. GIFs use
    /// their first frame; no animation or editing state is needed.
    private static func image(from data: Data) -> ProjectFilePreview {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            return .information(String(localized: "无法预览图片：文件已损坏或格式不受支持。"))
        }
        return .image(image)
    }
    private static func text(from data: Data) -> ProjectFilePreview {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { text = String(data: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, encoding: .utf8) }
        guard let text, !text.unicodeScalars.contains(where: {
            ($0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13) || $0.value == 127
        }) else { return .information(String(localized: "二进制文件或不支持的文本编码。支持 UTF-8 和带 BOM 的 UTF-16。")) }
        return .text(text)
    }
}
