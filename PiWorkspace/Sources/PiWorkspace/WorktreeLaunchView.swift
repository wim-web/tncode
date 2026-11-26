import SwiftUI

struct WorktreeLaunchView: View {
    let thread: Conversation
    let projectPath: String
    let checkedOutBranch: String?
    let launch: WorktreeLaunch
    @ObservedObject var model: WorkspaceModel
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.title)
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("worktree-launch-status")
            if let failure = launch.failure {
                ViewThatFits(in: .vertical) {
                    diagnostic(failure)
                    ScrollView { diagnostic(failure) }
                }
                .frame(maxHeight: 100)
            }
            ViewThatFits(in: .vertical) {
                prompt
                ScrollView { prompt }
            }
            .frame(maxHeight: 120)
            HStack {
                if model.canRetryWorktree {
                    Button("Retry") {
                        model.retryWorktree(threadID: thread.id, launchID: launch.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retry-worktree")
                } else if launch.awaitingHistory && model.phase == .ready && !thread.archived {
                    Button("Dismiss Pending Message", action: model.dismissUnconfirmedWorktreePrompt)
                }
                if model.canWorkLocally {
                    Button("Work locally") {
                        model.interruptWorktree(.workLocally, threadID: thread.id, launchID: launch.id)
                    }
                    .accessibilityIdentifier("worktree-launch-work-locally")
                }
                if model.canInterruptWorktree {
                    Button("Cancel") {
                        model.interruptWorktree(.cancel, threadID: thread.id, launchID: launch.id)
                    }
                    .accessibilityIdentifier("worktree-launch-cancel")
                }
            }
            DisclosureGroup(isExpanded: $detailsExpanded) {
                details
            } label: {
                Text("Details")
                    .accessibilityIdentifier("worktree-launch-details")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 15))
    }

    private var status: (title: String, stepLabel: String) {
        if let interruption = launch.interruption {
            if launch.failure != nil { return ("Could not finish setup interruption", "Last setup step") }
            if !model.preparingWorktree { return ("Setup interruption pending", "Last setup step") }
            let title = interruption == .cancel ? "Cancelling setup…" : "Switching to local workspace…"
            return (title, "Last setup step")
        }
        if launch.failure != nil {
            let title = thread.workingLocation == .project ? "Local thread setup failed" : "Worktree setup failed"
            return (title, "Failed step")
        }
        if launch.awaitingHistory {
            let title = model.phase == .ready ? "Pi could not confirm that it recorded this message."
                : "Waiting for Pi to confirm the first message…"
            return (title, "Pending step")
        }
        if model.preparingWorktree {
            let title = thread.workingLocation == .project ? "Opening local thread…" : "Preparing worktree…"
            return (title, "Current step")
        }
        return ("Setup paused", "Next step")
    }

    private var checkout: (branch: String?, base: String?, path: String?) {
        switch thread.workingLocation {
        case .newWorktree(let branch, let base):
            (branch, base, launch.checkout?.path ?? launch.targetPath)
        case .worktree(let path, let base):
            (launch.checkout?.branch ?? checkedOutBranch, base, path)
        case .project:
            (checkedOutBranch, nil, projectPath)
        }
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            detailRow(status.stepLabel, launch.stage.label, id: "worktree-launch-stage")
            if let branch = checkout.branch {
                detailRow("Branch", branch, id: "worktree-launch-branch")
            }
            if let base = checkout.base {
                detailRow("Base", base, id: "worktree-launch-base")
            }
            if let path = checkout.path {
                detailRow(thread.workingLocation.needsWorktree ? "Target path" : "Path", path,
                          id: "worktree-launch-path")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func detailRow(_ label: String, _ value: String, id: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .accessibilityIdentifier(id)
        }
    }

    private func diagnostic(_ failure: String) -> some View {
        Text(failure)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("worktree-launch-error")
    }

    private var prompt: some View {
        Text(launch.prompt)
            .font(.system(size: 14))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("worktree-launch-prompt")
    }
}
