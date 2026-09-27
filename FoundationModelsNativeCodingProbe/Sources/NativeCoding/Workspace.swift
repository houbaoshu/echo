import Darwin
import Foundation

/// probe 工作区根目录。`read_file` / `write_file` / `bash` 的路径都经 `resolve` 限制在根目录之内。
///
/// 规则：相对路径以根目录为基准；绝对路径也允许，只要落在根目录内。先做词法规范化（去掉 `.` / `..`），
/// 再对**最近一个已存在的祖先**取 `realpath`（用 `lstat` 判断存在，悬空 symlink 直接拒绝），
/// 拼回尚不存在的尾部后检查是否以 `root + "/"` 开头。之后所有文件操作都针对这个解析后的路径，
/// 所以 `..`、指向外部的 symlink、悬空 symlink 都无法把读写带出根目录。
///
/// 只约束 file tools 和 bash 的初始工作目录；bash 命令本身不做沙箱（可以 `cd ..`）。
public struct Workspace: Sendable {
    public let root: String

    public enum PathError: Error, LocalizedError, Equatable {
        case empty
        case outsideWorkspace(String)
        case danglingSymlink(String)

        public var errorDescription: String? {
            switch self {
            case .empty: "path is empty"
            case .outsideWorkspace(let path): "path \"\(path)\" resolves outside the workspace"
            case .danglingSymlink(let path): "path \"\(path)\" goes through a dangling symlink"
            }
        }
    }

    public init(root: String) throws {
        guard let real = realpath(root, nil) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root]) }
        defer { free(real) }
        self.root = String(cString: real)
    }

    /// 解析为根目录内的规范绝对路径。
    public func resolve(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PathError.empty }
        let absolute = trimmed.hasPrefix("/") ? trimmed : root + "/" + trimmed
        let lexical = URL(fileURLWithPath: absolute).standardizedFileURL.path

        // 从完整路径开始向上找第一个已存在的节点（lstat：symlink 本身也算存在）。
        var existing = lexical
        var missing: [String] = []
        var info = stat()
        while lstat(existing, &info) != 0 {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let real = realpath(existing, nil) else { throw PathError.danglingSymlink(path) }
        defer { free(real) }
        var resolved = String(cString: real)
        for component in missing { resolved = (resolved as NSString).appendingPathComponent(component) }

        guard resolved == root || resolved.hasPrefix(root + "/") else { throw PathError.outsideWorkspace(path) }
        return resolved
    }

    /// 相对根目录的显示路径。
    public func relative(_ resolved: String) -> String {
        resolved == root ? "." : String(resolved.dropFirst(root.count + 1))
    }
}
