import Charts
import SwiftUI

struct UsageSettingsView: View {
    let root: URL
    let projects: [Project]

    @AppStorage("usagePeriod") private var period = UsagePeriod.month
    @AppStorage("usageMetric") private var metric = UsageMetric.tokens
    @AppStorage("usageHiddenProviders") private var savedHiddenProviders = Data()
    @State private var project: UsageProject?
    @State private var breakdown = Breakdown.model
    @State private var selectedModel: UsageModel?
    @State private var snapshot: WorkspaceUsage?
    @State private var scanFailed = false
    @State private var refreshing = true
    @State private var refresh = 0

    private enum Breakdown: Hashable { case model, time }

    private var hiddenProviders: Set<String?> {
        (try? JSONDecoder().decode(Set<String?>.self, from: savedHiddenProviders)) ?? []
    }

    private var projectOptions: [(id: UsageProject, title: String)] {
        let folders = projects.filter { !$0.isScratch }.map {
            (UsageProject.project($0.id), $0.title + ($0.detached == true ? " (Detached)" : ""))
        }
        return projects.contains(where: \.isScratch) ? folders + [(.scratch, "No project")] : folders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Local workspace").font(.headline)
                Spacer()
                Picker("Usage metric", selection: $metric) {
                    ForEach(UsageMetric.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                .accessibilityLabel("Usage metric")
                .accessibilityIdentifier("usage-metric")
            }

            if metric == .limits {
                Text("Live provider limits are unavailable in this workspace.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("usage-limits-unavailable")
            } else {
                filters
                if refreshing && snapshot == nil {
                    ProgressView("Reading saved usage…")
                }
                if scanFailed {
                    Text("Could not read saved usage. Refresh to try again.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("usage-read-error")
                }
                if let snapshot {
                    results(snapshot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: refresh) {
            refreshing = true
            scanFailed = false
            do {
                snapshot = try await WorkspaceUsage.load(root: root, projects: projects)
            } catch is CancellationError {
                return
            } catch {
                scanFailed = true
            }
            refreshing = false
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Usage period", selection: $period) {
                    ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel("Usage period")
                .accessibilityIdentifier("usage-period")

                Spacer()
                Button {
                    refresh += 1
                } label: {
                    Label("Refresh usage", systemImage: "arrow.clockwise")
                }
                .disabled(refreshing)
                .accessibilityIdentifier("usage-refresh")
            }
            HStack {
                Picker("Project", selection: $project) {
                    Text("All projects").tag(nil as UsageProject?)
                    ForEach(projectOptions, id: \.id) { option in
                        Text(option.title).tag(Optional(option.id))
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("usage-project")

                Menu {
                    Button("All providers") { saveHiddenProviders([]) }
                        .accessibilityIdentifier("usage-provider-all")
                    ForEach((snapshot?.providers ?? []).sorted(by: providerOrder), id: \.self) { provider in
                        Toggle(providerName(provider), isOn: Binding(
                            get: { !hiddenProviders.contains(provider) },
                            set: { visible in
                                var hidden = hiddenProviders
                                if visible { hidden.remove(provider) } else { hidden.insert(provider) }
                                saveHiddenProviders(hidden)
                            }
                        ))
                        .accessibilityIdentifier("usage-provider-\(provider ?? "unidentified")")
                    }
                } label: {
                    Text(providerFilterTitle)
                }
                .fixedSize()
                .accessibilityLabel("Usage providers")
                .accessibilityValue(providerFilterTitle)
                .accessibilityIdentifier("usage-providers")
                .disabled(snapshot?.providers.isEmpty != false)
                Spacer()
                if refreshing && snapshot != nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing usage")
                }
            }
        }
        .onChange(of: project) { selectedModel = nil }
        .onChange(of: savedHiddenProviders) { selectedModel = nil }
    }

    private var providerFilterTitle: String {
        guard let snapshot else { return "All providers" }
        let visible = snapshot.providers.subtracting(hiddenProviders)
        if visible.count == snapshot.providers.count { return "All providers" }
        if visible.count == 1, let provider = visible.first { return providerName(provider) }
        return visible.isEmpty ? "No providers" : "\(visible.count) providers"
    }

    private func providerName(_ provider: String?) -> String {
        UsageModel(provider: provider, model: nil).providerTitle
    }

    private func providerOrder(_ a: String?, _ b: String?) -> Bool {
        providerName(a).localizedStandardCompare(providerName(b)) == .orderedAscending
    }

    private func saveHiddenProviders(_ providers: Set<String?>) {
        if let data = try? JSONEncoder().encode(providers) { savedHiddenProviders = data }
    }

    private func results(_ snapshot: WorkspaceUsage) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if snapshot.incompleteHistories(in: project) > 0 {
                        Text("Some saved histories could not be fully read.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("usage-incomplete-histories")
                    }
                    if let selectedModel {
                        modelDetail(selectedModel, snapshot: snapshot)
                    } else {
                        overview(snapshot)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("usage-results-start")
            }
            .onChange(of: selectedModel) { reader.scrollTo("usage-results-start", anchor: .top) }
        }
    }

    @ViewBuilder
    private func overview(_ snapshot: WorkspaceUsage) -> some View {
        let readout = snapshot.readout(period: period, project: project, hiddenProviders: hiddenProviders)
        if readout.total.responses == 0 {
            Text("No saved assistant messages for these filters and period.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("usage-empty")
        } else {
            summary(readout.total, id: "usage")
            timelineChart(readout, snapshot: snapshot)
            Picker("Usage breakdown", selection: $breakdown) {
                Text("Model").tag(Breakdown.model)
                Text(period == .pastDay ? "Hour" : "Day").tag(Breakdown.time)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel("Usage breakdown")
            .accessibilityIdentifier("usage-breakdown")

            if breakdown == .model {
                let models = readout.models.sorted { lhs, rhs in
                    let a = metric.amount(in: lhs.value).sum
                    let b = metric.amount(in: rhs.value).sum
                    if a != b { return a > b }
                    return (lhs.key.title, lhs.key.providerTitle, lhs.key.provider ?? "")
                        < (rhs.key.title, rhs.key.providerTitle, rhs.key.provider ?? "")
                }
                VStack(spacing: 0) {
                    ForEach(models, id: \.key) { row in
                        Button { selectedModel = row.key } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.key.title)
                                    Text(row.key.providerTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(metric.formatted(row.value)).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(row.key.title), \(row.key.providerTitle)")
                        .accessibilityValue(metric.formatted(row.value))
                        .accessibilityIdentifier("usage-model-\(row.key.provider ?? "unidentified")-\(row.key.model ?? "unidentified")")
                        Divider()
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("usage-model-list")
            } else {
                timelineRows(readout)
            }
        }
    }

    private func modelDetail(_ model: UsageModel, snapshot: WorkspaceUsage) -> some View {
        let readout = snapshot.readout(period: period, project: project, hiddenProviders: hiddenProviders, model: model)
        return VStack(alignment: .leading, spacing: 12) {
            Button("Back to usage", systemImage: "chevron.left") { selectedModel = nil }
                .accessibilityIdentifier("usage-model-back")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("usage-model-heading")
                Text(model.providerTitle).foregroundStyle(.secondary)
            }
            summary(readout.total, id: "usage-detail")
            VStack(spacing: 0) {
                ForEach(UsageToken.allCases, id: \.self) { category in
                    let amount = readout.total.tokens[category, default: .init()]
                    detailRow(category.title, value: UsageMetric.tokens.formatted(amount, responses: readout.total.responses),
                              id: "usage-detail-\(category.rawValue)")
                }
                detailRow("Saved USD cost", value: UsageMetric.cost.formatted(readout.total), id: "usage-detail-cost")
                if let basis = costBasis(readout.total), metric != .cost {
                    Text(basis)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 5)
                }
            }
            timelineChart(readout, snapshot: snapshot)
            timelineRows(readout)
        }
    }

    private func summary(_ totals: UsageTotals, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.formatted(totals))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .accessibilityIdentifier("\(id)-total")
            Text(totals.responses == 1 ? "1 assistant message" : "\(totals.responses.formatted()) assistant messages")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(id)-responses")
            if metric == .cost, let basis = costBasis(totals) {
                Text(basis).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(id)-cost-basis")
            }
        }
    }

    private func costBasis(_ totals: UsageTotals) -> String? {
        guard totals.cost.recorded > 0 else { return nil }
        if totals.reportedCosts == 0 { return "Pi estimates in USD" }
        if totals.reportedCosts == totals.cost.recorded { return "Provider-reported cost in USD" }
        return "Provider-reported cost and Pi estimates in USD"
    }

    @ViewBuilder
    private func timelineChart(_ readout: UsageReadout, snapshot: WorkspaceUsage) -> some View {
        if metric.amount(in: readout.total).sum > 0 {
            let unit: Calendar.Component = period == .pastDay ? .hour : .day
            let window = period.window(at: snapshot.readAt, calendar: snapshot.calendar)
            let start = period.bucket(for: window.lowerBound, calendar: snapshot.calendar)
            let lastBucket = period.bucket(for: window.upperBound.addingTimeInterval(-1), calendar: snapshot.calendar)
            let end = snapshot.calendar.date(byAdding: unit, value: 1, to: lastBucket) ?? snapshot.readAt
            let reported = readout.times.filter { metric.amount(in: $0.value).recorded > 0 }
            Chart(reported.sorted { $0.key < $1.key }, id: \.key) { row in
                BarMark(x: .value("Time", row.key, unit: unit, calendar: snapshot.calendar),
                        y: .value(metric.title, NSDecimalNumber(decimal: metric.amount(in: row.value).sum).doubleValue))
            }
            .chartXScale(domain: start...end)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
            .frame(height: 104)
            .accessibilityHidden(true)
        }
    }

    private func timelineRows(_ readout: UsageReadout) -> some View {
        VStack(spacing: 0) {
            ForEach(readout.times.sorted { $0.key > $1.key }, id: \.key) { row in
                let date = period == .pastDay
                    ? row.key.formatted(.dateTime.month(.abbreviated).day().hour().minute().timeZone())
                    : row.key.formatted(.dateTime.month(.abbreviated).day().year())
                detailRow(date, value: metric.formatted(row.value), id: "usage-time-\(Int(row.key.timeIntervalSince1970))")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-time-list")
    }

    private func detailRow(_ label: String, value: String, id: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                Spacer()
                Text(value)
                    .monospacedDigit()
                    .accessibilityIdentifier(id)
            }
            .padding(.vertical, 5)
            Divider()
        }
    }
}

private enum UsageMetric: String, CaseIterable, Identifiable {
    case tokens, cost, limits

    var id: Self { self }
    var title: String { rawValue.capitalized }

    func amount(in totals: UsageTotals) -> UsageTotals.Amount {
        self == .cost ? totals.cost : totals.tokens[.total, default: .init()]
    }

    func formatted(_ totals: UsageTotals) -> String {
        formatted(amount(in: totals), responses: totals.responses)
    }

    func formatted(_ amount: UsageTotals.Amount, responses: Int) -> String {
        guard amount.recorded > 0 else { return self == .cost ? "Unknown cost" : "Unknown tokens" }
        let value = self == .cost
            ? amount.sum.formatted(.currency(code: "USD").precision(.fractionLength(2...8)))
            : "\(amount.sum.formatted(.number.precision(.fractionLength(0)))) tokens"
        return amount.recorded < responses ? "\(value) + unreported" : value
    }
}
