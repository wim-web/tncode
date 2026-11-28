import AppKit
import SwiftUI

struct WorkspaceStartupRecoveryView: View {
    let model: WorkspaceModel
    let failure: WorkspaceStoreError
    let pasteboard: NSPasteboard

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
                Text("Quit the other instance of tncode, then choose Retry.")
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
        let info = AboutInfo()
        let product = [info.name, info.version].compactMap { $0 }.joined(separator: " ")
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown architecture"
        #endif
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let platform = "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion) \(architecture)"
        let details = [String(localized: "\(product) (\(platform)) could not open its workspace."),
                       String(localized: "Workspace: \(model.root.path)")]
            + failure.diagnosticLines(root: model.root)
        pasteboard.clearContents()
        pasteboard.setString(details.joined(separator: "\n"), forType: .string)
    }
}
