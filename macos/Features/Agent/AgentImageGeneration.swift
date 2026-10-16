import Foundation
import FoundationModels
import ImageIO

// generate_image for the native Agent: text to image with the Volcengine Ark group's vision model,
// through the Agent Plan's /images/generations with the group's key. Like web_search, the tool is
// offered whenever that key is saved, whichever service writes the reply.
//
// Measured on the Agent Plan (probe, 2026-10-16): both spellings of the model name are accepted; a
// "宽x高" size comes back exactly as asked, while "2K" lets the model choose the aspect ratio; one
// image takes 26–43 seconds at 2K; the Pro model makes one image per request and refuses
// sequential_image_generation, stream and tools with 400 InvalidParameter.

/// What a generate_image call asks for.
struct AgentImageRequest: Sendable, Equatable {
    enum AspectRatio: String, CaseIterable, Sendable {
        case square = "1:1", landscape = "4:3", portrait = "3:4", wide = "16:9", tall = "9:16"
        /// The size the request names, about 2K: the size the image comes back at.
        var size: String {
            switch self {
            case .square: "2048x2048"
            case .landscape: "2304x1728"
            case .portrait: "1728x2304"
            case .wide: "2560x1440"
            case .tall: "1440x2560"
            }
        }
    }
    var prompt: String
    var aspectRatio: AspectRatio?
    /// Saved in the chat's folder, as a PNG, instead of in Pictures/Echo as a JPEG.
    var saveToChatFolder = false

    var format: AgentGeneratedImage.Format { saveToChatFolder ? .png : .jpeg }
    /// Without an aspect ratio the model chooses one at 2K.
    var size: String { aspectRatio?.size ?? "2K" }
}

/// An image the service made.
struct AgentGeneratedImage: Sendable, Equatable {
    enum Format: String, Sendable {
        case jpeg, png
        var fileExtension: String { self == .png ? "png" : "jpeg" }
    }
    var data: Data
    var format: Format
    var width: Int
    var height: Int
}

/// Why no image came back.
enum AgentImageFailure: Error, Equatable {
    /// The service refused the key.
    case key(code: String)
    /// The service answered with an error of its own, such as a prompt it will not draw.
    case service(status: Int, code: String, message: String)
    case http(Int)
    case timeout
    case network(String)
    case response
}

/// The Agent Plan's image generation, with the Volcengine Ark key and vision model.
struct ArkImageGenerator: Sendable {
    static let endpoint = URL(string: ArkSettings.baseURL + "/images/generations")!
    /// About three times the longest generation measured.
    static let timeout: TimeInterval = 90
    /// The longest error message the card and the model are given.
    static let messageLimit = 300

    let key: String
    let model: String
    let transport: AgentTransport

    init(key: String, model: String, transport: AgentTransport = ArkImageGenerator.transport()) {
        self.key = key; self.model = model; self.transport = transport
    }

    static func transport(timeout: TimeInterval = ArkImageGenerator.timeout) -> AgentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return AgentTransport(configuration: configuration)
    }

    /// The generator a turn gets: one with the saved Volcengine Ark key and vision model, and none without the key.
    @MainActor static func generator(for settings: SettingsStore) -> ArkImageGenerator? {
        guard let key = settings.savedArkKey else { return nil }
        let model = settings.snapshot.ark.visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return ArkImageGenerator(key: key, model: model.isEmpty ? ArkSettings.defaultVisionModel : model)
    }

    /// One image, no watermark, returned in the response body rather than as a link that expires.
    func body(_ request: AgentImageRequest) -> [String: Any] {
        ["model": model, "prompt": request.prompt.trimmingCharacters(in: .whitespacesAndNewlines), "size": request.size,
         "watermark": false, "response_format": "b64_json", "output_format": request.format.rawValue]
    }

    /// Generates the image. Cancelling the task cancels the request.
    func generate(_ request: AgentImageRequest) async throws(AgentImageFailure) -> AgentGeneratedImage {
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body(request))
        let data: Data, response: URLResponse
        do { (data, response) = try await transport.session.data(for: urlRequest, delegate: transport) }
        catch let error as URLError where error.code == .timedOut { throw .timeout }
        catch { throw .network(error.localizedDescription) }
        return try Self.image(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, format: request.format)
    }

    /// The image in a response, or why there is none.
    static func image(_ data: Data, status: Int, format: AgentGeneratedImage.Format) throws(AgentImageFailure) -> AgentGeneratedImage {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let error = object?["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "", message = String((error["message"] as? String ?? "").prefix(messageLimit))
            if status == 401 || status == 403 || code == "AuthenticationError" || code.hasPrefix("InvalidApiKey") { throw .key(code: code) }
            throw .service(status: status, code: code, message: message)
        }
        guard (200..<300).contains(status) else { throw status == 401 || status == 403 ? .key(code: "HTTP \(status)") : .http(status) }
        guard let item = (object?["data"] as? [[String: Any]])?.first, let text = item["b64_json"] as? String,
              let bytes = Data(base64Encoded: text), let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw .response
        }
        let type = CGImageSourceGetType(source) as String?
        return AgentGeneratedImage(data: bytes, format: type == "public.png" ? .png : type == "public.jpeg" ? .jpeg : format,
                                   width: width, height: height)
    }
}

/// Runs generate_image calls for the conversation.
protocol AgentImageAccess: Sendable {
    func generate(call: GenerationID?, _ request: Result<AgentImageRequest, AgentInvalidArguments>) async throws -> String
}

struct GenerateImageTool: Tool {
    static let toolName = "generate_image"
    let name = GenerateImageTool.toolName
    let description = "Generate one image from a text description with Doubao Seedream. It takes about half a minute. The image is saved as a JPEG in the Echo folder of the person's Pictures folder; with save_to_chat_folder, as a PNG in this chat's folder instead. Returns where it was saved"
    let access: any AgentImageAccess

    @Generable
    struct Input {
        @Guide(description: "What the image shows, described in detail")
        var prompt: String
        @Guide(description: "Width to height; omit to let the model choose", .anyOf(AgentImageRequest.AspectRatio.allCases.map(\.rawValue)))
        var aspect_ratio: String?
        @Guide(description: "true only when the person explicitly asks to save the image in this chat's folder, its project or Finder folder; omit otherwise")
        var save_to_chat_folder: Bool?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        guard let input = try? Input(arguments), !input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.aspect_ratio.map({ AgentImageRequest.AspectRatio(rawValue: $0) != nil }) ?? true else {
            return try await access.generate(call: arguments.id, .failure(.init(result: AgentToolResult.failed(
                #"invalid arguments for generate_image; expected {"prompt": string, "aspect_ratio"?: "1:1" | "4:3" | "3:4" | "16:9" | "9:16", "save_to_chat_folder"?: boolean}. Received: "#
                + arguments.jsonString))))
        }
        return try await access.generate(call: arguments.id, .success(.init(
            prompt: input.prompt, aspectRatio: input.aspect_ratio.flatMap(AgentImageRequest.AspectRatio.init),
            saveToChatFolder: input.save_to_chat_folder ?? false)))
    }
}

// MARK: Files

/// Where generated images go and what they are called. By default flat in ~/Pictures/Echo, named
/// by the time and a few words of the prompt, "2026-10-16 23.45.12 一只橘猫坐在窗台上.jpeg", with
/// " 2", " 3"… added when the name is taken.
enum AgentImageFiles {
    /// `AgentBackupStore.Record.rootKind` of an image saved in Pictures/Echo.
    static let picturesRoot = "pictures"
    /// The largest image an undo still recognizes; the service's largest PNG is about 25 MB.
    static let maxBytes = 64 * 1024 * 1024
    static var picturesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Echo", isDirectory: true)
    }

    /// The file's name without its extension: the time, then the prompt's first phrase, cut short.
    static func baseName(prompt: String, at date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = String(format: "%04d-%02d-%02d %02d.%02d.%02d", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!)
        let words = summary(of: prompt)
        return words.isEmpty ? time : time + " " + words
    }

    /// Width a file name's description may take: a CJK character counts two, anything else one.
    static let summaryWidth = 40

    /// A few words of the prompt for a file name: its first phrase, without characters a file
    /// name cannot have, cut at `summaryWidth`, at a space when it has spaces.
    static func summary(of prompt: String) -> String {
        let phrase = prompt.split(whereSeparator: { "，,。.;；:：!！?？、\n\r".contains($0) }).first.map(String.init) ?? ""
        let cleaned = phrase.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" ? " " : String(scalar)
        }.joined()
        let words = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var result = "", width = 0
        for character in words {
            let wide = character.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
            width += wide ? 2 : 1
            guard width <= summaryWidth else {
                // Cut at the last space, so a word is not split, when there is one.
                if let space = result.lastIndex(of: " ") { result = String(result[..<space]) }
                break
            }
            result.append(character)
        }
        while result.hasPrefix(".") { result.removeFirst() }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// `base.ext`, or `base 2.ext`, `base 3.ext`… for the first name not taken in `directory`.
    static func freeName(in directory: Int32, base: String, ext: String) -> String {
        var number = 1
        while true {
            let name = number == 1 ? "\(base).\(ext)" : "\(base) \(number).\(ext)"
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return name }
            number += 1
        }
    }

    /// Why an image was not saved: what the system said.
    struct SaveFailure: Error, Equatable { let message: String }

    /// Saves `image` as a new file in `root`, a canonical folder, after `record` keeps a record of
    /// it under the name it gets. Never replaces a file. Returns the name.
    static func save(_ image: AgentGeneratedImage, in root: String, base: String,
                     record: (String) throws -> Void) -> Result<String, SaveFailure> {
        func failure(_ code: Int32) -> Result<String, SaveFailure> { .failure(.init(message: String(cString: strerror(code)))) }
        return AgentFileWriter.changes.withLock { _ in
            let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return failure(errno) }
            defer { close(fd) }
            // Another process can take the name between the look and the write; the next name then.
            for _ in 0..<5 {
                let name = freeName(in: fd, base: base, ext: image.format.fileExtension)
                do { try record(name) } catch { return .failure(.init(message: error.localizedDescription)) }
                switch AgentFileWriter.replace(in: fd, name: name, with: image.data, like: nil, skipping: []) {
                case .none: return .success(name)
                case .system(EEXIST): continue
                case .system(let code), .attribute(_, let code): return failure(code)
                }
            }
            return failure(EEXIST)
        }
    }
}

// MARK: Results

/// What generate_image returns: where the image went, or, when there is none, why in `detail` for
/// the model and in `reason` and its fields for the card, which words it in the person's language.
enum AgentImageResult {
    enum Reason: String {
        case key, service, http, timeout, network, response, save
    }

    /// `path` is what the model is told: "~/Pictures/Echo/<name>", or the name alone in the chat's folder.
    static func saved(_ image: AgentGeneratedImage, path: String) -> String {
        AgentToolResult.object(["action": "created", "path": path, "format": image.format.rawValue,
                                "width": image.width, "height": image.height, "bytes": image.data.count])
    }

    static func failed(_ failure: AgentImageFailure) -> String {
        let reason: Reason, detail: String, fields: [String: Any]
        switch failure {
        case .key(let code):
            (reason, fields) = (.key, ["code": code])
            detail = "The image service refused the API key (\(code)); no image was generated. The person can check the Volcengine Ark key on the model page of Settings"
        case .service(let status, let code, let message):
            (reason, fields) = (.service, ["http_status": status, "code": code, "message": message])
            detail = "The image service returned an error (HTTP \(status), \(code): \(message)); no image was generated"
        case .http(let status):
            (reason, fields) = (.http, ["http_status": status])
            detail = "The image service returned HTTP \(status); no image was generated"
        case .timeout:
            (reason, fields) = (.timeout, [:])
            detail = "The image service did not finish within \(Int(ArkImageGenerator.timeout)) seconds; no image was generated"
        case .network(let description):
            (reason, fields) = (.network, ["message": description])
            detail = "The image service could not be reached (\(description)); no image was generated"
        case .response:
            (reason, fields) = (.response, [:])
            detail = "The image service returned a response that could not be read; no image was generated"
        }
        return AgentToolResult.object(fields.merging(["status": "failed", "reason": reason.rawValue, "detail": detail]) { $1 })
    }

    /// The image was made but could not be saved.
    static func notSaved(_ message: String) -> String {
        AgentToolResult.object(["status": "failed", "reason": Reason.save.rawValue, "message": message,
                                "detail": "The image was generated but could not be saved (\(message)); there is no image file"])
    }
}
