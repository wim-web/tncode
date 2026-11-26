import Darwin
import Foundation

struct GitRepositoryState: Sendable {
    let branch: String?
    let branches: [String]
    let files: [GitFileChange]
    let directoryPrefix: String

    func workspacePath(for file: GitFileChange) -> String? {
        guard file.path.hasPrefix(directoryPrefix) else { return nil }
        return String(file.path.dropFirst(directoryPrefix.count))
    }
}

struct GitCheckout: Sendable {
    let path: String
    let branch: String?
    let head: String?
    let lockReason: String?
}

struct GitBranchRef: Identifiable, Sendable {
    let id: String
    let upstream: String
    let isDefault: Bool

    var isRemote: Bool { id.hasPrefix("refs/remotes/") }
    var name: String { Self.displayName(id) }

    static func displayName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    static func defaultWorktreeBase(in refs: [Self], current: String?) -> Self? {
        refs.first(where: \.isDefault)
            ?? refs.first { !$0.isRemote && $0.name == current }
    }
}

struct GitBranchChoices: Sendable {
    let current: String?
    let refs: [GitBranchRef]
    let linkedBranches: Set<String>
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
    struct PendingCheckout: Codable, Sendable {
        let path: String
        let branch: String
        let head: String
        let owner: UUID

        fileprivate var lockReason: String { "Pi Workspace preparing " + owner.uuidString }
        fileprivate var receipt: Data { Data((owner.uuidString + "\n" + head + "\n").utf8) }
        fileprivate var branchRef: String { "refs/heads/" + branch }
    }

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
        return try await installNewRepository(at: folder) { staging in
            _ = try await GitWorkspace(path: staging.path).run(["init", "--quiet", "--template="])
        }
    }

    struct CloneDestination {
        let folder: URL
        fileprivate let directory: FileHandle?
        var alreadyExists: Bool { directory != nil }

        init(_ input: URL) throws {
            try Task.checkCancellation()
            let url = input.standardizedFileURL
            guard url.isFileURL, !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else {
                throw WorkspaceError.invalidCloneDestination
            }
            let parent = url.deletingLastPathComponent()
            let files = FileManager.default
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
            folder = parent.resolvingSymlinksInPath().standardizedFileURL
                .appendingPathComponent(url.lastPathComponent, isDirectory: true)
            let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                guard code == .ENOENT else {
                    if code == .ENOTDIR || code == .ELOOP { throw WorkspaceError.projectFolderExists }
                    throw POSIXError(code)
                }
                directory = nil
            } else {
                directory = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try checkEmpty()
            }
        }

        private func checkEmpty(except stagingName: String? = nil) throws {
            let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            guard entries.allSatisfy({ $0 == stagingName }) else {
                throw WorkspaceError.cloneDestinationNotEmpty
            }
            guard matchesDirectory(at: folder.path) else { throw WorkspaceError.cloneDestinationChanged }
        }

        func matchesDirectory(at path: String) -> Bool {
            guard let directory else { return false }
            return GitWorkspace.matches(directory, at: path)
        }

        fileprivate func installContents(of staging: URL, from stage: FileHandle) throws {
            guard let directory else { throw WorkspaceError.cloneDestinationChanged }
            try checkEmpty(except: staging.lastPathComponent)
            // Once visible, an entry can contain user edits and must stay outside staging cleanup.
            let files = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            // Install .git last so a partial installation cannot look like a complete checkout.
            let entries = files.filter { $0 != ".git" } + [".git"]
            for (offset, entry) in entries.enumerated() {
                guard renameatx_np(stage.fileDescriptor, entry, directory.fileDescriptor, entry, UInt32(RENAME_EXCL)) == 0 else {
                    let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    if offset > 0 { throw WorkspaceError.partialClone(folder, failure) }
                    throw failure
                }
            }
            guard matchesDirectory(at: folder.path) else { throw WorkspaceError.cloneDestinationChanged }
        }
    }

    @MainActor
    static func cloneRepository(from source: String, to folder: URL) async throws -> URL {
        try await cloneRepository(from: source, to: CloneDestination(folder))
    }

    @MainActor
    static func cloneRepository(from source: String, to destination: CloneDestination) async throws -> URL {
        try await installNewRepository(at: destination.folder, cloneDestination: destination) { staging in
            _ = try await GitWorkspace(path: staging.path).run(
                ["clone", "--quiet", "--no-local", "--template=", "--", source, "."],
                outputLimit: 0
            )
        }
    }

    @MainActor
    private static func installNewRepository(
        at folder: URL, cloneDestination: CloneDestination? = nil, initialize: (URL) async throws -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let files = FileManager.default
        if cloneDestination?.alreadyExists != true {
            try folder.withUnsafeFileSystemRepresentation { destination in
                guard let destination else { throw WorkspaceError.invalidArgument }
                var info = stat()
                if lstat(destination, &info) == 0 { throw WorkspaceError.projectFolderExists }
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                if code != .ENOENT { throw POSIXError(code) }
            }
        }
        let name = ".pi-workspace-\(UUID())"
        let parent = cloneDestination?.directory?.fileDescriptor ?? AT_FDCWD
        let stageParent = parent == AT_FDCWD ? folder.deletingLastPathComponent() : folder
        let staging = stageParent.appendingPathComponent(name, isDirectory: true)
        let path = parent == AT_FDCWD ? staging.path : name
        guard mkdirat(parent, path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let fd = openat(parent, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            _ = unlinkat(parent, path, AT_REMOVEDIR)
            throw failure
        }
        let stage = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try await initialize(pathForStage(stage, originally: staging))
            try Task.checkCancellation()
            let currentStage = try pathForStage(stage, originally: staging)
            if let cloneDestination, cloneDestination.alreadyExists {
                try cloneDestination.installContents(of: currentStage, from: stage)
                guard rmdir(currentStage.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else {
                try moveNewRepository(from: currentStage, to: folder)
            }
        } catch let failure {
            do {
                // Locate our private stage even if the user moved the destination and replaced it.
                try files.removeItem(at: pathForStage(stage, originally: staging))
            } catch let cleanup as CocoaError where cleanup.code == .fileNoSuchFile {
                throw failure
            } catch {
                throw WorkspaceError.repositoryCleanupFailed(staging, failure: failure, cleanup: error)
            }
            throw failure
        }
        return folder
    }

    private static func pathForStage(_ stage: FileHandle, originally url: URL) throws -> URL {
        if matches(stage, at: url.path) { return url }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(stage.fileDescriptor, F_GETPATH, &path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let current = URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
        // F_GETPATH can still report the last path after unlink, even if another directory took its place.
        guard matches(stage, at: current.path) else { throw CocoaError(.fileNoSuchFile) }
        return current
    }

    private static func matches(_ directory: FileHandle, at path: String) -> Bool {
        var held = stat(), current = stat()
        return fstat(directory.fileDescriptor, &held) == 0 && lstat(path, &current) == 0 &&
            held.st_dev == current.st_dev && held.st_ino == current.st_ino
    }

    private static func moveNewRepository(from staging: URL, to folder: URL) throws {
        try staging.withUnsafeFileSystemRepresentation { source in
            try folder.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { throw WorkspaceError.invalidArgument }
                guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
                    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                    if code == .EEXIST || code == .ENOTEMPTY { throw WorkspaceError.projectFolderExists }
                    throw POSIXError(code)
                }
            }
        }
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

        let directoryPrefix = try await revParse(["--show-prefix"], in: nil)
        return GitRepositoryState(branch: branch, branches: branches, files: files, directoryPrefix: directoryPrefix)
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
                    let path = Self.canonicalCheckoutPath(checkoutPath)
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

    func branchChoices() async throws -> GitBranchChoices {
        let root = try await Self.canonicalCheckoutPath(repositoryRoot())
        let current = try await currentBranch()
        let linked = try await worktrees().filter { $0.path != root }.compactMap(\.branch)
        let refs = try await branchRefs()
        return GitBranchChoices(current: current, refs: refs, linkedBranches: Set(linked))
    }

    func branchRefs() async throws -> [GitBranchRef] {
        let format = "%(refname)%00%(symref)%00%(upstream)"
        let result = try await run(["for-each-ref", "--format=" + format, "refs/heads/", "refs/remotes/"])
        let output = try Self.decode(result.output.bytes, command: "for-each-ref")
        let rows = output.split(separator: "\n").map { $0.split(separator: "\0", omittingEmptySubsequences: false) }
        guard rows.allSatisfy({ $0.count == 3 }) else { throw WorkspaceError.invalidOutput(command: "for-each-ref") }
        var defaultRef: Substring?
        var defaultBranch: Substring?
        if rows.contains(where: { $0[0].hasPrefix("refs/remotes/") && !$0[1].isEmpty }) {
            let remotes = try await remoteNames(in: path)
            if let primary = remotes.first(where: { $0 == "origin" }) ?? remotes.first {
                let prefix = "refs/remotes/\(primary)/"
                let head = rows.first { $0[0] == prefix + "HEAD" }?[1]
                if let head, head.hasPrefix(prefix), rows.contains(where: { $0[0] == head && $0[1].isEmpty }) {
                    defaultRef = head
                    defaultBranch = head.dropFirst(prefix.count)
                }
            }
        }
        return rows.compactMap { row in
            guard row[1].isEmpty || row[0].hasPrefix("refs/heads/") else { return nil }
            let localDefault = defaultBranch.map { row[0] == "refs/heads/" + $0 } ?? false
            return GitBranchRef(id: String(row[0]), upstream: String(row[2]),
                                isDefault: localDefault || row[0] == defaultRef)
        }
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

    func pinWorktree(at target: String, branch: String, base: String, owner: UUID,
                     legacy: Bool = false, startFromRemote: Bool = false) async throws -> PendingCheckout {
        let root = try await repositoryRoot()
        let checked = try await run(["check-ref-format", "--branch", branch], in: root)
        guard checked.output.bytes == Data((branch + "\n").utf8) else { throw WorkspaceError.invalidBranch }
        var startRef = base
        if startFromRemote, let remoteRef = try await fetchWorktreeBase(base, in: root) {
            startRef = remoteRef
        }
        let commit = try await revParse(["--verify", "--end-of-options", startRef + "^{commit}"], in: root)
        let checkout = PendingCheckout(path: target, branch: branch, head: commit, owner: owner)
        if try await branchExists(checkout) {
            guard legacy, try await worktrees().contains(where: { $0.path == target && $0.branch == branch }) else {
                throw WorkspaceError.branchExists(branch)
            }
        }
        return checkout
    }

    private func remoteNames(in directory: String) async throws -> [String] {
        let result = try await run(["remote"], in: directory)
        return try Self.decode(result.output.bytes, command: "remote").split(separator: "\n").map(String.init)
    }

    private func fetchWorktreeBase(_ base: String, in root: String) async throws -> String? {
        let remotes = try await remoteNames(in: root)
        let name = GitBranchRef.displayName(base)
        var remote = "origin"
        var branch = name
        var hasLocalRef = base.hasPrefix("refs/heads/")
        if !base.hasPrefix("refs/remotes/") {
            let localRef = "refs/heads/" + name
            let result = try await run(["for-each-ref", "--format=%(refname)%00%(upstream:remotename)%00%(upstream:remoteref)",
                                        localRef], in: root)
            let output = try Self.decode(result.output.bytes, command: "for-each-ref")
            let upstream = output.split(separator: "\n").map { $0.split(separator: "\0", omittingEmptySubsequences: false) }
                .first { $0.count == 3 && $0[0].utf8.elementsEqual(localRef.utf8) }
            hasLocalRef = hasLocalRef || upstream != nil
            if let upstream, remotes.contains(String(upstream[1])), upstream[2].hasPrefix("refs/heads/") {
                remote = String(upstream[1])
                branch = String(upstream[2].dropFirst("refs/heads/".count))
            }
        }
        if !hasLocalRef, let matching = remotes.filter({ name.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            remote = matching
            branch = String(name.dropFirst(matching.count + 1))
        } else if base.hasPrefix("refs/remotes/") {
            return nil
        }
        guard remotes.contains(remote), branch != "HEAD", !branch.hasPrefix("-") else { return nil }
        let source = "refs/heads/" + branch
        let valid = try await run(["check-ref-format", source], in: root, acceptedStatuses: [0, 1])
        guard valid.status == 0 else { return nil }
        let tracking = "refs/remotes/\(remote)/\(branch)"
        let fetched = try await run(["fetch", "--quiet", "--no-tags", "--no-recurse-submodules",
                                     "--", remote, "+\(source):\(tracking)"],
                                    in: root, acceptedStatuses: [0, 128])
        if fetched.status == 0 { return tracking }
        if fetched.errorMessage.split(separator: "\n").contains("fatal: couldn't find remote ref \(source)") {
            return nil
        }
        throw WorkspaceError.commandFailed(command: "fetch", status: fetched.status, message: fetched.errorMessage)
    }

    func createWorktree(_ checkout: PendingCheckout, legacy: Bool = false) async throws -> String {
        let target = checkout.path
        guard Self.isCanonicalWorktree(target) else { throw WorkspaceError.worktreeChanged }
        let prepared = try await worktrees().first { $0.path == target }
        let hasBranch = try await branchExists(checkout)
        if hasBranch, !(legacy && prepared?.branch == checkout.branch) {
            guard try await ownsBranch(checkout) else { throw WorkspaceError.branchExists(checkout.branch) }
        }
        try Task.checkCancellation()
        if let prepared {
            guard try await ownsCheckout(prepared, for: checkout) else {
                throw WorkspaceError.worktreeChanged
            }
        } else {
            var entry = stat()
            guard lstat(target, &entry) == -1, errno == ENOENT else { throw WorkspaceError.worktreeChanged }
            _ = try await run(["worktree", "add", "--detach", "--lock", "--reason",
                               checkout.lockReason, "--", target, checkout.head])
        }
        try Task.checkCancellation()
        let ownsLock = prepared == nil || prepared?.lockReason == checkout.lockReason
        if ownsLock {
            let receipt = try await worktreeReceipt(at: target)
            try checkout.receipt.write(to: receipt, options: .atomic)
        }
        try Task.checkCancellation()
        if !hasBranch {
            let absent = String(repeating: "0", count: checkout.head.count)
            _ = try await run(["update-ref", "--create-reflog", "-m", checkout.lockReason,
                               checkout.branchRef, checkout.head, absent])
        }
        try Task.checkCancellation()
        if prepared?.branch != checkout.branch {
            _ = try await run(["switch", "--no-guess", "--", checkout.branch], in: target)
        }
        guard try await worktrees().contains(where: {
            $0.path == target && $0.head == checkout.head && $0.branch == checkout.branch
        }) else { throw WorkspaceError.worktreeChanged }
        if ownsLock { _ = try await run(["worktree", "unlock", "--", target]) }
        return target
    }

    func discardPendingCheckout(_ checkout: PendingCheckout, attached: Bool) async throws {
        guard Self.isCanonicalWorktree(checkout.path) else { return }
        if let prepared = try await worktrees().first(where: { $0.path == checkout.path }) {
            guard !attached || prepared.branch == checkout.branch,
                  try await ownsCheckout(prepared, for: checkout) else { return }
            if prepared.branch != nil {
                guard try await ownsBranch(checkout) else { return }
            }
            let status = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all",
                                        "--ignored", "--ignore-submodules=none"], in: checkout.path, outputLimit: 1)
            guard status.output.bytes.isEmpty, !status.output.truncated else { return }
            try Task.checkCancellation()
            if prepared.lockReason == checkout.lockReason {
                _ = try await run(["worktree", "unlock", "--", checkout.path])
            }
            _ = try await run(["worktree", "remove", "--", checkout.path])
        }
        guard try await ownsBranch(checkout),
              try await !worktrees().contains(where: { $0.branch == checkout.branch }) else { return }
        try Task.checkCancellation()
        _ = try await run(["update-ref", "-d", checkout.branchRef, checkout.head])
    }

    private static func isCanonicalWorktree(_ target: String) -> Bool {
        guard target.hasPrefix("/"), canonicalCheckoutPath(target) == target else { return false }
        // A missing checkout can hide a symlink in a parent folder replaced since the path was saved.
        var ancestor = URL(fileURLWithPath: target, isDirectory: true)
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            ancestor.deleteLastPathComponent()
        }
        return canonicalCheckoutPath(ancestor.path) == ancestor.path
    }

    static func canonicalCheckoutPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func branchExists(_ checkout: PendingCheckout) async throws -> Bool {
        try await run(["show-ref", "--verify", "--quiet", checkout.branchRef],
                      acceptedStatuses: [0, 1]).status == 0
    }

    private func ownsBranch(_ checkout: PendingCheckout) async throws -> Bool {
        guard try await branchExists(checkout) else { return false }
        let lastUpdate = try await run(["reflog", "show", "-1", "--format=%H%x00%gs", checkout.branchRef, "--"])
        return lastUpdate.output.bytes == Data((checkout.head + "\0" + checkout.lockReason + "\n").utf8)
    }

    private func ownsCheckout(_ prepared: GitCheckout, for checkout: PendingCheckout) async throws -> Bool {
        guard prepared.head == checkout.head, prepared.branch == nil || prepared.branch == checkout.branch,
              prepared.lockReason == nil || prepared.lockReason == checkout.lockReason else { return false }
        if prepared.lockReason == checkout.lockReason { return true }
        let receipt = try await worktreeReceipt(at: checkout.path)
        return (try? Data(contentsOf: receipt)) == checkout.receipt
    }

    private func worktreeReceipt(at target: String) async throws -> URL {
        let admin = try await revParse(["--absolute-git-dir"], in: target)
        return URL(fileURLWithPath: admin).appendingPathComponent("pi-workspace-owner")
    }

    private static let safeSwitch = ["switch", "--no-guess", "--no-overwrite-ignore", "--no-recurse-submodules"]

    /// Return a verified destination only when Git already has the target checked out elsewhere.
    func switchBranch(to refID: String, protecting protectedCheckouts: Set<String>,
                      beforeSwitch: @MainActor (String) throws -> Void) async throws -> String? {
        let refs = try await branchRefs()
        guard let ref = refs.first(where: { $0.id.utf8.elementsEqual(refID.utf8) }) else {
            throw WorkspaceError.refUnavailable(refID)
        }
        let local: GitBranchRef?
        if ref.isRemote {
            let trackers = refs.filter { !$0.isRemote && $0.upstream.utf8.elementsEqual(ref.id.utf8) }
            // Prefer the conventional name if multiple local branches track the same ref.
            let conventional = ref.name.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init)
            local = trackers.first { $0.name == conventional } ?? (trackers.count == 1 ? trackers.first : nil)
            if local == nil, !trackers.isEmpty {
                throw WorkspaceError.ambiguousTrackingBranch(ref.name)
            }
        } else {
            local = ref
        }

        let root = try await Self.canonicalCheckoutPath(repositoryRoot())
        guard !protectedCheckouts.contains(root) else { throw WorkspaceError.pendingWorktree }
        if let local {
            if try await currentBranch()?.utf8.elementsEqual(local.name.utf8) == true { return nil }
            let other = try await worktrees().filter {
                $0.path != root && $0.branch?.utf8.elementsEqual(local.name.utf8) == true
            }
            if let checkout = other.first {
                guard other.count == 1 else { throw WorkspaceError.branchCheckoutChanged }
                guard !protectedCheckouts.contains(checkout.path),
                      checkout.lockReason?.hasPrefix("Pi Workspace preparing ") != true else {
                    throw WorkspaceError.pendingWorktree
                }
                let commonDir = try await commonDirectory(in: root)
                let target = GitWorkspace(path: checkout.path)
                guard try await Self.canonicalCheckoutPath(target.repositoryRoot()) == checkout.path,
                      try await commonDirectory(in: checkout.path) == commonDir,
                      try await target.currentBranch()?.utf8.elementsEqual(local.name.utf8) == true else {
                    throw WorkspaceError.branchCheckoutChanged
                }
                return checkout.path
            }
            try await beforeSwitch(root)
            _ = try await run(Self.safeSwitch + ["--", local.name])
        } else {
            try await beforeSwitch(root)
            _ = try await run(Self.safeSwitch + ["--track", "--", ref.id])
        }
        return nil
    }

    func createBranch(_ name: String, from base: String, protecting protectedCheckouts: Set<String>,
                      beforeSwitch: @MainActor (String) throws -> Void) async throws {
        let root = try await Self.canonicalCheckoutPath(repositoryRoot())
        guard !protectedCheckouts.contains(root) else { throw WorkspaceError.pendingWorktree }
        let checked = try await run(["check-ref-format", "--branch", name])
        guard checked.output.bytes == Data((name + "\n").utf8) else { throw WorkspaceError.invalidBranch }
        if base != "HEAD" {
            let refs = try await branchRefs()
            guard refs.contains(where: { $0.id.utf8.elementsEqual(base.utf8) }) else {
                throw WorkspaceError.refUnavailable(base)
            }
        }
        let commit = try await revParse(["--verify", "--end-of-options", base + "^{commit}"], in: nil)
        try await beforeSwitch(root)
        _ = try await run(Self.safeSwitch + ["--no-track", "-c", name, "--", commit])
    }

    private func commonDirectory(in directory: String) async throws -> String {
        let path = try await revParse(["--path-format=absolute", "--git-common-dir"], in: directory)
        return Self.canonicalCheckoutPath(path)
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

        let cloning = arguments[0] == "clone"
        let fetching = arguments[0] == "fetch"
        var environment = ProcessInfo.processInfo.environment
        if arguments[0] == "init" || cloning {
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
        if cloning {
            environment["GIT_ALLOW_PROTOCOL"] = "file:git:http:https:ssh"
        }
        if fetching {
            environment["LC_ALL"] = "C"
            environment["GIT_ASKPASS"] = ""
            environment["SSH_ASKPASS_REQUIRE"] = "never"
            environment["GCM_INTERACTIVE"] = "never"
        }
        process.environment = environment

        let result = try await WorkspaceCommand.capture(process, outputLimit: outputLimit,
                                                        timeout: fetching ? .seconds(300) : nil,
                                                        cancelOnTaskCancellation: cloning || fetching)
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
        _ process: Process, outputLimit: Int?, timeout: DispatchTimeInterval? = nil,
        cancelOnTaskCancellation: Bool = false
    ) async throws -> Capture {
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput

        let cancellation = cancelOnTaskCancellation ? ProcessCancellation(process) : nil
        return try await withTaskCancellationHandler {
            defer { cancellation?.finish() }
            async let termination = launch(process, output: output, errorOutput: errorOutput,
                                           timeout: timeout, cancellation: cancellation)
            async let stdout = read(output.fileHandleForReading, limit: outputLimit)
            async let stderr = read(errorOutput.fileHandleForReading, limit: 16 * 1024)
            let (exit, outputCapture, errorCapture) = try await (termination, stdout, stderr)
            if cancellation != nil { try Task.checkCancellation() }
            return Capture(status: exit.status, exitedNormally: exit.exitedNormally,
                           output: outputCapture, error: errorCapture)
        } onCancel: {
            cancellation?.cancel()
        }
    }

    private static func launch(
        _ process: Process, output: Pipe, errorOutput: Pipe, timeout: DispatchTimeInterval?,
        cancellation: ProcessCancellation?
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
                if let cancellation { try cancellation.start() }
                else { try process.run() }
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

    private final class ProcessCancellation: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var cancelled = false
        private var pid: pid_t?

        init(_ process: Process) {
            self.process = process
        }

        func start() throws {
            try lock.withLock {
                if cancelled { throw CancellationError() }
                try process.run()
                pid = process.processIdentifier
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                guard let pid else { return }
                // On macOS, Process starts a process group. Git's transport also owns the pipes.
                if kill(-pid, SIGKILL) == -1, process.isRunning { kill(pid, SIGKILL) }
            }
        }

        func finish() {
            lock.withLock { pid = nil }
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
        case branchCheckoutChanged
        case refUnavailable(String)
        case ambiguousTrackingBranch(String)
        case pendingWorktree
        case emptyRepositoryPath
        case emptySelection
        case staleSelection
        case overlappingSelection(String)
        case indexLocked
        case indexInstallFailed(POSIXError)
        case invalidArgument
        case invalidProjectName
        case projectFolderExists
        case invalidCloneDestination
        case cloneDestinationNotEmpty
        case cloneDestinationChanged
        case partialClone(URL, Error)
        case repositoryCleanupFailed(URL, failure: Error, cleanup: Error)
        case invalidOutput(command: String)
        case commandFailed(command: String, status: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidBranch: return "Enter a local branch name."
            case .branchExists(let branch): return "A branch named '\(branch)' already exists."
            case .worktreeChanged: return "The prepared worktree no longer matches the selected base. Choose an existing worktree to use it."
            case .branchCheckoutChanged: return "Git could not confirm a single checkout for this branch. Refresh the picker and try again."
            case .refUnavailable(let ref): return "The branch '\(GitBranchRef.displayName(ref))' is no longer available."
            case .ambiguousTrackingBranch(let branch): return "Multiple local branches track '\(branch)'. Choose the local branch you want to use."
            case .pendingWorktree: return "Finish or cancel the other thread’s worktree launch first."
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
            case .invalidCloneDestination:
                return "Choose a local destination folder for the cloned repository."
            case .cloneDestinationNotEmpty:
                return "The clone destination must be an empty folder."
            case .cloneDestinationChanged:
                return "The clone destination changed before the repository could be added."
            case .partialClone(let folder, let error):
                return "Could not finish installing the clone at \(folder.path). Files already placed there were kept. \(error.localizedDescription)"
            case .repositoryCleanupFailed(let folder, let failure, let cleanup):
                let reason = failure is CancellationError ? "The operation was cancelled." : failure.localizedDescription
                return "\(reason) Could not remove the temporary repository at \(folder.path). \(cleanup.localizedDescription)"
            case .invalidOutput(let command):
                return "Git returned unreadable output for \(command)."
            case .commandFailed(let command, let status, let message):
                return message.isEmpty ? "Git \(command) exited with status \(status)." : message
            }
        }
    }
}
