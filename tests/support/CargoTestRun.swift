import Foundation
import Testing

private final class CargoTestBundleToken {}

/// Runs one workspace package's Rust tests with `cargo test` and reports them as a Swift test.
///
/// cargo starts through scripts/cargo-isolated.sh, the script Xcode's Rust build phase also
/// uses, so the tests find the same cargo and keep the test process's environment away from it.
/// Output goes to a debug-profile target directory per package under
/// ECHO_CARGO_TEST_TARGET_DIR (Echo.xcconfig), never into the repository and never next to the
/// release libraries the app links. cargo's combined output is attached to the test.
enum CargoTestRun {
    static func run(package: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let info = Bundle(for: CargoTestBundleToken.self).infoDictionary ?? [:]
        let project = try #require(info["EchoProjectDirectory"] as? String, sourceLocation: sourceLocation)
        let outputRoot = URL(filePath: try #require(info["EchoCargoTestTargetDirectory"] as? String, sourceLocation: sourceLocation))
        let targetDirectory = outputRoot.appending(path: package)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        // A file rather than a pipe: cargo can write more than a pipe buffers before it exits.
        let log = outputRoot.appending(path: "\(package).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(filePath: project).appending(path: "scripts/cargo-isolated.sh")
        // --offline: the dev-dependencies are in the Cargo cache, so the result never depends on
        // the network. --no-fail-fast: run every test binary and report all failures.
        process.arguments = [
            "test", "--locked", "--offline", "--no-fail-fast",
            "--package", package, "--target-dir", targetDirectory.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }

        let text = try String(contentsOf: log, encoding: .utf8)
        Attachment.record(text, named: "cargo test --package \(package).txt", sourceLocation: sourceLocation)
        let summary = CargoTestSummary(text)
        let command = "cargo test --package \(package)"
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let outcome = process.terminationReason == .exit
                ? "exited with status \(process.terminationStatus)" : "was killed by signal \(process.terminationStatus)"
            let detail = summary.failed.isEmpty
                ? "no Rust test reported a failure, so the build or cargo itself failed; see the attached output"
                : "failing Rust tests: \(summary.failed.joined(separator: ", "))"
            Issue.record("\(command) \(outcome): \(detail)", sourceLocation: sourceLocation)
            return
        }
        #expect(summary.passed > 0, "\(command) ran no Rust tests", sourceLocation: sourceLocation)
    }
}

/// What libtest printed: how many tests passed and which failed, each prefixed by its test binary.
private struct CargoTestSummary {
    var passed = 0
    var failed: [String] = []

    init(_ output: String) {
        var binary = ""
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Running ") {
                binary = line.dropFirst("Running ".count).prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Doc-tests ") {
                binary = line
            } else if line.hasPrefix("test "), line.hasSuffix(" ... FAILED") {
                failed.append("\(binary): \(line.dropFirst("test ".count).dropLast(" ... FAILED".count))")
            } else if line.hasPrefix("test result: "), let match = line.firstMatch(of: /(\d+) passed/) {
                passed += Int(match.1) ?? 0
            }
        }
    }
}
