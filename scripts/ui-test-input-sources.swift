// Puts the keyboard input sources back as they were before the UI tests.
//
// XCUITest's testmanagerd types what the current layout cannot through an input source it
// enables itself (Unicode Hex Input, or ABC / U.S.) and never disables again. The Echo-App
// scheme's test pre-action runs `record`, which notes the enabled keyboard input sources and the
// selected one; its post-action runs `restore`, which selects that one again and then disables
// only the sources that were added. Scheme actions run once per test run, however many test
// runners Xcode starts, and the post-action runs after failed and crashed tests too.
//
// What it does goes to <dir>/ui-test-input-sources.log and to stdout, which Xcode shows in the
// test run's report. (Not the unified log: run through `swift`, its messages were not kept.) It
// always exits 0: a cleanup that fails is logged and never fails the test run.
//
//   xcrun swift scripts/ui-test-input-sources.swift record|restore <dir>

import Carbon.HIToolbox
import Foundation

struct Snapshot: Codable {
    var selected: String?
    var enabled: [String]
}

let arguments = CommandLine.arguments
guard arguments.count == 3, ["record", "restore"].contains(arguments[1]) else {
    print("usage: ui-test-input-sources.swift record|restore <dir>")
    exit(0)
}
let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let stateURL = directory.appendingPathComponent("ui-test-input-sources.json")
let logURL = directory.appendingPathComponent("ui-test-input-sources.log")

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    let line = "\(stamp) \(message)\n"
    print(line, terminator: "")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: logURL) {
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

func enabled() -> [TISInputSource] {
    let keyboards = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
    return TISCreateInputSourceList(keyboards, false)?.takeRetainedValue() as? [TISInputSource] ?? []
}
func string(_ source: TISInputSource, _ key: CFString) -> String? {
    TISGetInputSourceProperty(source, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
}
func id(_ source: TISInputSource) -> String { string(source, kTISPropertyInputSourceID) ?? "?" }
func describe(_ source: TISInputSource) -> String { "\(string(source, kTISPropertyLocalizedName) ?? "?") (\(id(source)))" }
func selected() -> TISInputSource? { TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() }

if arguments[1] == "record" {
    let snapshot = Snapshot(selected: selected().map(id), enabled: enabled().map(id))
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: stateURL)
        log("before the UI tests, \(selected().map(describe) ?? "none") is selected; enabled: \(snapshot.enabled.sorted().joined(separator: ", "))")
    } catch {
        log("could not record the input sources before the UI tests: \(error)")
    }
    exit(0)
}

guard let data = try? Data(contentsOf: stateURL), let before = try? JSONDecoder().decode(Snapshot.self, from: data) else {
    log("after the UI tests, nothing was recorded before them, so nothing is restored")
    exit(0)
}
var done: [String] = []
// The original goes back first: the source that is selected may be one to disable.
if let original = before.selected, let current = selected(), id(current) != original {
    if let source = enabled().first(where: { id($0) == original }) {
        let status = TISSelectInputSource(source)
        done.append(status == noErr ? "selected \(describe(source)) again (was \(describe(current)))"
                                     : "could not select \(describe(source)) again: OSStatus \(status)")
    } else {
        done.append("could not select \(original) again: it is no longer enabled")
    }
}
for source in enabled() where !before.enabled.contains(id(source)) {
    let status = TISDisableInputSource(source)
    done.append(status == noErr ? "disabled \(describe(source))" : "could not disable \(describe(source)): OSStatus \(status)")
}
log(done.isEmpty ? "after the UI tests, nothing to restore" : "after the UI tests, " + done.joined(separator: "; "))
// One record serves one restore; a later run without a pre-action must not reuse it.
try? FileManager.default.removeItem(at: stateURL)
exit(0)
