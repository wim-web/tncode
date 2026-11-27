import SwiftUI

struct WelcomeProjectsSection: View {
    @ObservedObject var model: WorkspaceModel
    @State private var scanRequest = 0
    @State private var scanState = ScanState.idle
    @State private var selected = Set<PiHistoryDiscovery.FolderID>()
    @State private var actionStatus: ActionStatus?

    private enum ScanState {
        case idle, scanning, failed(String), complete(PiHistoryDiscovery.Result)
    }

    private enum ActionStatus {
        case registered, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projects")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                switch scanState {
                case .idle:
                    scanButton("Find Pi Projects", id: "welcome-find-pi-projects")
                case .scanning:
                    ProgressView().controlSize(.small).accessibilityLabel("Looking for Pi projects")
                case .failed:
                    scanButton("Retry", id: "welcome-pi-retry")
                case .complete:
                    scanButton("Scan Again", id: "welcome-pi-rescan")
                }
            }
            switch scanState {
            case .idle:
                status("Review projects and sessions from your local Pi history.")
            case .scanning:
                status("Looking for projects in local Pi history…")
            case .failed(let message):
                Text(message).foregroundStyle(.red).accessibilityIdentifier("welcome-pi-scan-error")
            case .complete(let result):
                results(result)
            }
            switch actionStatus {
            case .registered:
                Text("Selected projects registered.").accessibilityIdentifier("welcome-pi-registered")
            case .failed(let message):
                Text(message).foregroundStyle(.red).accessibilityIdentifier("welcome-pi-action-error")
            case nil:
                EmptyView()
            }
        }
        .task(id: scanRequest) {
            guard scanRequest > 0 else { return }
            let directory = PiHistoryDiscovery.localAgentDirectory
            let scan = Task.detached(priority: .userInitiated) {
                try PiHistoryDiscovery.scan(agentDirectory: directory)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: {
                    scan.cancel()
                }
                try Task.checkCancellation()
                selected.formIntersection(result.candidates.map(\.id))
                scanState = .complete(result)
            } catch {
                guard !Task.isCancelled else { return }
                scanState = .failed(error.localizedDescription)
            }
        }
    }

    private func scanButton(_ label: String, id: String) -> some View {
        Button(label) {
            actionStatus = nil
            scanState = .scanning
            scanRequest += 1
        }
        .accessibilityIdentifier(id)
    }

    private func status(_ message: String) -> some View {
        Text(message).foregroundStyle(.secondary).accessibilityIdentifier("welcome-pi-scan-status")
    }

    @ViewBuilder
    private func results(_ result: PiHistoryDiscovery.Result) -> some View {
        if result.candidates.isEmpty {
            status("No projects found in local Pi history.")
        } else {
            let registered = Set(model.workspace.projects.compactMap { PiHistoryDiscovery.FolderID($0.path) })
            let available = Set(result.candidates.map(\.id)).subtracting(registered)
            let picked = selected.intersection(available)
            HStack {
                Text("\(picked.count) selected")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("welcome-pi-selection")
                Spacer()
                Button("Select All") { selected = available }
                    .disabled(picked == available)
                    .accessibilityIdentifier("welcome-pi-select-all")
                Button("Select None") { selected.removeAll() }
                    .disabled(picked.isEmpty)
                    .accessibilityIdentifier("welcome-pi-select-none")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(result.candidates) { candidate in
                        projectRow(candidate, registered: registered.contains(candidate.id))
                    }
                }
                .padding(4)
            }
            .frame(height: 160)
            .scrollBounceBehavior(.basedOnSize)
            HStack {
                Text("Registration adds folders to your workspace. Pi sessions stay in local history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Register Selected") {
                    do {
                        try model.registerDiscoveredPiProjects(result.candidates.filter { picked.contains($0.id) })
                        selected.removeAll()
                        actionStatus = .registered
                    } catch {
                        actionStatus = .failed(error.localizedDescription)
                    }
                }
                .disabled(picked.isEmpty || model.operationsInProgress)
                .accessibilityIdentifier("welcome-pi-register")
            }
        }
        if result.skipped > 0 {
            Text("Some Pi sessions could not be read or refer to unavailable folders.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("welcome-pi-scan-skipped")
        }
        if result.limited {
            Text("Scan limit reached. Some projects or session details may be missing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("welcome-pi-scan-limit")
        }
    }

    private func projectRow(_ candidate: PiHistoryDiscovery.Candidate, registered: Bool) -> some View {
        let count = candidate.sessions.count
        let history = count == 1 ? "1 session" : "\(count) sessions"
        return HStack(alignment: .top, spacing: 8) {
            if !registered {
                Toggle("Select \(candidate.title)", isOn: Binding(
                    get: { selected.contains(candidate.id) },
                    set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Select \(candidate.title)")
                .accessibilityIdentifier("welcome-pi-select-\(candidate.folder.path)")
            }
            DisclosureGroup {
                ForEach(candidate.sessions) { session in
                    HStack {
                        Text(session.title).lineLimit(2)
                        Spacer(minLength: 12)
                        Text(session.modified, style: .date).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .accessibilityIdentifier("welcome-pi-session-\(session.id)")
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title).fontWeight(.medium)
                    Text(candidate.folder.path).lineLimit(1).truncationMode(.middle)
                    Text(registered ? "\(history) · Registered" : history)
                }
                .font(.caption)
            }
            .accessibilityIdentifier("welcome-pi-history-\(candidate.folder.path)")
            Button("Open Project") {
                do {
                    try model.openDiscoveredPiProject(candidate)
                } catch {
                    actionStatus = .failed(error.localizedDescription)
                }
            }
            .disabled(model.operationsInProgress)
            .accessibilityLabel("Open \(candidate.title)")
            .accessibilityIdentifier("welcome-pi-open-\(candidate.folder.path)")
        }
    }
}
