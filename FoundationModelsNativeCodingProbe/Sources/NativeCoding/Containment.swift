import Darwin
import Foundation

/// **实验级** containment：只为本 probe 隔离模型执行的 bash，不代表 Echo 正式的 sandbox 设计。
///
/// 用系统自带的 `/usr/bin/sandbox-exec -p <profile>`（Seatbelt）启动 bash；sandbox-exec 应用 profile 后 exec 成 bash，
/// pid 不变，所以 `ProcessRunner` 的进程组 / timeout / cancel / 清理逻辑不受影响。
///
/// 规则：
/// - 可写：fixture workspace、独立临时 HOME、独立临时 TMPDIR（后两者在 workspace 之外，file tools 看不到）、
///   `/dev/null` 等设备、`/dev/fd`；以及 xcrun shim（`python3` / `git` / `make`）固定写入的
///   `$DARWIN_USER_TEMP_DIR/xcrun_db*` 缓存文件（先写 `xcrun_db-XXXX` 再 rename 为 `xcrun_db`）——不放行时每条命令都在 stderr 打印 “couldn't create cache file”，会误导模型。
/// - 其它位置一律不可写（真实 HOME、/tmp、workspace 外）；symlink 按解析后路径判定。
/// - 禁止一切网络（含 localhost）。
/// - 不限制读取。真实 HOME 下的文件、Keychain（`security` 命令）仍可读，这是未覆盖的风险，见 README。
/// - 已知副作用：setuid 程序（如 `/bin/ps`）在 sandbox 内无法执行。
public struct Containment: Sendable {
    public let workspace: String
    public let home: String
    public let tmp: String

    /// 在 workspace 旁建 `<root>.env/home` 与 `<root>.env/tmp`。
    public init(workspace: Workspace) throws {
        let env = workspace.root + ".env"
        for directory in ["home", "tmp"] {
            try FileManager.default.createDirectory(atPath: env + "/" + directory, withIntermediateDirectories: true)
        }
        self.workspace = workspace.root
        self.home = try Workspace(root: env + "/home").root
        self.tmp = try Workspace(root: env + "/tmp").root
    }

    public var profile: String {
        var allowed = [workspace, home, tmp].map { "(subpath \(Self.quote($0)))" }
        allowed += ["/dev/null", "/dev/zero", "/dev/tty", "/dev/dtracehelper", "/dev/stdout", "/dev/stderr"].map { "(literal \(Self.quote($0)))" }
        allowed.append("(subpath \"/dev/fd\")")
        if let userTemp = Self.darwinUserTempDir() {
            allowed.append("(regex #\"^\(NSRegularExpression.escapedPattern(for: userTemp + "/xcrun_db"))\")")
        }
        return """
            (version 1)
            (allow default)
            (deny network*)
            (deny file-write*)
            (allow file-write*
              \(allowed.joined(separator: "\n  ")))
            """
    }

    /// 模型命令的环境：白名单变量 + 独立 HOME / TMPDIR。
    public var environment: [String: String] {
        var env = ProcessRunner.baseEnvironment()
        env["HOME"] = home
        env["TMPDIR"] = tmp + "/"
        return env
    }

    /// 在 sandbox 内执行的 runner。
    public func runner(timeout: Duration = .seconds(60)) -> ProcessRunner {
        var runner = ProcessRunner(timeout: timeout, environment: environment)
        runner.sandboxProfile = profile
        return runner
    }

    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)` 的规范路径（/var → /private/var），不带结尾斜杠。
    static func darwinUserTempDir() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0, let real = realpath(buffer, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}
