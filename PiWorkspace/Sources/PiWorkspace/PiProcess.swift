import Foundation
import Darwin

struct ChatMessage: Decodable, Identifiable {
    enum Role: String, Decodable { case user, assistant }
    let id: String
    let role: Role
    let text: String
}

enum PiEvent: Decodable {
    case credential(id: String, read: Bool)
    case ready([ChatMessage])
    case history([ChatMessage])
    case partial(String)
    case activity(String)
    case finished([ChatMessage], error: String?)
    case fatal(String)

    private enum Field: String, CodingKey { case type, requestID, operation, messages, text, error }
    private enum Kind: String, Decodable { case credential, ready, history, partial, activity, finished, fatal }
    private enum Operation: String, Decodable { case exists, read }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        switch try fields.decode(Kind.self, forKey: .type) {
        case .credential:
            self = .credential(id: try fields.decode(String.self, forKey: .requestID),
                               read: try fields.decode(Operation.self, forKey: .operation) == .read)
        case .ready: self = .ready(try fields.decode([ChatMessage].self, forKey: .messages))
        case .history: self = .history(try fields.decode([ChatMessage].self, forKey: .messages))
        case .partial: self = .partial(try fields.decode(String.self, forKey: .text))
        case .activity: self = .activity(try fields.decode(String.self, forKey: .text))
        case .finished:
            self = .finished(try fields.decode([ChatMessage].self, forKey: .messages),
                             error: try fields.decodeIfPresent(String.self, forKey: .error))
        case .fatal: self = .fatal(try fields.decode(String.self, forKey: .error))
        }
    }
}

struct OpenConversation: Encodable {
    var type = "open"
    let cwd: String
    let sessionDir: String
    let threadID: String
    let config: ModelSettings
    let allowEdits: Bool
}

struct SendPrompt: Encodable { var type = "prompt"; let text: String }
struct CancelPrompt: Encodable { var type = "cancel" }
struct CredentialResult: Encodable {
    var type = "credentialResult"
    let requestID: String
    var key: String?
    var exists: Bool?
    var error: Bool?
}

@MainActor
final class PiProcess {
    private let child = Process()
    private let input = Pipe()
    private let output = Pipe()
    var onEvent: ((PiEvent) -> Void)?
    var onClose: (() -> Void)?

    init(config: URL, cwd: String) throws {
        guard let resources = Bundle.main.resourceURL else { throw WorkspaceError("App resources are missing.") }
        let sidecar = resources.appendingPathComponent("Sidecar", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/node")
        child.arguments = [sidecar.appendingPathComponent("worker.mjs").path]
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

    func send(_ command: some Encodable) throws {
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
