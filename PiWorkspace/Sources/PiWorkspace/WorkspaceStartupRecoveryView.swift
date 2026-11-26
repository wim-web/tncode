import AppKit
import SwiftUI

struct WorkspaceStartupRecoveryView: View {
    let model: WorkspaceModel
    let failure: WorkspaceStoreError

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Could Not Open Workspace")
                .font(.title.weight(.semibold))
            Text(failure.localizedDescription)
                .accessibilityIdentifier("workspace-startup-error")
            Text(model.root.path)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if failure.canRestore {
                Text("Restoring can roll back recent changes to the project and thread list. The app keeps conversation files and a copy of any damaged index.")
                    .foregroundStyle(.secondary)
            } else if case .inUse = failure {
                Text("Quit the other instance of Pi Workspace, then choose Retry.")
                    .foregroundStyle(.secondary)
            } else {
                Text("After resolving the issue, choose Retry.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .accessibilityIdentifier("workspace-startup-quit")
                Button("Copy Details", action: copyDetails)
                    .accessibilityIdentifier("workspace-startup-copy-details")
                Spacer()
                if failure.canRestore {
                    Button("Restore Previous Workspace") { model.openWorkspace(restoringPrevious: true) }
                        .accessibilityIdentifier("workspace-startup-restore")
                }
                Button("Retry") { model.openWorkspace() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("workspace-startup-retry")
            }
        }
        .padding(32)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyDetails() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let details = ["Pi Workspace \(version)", model.root.path, failure.localizedDescription]
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }
}
