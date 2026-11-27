import SwiftUI

struct SnoozeOptionsSettingsView: View {
    private struct Row: Identifiable {
        let id = UUID()
        var option: ThreadSnoozeSchedule.Option
    }

    private let model: WorkspaceModel
    private let settingsFocus: FocusState<SettingsFocus?>.Binding
    @State private var rows: [Row]
    @State private var error: String?
    @State private var hoveringList = false
    @State private var editingRow: UUID?
    @FocusState private var focus: SnoozeOptionFocus?

    init(model: WorkspaceModel, settingsFocus: FocusState<SettingsFocus?>.Binding) {
        self.model = model
        self.settingsFocus = settingsFocus
        _rows = State(initialValue: Self.sorted(model.workspace.effectiveSnoozeOptions.map(Row.init(option:)),
                                                at: model.snoozeOptionsTime))
    }

    private var options: [ThreadSnoozeSchedule.Option] { rows.map(\.option) }
    private var atLimit: Bool { rows.count >= ThreadSnoozeSchedule.maximumOptions }
    private var shouldSettle: Bool { focus == nil && editingRow == nil && !hoveringList }
    private var canReset: Bool {
        options.map(\.id).sorted() != ThreadSnoozeSchedule.defaultOptions.map(\.id).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Snooze options")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .focusable()
                    .settingsTarget(.snoozeOptions, focus: settingsFocus)
                Spacer()
                if canReset {
                    Button("Reset to defaults") {
                        if save(ThreadSnoozeSchedule.defaultOptions.map(Row.init(option:))) { settle() }
                    }
                    .accessibilityLabel("Reset snooze options to default")
                    .accessibilityIdentifier("reset-snooze-options")
                }
            }
            Text("Choices in every snooze menu, listed soonest first. Weekdays mean the next one after today.")
                .foregroundStyle(.secondary)
                .font(.callout)
            TimelineView(.everyMinute) { _ in
                optionList(at: model.snoozeOptionsTime)
            }
            .onHover { hoveringList = $0 }
            .task(id: shouldSettle) {
                await Task.yield()
                if !Task.isCancelled, shouldSettle { settle() }
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("snooze-options-save-error")
            }
        }
    }

    private func optionList(at now: Date) -> some View {
        let previewTime = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        let resolved = options.map { $0.resolve(at: previewTime) }
        let menu = ThreadSnoozeSchedule.presets(at: previewTime, options: options)
        let labels = menu.map { preset in
            menu.filter { $0.label == preset.label }.count == 1 ? preset.label : preview(preset, at: now)
        }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack {
                    SnoozeOptionFields(option: row.option, number: index + 1, id: row.id, focus: $focus) { editing in
                        if editing { editingRow = row.id }
                        else if editingRow == row.id { editingRow = nil }
                    } save: { option in
                        save(rows.map { current in
                            guard current.id == row.id else { return current }
                            var updated = current
                            updated.option = option
                            return updated
                        })
                    }
                    Spacer(minLength: 8)
                    Text(rowPreview(resolved, at: index, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        save(rows.filter { $0.id != row.id })
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Remove snooze option \(index + 1)")
                    .accessibilityIdentifier("remove-snooze-option-\(index + 1)")
                    .focused($focus, equals: .remove(row.id))
                }
            }
            Text(labels.isEmpty ? "Menus offer only Custom…" : "Menu now: \(labels.joined(separator: " · "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("snooze-options-menu-preview")
            HStack {
                Button {
                    save(rows + [Row(option: ThreadSnoozeSchedule.nextOption(in: options))])
                } label: {
                    Label("Add option", systemImage: "plus")
                }
                .accessibilityIdentifier("add-snooze-option")
                .disabled(atLimit)
                .focused($focus, equals: .add)
                if atLimit {
                    Text("Up to \(ThreadSnoozeSchedule.maximumOptions) options")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rowPreview(_ resolved: [ThreadSnoozeSchedule.Preset?], at index: Int, now: Date) -> String {
        guard let preset = resolved[index] else { return "Passed for today" }
        let earlier = resolved.prefix(index).compactMap { $0 }
        if earlier.contains(where: { $0.id == preset.id }) { return "Duplicate of an option above" }
        if earlier.contains(where: { $0.shownDeadline == preset.shownDeadline }) { return "Same time as an option above" }
        return preview(preset, at: now)
    }

    private func preview(_ preset: ThreadSnoozeSchedule.Preset, at now: Date) -> String {
        "\(preset.label) · \(ThreadSnoozeSchedule.deadlineLabel(preset.shownDeadline, after: now))"
    }

    @discardableResult
    private func save(_ updated: [Row]) -> Bool {
        do {
            try model.updateSnoozeOptions(updated.map(\.option))
            rows = updated
            error = nil
            return true
        } catch {
            self.error = "Could not save snooze options. \(error.localizedDescription)"
            return false
        }
    }

    private func settle() {
        rows = Self.sorted(rows, at: model.snoozeOptionsTime)
    }

    private static func sorted(_ rows: [Row], at now: Date) -> [Row] {
        let minute = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        return rows.map { ($0, $0.option.resolve(at: minute)?.shownDeadline ?? .distantFuture) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }
}

private enum SnoozeOptionFocus: Hashable {
    case when(UUID), unit(UUID), step(UUID), remove(UUID), add
}

private struct SnoozeOptionFields: View {
    private typealias Schedule = ThreadSnoozeSchedule

    private enum When: Hashable {
        case after, at(Schedule.Day)
    }

    private let option: Schedule.Option
    let number: Int
    let id: UUID
    let focus: FocusState<SnoozeOptionFocus?>.Binding
    let editingChanged: (Bool) -> Void
    private let save: (Schedule.Option) -> Bool
    @State private var lastMinutes = 60
    @State private var lastTime = "09:00"
    @State private var chosenUnit: Schedule.Unit

    init(option: ThreadSnoozeSchedule.Option, number: Int, id: UUID,
         focus: FocusState<SnoozeOptionFocus?>.Binding, editingChanged: @escaping (Bool) -> Void,
         save: @escaping (ThreadSnoozeSchedule.Option) -> Bool) {
        self.option = option
        self.number = number
        self.id = id
        self.focus = focus
        self.editingChanged = editingChanged
        self.save = save
        if case let .after(minutes) = option {
            _chosenUnit = State(initialValue: .forMinutes(minutes))
        } else {
            _chosenUnit = State(initialValue: .hours)
        }
    }

    private var when: When {
        switch option {
        case .after: .after
        case let .at(day, _): .at(day)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("When", selection: Binding(get: { when }, set: changeWhen)) {
                Text("In").tag(When.after)
                ForEach(Schedule.Day.allCases, id: \.self) { day in
                    Text(day.rawValue.capitalized).tag(When.at(day))
                }
            }
            .labelsHidden()
            .frame(width: 113)
            .accessibilityIdentifier("snooze-option-when-\(number)")
            .focused(focus, equals: .when(id))

            switch option {
            case let .after(minutes):
                let unit = resolvedUnit(minutes)
                let amount = minutes / unit.minutesPerUnit
                valueField("Amount", value: String(amount), identifier: "snooze-option-amount-\(number)") { input in
                    guard let value = Double(input.trimmingCharacters(in: .whitespacesAndNewlines)),
                          value.isFinite else { return String(amount) }
                    let maximum = Double(Schedule.maximumMinutes / unit.minutesPerUnit)
                    let next = Int(min(maximum, max(1, value.rounded())))
                    return String(saveAmount(next, in: unit) ? next : amount)
                }
                    .frame(width: 54)
                Stepper(value: Binding(get: { amount }, set: { _ = saveAmount($0, in: unit) }),
                        in: 1...(Schedule.maximumMinutes / unit.minutesPerUnit)) {
                    Text("Amount")
                }
                .labelsHidden()
                .accessibilityIdentifier("snooze-option-step-\(number)")
                .focused(focus, equals: .step(id))
                Picker("Unit", selection: Binding(get: { unit }, set: { changeUnit($0, amount: amount) })) {
                    ForEach(Schedule.Unit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .labelsHidden()
                .frame(width: 87)
                .accessibilityIdentifier("snooze-option-unit-\(number)")
                .focused(focus, equals: .unit(id))
            case let .at(day, time):
                Text("at").foregroundStyle(.secondary)
                valueField("Time", value: time, identifier: "snooze-option-time-\(number)") { input in
                    let next = Schedule.Option.at(day: day, time: input)
                    return next.isValid && (next == option || save(next)) ? input : time
                }
                    .frame(width: 70)
            }
        }
    }

    private func valueField(_ label: String, value: String, identifier: String,
                            commit: @escaping (String) -> String) -> some View {
        SnoozeOptionTextField(label: label, identifier: identifier, value: value,
                              commit: commit, editingChanged: editingChanged)
            .accessibilityIdentifier(identifier)
    }

    private func changeWhen(_ next: When) {
        guard when != next else { return }
        switch (next, option) {
        case let (.after, .at(_, time)):
            if save(.after(minutes: lastMinutes)) { lastTime = time }
        case let (.at(day), .after(minutes)):
            if save(.at(day: day, time: lastTime)) { lastMinutes = minutes }
        case let (.at(day), .at(_, time)):
            _ = save(.at(day: day, time: time))
        case (.after, .after): break
        }
    }

    private func changeUnit(_ unit: Schedule.Unit, amount: Int) {
        let next = Schedule.Option.after(minutes: min(amount * unit.minutesPerUnit, Schedule.maximumMinutes))
        if save(next) { chosenUnit = unit }
    }

    private func saveAmount(_ amount: Int, in unit: Schedule.Unit) -> Bool {
        let next = Schedule.Option.after(minutes: amount * unit.minutesPerUnit)
        return next == option || save(next)
    }

    private func resolvedUnit(_ minutes: Int) -> Schedule.Unit {
        minutes.isMultiple(of: chosenUnit.minutesPerUnit) ? chosenUnit : .forMinutes(minutes)
    }
}

private struct SnoozeOptionTextField: NSViewRepresentable {
    let label: String
    let identifier: String
    let value: String
    let commit: (String) -> String
    let editingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: value)
        field.bezelStyle = .roundedBezel
        field.setAccessibilityLabel(label)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.setAccessibilityIdentifier(identifier)
        if field.currentEditor() == nil, field.stringValue != value { field.stringValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SnoozeOptionTextField

        init(parent: SnoozeOptionTextField) { self.parent = parent }

        @objc func submit(_ field: NSTextField) {
            let accepted = parent.commit(field.stringValue)
            if field.stringValue != accepted { field.stringValue = accepted }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.editingChanged(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { submit(field) }
            parent.editingChanged(false)
        }
    }
}
