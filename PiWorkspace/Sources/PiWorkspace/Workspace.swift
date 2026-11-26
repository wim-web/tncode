import Foundation
import CryptoKit
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
    enum ThinkingLevel: String, Codable, CaseIterable, Identifiable {
        case off, minimal, low, medium, high, xhigh, max

        var id: Self { self }
        var label: String {
            switch self {
            case .xhigh: "Extra high"
            case .max: "Maximum"
            default: rawValue.capitalized
            }
        }
    }

    var provider: Provider = .openai
    var model = Provider.openai.defaultModel
    var endpoint = "http://127.0.0.1:11434/v1"
    var contextWindow = 8192
    var localTools: Bool?
    var thinkingLevel: ThinkingLevel?

    var supportsTools: Bool { provider != .local || localTools == true }

    var account: String {
        provider == .local ? "local:" + endpoint : provider.rawValue
    }

    func validated() throws -> Self {
        var settings = self
        settings.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.thinkingLevel == .off { settings.thinkingLevel = nil }
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
        while url.percentEncodedPath.hasSuffix("/") { url.percentEncodedPath.removeLast() }
        guard let endpoint = url.string else { throw WorkspaceError("The local URL is invalid.") }
        settings.endpoint = endpoint
        settings.thinkingLevel = nil
        return settings
    }
}

enum ModelSettingsScope: Hashable {
    case workspace
    case project(UUID)
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
    enum Interruption: String, Codable {
        case cancel, workLocally
    }

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
    var id: UUID? = UUID()
    var originalDraft: String?
    var stage: Stage = .createCheckout
    var failure: String?
    var checkout: GitWorkspace.PendingCheckout?
    var interruption: Interruption?

    var awaitingHistory: Bool { stage == .sendPrompt && failure == nil }
    var canInterrupt: Bool { interruption == nil && !awaitingHistory }
}

struct Conversation: Codable, Identifiable {
    struct ComposerSubmission: Codable {
        let previousUserMessageID: String?
    }

    let id: UUID
    var title: String
    var archived = false
    var lastActiveAt: Date?
    var location: ThreadLocation?
    var shelf: ThreadShelf?
    var isDraft: Bool?
    var worktreeLaunch: WorktreeLaunch?
    var composerText: String?
    var composerSubmission: ComposerSubmission?
    var queuedMessages: [QueuedMessage]?

    var workingLocation: ThreadLocation { location ?? .project }
    var threadShelf: ThreadShelf { shelf ?? .active }
    var canDiscardDraft: Bool {
        isDraft == true && !archived && worktreeLaunch == nil && composerSubmission == nil
    }

    mutating func recordPrompt(_ text: String) {
        isDraft = false
        composerText = nil
        composerSubmission = nil
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
    let basePath: String?
}

enum ProjectSource {
    case localFolder(URL)
    case newProject(name: String, parent: URL)
}

enum ProjectFolder {
    static func resolve(_ input: String, relativeTo basePath: String?) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.utf8.contains(0) else {
            throw WorkspaceError("Enter a folder path.")
        }
        let path = (trimmed as NSString).expandingTildeInPath
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        guard let basePath else {
            throw WorkspaceError("Enter an absolute path or open a project to use a relative path.")
        }
        let base = URL(fileURLWithPath: basePath, isDirectory: true)
        return URL(fileURLWithPath: path, isDirectory: true, relativeTo: base).absoluteURL
    }

    static func existing(at url: URL) throws -> URL {
        guard url.isFileURL else { throw WorkspaceError("Choose a local folder.") }
        let folder = url.resolvingSymlinksInPath().standardizedFileURL
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw WorkspaceError("Choose an existing folder.")
        }
        return folder
    }
}

struct Project: Codable, Identifiable {
    enum Kind: String, Codable {
        case scratch
    }

    let id: UUID
    var path: String
    var title: String
    var allowEdits = false
    var supervisedTools: Bool?
    var detached: Bool?
    var pinned: Bool?
    var conversations: [Conversation] = []
    var selectedConversation: UUID?
    var createdAt: Date?
    var modelOverride: ModelSettings?
    var kind: Kind?

    var isScratch: Bool { kind == .scratch }

    var lastActivity: Date {
        max(createdAt ?? .distantPast, conversations.compactMap(\.lastActiveAt).max() ?? .distantPast)
    }

    mutating func selectDraft() {
        if let empty = conversations.first(where: {
            $0.canDiscardDraft && $0.composerText == nil
        }) {
            selectedConversation = empty.id
            return
        }
        let thread = Conversation(id: UUID(), title: "New thread", isDraft: true)
        conversations.insert(thread, at: 0)
        selectedConversation = thread.id
    }

    var toolPermission: ToolPermission {
        get {
            if supervisedTools == true { return .supervised }
            return allowEdits ? .shellAndEdits : .readFiles
        }
        set {
            allowEdits = newValue == .shellAndEdits
            supervisedTools = newValue == .supervised ? true : nil
        }
    }
}

struct Workspace: Codable {
    var activeProject: Project? {
        projects.first { $0.id == selectedProject && $0.detached != true }
    }
    var effectiveModel: ModelSettings { activeProject?.modelOverride ?? model }

    var projects: [Project] = []
    var selectedProject: UUID?
    var model = ModelSettings()
    var welcomeCompleted: Bool?
}

struct WorkspaceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum WorkspaceStoreError: LocalizedError {
    case inUse
    case access(URL, Error)
    case invalidIndex(missing: Bool, canRestore: Bool)

    var canRestore: Bool {
        if case .invalidIndex(_, let canRestore) = self { return canRestore }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .inUse:
            "This workspace is open in another Pi Workspace process."
        case let .access(file, error):
            "Could not access \(file.lastPathComponent). \(error.localizedDescription)"
        case let .invalidIndex(missing, canRestore):
            (missing ? "The workspace index is missing." : "The workspace index is damaged.")
                + (canRestore ? "" : " A readable, valid previous index is unavailable.")
        }
    }
}

final class WorkspaceStore {
    let root: URL
    private let lock: Int32

    init(root: URL) throws {
        self.root = root
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw WorkspaceStoreError.access(root, error)
        }
        let file = root.appendingPathComponent(".lock")
        let lock = Darwin.open(file.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Self.accessError(file, errno) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(lock)
            if code == EWOULDBLOCK { throw WorkspaceStoreError.inUse }
            throw Self.accessError(file, code)
        }
        self.lock = lock
    }

    deinit { Darwin.close(lock) }

    private var index: URL { root.appendingPathComponent("workspace.json") }
    private var previousIndex: URL { root.appendingPathComponent("workspace.previous.json") }
    var config: URL { root.appendingPathComponent("pi-config", isDirectory: true) }

    func load(restoringPrevious: Bool = false) throws -> Workspace {
        let current = try read(index)
        if let current, let workspace = try? JSONDecoder().decode(Workspace.self, from: current) {
            return workspace
        }

        let previous: Data?
        if current == nil {
            previous = try read(previousIndex)
            if previous == nil && !restoringPrevious { return Workspace() }
        } else {
            previous = try? read(previousIndex)
        }
        let workspace = previous.flatMap { try? JSONDecoder().decode(Workspace.self, from: $0) }
        guard restoringPrevious, let previous, let workspace else {
            throw WorkspaceStoreError.invalidIndex(missing: current == nil, canRestore: workspace != nil)
        }

        if let current { try ensureCorruptIndexArchived(current) }
        try write(previous, to: index)
        return workspace
    }

    func save(_ workspace: Workspace) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let updated = try encoder.encode(workspace)
        if let current = try read(index) {
            guard let saved = try? JSONDecoder().decode(Workspace.self, from: current) else {
                throw WorkspaceError("The workspace index is damaged. Reopen the workspace to recover it.")
            }
            if try encoder.encode(saved) == updated { return }
            try write(current, to: previousIndex)
        } else if try read(previousIndex) != nil {
            throw WorkspaceError("The workspace index is missing. Reopen the workspace to recover it.")
        }
        try write(updated, to: index)
    }

    private func ensureCorruptIndexArchived(_ data: Data) throws {
        // Reuse the archive if a prior recovery stopped before replacing the index.
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let archive = root.appendingPathComponent("workspace.corrupt-\(digest).json")
        if let saved = try read(archive) {
            guard saved == data else {
                throw WorkspaceStoreError.access(archive, WorkspaceError("The archive already contains different data."))
            }
        } else {
            try write(data, to: archive)
        }
    }

    private func read(_ file: URL) throws -> Data? {
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw Self.accessError(file, code)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.accessError(file, errno) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw WorkspaceStoreError.access(file, WorkspaceError("Expected a regular file."))
        }
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw WorkspaceStoreError.access(file, error)
        }
    }

    private func write(_ data: Data, to file: URL) throws {
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            throw WorkspaceStoreError.access(file, error)
        }
    }

    private static func accessError(_ file: URL, _ code: Int32) -> WorkspaceStoreError {
        .access(file, POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
    }

    func history(project: UUID, conversation: UUID) -> URL {
        Self.historyComponents(project: project, conversation: conversation).reduce(root) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
    }

    static func historyComponents(project: UUID, conversation: UUID) -> [String] {
        ["sessions", project.uuidString, conversation.uuidString]
    }

    func makeScratchProject(for thread: Conversation) throws -> Project {
        let id = UUID()
        let parent = root.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("scratch", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: parent, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        guard parent.resolvingSymlinksInPath().path == parent.path else {
            throw WorkspaceError("The scratch folder must be inside this workspace.")
        }
        let folder = parent.appendingPathComponent(id.uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        return Project(id: id, path: folder.path, title: "No project", conversations: [thread],
                       selectedConversation: thread.id, createdAt: Date(), kind: .scratch)
    }

    func discardEmptyScratchFolder(_ project: Project) {
        let parent = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("scratch", isDirectory: true)
        guard project.isScratch, project.path == parent.appendingPathComponent(project.id.uuidString).path else { return }
        let directory = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return }
        defer { Darwin.close(directory) }
        _ = unlinkat(directory, project.id.uuidString, AT_REMOVEDIR)
    }

    func worktree(project: UUID, conversation: UUID) throws -> URL {
        let workspace = root.resolvingSymlinksInPath().standardizedFileURL
        let parent = workspace.appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(project.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard parent.resolvingSymlinksInPath().path == parent.path else {
            throw WorkspaceError("The worktree folder must be inside this workspace.")
        }
        return parent.appendingPathComponent(conversation.uuidString, isDirectory: true)
    }
}
