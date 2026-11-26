import Foundation

struct GitRepositoryState: Sendable {
    let branch: String?
    let branches: [String]
    let files: [GitFileChange]
}

struct GitCheckout: Sendable {
    let path: String
    let branch: String?
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
}

struct GitWorkspace: Sendable {
    private let path: String
    private static let patchLimit = 256 * 1024

    init(path: String) {
        self.path = path
    }

    func state() async throws -> GitRepositoryState {
        let status = try await run([
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--renames", "--ignore-submodules=none"
        ])
        let head = try await run(["symbolic-ref", "--quiet", "HEAD"], acceptedStatuses: [0, 1])
        let refs = try await run(["for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/"])
        let headRef = try Self.decode(head.output.bytes, command: "symbolic-ref")
        let localBranchPrefix = "refs/heads/"
        let branch = headRef.hasPrefix(localBranchPrefix)
            ? String(decoding: headRef.utf8.dropFirst(localBranchPrefix.utf8.count).dropLast(), as: UTF8.self)
            : nil
        let branches = try Self.decode(refs.output.bytes, command: "for-each-ref")
            .split(separator: "\n")
            .map(String.init)

        return GitRepositoryState(branch: branch, branches: branches, files: try Self.parseStatus(status.output.bytes))
    }

    func worktrees() async throws -> [GitCheckout] {
        let listing = try await run(["worktree", "list", "--porcelain", "-z"])
        let pathPrefix = "worktree ".utf8
        let branchPrefix = "branch refs/heads/".utf8
        var checkouts: [GitCheckout] = []
        var checkoutPath: String?
        var checkoutBranch: String?

        for field in listing.output.bytes.split(separator: 0, omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let checkoutPath {
                    checkouts.append(GitCheckout(path: checkoutPath, branch: checkoutBranch))
                }
                checkoutPath = nil
                checkoutBranch = nil
            } else if field.starts(with: pathPrefix) {
                checkoutPath = try Self.decode(field.dropFirst(pathPrefix.count), command: "worktree list")
            } else if field.starts(with: branchPrefix) {
                checkoutBranch = try Self.decode(field.dropFirst(branchPrefix.count), command: "worktree list")
            }
        }

        return checkouts
    }

    func patch(for file: GitFileChange?, staged: Bool) async throws -> String {
        let root = try await repositoryRoot()
        var arguments = ["diff", "--patch", "--no-color", "--no-ext-diff", "--no-textconv"]
        let result: CommandResult

        if let file, file.isUntracked && !staged {
            arguments += ["--no-index", "--", "/dev/null", "./" + file.path]
            result = try await run(arguments, in: root, outputLimit: Self.patchLimit, acceptedStatuses: [0, 1])
            if result.status == 1 && result.output.bytes.isEmpty {
                throw result.failure(command: "diff")
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

    func createWorktree(at path: String, branch: String, base: String) async throws -> String {
        let root = try await repositoryRoot()
        _ = try await run(["worktree", "add", "-b", branch, "--", path, base], in: root)
        let target = path.hasPrefix("/") ? path : root + "/" + path
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

    func commit(message: String) async throws {
        _ = try await run(["commit", "--message", message])
    }

    private func repositoryRoot(in directory: String? = nil) async throws -> String {
        let result = try await run(["rev-parse", "--show-toplevel"], in: directory)
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
        outputLimit: Int? = nil,
        acceptedStatuses: [Int32] = [0]
    ) async throws -> CommandResult {
        let directory = directory ?? path
        guard !directory.isEmpty else {
            throw WorkspaceError.emptyRepositoryPath
        }
        guard !directory.utf8.contains(0), arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw WorkspaceError.invalidArgument
        }

        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "--literal-pathspecs", "-C", directory] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput

        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_PREFIX"] {
            environment.removeValue(forKey: key)
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        async let termination = Self.launch(process, output: output, errorOutput: errorOutput)
        async let stdout = Self.read(output.fileHandleForReading, limit: outputLimit)
        async let stderr = Self.read(errorOutput.fileHandleForReading, limit: 16 * 1024)
        let (exit, outputCapture, errorCapture) = try await (termination, stdout, stderr)

        let result = CommandResult(status: exit.status, output: outputCapture, error: errorCapture)
        if !exit.exitedNormally || !acceptedStatuses.contains(result.status) {
            throw result.failure(command: arguments[0])
        }
        return result
    }

    private static func launch(_ process: Process, output: Pipe, errorOutput: Pipe) async throws -> CommandExit {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: CommandExit(
                    status: process.terminationStatus,
                    exitedNormally: process.terminationReason == .exit
                ))
            }
            do {
                try process.run()
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

    private static func read(_ handle: FileHandle, limit: Int?) async throws -> OutputCapture {
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
                    return OutputCapture(bytes: bytes, truncated: truncated)
                })
            }
        }
    }

    private struct OutputCapture: Sendable {
        let bytes: Data
        let truncated: Bool
    }

    private struct CommandResult: Sendable {
        let status: Int32
        let output: OutputCapture
        let error: OutputCapture

        func failure(command: String) -> WorkspaceError {
            let message = String(decoding: error.bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .commandFailed(command: command, status: status, message: message)
        }
    }

    private enum WorkspaceError: LocalizedError {
        case emptyRepositoryPath
        case invalidArgument
        case invalidOutput(command: String)
        case commandFailed(command: String, status: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .emptyRepositoryPath:
                return "The Git repository path is empty."
            case .invalidArgument:
                return "A Git argument contains a NUL character."
            case .invalidOutput(let command):
                return "Git returned unreadable output for \(command)."
            case .commandFailed(let command, let status, let message):
                return message.isEmpty ? "Git \(command) exited with status \(status)." : message
            }
        }
    }
}
