import SwiftUI

struct PullRequestCodeView: View {
    private enum Target: Hashable {
        case page
        case file(Int)
    }

    private struct Request: Hashable {
        let target: Target
        let attempt: Int
    }

    private enum Phase {
        case loading, ready, failed(Error)
    }

    let reader: GitHubReader
    let details: GitHubPullRequestDetails
    let refresh: () -> Void
    @State private var request = Request(target: .page, attempt: 0)
    @State private var phase = Phase.loading
    @State private var files: [GitHubPullRequestFile] = []
    @State private var lastPage: GitHubPullRequestFilePage?
    @State private var selection: Int?

    var body: some View {
        let request = request
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: "#\(details.reference.number) \(details.pullRequest.title)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Link("Open files on GitHub", destination: details.url.appendingPathComponent("files"))
                    .font(.caption)
                    .fixedSize()
                    .accessibilityIdentifier("pr-files-open")
            }
            .padding(12)
            Divider()
            if case .failed(let error) = phase, requiresRefresh(error) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error.localizedDescription).accessibilityIdentifier("pr-files-stale")
                    Button("Load latest changes", action: refresh)
                        .accessibilityIdentifier("pr-files-refresh")
                }
                .padding(12)
            } else if let lastPage {
                if files.isEmpty && lastPage.fileCount == 0 {
                    Text("This pull request has no file changes.")
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .accessibilityIdentifier("pr-files-empty")
                } else {
                    HStack(spacing: 0) {
                        diff
                        Divider()
                        fileList(lastPage)
                            .frame(width: 168)
                    }
                }
            } else {
                pageStatus
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: request) { await load(request) }
    }

    private func fileList(_ page: GitHubPullRequestFilePage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Changed files")
                .font(.caption.weight(.semibold))
                .padding(8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(files.indices, id: \.self) { index in
                        fileRow(files[index], at: index)
                    }
                }
                .padding(4)
            }
            .accessibilityLabel("Pull request #\(details.reference.number) files")
            .accessibilityIdentifier("pr-files-list")
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("\(files.count) of \(page.fileCount) files")
                    .accessibilityIdentifier("pr-files-count")
                if request.target == .page {
                    pageStatus
                }
                if page.nextPage != nil, canLoadMore {
                    Button("Load more files") { begin(.page) }
                        .accessibilityIdentifier("pr-files-load-more")
                } else if page.nextPage == nil, files.count < page.fileCount {
                    Text("GitHub returned a partial file list.")
                        .accessibilityIdentifier("pr-files-partial")
                }
            }
            .font(.caption)
            .padding(8)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var canLoadMore: Bool {
        if request.target != .page { return true }
        if case .ready = phase { return true }
        return false
    }

    private func fileRow(_ file: GitHubPullRequestFile, at index: Int) -> some View {
        let selected = request.target == .file(index) || selection == index
        return Button { begin(.file(index)) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.statusLabel) · +\(file.additions) −\(file.deletions)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(5)
            .background(selected ? Color.accentColor.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("pr-file-row-\(index)")
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection {
                patch(files[selection])
                    .id(selection)
            } else if case .file = request.target {
                switch phase {
                case .loading:
                    ProgressView("Loading file diff…")
                        .controlSize(.small)
                        .accessibilityIdentifier("pr-file-diff-loading")
                case .failed(let error):
                    Text(error.localizedDescription).accessibilityIdentifier("pr-file-diff-error")
                    Button("Retry") { begin(request.target) }
                        .accessibilityIdentifier("pr-file-diff-retry")
                case .ready:
                    EmptyView()
                }
            } else {
                Text("Select a changed file").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func patch(_ file: GitHubPullRequestFile) -> some View {
        Text(verbatim: file.path)
            .font(.callout.weight(.semibold))
            .accessibilityIdentifier("pr-file-diff-path")
        if let previousPath = file.previousPath {
            Text("Previously \(previousPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pr-file-diff-previous-path")
        }
        switch file.patch {
        case .text(let text, let partial):
            if partial {
                Text("GitHub supplied part of this diff.")
                    .font(.caption)
                    .accessibilityIdentifier("pr-file-diff-partial")
            }
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .accessibilityIdentifier("pr-file-diff-text")
            }
        case .unavailable:
            Text("GitHub didn’t supply a text diff for this file.")
                .accessibilityIdentifier("pr-file-diff-unavailable")
        case .tooLarge:
            Text("This diff is too large to display here.")
                .accessibilityIdentifier("pr-file-diff-too-large")
        }
    }

    @ViewBuilder
    private var pageStatus: some View {
        switch phase {
        case .loading:
            ProgressView(lastPage == nil ? "Loading changed files…" : "Loading more files…")
                .controlSize(.small)
                .accessibilityIdentifier("pr-files-loading")
        case .failed(let error):
            Text(error.localizedDescription).accessibilityIdentifier("pr-files-error")
            Button("Retry") { begin(.page) }
                .accessibilityIdentifier("pr-files-retry")
        case .ready:
            EmptyView()
        }
    }

    private func requiresRefresh(_ error: Error) -> Bool {
        if error is GitHubPullRequestFilesError { return true }
        if case .repositoryChanged = error as? GitHubReader.ReadError { return true }
        return false
    }

    private func begin(_ target: Target) {
        if case .file = target { selection = nil }
        phase = .loading
        request = Request(target: target, attempt: request.attempt + 1)
    }

    @MainActor
    private func load(_ request: Request) async {
        guard !Task.isCancelled, request == self.request else { return }
        do {
            switch request.target {
            case .page:
                let page = try await reader.pullRequestFiles(in: details, after: lastPage)
                guard !Task.isCancelled, request == self.request else { return }
                files.append(contentsOf: page.files)
                lastPage = page
            case .file(let index):
                guard let lastPage else { return }
                try await reader.validatePullRequestFiles(lastPage, for: details.reference)
                guard !Task.isCancelled, request == self.request else { return }
                selection = index
            }
            phase = .ready
        } catch {
            guard !Task.isCancelled, request == self.request else { return }
            phase = .failed(error)
        }
    }
}
