import AppKit
import Foundation
import FoundationModels

// open_app and open_url for the native Agent. The tools read their arguments; the harness runs
// each call in its turn without asking first, and the card shows what was opened. Nothing here
// can be undone. `AgentOpener` is the only part that looks at installed apps or opens anything,
// so tests give the harness an opener of their own.
//
// An app is found by any name it goes by: the one Finder shows in Chinese or English, its bundle
// names, or its file name without .app. LaunchServices knows apps only by their English and file
// names and Spotlight by the system language's, so the names come from each bundle's own
// localizations. A web address opens only when it is http or https: any other scheme can make an
// app act on its own, which is not what opening a page means.

/// An installed app and every name it is looked up by.
struct AgentApp: Sendable, Equatable {
    var path: String
    /// The name Finder shows, in Echo's language.
    var name: String
    /// Its file name without .app, its bundle names, and those names in Chinese, English and the
    /// person's languages.
    var names: [String]
}

/// Finds and opens apps and web pages for the Agent.
protocol AgentOpener: Sendable {
    /// The apps in /Applications, /System/Applications and ~/Applications, a folder deep, and Finder's neighbours in CoreServices.
    func applications() async -> [AgentApp]
    /// Opens the app, or brings it to the front when it is running already. Says whether it was running.
    func openApplication(at path: String) async throws -> Bool
    /// Opens the page in the default browser, never in an app that claims its address.
    func openInBrowser(_ url: URL) async throws
}

/// What an open_app or open_url call asks for.
enum AgentOpenRequest: Sendable, Equatable {
    case app(String)
    case url(String)
}

/// Runs open_app and open_url calls for the conversation.
protocol AgentOpenAccess: Sendable {
    /// `call` links the call to the one the harness saw dispatched, as for finder_location.
    func run(call: GenerationID?, _ request: Result<AgentOpenRequest, AgentInvalidArguments>) async throws -> String
}

struct OpenAppTool: Tool {
    let name = "open_app"
    let description = "Open an app on the person's Mac, or bring it to the front when it is already open"
    let access: any AgentOpenAccess

    @Generable
    struct Input {
        @Guide(description: "The app's name as the person calls it, in Chinese or English, such as 访达, 提醒事项, 微信 or Finder; or the path of an .app")
        var name: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let request: Result<AgentOpenRequest, AgentInvalidArguments>
        if let input = try? Input(arguments), !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request = .success(.app(input.name))
        } else {
            request = .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for open_app; expected {\"name\": string}. Received: \(arguments.jsonString)")))
        }
        return try await access.run(call: arguments.id, request)
    }
}

struct OpenURLTool: Tool {
    let name = "open_url"
    let description = "Open a web page in the person's default browser"
    let access: any AgentOpenAccess

    @Generable
    struct Input {
        @Guide(description: "The page's full address, starting with http:// or https://")
        var url: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let request: Result<AgentOpenRequest, AgentInvalidArguments>
        if let input = try? Input(arguments) {
            request = .success(.url(input.url))
        } else {
            request = .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for open_url; expected {\"url\": string}. Received: \(arguments.jsonString)")))
        }
        return try await access.run(call: arguments.id, request)
    }
}

// MARK: Results

/// What the open tools return. A call that opened nothing says why in `detail` for the model and
/// in `reason` and its fields for the card, which words it in the person's language.
enum AgentOpenResult {
    enum Reason: String {
        case noApp = "no_app"
        case sameName = "same_name"
        case scheme
        case noScheme = "no_scheme"
        case invalidURL = "invalid_url"
        case failed
    }

    static func failed(_ reason: Reason, _ detail: String, _ fields: [String: Any] = [:]) -> String {
        AgentToolResult.object(fields.merging(["status": "failed", "detail": detail, "reason": reason.rawValue]) { $1 })
    }

    static func opened(_ app: AgentApp, wasRunning: Bool) -> String {
        AgentToolResult.object(["action": wasRunning ? "brought_to_front" : "opened", "app": app.name, "path": app.path])
    }

    static func opened(_ url: URL) -> String {
        AgentToolResult.object(["action": "opened", "url": url.absoluteString])
    }

    static func noApp(_ name: String, closest: [String]) -> String {
        let names = closest.map { "\"\($0)\"" }.joined(separator: ", ")
        return failed(.noApp, "there is no app named \(name), so nothing was opened"
                      + (closest.isEmpty ? "" : "; the closest names are \(names)"), ["name": name, "closest": closest])
    }

    static func sameName(_ name: String, apps: [AgentApp]) -> String {
        failed(.sameName, "\(apps.count) apps are named \(name), so none was opened: "
               + apps.map(\.path).joined(separator: ", ") + ". name may also be the path of one of them",
               ["name": name, "apps": apps.map(\.path)])
    }

    static func scheme(_ scheme: String) -> String {
        failed(.scheme, "only http and https addresses are opened, and this one is \(scheme):, which can make another app take an action, so nothing was opened",
               ["scheme": scheme])
    }

    static let noScheme = failed(.noScheme, "the address has no http:// or https:// in front, so nothing was opened")
    static let invalidURL = failed(.invalidURL, "this is not a web address, so nothing was opened")
}

// MARK: Running a call

/// A call worked out with nothing opened yet, or its result.
enum AgentOpenPlan: Sendable {
    case done(String)
    case app(AgentApp)
    case url(URL)
}

enum AgentOpenRunner {
    static let closestCount = 5

    static func prepare(_ request: AgentOpenRequest, opener: any AgentOpener) async -> AgentOpenPlan {
        switch request {
        case .url(let raw):
            switch webAddress(raw) {
            case .success(let url): return .url(url)
            case .failure(let refusal): return .done(refusal.result)
            }
        case .app(let raw):
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let apps = await opener.applications()
            let found = find(name, in: apps)
            switch found.count {
            case 1: return .app(found[0])
            case 0: return .done(AgentOpenResult.noApp(name, closest: closest(to: name, in: apps)))
            default: return .done(AgentOpenResult.sameName(name, apps: found))
            }
        }
    }

    static func commit(_ plan: AgentOpenPlan, opener: any AgentOpener) async -> String {
        do {
            switch plan {
            case .done(let result):
                return result
            case .app(let app):
                return AgentOpenResult.opened(app, wasRunning: try await opener.openApplication(at: app.path))
            case .url(let url):
                try await opener.openInBrowser(url)
                return AgentOpenResult.opened(url)
            }
        } catch {
            return AgentOpenResult.failed(.failed, error.localizedDescription)
        }
    }

    // MARK: Apps

    /// Every app that goes by `name`, as the person may say it: case, width and spaces do not
    /// matter, nor does a trailing .app. A path finds the app at that path. Two copies of one app
    /// at different paths are two apps: which to open is the person's choice.
    static func find(_ name: String, in apps: [AgentApp]) -> [AgentApp] {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.hasPrefix("/") || wanted.hasPrefix("~/") {
            let path = URL(fileURLWithPath: (wanted as NSString).expandingTildeInPath).standardizedFileURL.path
            return apps.filter { $0.path == path }
        }
        let key = loose(wanted)
        guard !key.isEmpty else { return [] }
        return apps.filter { $0.names.contains { loose($0) == key } }
    }

    /// The names closest to `name`, best first and one per app: names that contain it or that it
    /// contains come first, then the fewest edits apart for their length.
    static func closest(to name: String, in apps: [AgentApp]) -> [String] {
        let key = loose(name)
        guard !key.isEmpty else { return [] }
        let scored = apps.compactMap { app -> (name: String, score: Double)? in
            app.names.map { candidate -> (name: String, score: Double) in
                let other = loose(candidate)
                if other.contains(key) || key.contains(other) {
                    return (candidate, Double(abs(other.count - key.count)) / Double(max(other.count, key.count)) - 1)
                }
                return (candidate, Double(distance(key, other)) / Double(max(other.count, key.count)))
            }.min { $0.score < $1.score }
        }
        var seen: Set<String> = []
        return scored.sorted { ($0.score, $0.name) < ($1.score, $1.name) }
            .map(\.name).filter { seen.insert(loose($0)).inserted }.prefix(closestCount).map { $0 }
    }

    /// A name without spaces, case, width or a trailing .app.
    static func loose(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".app") { text.removeLast(4) }
        return String(text.filter { !$0.isWhitespace })
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Edits between two names, by character.
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }

    // MARK: Web addresses

    /// The address as it opens, or why it does not: http or https in any case, with a host;
    /// spaces around it are dropped and spaces in it encoded.
    static func webAddress(_ raw: String) -> Result<URL, AgentInvalidArguments> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.init(result: AgentOpenResult.invalidURL))
        }
        guard let scheme = parts.scheme?.lowercased() else { return .failure(.init(result: AgentOpenResult.noScheme)) }
        guard scheme == "http" || scheme == "https" else { return .failure(.init(result: AgentOpenResult.scheme(scheme))) }
        guard let host = parts.host, !host.isEmpty else { return .failure(.init(result: AgentOpenResult.invalidURL)) }
        parts.scheme = scheme
        guard let opened = parts.url else { return .failure(.init(result: AgentOpenResult.invalidURL)) }
        return .success(opened)
    }
}

// MARK: The system

/// Apps from the folders people keep them in, and LaunchServices to open them. Each app's names
/// are read once and again only after its Info.plist changes.
actor WorkspaceOpener: AgentOpener {
    static let shared = WorkspaceOpener()

    private var known: [String: (modified: Date, app: AgentApp)] = [:]

    func applications() async -> [AgentApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        for root in ["/Applications", "/System/Applications", home + "/Applications"] { Self.scan(root, depth: 2, into: &paths) }
        // CoreServices holds Finder among system helpers that share names with real apps:
        // only those with a Dock icon are apps a person opens.
        var services: [String] = []
        Self.scan("/System/Library/CoreServices", depth: 0, into: &services)
        paths += services.filter(Self.hasDockIcon)

        var apps: [AgentApp] = []
        var seen: Set<String> = []
        for path in paths where seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted {
            let modified = (try? FileManager.default.attributesOfItem(atPath: path + "/Contents/Info.plist")[.modificationDate] as? Date) ?? .distantPast
            if let cached = known[path], cached.modified == modified { apps.append(cached.app); continue }
            let app = AgentApp(path: path, name: FileManager.default.displayName(atPath: path), names: Self.names(path))
            known[path] = (modified, app)
            apps.append(app)
        }
        return apps
    }

    nonisolated func openApplication(at path: String) async throws -> Bool {
        let url = URL(fileURLWithPath: path)
        let id = Bundle(url: url)?.bundleIdentifier
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { app in
                app.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() || (id != nil && app.bundleIdentifier == id)
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return running
    }

    nonisolated func openInBrowser(_ url: URL) async throws {
        // Asking for the scheme's handler, not the address's, keeps an app that claims the
        // address as a universal link out of it.
        guard let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https:")!) else {
            throw CocoaError(.featureUnsupported)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: configuration)
    }

    /// The .app bundles in `folder`, and in its folders down to `depth` more levels; not inside a bundle.
    private static func scan(_ folder: String, depth: Int, into paths: inout [String]) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        for item in items.sorted() where !item.hasPrefix(".") {
            let path = folder + "/" + item
            if item.hasSuffix(".app") { paths.append(path); continue }
            var isFolder: ObjCBool = false
            if depth > 0, FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                scan(path, depth: depth - 1, into: &paths)
            }
        }
    }

    private static func hasDockIcon(_ path: String) -> Bool {
        let info = Bundle(path: path)?.infoDictionary ?? [:]
        func set(_ key: String) -> Bool { (info[key] as? Bool) ?? ((info[key] as? String).map { $0 == "1" || $0.lowercased() == "true" } ?? false) }
        return !set("LSUIElement") && !set("LSBackgroundOnly")
    }

    /// The names an app goes by: file name, bundle names, and their translations in Chinese,
    /// English and the person's languages, from the bundle's InfoPlist.loctable (system apps) or
    /// its .lproj InfoPlist.strings (other apps).
    static func names(_ path: String) -> [String] {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        var names = [((path as NSString).lastPathComponent as NSString).deletingPathExtension]
        let info = Bundle(path: path)?.infoDictionary ?? [:]
        names += keys.compactMap { info[$0] as? String }
        let preferred = Set(Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier })
        func wanted(_ localization: String) -> Bool {
            let code = Locale(identifier: localization).language.languageCode?.identifier ?? localization.lowercased()
            return ["zh", "en"].contains(code) || preferred.contains(code)
                || ["base", "english", "chinese"].contains(localization.lowercased())
        }
        let resources = path + "/Contents/Resources"
        if let table = NSDictionary(contentsOfFile: resources + "/InfoPlist.loctable") as? [String: Any] {
            for (localization, strings) in table where wanted(localization) {
                names += keys.compactMap { (strings as? [String: Any])?[$0] as? String }
            }
        }
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? [] where folder.hasSuffix(".lproj") {
            guard wanted(String(folder.dropLast(6))),
                  let strings = NSDictionary(contentsOfFile: resources + "/" + folder + "/InfoPlist.strings") as? [String: Any] else { continue }
            names += keys.compactMap { strings[$0] as? String }
        }
        var seen: Set<String> = []
        return names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
    }
}
