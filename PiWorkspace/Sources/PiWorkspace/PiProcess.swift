import Foundation
import Darwin

struct ChatMessage: Decodable, Identifiable {
    enum Role: String, Decodable { case user, assistant }
    enum IncompleteReply: String, Decodable { case interrupted, truncated }
    let id: String
    let role: Role
    let text: String
    var queuedID: UUID? = nil
    var canFork: Bool? = nil
    var incompleteReply: IncompleteReply? = nil
    var submissionID: UUID? = nil
    var attachments: [SentAttachment]? = nil
}

enum PiEvent: Decodable {
    case credential(id: String, read: Bool)
    case modelCatalog([Provider: [String: String]])
    case ready([ChatMessage], supportsImages: Bool = false)
    case history([ChatMessage])
    case sentAttachment(requestID: UUID, ComposerAttachment.Payload?)
    case partial(String)
    case activity(String)
    case toolApproval(ToolApproval)
    case agentQuestion(AgentQuestionRequest)
    case agentQuestionEnded(AgentQuestionEnd)
    case agentQuestionRejected(AgentQuestionScope)
    case inputMode(turnID: UUID, PiInputMode)
    case queueRejected(turnID: UUID, queuedID: UUID, error: String? = nil)
    case compactionSkipped(turnID: UUID, queuedID: UUID)
    case forked(threadID: UUID, error: String?)
    case finished(turnID: UUID, [ChatMessage], error: String?)
    case commitMessage(String)
    case fatal(String)

    private enum Field: String, CodingKey {
        case type, requestID, operation, messages, image, file, text, error, turnID, queuedID, mode, threadID, scope, models
    }
    private enum Capability: String, CodingKey { case supportsImages }
    private enum Kind: String, Decodable {
        case credential, modelCatalog, ready, history, sentImage, sentFile, partial, activity, toolApproval, finished, fatal
        case agentQuestion, agentQuestionEnded, agentQuestionRejected, commitMessage
        case inputMode, queueRejected, compactionSkipped, forked
    }
    private enum Operation: String, Decodable { case exists, read }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        let kind = try fields.decode(Kind.self, forKey: .type)
        switch kind {
        case .credential:
            self = .credential(id: try fields.decode(String.self, forKey: .requestID),
                               read: try fields.decode(Operation.self, forKey: .operation) == .read)
        case .modelCatalog:
            let models = try fields.decode([String: [String: String]].self, forKey: .models)
            self = .modelCatalog(Dictionary(uniqueKeysWithValues: Provider.allCases.compactMap { provider in
                models[provider.rawValue].map { (provider, $0) }
            }))
        case .ready:
            let capabilities = try decoder.container(keyedBy: Capability.self)
            self = .ready(try fields.decode([ChatMessage].self, forKey: .messages),
                          supportsImages: try capabilities.decodeIfPresent(Bool.self, forKey: .supportsImages) ?? false)
        case .history: self = .history(try fields.decode([ChatMessage].self, forKey: .messages))
        case .sentImage, .sentFile:
            self = .sentAttachment(requestID: try fields.decode(UUID.self, forKey: .requestID),
                                   try? fields.decode(ComposerAttachment.Payload.self, forKey: kind == .sentImage ? .image : .file))
        case .partial: self = .partial(try fields.decode(String.self, forKey: .text))
        case .activity: self = .activity(try fields.decode(String.self, forKey: .text))
        case .toolApproval: self = .toolApproval(try ToolApproval(from: decoder))
        case .agentQuestion: self = .agentQuestion(try AgentQuestionRequest(from: decoder))
        case .agentQuestionEnded: self = .agentQuestionEnded(try AgentQuestionEnd(from: decoder))
        case .agentQuestionRejected:
            self = .agentQuestionRejected(try fields.decode(AgentQuestionScope.self, forKey: .scope))
        case .inputMode:
            self = .inputMode(turnID: try fields.decode(UUID.self, forKey: .turnID),
                              try fields.decode(PiInputMode.self, forKey: .mode))
        case .queueRejected, .compactionSkipped:
            let turnID = try fields.decode(UUID.self, forKey: .turnID)
            let queuedID = try fields.decode(UUID.self, forKey: .queuedID)
            self = kind == .queueRejected
                ? .queueRejected(turnID: turnID, queuedID: queuedID,
                                 error: try fields.decodeIfPresent(String.self, forKey: .error))
                : .compactionSkipped(turnID: turnID, queuedID: queuedID)
        case .forked:
            self = .forked(threadID: try fields.decode(UUID.self, forKey: .threadID),
                           error: try fields.decodeIfPresent(String.self, forKey: .error))
        case .finished:
            self = .finished(turnID: try fields.decode(UUID.self, forKey: .turnID),
                             try fields.decode([ChatMessage].self, forKey: .messages),
                             error: try fields.decodeIfPresent(String.self, forKey: .error))
        case .commitMessage: self = .commitMessage(try fields.decode(String.self, forKey: .text))
        case .fatal: self = .fatal(try fields.decode(String.self, forKey: .error))
        }
    }
}

struct OpenConversation: Encodable, Equatable {
    struct SideChatSource: Encodable, Equatable {
        let threadID: UUID
        let sessionDir: String
        let cutoff: String?
    }

    var type = "open"
    let cwd: String
    let sessionDir: String
    let threadID: String
    let config: ModelSettings
    let toolPermission: ToolPermission
    var forkMessageID: String?
    var requireHistory = false
    var sideChatSource: SideChatSource?
}

struct ForkConversation: Encodable {
    let type = "fork"
    let threadID: UUID
    let messageID: String
}

struct ReadSentAttachment: Encodable {
    enum Kind: String, Encodable { case readSentImage, readSentFile }
    let type: Kind
    let requestID: UUID
    let messageID: String
    let attachmentID: UUID
}

struct SendPrompt: Encodable {
    let type = "prompt"
    let turnID: UUID
    let text: String
    var queuedID: UUID?
    var skipCompaction: Bool?
    var submissionID: UUID?
    var attachments: [ComposerAttachment]?
    var sideChatContext: String?
}
struct SendQueuedInput: Encodable {
    enum Kind: String, Encodable { case steer, skipCompaction }
    let type: Kind
    let turnID: UUID
    let queuedID: UUID
    var text: String?
    var attachments: [ComposerAttachment]?
}
struct CancelPrompt: Encodable { let type = "cancel"; let turnID: UUID }
struct GenerateCommitMessage: Encodable {
    let type = "generateCommitMessage"
    let config: ModelSettings
    let patch: String
    let style: CommitWritingSettings.Style
    let instructions: String?
    let relatedSubjects: String
}

struct CredentialResult: Encodable {
    var type = "credentialResult"
    let requestID: String
    var key: String?
    var exists: Bool?
    var error: Bool?
}

@MainActor
protocol PiConnection: AnyObject {
    var onEvent: ((PiEvent) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func send(_ command: any Encodable) throws
    func close()
}

@MainActor
final class PiProcess: PiConnection {
    private let child = Process()
    private let input = Pipe()
    private let output = Pipe()
    var onEvent: ((PiEvent) -> Void)?
    var onClose: (() -> Void)?

    convenience init(config: URL, cwd: String) throws {
        guard let resources = Bundle.main.resourceURL else { throw WorkspaceError("App resources are missing.") }
        let sidecar = resources.appendingPathComponent("Sidecar", isDirectory: true)
        try self.init(
            config: config, cwd: cwd,
            executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/node"),
            arguments: [sidecar.appendingPathComponent("worker.mjs").path]
        )
    }

    init(config: URL, cwd: String, executable: URL, arguments: [String]) throws {
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        child.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "PI_CODING_AGENT_DIR": config.path,
            "PI_OFFLINE": "1",
            "PI_TELEMETRY": "0"
        ]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()

        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let decoder = JSONDecoder()
            while true {
                let size = bytes.withUnsafeMutableBytes {
                    Darwin.read(reader.fileDescriptor, $0.baseAddress, $0.count)
                }
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { break }
                buffer.append(contentsOf: bytes.prefix(size))
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end)
                    if let event = try? decoder.decode(PiEvent.self, from: line) {
                        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
                    }
                    buffer.removeSubrange(...end)
                }
            }
            DispatchQueue.main.async { [weak self] in self?.onClose?() }
        }
    }

    func send(_ command: any Encodable) throws {
        var data = try JSONEncoder().encode(command)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func close() {
        onEvent = nil
        onClose = nil
        try? input.fileHandleForWriting.close()
        let process = child
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
    }
}
