import Foundation
import FoundationModels

// What the person asked the Agent to remember about them: one Markdown file beside settings.json,
// a line each. Every cloud request carries the whole file in its instructions, read as the request
// is built, so an edit the person makes in their editor reaches the next one; a file that did not
// change leaves the instructions byte-identical for a service's prompt cache. The model changes it
// only through remember and update_memory, which run as the write tools do: in their turn, saved
// before the change, with a record kept for the card's Undo.

/// The memory file. Its folder is Echo's own, which the write tools never write in.
struct AgentMemoryFile: Sendable, Equatable {
    static let fileName = "memory.md"
    /// Most characters the memory holds once a call has changed it.
    static let maxCharacters = 8_000
    let url: URL

    init(folder: URL) { url = folder.appendingPathComponent(Self.fileName) }

    var folder: URL { url.deletingLastPathComponent() }

    /// The file's text without the blank lines around it, or nil when there is none: no file, an
    /// empty one, or one that is not UTF-8 text.
    func read() -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= ReadFileTool.maxFileBytes,
              let text = String(validating: data, as: UTF8.self) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The file, created empty when there is none, for the person to open.
    func prepareForEditing() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o644]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        return url
    }
}

/// What a memory call asks for.
enum AgentMemoryChange: Sendable, Equatable {
    /// remember: one more line.
    case remember(String)
    /// update_memory: one exact passage and what replaces it; empty removes it.
    case update(old: String, new: String)
}

/// Runs memory calls for the conversation.
protocol AgentMemoryAccess: Sendable {
    /// `call` links the call to the one the harness saw dispatched, as for the write tools.
    func change(call: GenerationID?, _ request: Result<AgentMemoryChange, AgentInvalidArguments>) async throws -> String
}

struct RememberTool: Tool {
    let name = "remember"
    let description = "Add one line to what the person asked you to remember about them"
    let access: any AgentMemoryAccess

    @Generable
    struct Input {
        @Guide(description: "What to remember about the person, as one short line")
        var text: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        guard let input = try? Input(arguments) else {
            return try await access.change(call: arguments.id, .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for remember; expected {\"text\": string}. Received: \(arguments.jsonString)"))))
        }
        return try await access.change(call: arguments.id, .success(.remember(input.text)))
    }
}

struct UpdateMemoryTool: Tool {
    let name = "update_memory"
    let description = "Replace one exact passage of what the person asked you to remember about them; an empty new_text removes it"
    let access: any AgentMemoryAccess

    @Generable
    struct Input {
        @Guide(description: "The passage to replace, exactly as it appears in the memory; it must appear exactly once")
        var old_text: String
        @Guide(description: "The text that replaces it; empty to remove the passage")
        var new_text: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        guard let input = try? Input(arguments) else {
            return try await access.change(call: arguments.id, .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for update_memory; expected {\"old_text\": string, \"new_text\": string}. Received: \(arguments.jsonString)"))))
        }
        return try await access.change(call: arguments.id, .success(.update(old: input.old_text, new: input.new_text)))
    }
}

/// The memory's new content and the results the model and the card get, in the person's terms.
enum AgentMemoryEdit {
    /// Why a call changed nothing, for the card. Raw values are what results carry.
    enum Reason: String {
        case empty, full, notFound = "not_found", ambiguous, nothingRemembered = "nothing_remembered", notText = "not_text"
    }

    /// What a remember call adds: the text on one line, as a Markdown list item.
    static func line(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        // The model may write the list marker itself.
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return line
    }

    /// The memory after `change`, from what it holds now (nil when there is no file), or the
    /// result that ends the call with nothing changed.
    static func apply(_ change: AgentMemoryChange, to data: Data?) -> Result<Data, AgentInvalidArguments> {
        let current: String
        if let data {
            guard let text = String(validating: data, as: UTF8.self) else {
                return failure(.notText, "the memory file is not UTF-8 text, so it was not changed; the person can fix it in Settings")
            }
            current = text
        } else {
            current = ""
        }
        let updated: String
        switch change {
        case .remember(let text):
            let line = line(text)
            guard !line.isEmpty else { return failure(.empty, "text must not be empty, so nothing was remembered") }
            updated = current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + "- " + line + "\n"
        case .update(let old, let new):
            guard !old.isEmpty else { return failure(.empty, "old_text must not be empty") }
            guard data != nil, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failure(.nothingRemembered, "nothing is remembered yet, so nothing was changed")
            }
            switch replacing(old, with: new, in: Data(current.utf8)) {
            case .success(let data): updated = String(decoding: data, as: UTF8.self)
            case .failure(let failure): return .failure(failure)
            }
        }
        // A memory the person made longer by hand can still be shortened.
        guard updated.count <= AgentMemoryFile.maxCharacters || updated.count <= current.count else {
            return failure(.full, "the memory is full: it holds at most \(AgentMemoryFile.maxCharacters) characters, and this change would make it \(updated.count), so nothing was changed. update_memory can shorten or remove lines, and the person can edit the memory file in Settings")
        }
        return .success(Data(updated.utf8))
    }

    /// `old`'s one occurrence replaced by `new`, compared byte for byte as edit_file does. Removing
    /// a passage removes its line too when nothing but a list marker is left of it.
    private static func replacing(_ old: String, with new: String, in data: Data) -> Result<Data, AgentInvalidArguments> {
        let needle = Data(old.utf8)
        var matches: [Range<Data.Index>] = []
        var start = data.startIndex
        while let found = data.range(of: needle, in: start..<data.endIndex) {
            matches.append(found)
            start = data.index(after: found.lowerBound)
        }
        switch matches.count {
        case 0:
            return failure(.notFound, "old_text was not found in the memory, so nothing was changed; it must match the memory exactly, including spaces and line breaks")
        case 1: break
        default:
            return failure(.ambiguous, "old_text appears \(matches.count) times in the memory, so nothing was changed; it must appear exactly once, so include more of the text around it", count: matches.count)
        }
        var result = data
        let match = matches[0]
        result.replaceSubrange(match, with: Data(new.utf8))
        guard new.isEmpty, !old.contains("\n") else { return .success(result) }
        let newline = UInt8(ascii: "\n")
        let lineStart = result[..<match.lowerBound].lastIndex(of: newline).map { $0 + 1 } ?? result.startIndex
        let lineEnd = result[match.lowerBound...].firstIndex(of: newline) ?? result.endIndex
        let rest = String(decoding: result[lineStart..<lineEnd], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard ["", "-", "*", "+"].contains(rest) else { return .success(result) }
        // The line goes with its line break: the one after it, or before it for the last line.
        if lineEnd < result.endIndex {
            result.removeSubrange(lineStart...lineEnd)
        } else if lineStart > result.startIndex {
            result.removeSubrange((lineStart - 1)..<lineEnd)
        } else {
            result.removeSubrange(lineStart..<lineEnd)
        }
        return .success(result)
    }

    private static func failure(_ reason: Reason, _ detail: String, count: Int? = nil) -> Result<Data, AgentInvalidArguments> {
        var value: [String: Any] = ["status": "failed", "detail": detail, "reason": reason.rawValue]
        if let count { value["count"] = count }
        return .failure(.init(result: AgentToolResult.object(value)))
    }

    /// A finished call's result: what the memory now holds of the change.
    static func result(_ change: AgentMemoryChange) -> String {
        switch change {
        case .remember(let text): AgentToolResult.object(["action": "remembered", "text": line(text)])
        case .update(_, let new) where new.isEmpty: AgentToolResult.object(["action": "removed"])
        case .update: AgentToolResult.object(["action": "updated"])
        }
    }
}
