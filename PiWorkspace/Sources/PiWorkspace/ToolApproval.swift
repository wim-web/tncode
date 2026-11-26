import SwiftUI

enum ToolPermission: String, CaseIterable, Encodable {
    case readFiles, supervised, shellAndEdits

    var title: String {
        switch self {
        case .readFiles: "Read files"
        case .supervised: "Supervised"
        case .shellAndEdits: "Shell and edits"
        }
    }

    var icon: String {
        switch self {
        case .readFiles: "lock.shield"
        case .supervised: "checkmark.shield"
        case .shellAndEdits: "terminal"
        }
    }
}

struct ToolApproval: Decodable {
    let requestID: String
    let threadID: UUID
    let turnID: UUID
    let tool: String
    let details: String
}

enum ToolApprovalDecision: String, Encodable {
    case approve, decline
}

struct ToolApprovalResult: Encodable {
    let type = "toolApprovalResult"
    let requestID: String
    let threadID: UUID
    let turnID: UUID
    let decision: ToolApprovalDecision

    init(_ approval: ToolApproval, decision: ToolApprovalDecision) {
        requestID = approval.requestID
        threadID = approval.threadID
        turnID = approval.turnID
        self.decision = decision
    }
}

struct ToolApprovalCard: View {
    let approval: ToolApproval
    let directory: String
    let respond: (ToolApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allow \(approval.tool)?", systemImage: "checkmark.shield")
                .font(.callout.weight(.semibold))
            Text(verbatim: directory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ScrollView {
                Text(verbatim: approval.details)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
            .accessibilityIdentifier("tool-approval-details")
            HStack {
                Spacer()
                Button("Decline") { respond(.decline) }
                    .accessibilityIdentifier("decline-tool")
                Button("Approve") { respond(.approve) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("approve-tool")
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-approval")
    }
}
