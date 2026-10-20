import Foundation
import FoundationModels

enum AgentTurnOutcome: String, Codable, Sendable {
    case completed, interrupted, failed
    case stepLimit = "step_limit"
    case formatErrorLimit = "format_error_limit"
}

/// Everything the native engine needs to continue a conversation, saved in its sidecar.
struct NativeAgentState: Codable {
    struct Turn: Codable, Equatable {
        /// Index of the turn's first transcript entry.
        var start: Int
        var outcome: AgentTurnOutcome?
    }
    struct Input: Codable, Equatable {
        var messageID: UUID
        var text: String
        /// Where the files the person added with this input are; none for most input.
        var attachments: [String]?
        /// The names those files go by in the chat, given when the input was queued. Input saved
        /// before names were given has none; its files are named as they reach the transcript.
        var names: [String]?
    }
    /// The model context without instructions, which each `respond` rebuilds from the profile.
    var entries: [Transcript.Entry] = []
    var turns: [Turn] = []
    /// User input not yet in the transcript: queued while a turn ran, or sent when it could not start.
    var pendingInputs: [Input] = []
    /// The assistant message shown for each response entry, by entry ID.
    var replies: [String: UUID] = [:]
    /// This chat's Finder folder: the canonical path the read tools use as their Finder root. Set by
    /// the first read of Finder's side and replaced only by finder_location. Not a project.
    var finderFolder: String?
    /// Changes the person undid since the model last heard: one line each, told to the model at the
    /// start of the next message it gets from the person.
    var undoNotices: [String] = []
    /// Every file the person added to this chat, from the input that brought it into the
    /// transcript on. read_file reads them by name for the rest of the chat.
    var attachments: [AttachedFile] = []
    /// The reminders and events Echo created or completed in this chat, by the card of the call
    /// that did it, for an undo.
    var calendarChanges: [String: AgentCalendarChange] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey { case transcript, turns, pendingInputs, replies, finderFolder, undoNotices, attachments, calendarChanges }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = Array(try values.decode(Transcript.self, forKey: .transcript))
        turns = try values.decode([Turn].self, forKey: .turns)
        pendingInputs = try values.decode([Input].self, forKey: .pendingInputs)
        replies = try values.decode([String: UUID].self, forKey: .replies)
        finderFolder = try values.decodeIfPresent(String.self, forKey: .finderFolder)
        undoNotices = try values.decodeIfPresent([String].self, forKey: .undoNotices) ?? []
        attachments = try values.decodeIfPresent([AttachedFile].self, forKey: .attachments) ?? []
        calendarChanges = try values.decodeIfPresent([String: AgentCalendarChange].self, forKey: .calendarChanges) ?? [:]
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Transcript(entries: entries), forKey: .transcript)
        try values.encode(turns, forKey: .turns)
        try values.encode(pendingInputs, forKey: .pendingInputs)
        try values.encode(replies, forKey: .replies)
        try values.encodeIfPresent(finderFolder, forKey: .finderFolder)
        if !undoNotices.isEmpty { try values.encode(undoNotices, forKey: .undoNotices) }
        if !attachments.isEmpty { try values.encode(attachments, forKey: .attachments) }
        if !calendarChanges.isEmpty { try values.encode(calendarChanges, forKey: .calendarChanges) }
    }

    /// The names the files at `paths` would go by in this chat, in order: a file the chat already
    /// has, or input still pending carries, keeps its name; a new one gets one no other file has.
    func names(for paths: [String]) -> [String] {
        let pending = pendingInputs.flatMap { input in
            zip(input.attachments ?? [], input.names ?? []).map { AttachedFile(name: $1, path: $0) }
        }
        return AttachedFile.names(for: paths, known: attachments + pending)
    }

    /// The files sent with `input` join the chat's attached files, by the names they were given
    /// when it was queued, and those names come back in order. A file the chat has keeps its name.
    mutating func attach(_ input: Input) -> [String] {
        let paths = input.attachments ?? []
        let given = input.names?.count == paths.count ? input.names! : AttachedFile.names(for: paths, known: attachments)
        return zip(paths, given).map { path, name in
            if let known = attachments.first(where: { $0.path == path }) { return known.name }
            let unique = attachments.contains { $0.name == name } ? AttachedFile.name(for: path, taken: Set(attachments.map(\.name))) : name
            attachments.append(AttachedFile(name: unique, path: path))
            return unique
        }
    }

    /// Continue is offered for input that never reached the model and for a last turn that did not complete.
    var continuable: Bool {
        !pendingInputs.isEmpty || (turns.last.map { $0.outcome != .completed } ?? false)
    }
}

/// A file attached to the chat as the Agent knows it: by a name unique in the chat, which is all
/// the model sees. Two files with the same name get Finder's "name 2.ext".
struct AttachedFile: Codable, Equatable, Sendable {
    var name: String
    /// Absolute; for Echo and the card, never for the model.
    var path: String

    /// Names for the files at `paths`, given those the chat `known` already names: a known file
    /// keeps its name, and a new one gets one no other file has, the earlier ones in `paths` included.
    static func names(for paths: [String], known: [AttachedFile]) -> [String] {
        var known = known
        return paths.map { path in
            if let file = known.first(where: { $0.path == path }) { return file.name }
            let file = AttachedFile(name: name(for: path, taken: Set(known.map(\.name))), path: path)
            known.append(file)
            return file.name
        }
    }

    static func name(for path: String, taken: Set<String>) -> String {
        let name = (path as NSString).lastPathComponent
        guard taken.contains(name) else { return name }
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty || stem.isEmpty ? "\(name) \(number)" : "\(stem) \(number).\(ext)"
            if !taken.contains(candidate) { return candidate }
            number += 1
        }
    }
}
