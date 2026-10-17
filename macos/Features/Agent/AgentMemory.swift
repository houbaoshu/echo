import Foundation
import FoundationModels

// What the person asked the Agent to remember about them: one Markdown file beside settings.json,
// a line each. While the person has it in use, every cloud request carries the whole file in its
// instructions, read as the request is built, so an edit the person makes in their editor reaches
// the next one; a file that did not change leaves the instructions byte-identical for a service's
// prompt cache. The model changes it only through remember and update_memory, which run as the
// write tools do: in their turn, saved before the change, with a record kept for the card's Undo.

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

    /// When the file last changed, or nil when there is none.
    func modified() -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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

/// One line of the memory as settings shows it: a list item without its marker, or any other
/// line as it is written.
enum AgentMemoryLine: Equatable, Sendable {
    case item(String)
    case text(String)

    /// The non-blank lines of `text`, each trimmed; a list marker with nothing after it is no line.
    static func lines(of text: String) -> [AgentMemoryLine] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !AgentMemoryEdit.markers.contains(line + " ") else { return nil }
            guard AgentMemoryEdit.markers.contains(where: { line.hasPrefix($0) }) else { return .text(line) }
            let item = AgentMemoryEdit.unmarked(line)
            return item.isEmpty ? nil : .item(item)
        }
    }
}

/// How the memory's lines are written, for the instructions and the tools that write them.
enum AgentMemoryForm {
    /// What every line is.
    static let rule = "one rule that reads on its own, without the chat it came from, and covers exactly what the person said, no more and no less, in the language they said it in"
    /// When a line also carries what the person said.
    static let quote = "When the rule is worded quite differently from what the person said, the line ends with their own words in parentheses, quoted exactly as they said them; otherwise it has no parentheses."
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
    let description = "Add one line to what the person asked you to remember about them: \(AgentMemoryForm.rule). \(AgentMemoryForm.quote) "
        + AgentMemorySensitive.toolNote
    let access: any AgentMemoryAccess

    @Generable
    struct Input {
        @Guide(description: "What to remember about the person, as one rule on one short line")
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
    let description = "Replace one exact passage of what the person asked you to remember about them; an empty new_text removes it. "
        + "Each line new_text writes is \(AgentMemoryForm.rule). \(AgentMemoryForm.quote) " + AgentMemorySensitive.toolNote
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
        case empty, full, notFound = "not_found", ambiguous, nothingRemembered = "nothing_remembered", notText = "not_text", sensitive
    }

    /// What a remember call adds: the text on one line, as a Markdown list item.
    static func line(_ text: String) -> String {
        // The model may write the list marker itself.
        unmarked(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// The Markdown list markers a line may start with.
    static let markers = ["- ", "* ", "+ "]

    /// `line` without the list markers it starts with.
    static func unmarked(_ line: String) -> String {
        var line = line
        for marker in markers where line.hasPrefix(marker) { line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return line
    }

    /// The memory after `change`, from what it holds now (nil when there is no file), or the
    /// result that ends the call with nothing changed.
    static func apply(_ change: AgentMemoryChange, to data: Data?) -> Result<Data, AgentInvalidArguments> {
        // What the call would write is checked first, whatever the file holds; update_memory's
        // old_text is already in the memory, so only its new_text is.
        let (field, written) = switch change {
        case .remember(let text): ("text", line(text))
        case .update(_, let new): ("new_text", new)
        }
        let kinds = AgentMemorySensitive.kinds(in: written)
        if !kinds.isEmpty {
            // The result names what was found, never the text itself.
            return failure(.sensitive, "\(field) contains \(AgentMemorySensitive.phrase(kinds)), which the memory does not accept, so nothing was \(field == "text" ? "remembered" : "changed")",
                           kinds: kinds)
        }
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

    private static func failure(_ reason: Reason, _ detail: String, count: Int? = nil,
                                kinds: [AgentMemorySensitive] = []) -> Result<Data, AgentInvalidArguments> {
        var value: [String: Any] = ["status": "failed", "detail": detail, "reason": reason.rawValue]
        if let count { value["count"] = count }
        if !kinds.isEmpty { value["kinds"] = kinds.map(\.rawValue) }
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

/// What the memory does not accept: personal details that are found by how they are written, so a
/// call holding one changes nothing. Numbers count only when their check digits agree, keys only by
/// their services' fixed prefixes, and an address only down to a door, building, unit or room number;
/// a city or district alone is not one. The person's own edits to the file are not checked.
enum AgentMemorySensitive: String, CaseIterable, Sendable {
    case idCard = "id_card", bankCard = "bank_card", password, apiKey = "api_key", phone, email, address

    /// What the tool descriptions say of it.
    static let toolNote = "The memory does not accept ID card numbers, bank card numbers, passwords, API keys or tokens, phone numbers, email addresses or street addresses."

    /// How a result names one.
    var phrase: String {
        switch self {
        case .idCard: "a Chinese resident ID card number"
        case .bankCard: "a bank card number"
        case .password: "a password"
        case .apiKey: "an API key or token"
        case .phone: "a phone number"
        case .email: "an email address"
        case .address: "a street address"
        }
    }

    /// "a phone number and an email address".
    static func phrase(_ kinds: [Self]) -> String {
        let phrases = kinds.map(\.phrase)
        guard let last = phrases.last else { return "" }
        return phrases.count == 1 ? last : phrases.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Every kind `text` holds, in the order of the cases.
    static func kinds(in text: String) -> [Self] {
        var found = numberKinds(in: text)
        for (kind, patterns) in patterns where patterns.contains(where: { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }) {
            found.insert(kind)
        }
        return allCases.filter(found.contains)
    }

    private static let patterns: [(Self, [NSRegularExpression])] = [
        // The word, then a colon, 是/为/is or an equals sign and a value; or the word, a space and
        // a value with a digit or a symbol in it, so "password manager" is not one. A value is
        // four or more printable ASCII characters: "密码学" and "密码是什么" are not.
        (.password, [
            #"(?i)(?<![a-z])(?:密码|口令|password|passwd|pwd)\s*(?:[:：=]|是|为|is(?![a-z]))\s*[!-~]{4,}"#,
            #"(?i)(?<![a-z])(?:密码|口令|password|passwd|pwd)\s+(?=[a-z]*[!-@\[-`{-~])[!-~]{4,}"#,
        ]),
        (.apiKey, [
            #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{20,}"#,                          // OpenAI, Anthropic, DeepSeek…
            #"(?<![A-Za-z0-9])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#,        // Stripe
            #"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{30,}"#,                      // GitHub
            #"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{30,}"#,
            #"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_\-]{20,}"#,                       // GitLab
            #"(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Za-z])"#,        // AWS access key ID
            #"(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{35}"#,                          // Google
            #"(?<![A-Za-z0-9])xox[abposr]-[A-Za-z0-9\-]{10,}"#,                  // Slack
            #"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,}"#,                             // Hugging Face
            #"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36}"#,                             // npm
            #"(?<![A-Za-z0-9])pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_\-]{20,}"#,         // PyPI
            #"(?<![A-Za-z0-9])SG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}"#,    // SendGrid
            #"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]+"#,   // JWT
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        ]),
        (.email, [#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#]),
        // A road, street or lane and a door number ("文三路 88 号", but not "3 号线"); a building or
        // unit number ("5 栋", "2 号楼", "3 单元", but not "第 3 单元"); a room number of three or
        // more digits ("1201 室", but not "3 室 2 厅"). "5 号" alone is as often a date.
        (.address, [
            #"(?:路|街|(?<!知)道|巷|弄|胡同)\s*[0-9]+\s*(?:号|弄)(?!线)"#,
            #"[0-9]+\s*(?:栋|幢|号楼)"#,
            #"(?<![0-9第])(?<!第 )[0-9]+\s*单元"#,
            #"[0-9]{3,}\s*室"#,
        ]),
    ].map { kind, patterns in (kind, patterns.map { try! NSRegularExpression(pattern: $0) }) }

    /// Digits, maybe split by single spaces or hyphens ("138 0013 8000", "6222-0200-…"); an ID
    /// card number may end in X.
    private static let numberRun = try! NSRegularExpression(pattern: #"[0-9]+(?:[ \-][0-9]+)*[Xx]?"#)

    /// ID card, phone and bank card numbers. Each run of consecutive groups in a written number is
    /// tried, so a phone number written after a date on the same line is still found.
    private static func numberKinds(in text: String) -> Set<Self> {
        var found = Set<Self>()
        for match in numberRun.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let groups = text[range].split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            for start in groups.indices {
                var digits = ""
                for group in groups[start...] {
                    digits += group
                    guard digits.count <= 19 else { break }
                    if let kind = numberKind(digits) { found.insert(kind) }
                }
            }
        }
        return found
    }

    private static func numberKind(_ number: String) -> Self? {
        let digits = number.compactMap(\.wholeNumberValue)
        if isIDCard(number) { return .idCard }
        guard digits.count == number.count else { return nil }   // an X anywhere else
        // 11 digits from 13 to 19, maybe after 86.
        let local = digits.count == 13 && digits.starts(with: [8, 6]) ? Array(digits.dropFirst(2)) : digits
        if local.count == 11, local[0] == 1, (3...9).contains(local[1]) { return .phone }
        if (13...19).contains(digits.count), luhn(digits) { return .bankCard }
        return nil
    }

    /// 18 characters: a birth date at 7–14 and a check character that agrees with the other 17.
    private static func isIDCard(_ number: String) -> Bool {
        let characters = Array(number.uppercased())
        guard characters.count == 18 else { return false }
        let digits = characters.prefix(17).compactMap(\.wholeNumberValue)
        guard digits.count == 17 else { return false }
        func value(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
        let year = value(6..<10), month = value(10..<12), day = value(12..<14)
        guard (1900...2099).contains(year), (1...12).contains(month), (1...31).contains(day) else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let sum = zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 }
        return characters[17] == Array("10X98765432")[sum % 11]
    }

    private static func luhn(_ digits: [Int]) -> Bool {
        let sum = digits.reversed().enumerated().reduce(0) { sum, item in
            let (index, digit) = item
            guard index % 2 == 1 else { return sum + digit }
            return sum + (digit * 2 > 9 ? digit * 2 - 9 : digit * 2)
        }
        return sum % 10 == 0
    }
}
