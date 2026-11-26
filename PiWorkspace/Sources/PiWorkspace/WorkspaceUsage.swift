import Darwin
import Foundation

enum UsagePeriod: Int, CaseIterable, Identifiable {
    case pastDay = 1, week = 7, month = 30, quarter = 90

    var id: Self { self }

    var title: String {
        self == .pastDay ? "Past 24h" : "\(rawValue) days"
    }

    func window(at now: Date, calendar: Calendar) -> Range<Date> {
        if self == .pastDay {
            let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
            return end.addingTimeInterval(-86_400)..<end
        }
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: 1 - rawValue, to: today) ?? today
        let nextDay = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return firstDay..<nextDay
    }

    func bucket(for date: Date, calendar: Calendar) -> Date {
        self == .pastDay ? calendar.dateInterval(of: .hour, for: date)?.start ?? date : calendar.startOfDay(for: date)
    }
}

enum UsageToken: String, CodingKey, CaseIterable, Sendable {
    case total = "totalTokens"
    case input, output, cacheRead, cacheWrite

    var title: String {
        switch self {
        case .total: "Tokens"
        case .input: "Input tokens"
        case .output: "Output tokens"
        case .cacheRead: "Cache read tokens"
        case .cacheWrite: "Cache write tokens"
        }
    }
}

struct UsageModel: Hashable, Identifiable, Sendable {
    let provider: String?
    let model: String?

    var id: Self { self }
    var title: String { model ?? "Unknown model" }

    var providerTitle: String {
        guard let provider else { return "Unknown provider" }
        return Provider(rawValue: provider)?.label ?? provider
    }
}

enum UsageProject: Hashable, Sendable {
    case project(UUID)
    case scratch
}

struct UsageTotals: Sendable {
    struct Amount: Sendable {
        private(set) var sum: Decimal = 0
        private(set) var recorded = 0

        mutating func add(_ value: Decimal) {
            sum += value
            recorded += 1
        }
    }

    private(set) var responses = 0
    private(set) var tokens: [UsageToken: Amount] = [:]
    private(set) var cost = Amount()
    private(set) var reportedCosts = 0

    fileprivate mutating func add(_ entry: UsageEntry) {
        responses += 1
        for (token, value) in entry.tokens {
            tokens[token, default: Amount()].add(value)
        }
        if let value = entry.cost {
            cost.add(value.amount)
            if value.fromProvider { reportedCosts += 1 }
        }
    }
}

struct UsageReadout {
    fileprivate(set) var total = UsageTotals()
    fileprivate(set) var models: [UsageModel: UsageTotals] = [:]
    fileprivate(set) var times: [Date: UsageTotals] = [:]
}

struct WorkspaceUsage: Sendable {
    let readAt: Date
    let calendar: Calendar
    private let entries: [UsageEntry]
    private let incomplete: [UsageProject: Int]

    var providers: Set<String?> { Set(entries.map(\.model.provider)) }

    func incompleteHistories(in project: UsageProject?) -> Int {
        project.map { incomplete[$0, default: 0] } ?? incomplete.values.reduce(0, +)
    }

    func readout(period: UsagePeriod, project: UsageProject?, hiddenProviders: Set<String?> = [],
                 model: UsageModel? = nil) -> UsageReadout {
        let window = period.window(at: readAt, calendar: calendar)
        var result = UsageReadout()
        for entry in entries where window.contains(entry.date) && !hiddenProviders.contains(entry.model.provider) {
            if let project, !entry.projects.contains(project) { continue }
            if let model, entry.model != model { continue }
            result.total.add(entry)
            result.models[entry.model, default: UsageTotals()].add(entry)
            let bucket = period.bucket(for: entry.date, calendar: calendar)
            result.times[bucket, default: UsageTotals()].add(entry)
        }
        return result
    }

    static func load(root: URL, projects: [Project], now: Date = .now,
                     calendar: Calendar = .current) async throws -> Self {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try scan(root: root, projects: projects, now: now, calendar: calendar)
        }
        return try await withTaskCancellationHandler {
            let snapshot = try await worker.value
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            worker.cancel()
        }
    }

    private static func scan(root: URL, projects: [Project], now: Date, calendar: Calendar) throws -> Self {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceHistory.accessError(errno) }
        defer { close(fd) }

        var recorded: [UsageEntry.Identity: UsageEntry] = [:]
        var incomplete: [UsageProject: Int] = [:]
        let earliest = UsagePeriod.quarter.window(at: now, calendar: calendar).lowerBound
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)

        for project in projects {
            let scope: UsageProject = project.isScratch ? .scratch : .project(project.id)
            for thread in project.conversations {
                try Task.checkCancellation()
                do {
                    guard let file = try WorkspaceHistory.open(in: fd, projectID: project.id, threadID: thread.id) else {
                        if thread.isDraft == false || thread.forkOrigin != nil { incomplete[scope, default: 0] += 1 }
                        continue
                    }
                    defer { try? file.close() }
                    var hasHeader = false
                    var damaged = false
                    try WorkspaceHistory.readLines(in: file) { line in
                        guard !line.isEmpty else { return }
                        if !hasHeader {
                            let header = try decoder.decode(SessionHeader.self, from: line)
                            guard header.type == "session", header.id == thread.id.uuidString, header.version >= 2 else {
                                throw WorkspaceError("Unsupported conversation history.")
                            }
                            hasHeader = true
                            return
                        }
                        guard let line = try? decoder.decode(SessionLine.self, from: line) else {
                            damaged = true
                            return
                        }
                        guard let assistant = line.assistant else { return }
                        guard let identity = line.identity,
                              let date = assistant.date ?? formatter.date(from: identity.timestamp) else {
                            damaged = true
                            return
                        }
                        guard (earliest...now).contains(date) else { return }

                        // Pi preserves entry IDs and append timestamps when copying a branch.
                        // IDs alone are only unique within a file.
                        if recorded[identity] != nil {
                            recorded[identity]?.projects.insert(scope)
                        } else {
                            recorded[identity] = UsageEntry(date: date, model: assistant.model, projects: [scope],
                                                            tokens: assistant.tokens, cost: assistant.cost)
                        }
                    }
                    if !hasHeader || damaged { incomplete[scope, default: 0] += 1 }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    incomplete[scope, default: 0] += 1
                }
            }
        }
        return Self(readAt: now, calendar: calendar, entries: Array(recorded.values), incomplete: incomplete)
    }

    private struct SessionHeader: Decodable {
        let type: String
        let id: String
        let version: Int
    }

    private struct SessionLine: Decodable {
        let identity: UsageEntry.Identity?
        let assistant: Assistant?

        private enum Field: String, CodingKey { case type, id, timestamp, message }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Field.self)
            if try fields.decode(String.self, forKey: .type) == "message" {
                let message = try fields.decode(Assistant.self, forKey: .message)
                if message.role == "assistant" {
                    assistant = message
                    identity = try UsageEntry.Identity(id: fields.decode(String.self, forKey: .id),
                                                       timestamp: fields.decode(String.self, forKey: .timestamp),
                                                       model: message.model)
                    return
                }
            }
            identity = nil
            assistant = nil
        }
    }

    private struct Assistant: Decodable {
        let role: String
        let date: Date?
        let model: UsageModel
        let tokens: [UsageToken: Decimal]
        let cost: UsageEntry.Cost?

        private enum Field: String, CodingKey { case role, timestamp, provider, model, usage }
        private enum CostField: String, CodingKey { case cost, total, totalFromProvider }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Field.self)
            role = try fields.decode(String.self, forKey: .role)
            let milliseconds = try? fields.decode(Double.self, forKey: .timestamp)
            date = milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }

            func name(_ key: Field) -> String? {
                guard let value = try? fields.decode(String.self, forKey: key), !value.isEmpty else { return nil }
                return value
            }
            model = UsageModel(provider: name(.provider), model: name(.model))

            if role == "assistant", let usage = try? fields.superDecoder(forKey: .usage) {
                tokens = Self.readTokens(from: usage)
                cost = Self.readCost(from: usage)
            } else {
                tokens = [:]
                cost = nil
            }
        }

        private static func readTokens(from decoder: Decoder) -> [UsageToken: Decimal] {
            guard let fields = try? decoder.container(keyedBy: UsageToken.self) else { return [:] }
            var values: [UsageToken: Decimal] = [:]
            for category in UsageToken.allCases {
                if let count = try? fields.decode(Int64.self, forKey: category), count >= 0 {
                    values[category] = Decimal(count)
                }
            }
            // Pi initializes all counts to zero when a stream supplies no accounting.
            guard values.values.contains(where: { $0 > 0 }) else { return [:] }
            if (values[.total] ?? 0) == 0 {
                values[.total] = nil
                if values.count == UsageToken.allCases.count - 1 {
                    values[.total] = values.values.reduce(0, +)
                }
            }
            return values
        }

        private static func readCost(from decoder: Decoder) -> UsageEntry.Cost? {
            guard let usage = try? decoder.container(keyedBy: CostField.self),
                  let fields = try? usage.nestedContainer(keyedBy: CostField.self, forKey: .cost),
                  let amount = try? fields.decode(Decimal.self, forKey: .total), amount >= 0 else { return nil }
            let fromProvider = (try? fields.decode(Bool.self, forKey: .totalFromProvider)) == true
            // An unconfirmed zero also represents a missing catalog price, including local models.
            guard amount > 0 || fromProvider else { return nil }
            return UsageEntry.Cost(amount: amount, fromProvider: fromProvider)
        }
    }
}

private struct UsageEntry: Sendable {
    struct Identity: Hashable {
        let id: String
        let timestamp: String
        let model: UsageModel
    }

    struct Cost: Sendable {
        let amount: Decimal
        let fromProvider: Bool
    }

    let date: Date
    let model: UsageModel
    var projects: Set<UsageProject>
    let tokens: [UsageToken: Decimal]
    let cost: Cost?
}
