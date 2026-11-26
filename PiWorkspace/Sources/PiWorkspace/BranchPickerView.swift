import Carbon.HIToolbox
import SwiftUI

struct ThreadBranchButton: View {
    let branch: String?
    var fallback = "Detached HEAD"
    var identifier = "git-branch"
    let open: () -> Void
    let copy: (String) -> Void

    var body: some View {
        Button(action: open) {
            Label(branch ?? fallback, systemImage: "arrow.triangle.branch")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Choose branch")
        .accessibilityIdentifier(identifier)
        .contextMenu {
            if let branch {
                Button("Copy branch name") { copy(branch) }
                    .accessibilityIdentifier("git-copy-branch")
            }
        }
    }
}

struct BranchPickerView: View {
    let scope: WorkspaceModel.BranchPickerScope
    @ObservedObject var model: WorkspaceModel
    let pasteboard: NSPasteboard
    let finish: () -> Void

    @State private var choices: GitBranchChoices?
    @State private var query = ""
    @State private var highlightedRef: String?
    @State private var creating = false
    @State private var name = ""
    @State private var base = "HEAD"
    @State private var applying = false
    @State private var loading = true
    @State private var failure: String?
    @FocusState private var focused: Field?

    private enum Field { case search, name }

    private var pendingBase: String? {
        if case let .newWorktree(_, base) = scope.location { return base }
        return nil
    }

    private var shownBranch: String? {
        pendingBase.map(GitBranchRef.displayName) ?? choices?.current
    }

    private var results: [GitBranchRef] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (choices?.refs ?? []).filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) }
    }

    private var selectedRef: GitBranchRef? {
        results.first { $0.id == highlightedRef } ?? results.first
    }

    private var canChange: Bool {
        !loading && !applying && choices != nil && model.branchChangeBlocked == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(creating ? "Create branch" : pendingBase == nil ? "Choose branch" : "Choose base branch")
                .font(.headline)
            if creating {
                newBranchForm
            } else {
                TextField("Search refs…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .search)
                    .onAppear { focused = .search }
                    .accessibilityIdentifier("git-branch-search")
                    .onChange(of: query) { highlightedRef = nil }
                refList
            }
            if let reason = model.branchChangeBlocked, !applying {
                Text(reason).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("git-branch-blocked")
            }
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("git-branch-error")
            }
            controls
        }
        .padding(18)
        .frame(width: 470)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branch picker")
        .accessibilityIdentifier("git-branch-picker")
        .interactiveDismissDisabled(applying)
        .defaultFocus($focused, creating ? .name : .search)
        .task { await loadBranches() }
        .background {
            WindowKeyMonitor { event, window in handleKey(event, in: window) }
        }
    }

    @ViewBuilder
    private var refList: some View {
        if loading {
            ProgressView().controlSize(.small).frame(height: 64)
        } else if results.isEmpty {
            Text("No matching branches")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 64)
                .accessibilityIdentifier("git-branch-empty")
        } else {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(results) { ref in
                            refRow(ref).id(ref.id)
                        }
                    }
                }
                .frame(height: min(260, CGFloat(results.count * 32)))
                .onChange(of: selectedRef?.id) { _, id in
                    if results.count * 32 > 260, let id { reader.scrollTo(id) }
                }
            }
        }
    }

    private func refRow(_ ref: GitBranchRef) -> some View {
        let badges = badges(for: ref)
        return Button {
            apply(.existing(ref.id))
        } label: {
            HStack(spacing: 7) {
                Text(ref.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                ForEach(badges, id: \.self) { badge in
                    Text(badge).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 29)
            .contentShape(Rectangle())
            .background(ref.id == selectedRef?.id ? Color.accentColor.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!canChange)
        .accessibilityLabel(([ref.name] + badges).joined(separator: ", "))
        .accessibilityAddTraits(ref.id == selectedRef?.id ? .isSelected : [])
        .accessibilityIdentifier("git-branch-ref-\(ref.id)")
    }

    private func badges(for ref: GitBranchRef) -> [String] {
        var badges: [String] = []
        if let pendingBase {
            if ref.id == pendingBase || ref.name == pendingBase { badges.append("Base") }
        } else if !ref.isRemote && ref.name == choices?.current {
            badges.append("Current")
        }
        if !ref.isRemote && choices?.linkedBranches.contains(ref.name) == true { badges.append("Worktree") }
        if ref.isRemote { badges.append("Remote") }
        if ref.isDefault { badges.append("Default") }
        return badges
    }

    private var newBranchForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("New branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .name)
                .onAppear { focused = .name }
                .accessibilityIdentifier("git-new-branch-name")
            Picker("Base branch", selection: $base) {
                Text("Current HEAD").tag("HEAD")
                ForEach(choices?.refs ?? []) { ref in Text(ref.name).tag(ref.id) }
            }
            .accessibilityIdentifier("git-new-branch-base")
        }
        .disabled(applying)
    }

    private var controls: some View {
        HStack {
            if creating {
                Button("Back", action: back)
                    .disabled(applying)
                    .accessibilityIdentifier("git-new-branch-back")
            } else if let shownBranch {
                Button("Copy branch name") { copy(shownBranch) }
                    .help("Copy branch name (⇧⌘C)")
                    .disabled(applying)
                    .accessibilityIdentifier("git-copy-branch-in-picker")
            }
            Spacer()
            if applying { ProgressView().controlSize(.small) }
            Button("Cancel", action: finish)
                .disabled(applying)
                .accessibilityIdentifier("git-branch-cancel")
            if creating {
                Button("Create and Switch") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canChange || trimmedName.isEmpty)
                    .accessibilityIdentifier("git-create-and-switch")
            } else if pendingBase == nil {
                Button("New Branch", action: startCreating)
                    .disabled(!canChange)
                    .accessibilityIdentifier("git-new-branch")
            }
        }
    }

    static func copyBranch(_ branch: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(branch, forType: .string)
    }

    private func copy(_ branch: String) {
        if !Self.copyBranch(branch, to: pasteboard) { failure = "Could not copy the branch name." }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func startCreating() {
        guard canChange, pendingBase == nil else { return }
        name = query
        base = choices?.current.flatMap { current in
            choices?.refs.first { !$0.isRemote && $0.name == current }?.id
        } ?? "HEAD"
        failure = nil
        creating = true
    }

    private func back() {
        creating = false
        failure = nil
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        apply(.create(name: trimmedName, base: base))
    }

    private func apply(_ choice: WorkspaceModel.BranchChoice) {
        guard canChange else { return }
        applying = true
        failure = nil
        Task {
            defer { applying = false }
            do {
                try await model.changeThreadBranch(choice, in: scope)
                finish()
            } catch {
                let title: String
                switch choice {
                case .existing: title = "Failed to switch ref."
                case .create: title = "Failed to create and switch ref."
                }
                failure = "\(title) \(error.localizedDescription)"
                await loadBranches()
            }
        }
    }

    private func loadBranches() async {
        defer { loading = false }
        do {
            let refreshed = try await GitWorkspace(path: scope.directory).branchChoices()
            guard !Task.isCancelled else { return }
            choices = refreshed
        } catch {
            guard !Task.isCancelled else { return }
            if failure == nil { failure = error.localizedDescription }
        }
    }

    private func handleKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let editor = window.firstResponder as? NSTextView
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c",
           !creating, !applying, let shownBranch, editor?.hasMarkedText() != true {
            if !event.isARepeat { copy(shownBranch) }
            return true
        }
        guard modifiers.isEmpty, editor?.hasMarkedText() != true else { return false }
        let code = Int(event.keyCode)
        switch code {
        case kVK_Escape:
            guard !applying, !event.isARepeat else { return true }
            if creating { back() } else { finish() }
        case kVK_UpArrow, kVK_DownArrow:
            guard editor?.isFieldEditor == true, !creating else { return false }
            let refs = results
            if let index = refs.firstIndex(where: { $0.id == selectedRef?.id }) {
                let delta = code == kVK_DownArrow ? 1 : -1
                highlightedRef = refs[(index + delta + refs.count) % refs.count].id
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard editor?.isFieldEditor == true else { return false }
            guard !event.isARepeat else { return true }
            if creating {
                create()
            } else if let selectedRef {
                apply(.existing(selectedRef.id))
            } else if !query.isEmpty {
                startCreating()
            }
        default:
            return false
        }
        return true
    }
}
