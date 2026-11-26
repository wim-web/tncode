import SwiftUI

struct WorktreeLaunchView: View {
    let launch: WorktreeLaunch
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.preparingWorktree {
                Text(launch.stage.label)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("worktree-launch-stage")
                if let failure = launch.failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("worktree-launch-error")
                } else if launch.awaitingHistory && model.phase == .ready {
                    Text("Pi could not confirm that it recorded this message.")
                        .font(.callout)
                }
            }
            ViewThatFits(in: .vertical) {
                prompt
                ScrollView { prompt }
            }
            .frame(maxHeight: 120)
            if model.canRetryWorktree {
                Button("Retry", action: model.retryWorktree)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retry-worktree")
            } else if launch.awaitingHistory && model.phase == .ready && model.conversation?.archived == false {
                Button("Dismiss Pending Message", action: model.dismissUnconfirmedWorktreePrompt)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 15))
    }

    private var prompt: some View {
        Text(launch.prompt)
            .font(.system(size: 14))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("worktree-launch-prompt")
    }
}
