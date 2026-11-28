import SwiftUI

struct AgentQuestionScope: Codable, Equatable {
    let threadID: UUID
    let turnID: UUID
    let requestID: UUID
}

struct AgentQuestionRequest: Decodable {
    struct Question: Decodable, Identifiable {
        struct Option: Decodable {
            let label: String
            let description: String?
        }

        let id: String
        let header: String
        let prompt: String
        let options: [Option]
        let multiSelect: Bool
    }

    let scope: AgentQuestionScope
    let questions: [Question]
}

struct AgentQuestionEnd: Decodable {
    enum Status: String, Decodable { case answered, declined, expired, cancelled }
    let scope: AgentQuestionScope
    let status: Status
}

struct AgentQuestionReply: Encodable {
    struct Answer: Encodable {
        private enum Field: String, CodingKey { case questionID, kind, text, selected }
        enum Value {
            case text(String)
            case options([Int])
        }

        let questionID: String
        let value: Value

        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: Field.self)
            try fields.encode(questionID, forKey: .questionID)
            switch value {
            case .text(let text):
                try fields.encode("text", forKey: .kind)
                try fields.encode(text, forKey: .text)
            case .options(let selected):
                try fields.encode("options", forKey: .kind)
                try fields.encode(selected, forKey: .selected)
            }
        }
    }

    enum Decision {
        case answer([Answer])
        case decline
    }

    private enum Field: String, CodingKey { case type, scope, decision, answers }
    let scope: AgentQuestionScope
    let decision: Decision

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: Field.self)
        try fields.encode("agentQuestionResult", forKey: .type)
        try fields.encode(scope, forKey: .scope)
        switch decision {
        case .answer(let answers):
            try fields.encode("answer", forKey: .decision)
            try fields.encode(answers, forKey: .answers)
        case .decline:
            try fields.encode("decline", forKey: .decision)
        }
    }
}

private struct AgentQuestionDraft {
    struct Answer {
        static let maxLength = 4000
        var text = ""
        var selected: Set<Int> = []

        private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var tooLong: Bool { trimmed.utf16.count > Self.maxLength }

        var value: AgentQuestionReply.Answer.Value? {
            if !trimmed.isEmpty { return tooLong ? nil : .text(trimmed) }
            return selected.isEmpty ? nil : .options(selected.sorted())
        }
    }

    var index = 0
    var expanded = true
    var answers: [String: Answer] = [:]

    mutating func select(_ option: Int, in question: AgentQuestionRequest.Question) {
        var answer = answers[question.id, default: Answer()]
        if question.multiSelect {
            if answer.selected.remove(option) == nil { answer.selected.insert(option) }
        } else {
            answer.selected = [option]
        }
        answer.text = ""
        answers[question.id] = answer
    }

    mutating func setText(_ text: String, for questionID: String) {
        answers[questionID, default: Answer()].text = text
        if !text.isEmpty { answers[questionID]?.selected = [] }
    }

    func completedAnswers(for request: AgentQuestionRequest) -> [AgentQuestionReply.Answer]? {
        let completed = request.questions.compactMap { question in
            answers[question.id]?.value.map { AgentQuestionReply.Answer(questionID: question.id, value: $0) }
        }
        return completed.count == request.questions.count ? completed : nil
    }
}

struct AgentQuestionCard: View {
    let request: AgentQuestionRequest
    let submitting: Bool
    let error: String?
    let respond: (AgentQuestionReply.Decision) -> Void
    let stop: () -> Void
    @State private var draft = AgentQuestionDraft()

    var body: some View {
        let question = request.questions[draft.index]
        let answer = draft.answers[question.id, default: .init()]
        let last = draft.index == request.questions.count - 1
        let completed = draft.completedAnswers(for: request)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    draft.expanded.toggle()
                } label: {
                    Label {
                        Text(verbatim: question.header).lineLimit(1)
                    } icon: {
                        Image(systemName: draft.expanded ? "chevron.down" : "chevron.right")
                    }
                    .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityHint(draft.expanded ? "Hide the question and its options" : "Show the question and its options")
                .accessibilityIdentifier("agent-question-toggle")
                Spacer()
                if request.questions.count > 1 {
                    Text("\(draft.index + 1) of \(request.questions.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("agent-question-progress")
                }
                Button {
                    respond(.decline)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(submitting)
                .help("Dismiss question without answering")
                .accessibilityLabel("Dismiss question without answering")
                .accessibilityIdentifier("agent-question-dismiss")
            }
            if draft.expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(formattedPrompt(question.prompt))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("agent-question-prompt")
                        ForEach(question.options.indices, id: \.self) { index in
                            let option = question.options[index]
                            let selected = answer.selected.contains(index)
                            Button {
                                draft.select(index, in: question)
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: optionIcon(selected: selected, multiSelect: question.multiSelect))
                                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: option.label)
                                        if let description = option.description {
                                            Text(verbatim: description).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("agent-question-option-\(index)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(question.id)
                }
                .frame(maxHeight: 140)
                .scrollBounceBehavior(.basedOnSize)
                .disabled(submitting)
                TextField(question.options.isEmpty ? "Type an answer" : "Or type an answer", text: Binding(
                    get: { draft.answers[question.id]?.text ?? "" },
                    set: { draft.setText($0, for: question.id) }
                ))
                .textFieldStyle(.roundedBorder)
                .id(question.id)
                .disabled(submitting)
                .accessibilityIdentifier("agent-question-answer")
            }
            if answer.tooLong {
                Text("Shorten your answer to 4,000 characters or fewer.").font(.caption).foregroundStyle(.red)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if draft.index > 0 {
                    Button("Previous") { draft.index -= 1 }
                        .disabled(submitting)
                        .accessibilityLabel("Previous question")
                        .accessibilityIdentifier("agent-question-previous")
                }
                Spacer()
                if last {
                    Button(request.questions.count == 1 ? "Submit Answer" : "Submit Answers") {
                        if let completed { respond(.answer(completed)) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting || completed == nil)
                    .accessibilityIdentifier("agent-question-submit")
                } else {
                    Button("Next") { draft.index += 1 }
                        .buttonStyle(.borderedProminent)
                        .disabled(submitting || answer.value == nil)
                        .accessibilityLabel("Next question")
                        .accessibilityIdentifier("agent-question-next")
                }
                Button(action: stop) { Image(systemName: "stop.fill") }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("stop-message")
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-question")
    }

    private func optionIcon(selected: Bool, multiSelect: Bool) -> String {
        if multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func formattedPrompt(_ prompt: String) -> AttributedString {
        var formatted = (try? AttributedString(markdown: prompt, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(prompt)
        formatted.link = nil
        return formatted
    }
}
