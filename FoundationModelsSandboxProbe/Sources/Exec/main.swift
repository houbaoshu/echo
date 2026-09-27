// SandboxProbeExec: embedded XPC service signed with App Sandbox only (no network, no
// user-selected files, no keychain access group). It resolves bookmarks from the host,
// starts accessing them, and runs /bin/bash; every child inherits this sandbox.
import Foundation
import XPC

let registry = RunRegistry()
let work = DispatchQueue(label: "probe.exec.work", attributes: .concurrent)

func perform(_ request: RunRequest) -> RunResult {
    var result = RunResult(id: request.id, sandboxed: true)
    var accessed: [URL] = []
    for data in request.bookmarks {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withoutImplicitStartAccessing],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            let started = url.startAccessingSecurityScopedResource()
            if started { accessed.append(url) }
            result.access.append(BookmarkAccess(path: url.path, stale: stale, started: started))
        } catch {
            result.access.append(BookmarkAccess(path: nil, stale: stale, started: false, error: "\(error)"))
        }
    }
    let env = Runner.environment(home: NSHomeDirectory(), tmp: NSTemporaryDirectory(), extra: request.environment)
    let handle: RunHandle
    do {
        handle = try Runner.spawn(id: request.id, command: request.command, directory: request.directory, environment: env)
    } catch {
        accessed.forEach { $0.stopAccessingSecurityScopedResource() }
        result.spawnError = "\(error)"
        return result
    }
    registry.add(handle)
    if request.releaseAfterSpawn { accessed.forEach { $0.stopAccessingSecurityScopedResource() }; accessed = [] }
    let finished = Runner.wait(handle, timeout: request.timeout, sandboxed: true)
    registry.remove(request.id)
    accessed.forEach { $0.stopAccessingSecurityScopedResource() }
    var merged = finished
    merged.access = result.access
    return merged
}

func procProbe() -> String {
    let selfInfo = ProcIdentity.of(getpid()) != nil
    let allPIDs = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    var parts = ["self PROC_PIDTBSDINFO=\(selfInfo)", "PROC_ALL_PIDS bytes=\(allPIDs) errno=\(errno)"]
    if let handle = try? Runner.spawn(id: "proc-probe", command: "sleep 2 & sleep 2", directory: "/",
                                      environment: Runner.environment(home: NSHomeDirectory(), tmp: NSTemporaryDirectory(), extra: [:])) {
        usleep(300_000)
        let children = ProcList.children(of: getpid())
        let group = ProcList.group(handle.shellPID)
        parts.append("child identity=\(ProcIdentity.of(handle.shellPID) != nil)")
        parts.append("listchildpids(self)=\(children.count)")
        parts.append("PGRP_ONLY(shell)=\(group.count)")
        parts.append("listchildpids(shell)=\(ProcList.children(of: handle.shellPID).count)")
        handle.markTimedOut()
        _ = Runner.wait(handle, timeout: 5, sandboxed: true)
    }
    return parts.joined(separator: ", ")
}

func info() -> ServiceInfo {
    let env = ProcessInfo.processInfo.environment
    return ServiceInfo(pid: getpid(), home: NSHomeDirectory(), tmp: NSTemporaryDirectory(),
                       sandboxContainerID: env["APP_SANDBOX_CONTAINER_ID"], environmentKeys: env.keys.sorted(),
                       procProbe: procProbe())
}

do {
    let listener = try XPCListener(service: execServiceName, requirement: .isFromSameTeam()) { request in
        request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
            guard let decoded = try? message.decode(as: ProbeRequest.self) else {
                return ProbeReply(error: "undecodable request")
            }
            switch decoded {
            case .info:
                return ProbeReply(info: info())
            case .cancel(let id):
                return ProbeReply(acknowledged: registry.cancel(id))
            case .run(let run):
                return message.handoffReply(to: work) {
                    message.reply(ProbeReply(run: perform(run)))
                }
            }
        }
    }
    _ = listener
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("SandboxProbeExec listener failed: \(error)\n".utf8))
    exit(1)
}
