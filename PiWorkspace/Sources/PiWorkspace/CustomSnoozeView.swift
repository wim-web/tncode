import SwiftUI

struct CustomSnoozeView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case date = "Date and time"
        case duration = "Duration"

        var id: Self { self }
    }

    @State private var mode: Mode = .date
    @State private var date: String
    @State private var time: String
    @State private var amount = "2"
    @State private var unit: ThreadSnoozeSchedule.Unit = .hours
    @State private var error: String?

    let model: WorkspaceModel
    let target: ThreadSnoozeTarget
    let editOptions: () -> Void
    let close: (Bool) -> Void

    init(model: WorkspaceModel, target: ThreadSnoozeTarget, editOptions: @escaping () -> Void,
         close: @escaping (Bool) -> Void) {
        self.model = model
        self.target = target
        self.editOptions = editOptions
        self.close = close
        let fields = ThreadSnoozeSchedule.localFields(for: model.initialCustomSnoozeDate)
        _date = State(initialValue: fields.date)
        _time = State(initialValue: fields.time)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom snooze").font(.headline)
            Picker("Schedule type", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("snooze-schedule-type")
            .onChange(of: mode) { error = nil }

            if mode == .date {
                HStack {
                    TextField("Date", text: $date, prompt: Text("YYYY-MM-DD"))
                        .accessibilityIdentifier("snooze-date")
                    TextField("Time", text: $time, prompt: Text("HH:MM"))
                        .accessibilityIdentifier("snooze-time")
                }
            } else {
                HStack {
                    TextField("Snooze for", text: $amount)
                        .accessibilityIdentifier("snooze-duration")
                    Picker("Unit", selection: $unit) {
                        ForEach(ThreadSnoozeSchedule.Unit.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .accessibilityIdentifier("snooze-duration-unit")
                }
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("snooze-validation-error")
            }
            HStack {
                Button("Edit snooze options", action: editOptions)
                    .accessibilityIdentifier("edit-snooze-options")
                Spacer()
                Button("Cancel") { close(false) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancel-custom-snooze")
                Button("Snooze", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirm-custom-snooze")
            }
        }
        .padding(20)
        .frame(width: 390)
    }

    private func submit() {
        do {
            switch mode {
            case .date: try model.snooze(target, date: date, time: time)
            case .duration: try model.snooze(target, amount: amount, unit: unit)
            }
            close(true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
