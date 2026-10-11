import CoreServices
import Darwin
import Foundation
import Synchronization

// Where Finder's frontmost browser window is, for `finder_location`. One Apple Event, core/getd
// for `target of Finder window 1` as a file URL. Measured on this machine (finder-location probe):
// -1743, -1708 and -1728 come back in the reply's errn while `sendEvent` returns normally; only
// -1712 (timeout) and -600 (Finder not running) are thrown. The permission prompt lives only as
// long as the send waits: when the timeout ends it, the prompt goes and nothing is recorded.

/// What `finder_location` learned about Finder's frontmost browser window.
enum FinderLocation: Sendable, Equatable {
    /// The folder's canonical path, e.g. /private/tmp for /tmp.
    case folder(String)
    case unavailable(Unavailable)
    /// Echo may not send Apple Events to Finder (-1743).
    case permissionDenied

    enum Unavailable: Sendable, Equatable {
        /// No folder there: a location that is not one (-1708: Recents, AirDrop, Network, tags),
        /// no browser window (-1728), Finder not running (-600), or a folder that cannot be opened.
        case noFolder
        /// The permission prompt got no answer before the send timed out (-1712).
        case promptUnanswered
        /// An Apple Event error nothing above accounts for.
        case error(Int)
    }

    /// An Apple Event error, from the reply's errn or thrown by the send.
    static func classify(_ code: Int) -> FinderLocation {
        switch code {
        case -1743: .permissionDenied
        case -1712: .unavailable(.promptUnanswered)
        case -1708, -1728, -600: .unavailable(.noFolder)
        default: .unavailable(.error(code))
        }
    }

    /// The reply to the getd event: its errn first, then the folder it names.
    static func classify(reply: NSAppleEventDescriptor) -> FinderLocation {
        if let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != 0 {
            return classify(Int(code))
        }
        guard let url = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.fileURLValue else {
            return .unavailable(.noFolder)
        }
        return opening(url.path)
    }

    static func classify(thrown error: any Error) -> FinderLocation {
        classify((error as NSError).code)
    }

    /// The folder once it opens; one that does not (EPERM, say) is no folder to report. A protected
    /// folder need not prompt for access: on the probe machine none did.
    static func opening(_ path: String) -> FinderLocation {
        guard let canonical = ProjectPath.canonical(path) else { return .unavailable(.noFolder) }
        let fd = open(canonical, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return .unavailable(.noFolder) }
        close(fd)
        return .folder(canonical)
    }

    /// What the model sees: the folder's name as Finder shows it, never a path.
    var toolResult: String {
        switch self {
        case .folder(let path):
            AgentToolResult.object(["folder": FileManager.default.displayName(atPath: path)])
        case .permissionDenied:
            AgentToolResult.status("permission_denied",
                "Echo is not allowed to control Finder. Ask the person to turn on Finder for Echo in System Settings > Privacy & Security > Automation, then ask again.")
        case .unavailable(.promptUnanswered):
            AgentToolResult.status("unavailable",
                "The prompt asking whether Echo may control Finder got no answer. Ask the person to click Allow in the prompt when it appears, then ask again.")
        case .unavailable(.noFolder):
            AgentToolResult.status("unavailable",
                "Finder's frontmost window is not in a readable folder, or no Finder window is open. Answer normally; do not present this to the person as an error.")
        case .unavailable(.error(let code)):
            AgentToolResult.status("unavailable",
                "Finder did not report its location (Apple Event error \(code)). Tell the person Echo could not tell which folder Finder is showing.")
        }
    }
}

/// Finds Finder's location. Tests replace it; nothing in a test may send Finder an Apple Event.
protocol FinderLocating: Sendable {
    func locate() async -> FinderLocation
}

/// Asks Finder over Apple Events, one send at a time app-wide: a call made while a send is out
/// waits for that send's result. The send blocks its thread for up to `timeout`, so it runs on a
/// dispatch queue rather than the main actor or Swift's cooperative pool.
final class AppleEventFinderLocator: FinderLocating {
    static let shared = AppleEventFinderLocator()
    /// Long enough for the person to answer the permission prompt, which closes when this runs out.
    static let timeout: TimeInterval = 60

    private let waiters = Mutex<[CheckedContinuation<FinderLocation, Never>]?>(nil)

    func locate() async -> FinderLocation {
        await withCheckedContinuation { continuation in
            let first = waiters.withLock { waiters in
                defer { waiters = (waiters ?? []) + [continuation] }
                return waiters == nil
            }
            guard first else { return }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let location = Self.query()
                let waiting = waiters.withLock { waiters in
                    defer { waiters = nil }
                    return waiters ?? []
                }
                waiting.forEach { $0.resume(returning: location) }
            }
        }
    }

    private static func query() -> FinderLocation {
        do { return FinderLocation.classify(reply: try event().sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)) }
        catch { return FinderLocation.classify(thrown: error) }
    }

    /// `get target of Finder window 1 as «class furl»`. Class and property codes are from Finder's
    /// sdef: `Finder window` is 'brow', its `target` is 'fvtg'.
    static func event() -> NSAppleEventDescriptor {
        let window = specifier(want: code("brow"), form: DescType(formAbsolutePosition), data: NSAppleEventDescriptor(int32: 1), from: .null())
        let target = specifier(want: DescType(typeProperty), form: DescType(formPropertyID), data: NSAppleEventDescriptor(typeCode: code("fvtg")), from: window)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(target, forKeyword: AEKeyword(keyDirectObject))
        event.setParam(NSAppleEventDescriptor(typeCode: DescType(typeFileURL)), forKeyword: AEKeyword(keyAERequestedType))
        return event
    }

    private static func specifier(want: DescType, form: DescType, data: NSAppleEventDescriptor, from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        // A record coerces to an object specifier by retyping; this never fails.
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? record
    }

    private static func code(_ text: StaticString) -> FourCharCode {
        UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount).reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
