import Darwin
import Foundation

struct GitRepositoryState: Sendable {
    let branch: String?
    let branches: [String]
    let files: [GitFileChange]
}

struct GitCheckout: Sendable {
    let path: String
    let branch: String?
    let head: String?
    let lockReason: String?
}

struct GitFileChange: Identifiable, Hashable, Sendable {
    let path: String
    let indexStatus: Character
    let worktreeStatus: Character
    let originalPath: String?

    init(path: String, indexStatus: Character, worktreeStatus: Character, originalPath: String? = nil) {
        self.path = path
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.originalPath = originalPath
    }

    var id: String {
        // A staged deletion and an untracked replacement can have the same path.
        isUntracked ? path + "\0?" : path
    }

    fileprivate var isUntracked: Bool {
        indexStatus == "?" && worktreeStatus == "?"
    }

    var isStaged: Bool { ![" ", "?", "!"].contains(indexStatus) }

    fileprivate var commitPaths: [String] {
        if let originalPath, indexStatus == "R" || worktreeStatus == "R" {
            return [path, originalPath]
        }
        return [path]
    }
}

struct GitWorkspace: Sendable {
    private let path: String
    private static let patchLimit = 256 * 1024

    init(path: String) {
        self.path = path
    }

    static func createRepository(named input: String, in parent: URL) async throws -> URL {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw WorkspaceError.invalidProjectName
        }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        let staging = parent.appendingPathComponent(".pi-workspace-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var moved = false
        defer {
            if !moved { try? FileManager.default.removeItem(at: staging) }
        }
        _ = try await GitWorkspace(path: staging.path).run(["init", "--quiet", "--template="])
        try staging.withUnsafeFileSystemRepresentation { source in
            try folder.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { throw WorkspaceError.invalidProjectName }
                guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
                    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                    if code == .EEXIST || code == .ENOTEMPTY { throw WorkspaceError.projectFolderExists }
                    throw POSIXError(code)
                }
            }
        }
        moved = true
        return folder
    }

    func fetchRemotes() async throws -> [(name: String, url: String)] {
        let names = try await run(["remote"], outputLimit: 64 * 1024)
        guard !names.output.truncated else { throw WorkspaceError.invalidOutput(command: "remote") }
        let listing = try Self.decode(names.output.bytes, command: "remote")
        var remotes: [(name: String, url: String)] = []
        for name in listing.split(separator: "\n").map(String.init) {
            let result = try await run(["remote", "get-url", "--", name], outputLimit: 64 * 1024)
            guard !result.output.truncated, result.output.bytes.last == 10 else {
                throw WorkspaceError.invalidOutput(command: "remote get-url")
            }
            let url = try Self.decode(result.output.bytes.dropLast(), command: "remote get-url")
            if !url.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                remotes.append((name, url))
            }
        }
        return remotes
    }

    func state() async throws -> GitRepositoryState {
        let files = try await changes()
        let branch = try await currentBranch()
        let refs = try await run(["for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/"])
        let branches = try Self.decode(refs.output.bytes, command: "for-each-ref")
            .split(separator: "\n")
            .map(String.init)

        return GitRepositoryState(branch: branch, branches: branches, files: files)
    }

    func currentBranch() async throws -> String? {
        let head = try await run(["symbolic-ref", "--quiet", "HEAD"], acceptedStatuses: [0, 1])
        let headRef = try Self.decode(head.output.bytes, command: "symbolic-ref")
        let localBranchPrefix = "refs/heads/"
        return headRef.hasPrefix(localBranchPrefix)
            ? String(decoding: headRef.utf8.dropFirst(localBranchPrefix.utf8.count).dropLast(), as: UTF8.self)
            : nil
    }

    func worktrees() async throws -> [GitCheckout] {
        let listing = try await run(["worktree", "list", "--porcelain", "-z"])
        let pathPrefix = "worktree ".utf8
        let branchPrefix = "branch refs/heads/".utf8
        var checkouts: [GitCheckout] = []
        var checkoutPath: String?
        var checkoutBranch: String?
        var head: String?
        var lockReason: String?

        for field in listing.output.bytes.split(separator: 0, omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let checkoutPath {
                    let path = URL(fileURLWithPath: checkoutPath).resolvingSymlinksInPath().standardizedFileURL.path
                    checkouts.append(GitCheckout(path: path, branch: checkoutBranch, head: head, lockReason: lockReason))
                }
                checkoutPath = nil
                checkoutBranch = nil
                head = nil
                lockReason = nil
            } else if field.starts(with: pathPrefix) {
                checkoutPath = try Self.decode(field.dropFirst(pathPrefix.count), command: "worktree list")
            } else if field.starts(with: branchPrefix) {
                checkoutBranch = try Self.decode(field.dropFirst(branchPrefix.count), command: "worktree list")
            } else if field.starts(with: "HEAD ".utf8) {
                head = try Self.decode(field.dropFirst(5), command: "worktree list")
            } else if field.starts(with: "locked".utf8) {
                lockReason = try Self.decode(field.dropFirst(7), command: "worktree list")
            }
        }

        return checkouts
    }

    func patch(for file: GitFileChange?, staged: Bool) async throws -> String {
        let root = try await repositoryRoot()
        var arguments = ["diff", "--patch", "--no-color", "--no-ext-diff", "--no-textconv"]
        let result: WorkspaceCommand.Capture

        if let file, file.isUntracked && !staged {
            arguments += ["--no-index", "--", "/dev/null", "./" + file.path]
            result = try await run(arguments, in: root, outputLimit: Self.patchLimit, acceptedStatuses: [0, 1])
            if result.status == 1 && result.output.bytes.isEmpty {
                throw WorkspaceError.commandFailed(command: "diff", status: result.status, message: result.errorMessage)
            }
        } else {
            arguments += ["--no-relative", "--find-renames"]
            if staged {
                arguments.append("--cached")
            }
            arguments.append("--")
            if let file {
                let status = staged ? file.indexStatus : file.worktreeStatus
                if let originalPath = file.originalPath, status == "R" || status == "C" {
                    arguments.append(originalPath)
                }
                arguments.append(file.path)
            }
            result = try await run(arguments, in: root, outputLimit: Self.patchLimit)
        }

        let output = String(decoding: result.output.bytes, as: UTF8.self)
        return result.output.truncated ? output + "\n[Diff truncated after 256 KiB]\n" : output
    }

    func createWorktree(at path: String, branch: String, base: String, for thread: UUID) async throws -> String {
        let root = try await repositoryRoot()
        let absolute = path.hasPrefix("/") ? path : root + "/" + path
        let target = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().standardizedFileURL.path
        let prepared = try await worktrees().first { $0.path == target }
        let checked = try await run(["check-ref-format", "--branch", branch], in: root)
        guard checked.output.bytes == Data((branch + "\n").utf8) else { throw WorkspaceError.invalidBranch }
        let existingRef = try await run(["show-ref", "--verify", "--quiet", "refs/heads/" + branch],
                                        in: root, acceptedStatuses: [0, 1])
        guard existingRef.status == 1 || prepared?.branch == branch else { throw WorkspaceError.branchExists(branch) }
        let commit = try await revParse(["--verify", "--end-of-options", base + "^{commit}"], in: root)
        let reason = "Pi Workspace preparing " + thread.uuidString
        if let prepared {
            guard prepared.head == commit, prepared.branch == nil || prepared.branch == branch,
                  prepared.lockReason == nil || prepared.lockReason == reason else {
                throw WorkspaceError.worktreeChanged
            }
        } else {
            _ = try await run(["worktree", "add", "--detach", "--lock", "--reason", reason, "--", target, commit], in: root)
        }
        let admin = try await revParse(["--absolute-git-dir"], in: target)
        let receipt = URL(fileURLWithPath: admin).appendingPathComponent("pi-workspace-owner")
        let owner = Data((thread.uuidString + "\n" + commit + "\n").utf8)
        let ownsLock = prepared == nil || prepared?.lockReason == reason
        if ownsLock {
            try owner.write(to: receipt, options: .atomic)
        } else {
            guard (try? Data(contentsOf: receipt)) == owner else { throw WorkspaceError.worktreeChanged }
        }
        if prepared?.branch != branch {
            _ = try await run(["switch", "--no-guess", "-c", branch], in: target)
        }
        if ownsLock { _ = try await run(["worktree", "unlock", "--", target], in: root) }
        return try await repositoryRoot(in: target)
    }

    func switchBranch(_ branch: String) async throws {
        _ = try await run(["switch", "--no-guess", "--", branch])
    }

    func stage(_ file: GitFileChange) async throws {
        let root = try await repositoryRoot()
        var paths = [file.path]
        if file.worktreeStatus == "R", let originalPath = file.originalPath {
            paths.append(originalPath)
        }
        let mode = file.worktreeStatus == "D" ? "--update" : "--all"
        _ = try await run(["add", mode, "--"] + paths, in: root)
    }

    func unstage(_ file: GitFileChange) async throws {
        let root = try await repositoryRoot()
        var paths = [file.path]
        if file.indexStatus == "R", let originalPath = file.originalPath {
            paths.append(originalPath)
        }
        _ = try await run(["reset", "--quiet", "--"] + paths, in: root)
    }

    func commit(message: String, paths: Set<String>) async throws {
        guard !paths.isEmpty else { throw WorkspaceError.emptySelection }
        let root = try await repositoryRoot()
        let indexPath = try await revParse(["--path-format=absolute", "--git-path", "index"], in: root)
        let index = URL(fileURLWithPath: indexPath)
        let lockPath = indexPath + ".lock"
        let lock = open(lockPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        if lock == -1 {
            let code = errno
            if code == EEXIST { throw WorkspaceError.indexLocked }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { unlink(lockPath) }
        close(lock)

        let currentChanges = try await changes(in: root)
        let selected = currentChanges.filter { paths.contains($0.path) }
        guard Set(selected.map(\.path)) == paths else { throw WorkspaceError.staleSelection }
        let commitPaths = Set(selected.flatMap(\.commitPaths))
        let excluded = currentChanges.filter { !paths.contains($0.path) }
        let excludedPaths = Set(excluded.flatMap(\.commitPaths))
        for path in excludedPaths {
            let overlaps = commitPaths.contains { selectedPath in
                selectedPath == path || selectedPath.hasPrefix(path + "/") || path.hasPrefix(selectedPath + "/")
            }
            guard !overlaps else {
                throw WorkspaceError.overlappingSelection(path)
            }
        }

        // Git requires new paths to be in the index before `commit --only` can select them.
        let scratch = index.deletingLastPathComponent().appendingPathComponent("pi-commit-" + UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: scratch) }
        let temporaryIndex = scratch.appendingPathComponent("index")
        do {
            try manager.copyItem(at: index, to: temporaryIndex)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // A new repository may not have an index yet. Git can start from an absent alternate index.
        }

        let pathspec = scratch.appendingPathComponent("paths")
        let pathspecArguments = ["--pathspec-from-file=" + pathspec.path, "--pathspec-file-nul"]
        let excludedStaged = Set(excluded.filter(\.isStaged).flatMap(\.commitPaths))
        if !excludedStaged.isEmpty {
            try Self.writePathspec(excludedStaged.sorted(), to: pathspec)
            _ = try await run(["reset", "--quiet"] + pathspecArguments, in: root, index: temporaryIndex)
        }
        let untracked = selected.filter(\.isUntracked).map(\.path)
        if !untracked.isEmpty {
            try Self.writePathspec(untracked, to: pathspec)
            _ = try await run(["add", "--intent-to-add"] + pathspecArguments, in: root, index: temporaryIndex)
        }
        try Self.writePathspec(commitPaths.sorted(), to: pathspec)
        _ = try await run(["commit", "--only", "--message", message] + pathspecArguments,
                          in: root, index: temporaryIndex)

        guard rename(temporaryIndex.path, indexPath) == 0 else {
            throw WorkspaceError.indexInstallFailed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
    }

    private func changes(in directory: String? = nil) async throws -> [GitFileChange] {
        let status = try await run([
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--renames", "--ignore-submodules=none"
        ], in: directory)
        return try Self.parseStatus(status.output.bytes)
    }

    private static func writePathspec(_ paths: [String], to file: URL) throws {
        var data = Data()
        for path in paths {
            data.append(contentsOf: path.utf8)
            data.append(0)
        }
        try data.write(to: file)
    }

    private func repositoryRoot(in directory: String? = nil) async throws -> String {
        try await revParse(["--show-toplevel"], in: directory)
    }

    private func revParse(_ arguments: [String], in directory: String?) async throws -> String {
        let result = try await run(["rev-parse"] + arguments, in: directory)
        guard result.output.bytes.last == 10 else {
            throw WorkspaceError.invalidOutput(command: "rev-parse")
        }
        return try Self.decode(result.output.bytes.dropLast(), command: "rev-parse")
    }

    private static func parseStatus(_ bytes: Data) throws -> [GitFileChange] {
        var records = bytes.split(separator: 0, omittingEmptySubsequences: false).makeIterator()
        var changes: [GitFileChange] = []

        while let record = records.next(), !record.isEmpty {
            let start = record.startIndex
            guard record.count > 3, record[start + 2] == 32 else {
                throw WorkspaceError.invalidOutput(command: "status")
            }

            let index = Character(UnicodeScalar(record[start]))
            let worktree = Character(UnicodeScalar(record[start + 1]))
            let path = try decode(record.dropFirst(3), command: "status")
            var originalPath: String?

            if index == "R" || index == "C" || worktree == "R" || worktree == "C" {
                guard let source = records.next(), !source.isEmpty else {
                    throw WorkspaceError.invalidOutput(command: "status")
                }
                originalPath = try decode(source, command: "status")
            }

            changes.append(GitFileChange(path: path, indexStatus: index, worktreeStatus: worktree, originalPath: originalPath))
        }

        return changes
    }

    private static func decode(_ bytes: Data, command: String) throws -> String {
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw WorkspaceError.invalidOutput(command: command)
        }
        return string
    }

    private func run(
        _ arguments: [String],
        in directory: String? = nil,
        index: URL? = nil,
        outputLimit: Int? = nil,
        acceptedStatuses: [Int32] = [0]
    ) async throws -> WorkspaceCommand.Capture {
        let directory = directory ?? path
        guard !directory.isEmpty else {
            throw WorkspaceError.emptyRepositoryPath
        }
        guard !directory.utf8.contains(0), arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw WorkspaceError.invalidArgument
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "--literal-pathspecs", "-C", directory] + arguments

        var environment = ProcessInfo.processInfo.environment
        if arguments[0] == "init" {
            environment = environment.filter { !$0.key.hasPrefix("GIT_") }
        } else {
            for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_PREFIX"] {
                environment.removeValue(forKey: key)
            }
        }
        environment["GIT_INDEX_FILE"] = index?.path
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let result = try await WorkspaceCommand.capture(process, outputLimit: outputLimit)
        if !result.exitedNormally || !acceptedStatuses.contains(result.status) {
            throw WorkspaceError.commandFailed(command: arguments[0], status: result.status, message: result.errorMessage)
        }
        return result
    }
}

enum WorkspaceCommand {
    struct Output: Sendable {
        let bytes: Data
        let truncated: Bool
    }

    struct Capture: Sendable {
        let status: Int32
        let exitedNormally: Bool
        let output: Output
        fileprivate let error: Output

        var errorMessage: String {
            String(decoding: error.bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func capture(
        _ process: Process, outputLimit: Int?, timeout: DispatchTimeInterval? = nil
    ) async throws -> Capture {
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput

        async let termination = launch(process, output: output, errorOutput: errorOutput, timeout: timeout)
        async let stdout = read(output.fileHandleForReading, limit: outputLimit)
        async let stderr = read(errorOutput.fileHandleForReading, limit: 16 * 1024)
        let (exit, outputCapture, errorCapture) = try await (termination, stdout, stderr)
        return Capture(status: exit.status, exitedNormally: exit.exitedNormally,
                      output: outputCapture, error: errorCapture)
    }

    private static func launch(
        _ process: Process, output: Pipe, errorOutput: Pipe, timeout: DispatchTimeInterval?
    ) async throws -> CommandExit {
        try await withCheckedThrowingContinuation { continuation in
            let stop = DispatchWorkItem { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
            process.terminationHandler = { process in
                stop.cancel()
                continuation.resume(returning: CommandExit(
                    status: process.terminationStatus,
                    exitedNormally: process.terminationReason == .exit
                ))
            }
            do {
                try process.run()
                if let timeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
                }
            } catch {
                process.terminationHandler = nil
                try? output.fileHandleForWriting.close()
                try? errorOutput.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }

    private struct CommandExit: Sendable {
        let status: Int32
        let exitedNormally: Bool
    }

    private static func read(_ handle: FileHandle, limit: Int?) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close() }
                continuation.resume(with: Result {
                    var bytes = Data()
                    var truncated = false
                    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        let available = limit.map { $0 - bytes.count } ?? chunk.count
                        bytes.append(chunk.prefix(available))
                        truncated = truncated || chunk.count > available
                    }
                    return Output(bytes: bytes, truncated: truncated)
                })
            }
        }
    }
}

extension GitWorkspace {
    private enum WorkspaceError: LocalizedError {
        case invalidBranch
        case branchExists(String)
        case worktreeChanged
        case emptyRepositoryPath
        case emptySelection
        case staleSelection
        case overlappingSelection(String)
        case indexLocked
        case indexInstallFailed(POSIXError)
        case invalidArgument
        case invalidProjectName
        case projectFolderExists
        case invalidOutput(command: String)
        case commandFailed(command: String, status: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidBranch: return "Enter a local branch name."
            case .branchExists(let branch): return "A branch named '\(branch)' already exists."
            case .worktreeChanged: return "The prepared worktree no longer matches the selected base. Choose an existing worktree to use it."
            case .emptyRepositoryPath:
                return "The Git repository path is empty."
            case .emptySelection:
                return "Select at least one file to commit."
            case .staleSelection:
                return "The selected changes have changed. Review the refreshed file list and try again."
            case .overlappingSelection(let path):
                return "The selected changes overlap \(path). Include all related paths to commit them together."
            case .indexLocked:
                return "The Git index is locked. Finish the other Git operation and try again."
            case .indexInstallFailed(let error):
                return "Git created the commit, but could not save the updated index. \(error.localizedDescription)"
            case .invalidArgument:
                return "A Git argument contains a NUL character."
            case .invalidProjectName:
                return "Enter a name that can be used for a new folder."
            case .projectFolderExists:
                return "That name is already in use in the chosen folder."
            case .invalidOutput(let command):
                return "Git returned unreadable output for \(command)."
            case .commandFailed(let command, let status, let message):
                return message.isEmpty ? "Git \(command) exited with status \(status)." : message
            }
        }
    }
}
