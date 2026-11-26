import Foundation
import Darwin

enum Provider: String, Codable, CaseIterable, Identifiable {
    case openai, anthropic, local

    var id: Self { self }
    var label: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .local: "Local OpenAI-compatible"
        }
    }
    var defaultModel: String {
        switch self {
        case .openai: "gpt-5-mini"
        case .anthropic: "claude-sonnet-4-6"
        case .local: "smollm2:135m"
        }
    }
}

struct ModelSettings: Codable, Equatable {
    var provider: Provider = .openai
    var model = Provider.openai.defaultModel
    var endpoint = "http://127.0.0.1:11434/v1"
    var contextWindow = 8192
    var localTools: Bool?

    var supportsTools: Bool { provider != .local || localTools == true }

    var account: String {
        provider == .local ? "local:" + endpoint : provider.rawValue
    }

    func validated() throws -> Self {
        var settings = self
        settings.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settings.model.isEmpty else { throw WorkspaceError("Enter a model ID.") }
        guard provider == .local else { return settings }

        guard var url = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw WorkspaceError("Use a loopback URL such as http://127.0.0.1:11434/v1.")
        }
        guard (8192...2_000_000).contains(contextWindow) else {
            throw WorkspaceError("Enter a context window between 8,192 and 2,000,000 tokens.")
        }
        url.scheme = scheme
        url.host = host
        if url.path.hasSuffix("/") { url.path.removeLast() }
        guard let endpoint = url.string else { throw WorkspaceError("The local URL is invalid.") }
        settings.endpoint = endpoint
        return settings
    }
}

enum ThreadLocation: Codable, Equatable {
    case project
    case newWorktree(branch: String, base: String)
    case worktree(path: String, base: String?)

    var label: String {
        switch self {
        case .project: "Local"
        case .newWorktree: "New worktree"
        case .worktree: "Worktree"
        }
    }

    func directory(in project: Project) -> String {
        switch self {
        case .project, .newWorktree: project.path
        case let .worktree(path, _): path
        }
    }

    var needsWorktree: Bool {
        if case .newWorktree = self { return true }
        return false
    }
}

enum ThreadLocationChoice {
    case project
    case existing(path: String)
    case create(branch: String, base: String)
}

enum ThreadShelf: String, Codable {
    case active, pinned, settled
}

struct WorktreeLaunch: Codable {
    enum Stage: String, Codable {
        case createCheckout, openThread, sendPrompt

        var label: String {
            switch self {
            case .createCheckout: "Create worktree"
            case .openThread: "Open thread"
            case .sendPrompt: "Send first message"
            }
        }
    }

    let prompt: String
    var stage: Stage = .createCheckout
    var failure: String?

    var awaitingHistory: Bool { stage == .sendPrompt && failure == nil }
}

struct Conversation: Codable, Identifiable {
    let id: UUID
    var title: String
    var archived = false
    var lastActiveAt: Date?
    var location: ThreadLocation?
    var shelf: ThreadShelf?
    var isDraft: Bool?
    var worktreeLaunch: WorktreeLaunch?

    var workingLocation: ThreadLocation { location ?? .project }
    var threadShelf: ThreadShelf { shelf ?? .active }

    mutating func recordPrompt(_ text: String) {
        isDraft = nil
        lastActiveAt = Date()
        if threadShelf == .settled { shelf = .active }
        if ["New thread", "New conversation"].contains(title) {
            title = String((text.split(whereSeparator: \.isNewline).first ?? Substring(text)).prefix(54))
        }
    }
}

struct ProjectPickerRequest: Identifiable {
    let id = UUID()
    let relinking: UUID?
    let startThread: Bool
    let initialPath: String
}

struct Project: Codable, Identifiable {
    let id: UUID
    var path: String
    var title: String
    var allowEdits = false
    var detached: Bool?
    var conversations: [Conversation] = []
    var selectedConversation: UUID?
    var createdAt: Date?

    var lastActivity: Date {
        max(createdAt ?? .distantPast, conversations.compactMap(\.lastActiveAt).max() ?? .distantPast)
    }

    mutating func selectDraft(occupied: Set<UUID>) {
        if let empty = conversations.first(where: {
            $0.isDraft == true && !$0.archived && !occupied.contains($0.id)
        }) {
            selectedConversation = empty.id
            return
        }
        let thread = Conversation(id: UUID(), title: "New thread", isDraft: true)
        conversations.insert(thread, at: 0)
        selectedConversation = thread.id
    }
}

struct Workspace: Codable {
    var projects: [Project] = []
    var selectedProject: UUID?
    var model = ModelSettings()
}

struct WorkspaceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class WorkspaceStore {
    let root: URL
    private let lock: Int32

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent(".lock").path
        let lock = Darwin.open(file, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw WorkspaceError("The workspace directory is not writable.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock)
            throw WorkspaceError("This workspace is open in another Pi Workspace process.")
        }
        self.lock = lock
    }

    deinit { Darwin.close(lock) }

    private var index: URL { root.appendingPathComponent("workspace.json") }
    var config: URL { root.appendingPathComponent("pi-config", isDirectory: true) }

    func load() throws -> Workspace {
        do {
            return try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Workspace()
        }
    }

    func save(_ workspace: Workspace) throws {
        try JSONEncoder().encode(workspace).write(to: index, options: .atomic)
    }

    func history(project: UUID, conversation: UUID) -> URL {
        root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(project.uuidString, isDirectory: true)
            .appendingPathComponent(conversation.uuidString, isDirectory: true)
    }

    func worktree(project: UUID, conversation: UUID) throws -> URL {
        let parent = root.appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(project.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return parent.appendingPathComponent(conversation.uuidString, isDirectory: true)
    }
}
