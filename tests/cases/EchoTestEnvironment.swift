import Foundation

/// The suites resolve fixtures — build/agent/conversation.md, the loopback
/// server scripts — relative to the working directory, because the shell
/// scripts ran them from the project root. A test bundle starts somewhere else,
/// and Xcode's Test action does not carry a custom working directory, so derive
/// the root from this file's own compile-time path instead.
enum EchoTestEnvironment {
    static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)      // tests/cases/EchoTestEnvironment.swift
            .deletingLastPathComponent()     // tests/cases
            .deletingLastPathComponent()     // tests
            .deletingLastPathComponent()     // project root
    }

    static func useProjectRootAsWorkingDirectory() {
        precondition(FileManager.default.changeCurrentDirectoryPath(projectRoot.path),
                     "Cannot enter the project root at \(projectRoot.path)")
    }
}
