// Messages shared by SandboxProbeHost and the SandboxProbeExec XPC service.
import Foundation

let execServiceName = "local.chiyan.sandbox-probe.exec"

enum ProbeRequest: Codable {
    case info
    case run(RunRequest)
    case cancel(String)
}

struct RunRequest: Codable {
    var id: String
    var command: String
    /// Bookmark data created by the host without security-scope options (implicit ephemeral scope).
    var bookmarks: [Data] = []
    /// Working directory; must be inside one of the bookmarks for the sandboxed side.
    var directory: String
    var timeout: Double = 20
    /// Stop accessing every bookmark right after the shell is spawned (S8 pattern).
    var releaseAfterSpawn = false
    /// Extra environment on top of the runner's whitelist.
    var environment: [String: String] = [:]
}

struct BookmarkAccess: Codable {
    var path: String?
    var stale: Bool
    var started: Bool
    var error: String?
}

struct RunResult: Codable {
    var id: String
    var sandboxed: Bool
    var access: [BookmarkAccess] = []
    var spawnError: String?
    var exitCode: Int32?
    var signal: Int32?
    var stdout = ""
    var stderr = ""
    var timedOut = false
    var cancelled = false
    var shellPID: Int32 = 0
    /// Every descendant the tracker observed (pid list; identities checked with start time).
    var tracked: [Int32] = []
    /// Tracked processes that were still alive after the shell exited and were killed by cleanup.
    var leftoversKilled: [Int32] = []
    /// Tracked processes still alive after cleanup (should be empty).
    var survivors: [Int32] = []
    var durationMS: Int = 0
}

struct ServiceInfo: Codable {
    var pid: Int32
    var home: String
    var tmp: String
    var sandboxContainerID: String?
    var environmentKeys: [String]
    /// Whether public libproc calls work from inside this process (S5 tracking).
    var procProbe: String? = nil
}

struct ProbeReply: Codable {
    var info: ServiceInfo?
    var run: RunResult?
    var acknowledged = false
    var error: String?
}
