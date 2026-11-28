import SwiftUI

struct ComposerStashView: View {
    let entries: [StashedPrompt]
    let canRestore: Bool
    let restore: (UUID) -> Void
    let delete: (UUID) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Stash", systemImage: "bookmark")
                    .fontWeight(.semibold)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .accessibilityLabel("Close stash")
                    .accessibilityIdentifier("close-composer-stash")
            }
            if entries.isEmpty {
                Text("Nothing stashed yet. Press ⌘S with a draft to stash it.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(entries) { entry in
                            HStack {
                                Button { restore(entry.id) } label: {
                                    Text(entry.snippet)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .help("Restore stashed prompt")
                                .accessibilityLabel("Restore stashed prompt: \(entry.snippet)")
                                .accessibilityIdentifier("restore-stashed-prompt-\(entry.id)")
                                .disabled(!canRestore)
                                if !entry.attachments.isEmpty {
                                    Label("\(entry.attachments.count)", systemImage: "paperclip")
                                        .accessibilityLabel("Attachments: \(entry.attachments.count)")
                                }
                                Text(entry.createdAt, style: .relative)
                                    .help(entry.createdAt.formatted())
                                Button { delete(entry.id) } label: { Image(systemName: "trash") }
                                    .help("Delete stashed prompt")
                                    .accessibilityLabel("Delete stashed prompt")
                                    .accessibilityIdentifier("delete-stashed-prompt-\(entry.id)")
                            }
                            .foregroundStyle(.secondary)
                            .frame(height: 26)
                        }
                    }
                }
                .frame(height: CGFloat(min(entries.count, 5) * 30 - 4))
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-stash")
    }
}
