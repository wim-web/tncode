import Foundation

struct GitChangesCheckout: Sendable {
    let root: String
    let branch: String?
    let head: String?
    let refs: [GitBranchRef]
    let automaticRef: String?
    let baseChoices: [GitChangesBaseChoice]
    let repository: GitHubRepository?

    var revision: GitCheckoutRevision { .init(root: root, branch: branch, head: head) }
    var headLabel: String { branch ?? head.map { String($0.prefix(7)) } ?? "HEAD" }
}

struct GitChangesBaseChoice: Identifiable, Sendable {
    let primary: GitBranchRef
    let remote: GitBranchRef?

    var id: Data { Data(primary.id.utf8) }
    var label: String { primary.isRemote ? primary.name + " (Remote)" : primary.name }

    func matches(_ query: String) -> Bool {
        query.isEmpty || primary.name.localizedCaseInsensitiveContains(query)
            || remote?.name.localizedCaseInsensitiveContains(query) == true
    }

    static func list(refs: [GitBranchRef], remotes: [String], branch: String?) -> [Self] {
        let remoteRefs = refs.filter(\.isRemote)
        let remotePrefixes = remotes.sorted { $0.utf8.count > $1.utf8.count }.map { $0 + "/" }
        let byBranch = Dictionary(grouping: remoteRefs) { ref in
            let name = ref.name
            if let prefix = remotePrefixes.first(where: { name.utf8.starts(with: $0.utf8) }) {
                return Data(name.utf8.dropFirst(prefix.utf8.count))
            }
            return Data((name.split(separator: "/", maxSplits: 1).last ?? name[...]).utf8)
        }
        let currentBranch = branch.map { Data($0.utf8) }
        var paired: Set<Data> = []
        let localChoices = refs.filter { !$0.isRemote && Data($0.name.utf8) != currentBranch }
            .map { local in
                let matches = byBranch[Data(local.name.utf8)] ?? []
                let originRef = "refs/remotes/origin/" + local.name
                let remote = matches.first { $0.id.utf8.elementsEqual(originRef.utf8) } ?? matches.first
                if let remote { paired.insert(Data(remote.id.utf8)) }
                return Self(primary: local, remote: remote)
            }
        return localChoices + remoteRefs.filter { !paired.contains(Data($0.id.utf8)) }
            .map { Self(primary: $0, remote: nil) }
    }
}

struct GitChangesCommit: Identifiable, Hashable, Sendable {
    let id: String
    let subject: String

    var shortID: String { String(id.prefix(7)) }
    var label: String { subject.isEmpty ? "Commit \(shortID)" : "\(shortID) · \(subject)" }

    var hasFullObjectID: Bool {
        [40, 64].contains(id.utf8.count) &&
            id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func webURL(in repository: GitHubRepository) -> URL? {
        guard hasFullObjectID else { return nil }
        return URL(string: "https://\(repository.cliName)/commit/\(id)")
    }
}

enum GitChangesScope: Hashable, Sendable {
    case changes
    case uncommitted
    case commit(GitChangesCommit)

    var label: String {
        switch self {
        case .changes: "Changes"
        case .uncommitted: "Uncommitted"
        case .commit(let commit): "Commit \(commit.shortID)"
        }
    }
}

struct GitChangesTarget: Sendable {
    let checkout: GitChangesCheckout
    let baseRef: String?
    let baseTip: String?
    let before: String
    let after: String?
}

struct GitChangesFile: Identifiable, Hashable, Sendable {
    let path: String
    let previousPath: String?
    let status: Character

    var isUntracked: Bool { status == "?" }
    var id: String { isUntracked ? path + "\0?" : path }
}

private enum GitChangesError: LocalizedError {
    case missingBase(String)
    case noCommonCommit(String, shallow: Bool)
    case unavailableCommit
    case unavailableParent(String)

    var errorDescription: String? {
        switch self {
        case .missingBase(let ref):
            "The comparison branch \(GitBranchRef.displayName(ref)) is unavailable locally."
        case .noCommonCommit(let ref, let shallow):
            "No common commit with \(GitBranchRef.displayName(ref))."
                + (shallow ? " This checkout has shallow history." : "")
        case .unavailableCommit:
            "The selected commit is unavailable locally."
        case .unavailableParent(let sha):
            "Commit \(sha.prefix(7))’s first parent is unavailable locally."
        }
    }
}

extension GitWorkspace {
    private static let reviewDiffOptions = [
        "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "--find-renames", "--ignore-submodules=none"
    ]

    func changesCheckout() async throws -> GitChangesCheckout {
        let root = try await repositoryRoot()
        async let repository = try? GitHubReader(directory: root).repository()
        let branch = try await currentBranch()
        let head = try await headObjectID()
        let refs = try await branchRefs()
        let remotes = try await remoteNames(in: root)
        let automatic = try await automaticComparisonRef(branch: branch, refs: refs, remotes: remotes, root: root)
        let choices = GitChangesBaseChoice.list(refs: refs, remotes: remotes, branch: branch)
        let checkout = await GitChangesCheckout(root: root, branch: branch, head: head, refs: refs,
                                                automaticRef: automatic, baseChoices: choices, repository: repository)
        try await verifyChangesCheckout(checkout)
        return checkout
    }

    private func automaticComparisonRef(branch: String?, refs: [GitBranchRef], remotes: [String],
                                        root: String) async throws -> String? {
        guard let branch else { return nil }
        func ref(_ id: String) -> GitBranchRef? {
            refs.first { $0.id.utf8.elementsEqual(id.utf8) }
        }

        func config(_ key: String) async throws -> String? {
            let result = try await run(["config", "--get", "branch.\(branch).\(key)"],
                                       in: root, acceptedStatuses: [0, 1], cancellable: true)
            return result.status == 0 ? try Self.decode(result.output.bytes.dropLast(), command: "config") : nil
        }

        func upstream(of localBranch: String) -> String? {
            guard let upstream = ref("refs/heads/" + localBranch)?.upstream,
                  ref(upstream)?.isRemote == true else { return nil }
            return upstream
        }

        if let configured = try await config("t3-merge-base-ref"), ref(configured) != nil { return configured }
        var configured = try await config("t3-merge-base")
        if configured == nil { configured = try await config("gh-merge-base") }
        if let configured {
            if ref(configured) != nil { return configured }
            if configured.contains("/"), ref("refs/heads/" + configured) != nil {
                return "refs/heads/" + configured
            }
            if ref("refs/remotes/" + configured) != nil { return "refs/remotes/" + configured }
            if configured != branch, let tracked = upstream(of: configured) { return tracked }
        }

        let primary = remotes.contains("origin") ? "origin" : remotes.first
        let remotePrefix = primary.map { "refs/remotes/" + $0 + "/" }
        let defaultName = refs.first { $0.isRemote && $0.isDefault }.flatMap { ref in
            remotePrefix.map { String(ref.id.dropFirst($0.count)) }
        }
        for name in [configured, defaultName, "main", "master"].compactMap({ $0 }) {
            if name == branch, let tracked = upstream(of: branch) { return tracked }
            if let remotePrefix, ref(remotePrefix + name) != nil { return remotePrefix + name }
            if name != branch, ref("refs/heads/" + name) != nil { return "refs/heads/" + name }
        }
        return nil
    }

    func changesTarget(_ scope: GitChangesScope, checkout: GitChangesCheckout, selectedBase: String?) async throws -> GitChangesTarget {
        let root = checkout.root
        var after: String?
        var baseRef: String?
        var baseTip: String?
        let before: String

        switch scope {
        case .changes:
            baseRef = selectedBase ?? checkout.automaticRef
            if let baseRef, selectedBase != nil || checkout.head != nil {
                guard checkout.refs.contains(where: { $0.id.utf8.elementsEqual(baseRef.utf8) }),
                      let tip = try await changesObjectID(baseRef, root: root) else {
                    throw GitChangesError.missingBase(baseRef)
                }
                guard let head = checkout.head else { throw GitChangesError.noCommonCommit(baseRef, shallow: false) }
                let merge = try await run(["merge-base", tip, head], in: root,
                                          acceptedStatuses: [0, 1], cancellable: true)
                guard merge.status == 0 else {
                    let shallow = try await run(["rev-parse", "--is-shallow-repository"], in: root, cancellable: true)
                    throw GitChangesError.noCommonCommit(baseRef, shallow: Self.line(shallow) == "true")
                }
                baseTip = tip
                before = Self.line(merge)
            } else {
                baseRef = nil
                before = try await changesHeadTree(checkout)
            }
        case .uncommitted:
            before = try await changesHeadTree(checkout)
        case .commit(let commit):
            guard commit.hasFullObjectID,
                  let sha = try await changesObjectID(commit.id, root: root) else {
                throw GitChangesError.unavailableCommit
            }
            after = sha
            // The stored parent survives the shallow graft that hides it from log and revision walks.
            let object = try await run(["cat-file", "commit", sha], in: root, outputLimit: 1024, cancellable: true)
            let parent = String(decoding: object.output.bytes, as: UTF8.self).split(separator: "\n").dropFirst().first
            if let parent, parent.hasPrefix("parent ") {
                let oid = String(parent.dropFirst(7))
                guard try await changesObjectID(oid, root: root) != nil else {
                    throw GitChangesError.unavailableParent(sha)
                }
                before = oid
            } else {
                before = try await changesEmptyTree(root)
            }
        }

        let target = GitChangesTarget(checkout: checkout, baseRef: baseRef, baseTip: baseTip, before: before, after: after)
        try await verifyChangesTarget(target)
        return target
    }

    func changesCommits(_ checkout: GitChangesCheckout, selectedBase: String?) async throws -> [GitChangesCommit] {
        guard let head = checkout.head else { return [] }
        let target: GitChangesTarget?
        let range: String
        do {
            let comparison = try await changesTarget(.changes, checkout: checkout, selectedBase: selectedBase)
            target = comparison
            range = comparison.before == head ? head : "\(comparison.before)..\(head)"
        } catch GitChangesError.missingBase(_) {
            target = nil
            range = head
        } catch GitChangesError.noCommonCommit(_, _) {
            target = nil
            range = head
        }
        let log = try await run(["log", "-z", "--format=%H%x00%s", "--no-notes",
                                 "--no-show-signature", "--max-count=100", range, "--"],
                                in: checkout.root, cancellable: true)
        var fields = log.output.bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast().makeIterator()
        var commits: [GitChangesCommit] = []
        while let sha = fields.next() {
            guard let subject = fields.next() else { throw WorkspaceError.invalidOutput(command: "log") }
            commits.append(GitChangesCommit(id: String(decoding: sha, as: UTF8.self),
                                            subject: String(String(decoding: subject, as: UTF8.self).prefix(300))))
        }
        if let target {
            try await verifyChangesTarget(target)
        } else {
            try await verifyChangesCheckout(checkout)
        }
        return commits
    }

    func changedFiles(in target: GitChangesTarget, ignoringWhitespace: Bool = false) async throws -> [GitChangesFile] {
        let result = try await changesDiff(in: target, format: ["--name-status", "-z"])
        var fields = result.output.bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast().makeIterator()
        var files: [GitChangesFile] = []
        while let status = fields.next() {
            guard let code = status.first, let first = fields.next(), !first.isEmpty else {
                throw WorkspaceError.invalidOutput(command: "diff --name-status")
            }
            let firstPath = try Self.decode(first, command: "diff --name-status")
            let kind = Character(UnicodeScalar(code))
            if kind == "R" || kind == "C" {
                guard let next = fields.next(), !next.isEmpty else {
                    throw WorkspaceError.invalidOutput(command: "diff --name-status")
                }
                let path = try Self.decode(next, command: "diff --name-status")
                files.append(GitChangesFile(path: path, previousPath: firstPath, status: kind))
            } else {
                files.append(GitChangesFile(path: firstPath, previousPath: nil, status: kind))
            }
        }

        if ignoringWhitespace, !files.isEmpty {
            let visible = try await changedPathsIgnoringWhitespace(in: target)
            files.removeAll { !visible.contains(Data($0.path.utf8)) }
        }
        if target.after == nil {
            let others = try await run(["ls-files", "--others", "--exclude-standard", "-z"],
                                       in: target.checkout.root, cancellable: true)
            for field in others.output.bytes.split(separator: 0) {
                let path = try Self.decode(field, command: "ls-files")
                files.append(GitChangesFile(path: path, previousPath: nil, status: "?"))
            }
        }
        try await verifyChangesTarget(target)
        return files
    }

    private func changedPathsIgnoringWhitespace(in target: GitChangesTarget) async throws -> Set<Data> {
        let result = try await changesDiff(in: target, format: ["--numstat", "-z", "--ignore-all-space"])
        var fields = result.output.bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast().makeIterator()
        var paths: Set<Data> = []
        while let field = fields.next() {
            let columns = field.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { throw WorkspaceError.invalidOutput(command: "diff --numstat") }
            if columns[2].isEmpty {
                guard fields.next() != nil, let path = fields.next(), !path.isEmpty else {
                    throw WorkspaceError.invalidOutput(command: "diff --numstat")
                }
                paths.insert(Data(path))
            } else {
                paths.insert(Data(columns[2]))
            }
        }
        return paths
    }

    func changesPatch(in target: GitChangesTarget, file: GitChangesFile?, files: [GitChangesFile],
                      ignoringWhitespace: Bool = false) async throws -> String {
        let limit = Self.patchLimit
        let whitespaceOptions = ignoringWhitespace ? ["--ignore-all-space"] : []
        let tracked: WorkspaceCommand.Capture?
        if file?.isUntracked == true {
            tracked = nil
        } else {
            let paths = file.map { [$0.previousPath, $0.path].compactMap { $0 } } ?? []
            tracked = try await changesDiff(in: target, format: ["--patch"] + whitespaceOptions,
                                            paths: paths, limit: limit)
        }
        var data = tracked?.output.bytes ?? Data()
        var truncated = tracked?.output.truncated == true
        let untracked = file.map { $0.isUntracked ? [$0] : [] } ?? files.filter(\.isUntracked)
        for (index, item) in untracked.enumerated() {
            guard !truncated, data.count < limit, index < 64 else {
                truncated = true
                break
            }
            let result = try await run(["diff", "--patch", "--no-color", "--no-ext-diff", "--no-textconv"]
                                       + whitespaceOptions + ["--no-index", "--", "/dev/null", "./" + item.path],
                                       in: target.checkout.root, outputLimit: limit - data.count,
                                       acceptedStatuses: [0, 1], cancellable: true)
            guard result.status == 0 || !result.output.bytes.isEmpty else {
                throw WorkspaceError.commandFailed(command: "diff", status: result.status, message: result.errorMessage)
            }
            data.append(result.output.bytes)
            truncated = result.output.truncated
        }
        try await verifyChangesTarget(target)
        let patch = String(decoding: data, as: UTF8.self)
        guard truncated else { return patch }
        let notice = file == nil ? "Diff preview limited. Select a file to view its patch." : "Diff truncated after 256 KiB."
        return patch + "\n[\(notice)]\n"
    }

    func verifyChangesCheckout(_ checkout: GitChangesCheckout) async throws {
        try await verifyCheckoutRevision(checkout.revision)
    }

    private func verifyChangesTarget(_ target: GitChangesTarget) async throws {
        try await verifyChangesCheckout(target.checkout)
        if let ref = target.baseRef, try await changesObjectID(ref, root: target.checkout.root) != target.baseTip {
            throw WorkspaceError.changesCheckoutChanged
        }
    }

    private func changesDiff(in target: GitChangesTarget, format: [String], paths: [String] = [],
                             limit: Int? = nil) async throws -> WorkspaceCommand.Capture {
        let revisions = [target.before, target.after].compactMap { $0 }
        return try await run(["diff"] + Self.reviewDiffOptions + format + revisions + ["--"] + paths,
                             in: target.checkout.root, outputLimit: limit, cancellable: true)
    }

    private func changesHeadTree(_ checkout: GitChangesCheckout) async throws -> String {
        if let head = checkout.head { return head }
        return try await changesEmptyTree(checkout.root)
    }

    private func changesEmptyTree(_ root: String) async throws -> String {
        Self.line(try await run(["hash-object", "-t", "tree", "/dev/null"], in: root, cancellable: true))
    }

    private func changesObjectID(_ ref: String, root: String) async throws -> String? {
        let result = try await run(["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"],
                                   in: root, acceptedStatuses: [0, 1], cancellable: true)
        return result.status == 0 ? Self.line(result) : nil
    }

    private static func line(_ result: WorkspaceCommand.Capture) -> String {
        String(decoding: result.output.bytes.dropLast(), as: UTF8.self)
    }
}
