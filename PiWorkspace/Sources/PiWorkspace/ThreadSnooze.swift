import Foundation

struct ThreadSnoozeTarget: Hashable {
    let projectID: UUID
    let threadID: UUID
}

enum ThreadSnoozeStatus: Equatable {
    case snoozed(until: Date)
    case woke(at: Date)

    var isSnoozed: Bool {
        if case .snoozed = self { return true }
        return false
    }
}

enum ThreadSnoozeSchedule {
    static let maximumOptions = 8
    static let maximumMinutes = 30 * 24 * 60

    enum Unit: String, CaseIterable, Identifiable {
        case minutes = "Minutes"
        case hours = "Hours"
        case days = "Days"

        var id: Self { self }
        var minutesPerUnit: Int {
            switch self {
            case .minutes: 1
            case .hours: 60
            case .days: 1440
            }
        }

        static func forMinutes(_ minutes: Int) -> Self {
            allCases.reversed().first { minutes.isMultiple(of: $0.minutesPerUnit) } ?? .minutes
        }
    }

    enum Day: String, Codable, CaseIterable {
        case today, tomorrow, monday, tuesday, wednesday, thursday, friday, saturday, sunday

        private var weekday: Int? {
            switch self {
            case .today, .tomorrow: nil
            case .sunday: 1
            case .monday: 2
            case .tuesday: 3
            case .wednesday: 4
            case .thursday: 5
            case .friday: 6
            case .saturday: 7
            }
        }

        func daysAhead(at now: Date, calendar: Calendar) -> Int {
            guard let weekday else { return self == .today ? 0 : 1 }
            let gap = (weekday - calendar.component(.weekday, from: now) + 7) % 7
            return gap == 0 ? 7 : gap
        }
    }

    enum Option: Codable, Hashable {
        case after(minutes: Int)
        case at(day: Day, time: String)

        var isValid: Bool {
            switch self {
            case let .after(minutes): (1...maximumMinutes).contains(minutes)
            case let .at(_, time): clockComponents(time) != nil
            }
        }

        var id: String {
            switch self {
            case .after(60): "one-hour"
            case .after(180): "three-hours"
            case .at(.today, "18:00"): "this-evening"
            case .at(.tomorrow, "09:00"): "tomorrow"
            case .at(.monday, "09:00"): "next-week"
            case let .after(minutes): "after-\(minutes)"
            case let .at(day, time): "at-\(day.rawValue)-\(time)"
            }
        }

        func resolve(at now: Date, calendar: Calendar = localCalendar) -> Preset? {
            guard isValid else { return nil }
            switch self {
            case let .after(minutes):
                let unit = Unit.forMinutes(minutes)
                let amount = minutes / unit.minutesPerUnit
                let name = unit.rawValue.lowercased()
                let elapsed = TimeInterval(minutes * 60)
                return Preset(id: id, label: "In \(amount) \(amount == 1 ? String(name.dropLast()) : name)",
                              shownDeadline: now.addingTimeInterval(elapsed), elapsed: elapsed)
            case let .at(day, time):
                let days = day.daysAhead(at: now, calendar: calendar)
                guard let (hour, minute) = clockComponents(time),
                      let date = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)),
                      let deadline = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date,
                                                   matchingPolicy: .nextTimePreservingSmallerComponents),
                      deadline > now else { return nil }
                let label: String
                switch days {
                case 0: label = hour < 12 ? "This morning" : hour < 17 ? "This afternoon" : "This evening"
                case 1: label = "Tomorrow"
                default:
                    let name = day.rawValue.capitalized
                    label = day == .monday ? "Next week" : days == 7 ? "Next \(name)" : name
                }
                return Preset(id: id, label: label, shownDeadline: deadline)
            }
        }
    }

    struct Preset: Identifiable {
        let id: String
        let label: String
        let shownDeadline: Date
        var elapsed: TimeInterval? = nil

        func deadline(at now: Date) -> Date {
            elapsed.map { now.addingTimeInterval($0) } ?? shownDeadline
        }
    }

    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static let defaultOptions: [Option] = [
        .after(minutes: 60), .after(minutes: 180), .at(day: .today, time: "18:00"),
        .at(day: .tomorrow, time: "09:00"), .at(day: .monday, time: "09:00")
    ]

    static func nextOption(in options: [Option]) -> Option {
        let candidates = defaultOptions + [.after(minutes: 30), .at(day: .saturday, time: "09:00"),
                                            .after(minutes: 1440)]
        return candidates.first { !options.contains($0) } ?? .after(minutes: 60)
    }

    static func presets(at now: Date, options: [Option] = defaultOptions,
                        calendar: Calendar = localCalendar) -> [Preset] {
        var minutes = Set<Double>()
        let wakeMinute: (Preset) -> Double = { floor($0.shownDeadline.timeIntervalSince1970 / 60) }
        return options.compactMap { $0.resolve(at: now, calendar: calendar) }
            .sorted { wakeMinute($0) < wakeMinute($1) }
            .filter { minutes.insert(wakeMinute($0)).inserted }
    }

    static func localFields(for date: Date, calendar: Calendar = localCalendar) -> (date: String, time: String) {
        (formatted(date, as: "yyyy-MM-dd", calendar: calendar),
         formatted(date, as: "HH:mm", calendar: calendar))
    }

    static func deadline(date: String, time: String, after now: Date, calendar: Calendar = localCalendar) -> Date? {
        let dayParts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard dayParts.map(\.count) == [4, 2, 2],
              let year = Int(dayParts[0]), let month = Int(dayParts[1]), let day = Int(dayParts[2]),
              let (hour, minute) = clockComponents(time),
              let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              let wake = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start,
                                       matchingPolicy: .strict, repeatedTimePolicy: .first),
              localFields(for: wake, calendar: calendar) == (date, time),
              isFuture(wake, after: now) else { return nil }
        return wake
    }

    static func deadline(amount: String, unit: Unit, after now: Date) -> Date? {
        guard let amount = Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)), amount > 0 else { return nil }
        let wake = now.addingTimeInterval(amount * TimeInterval(unit.minutesPerUnit * 60))
        return isFuture(wake, after: now) ? wake : nil
    }

    static func isFuture(_ date: Date, after now: Date) -> Bool {
        date > now && abs(date.timeIntervalSince1970) <= 8_640_000_000_000
    }

    static func deadlineLabel(_ deadline: Date, after now: Date) -> String {
        let style: Date.FormatStyle = localCalendar.isDate(deadline, inSameDayAs: now)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        return deadline.formatted(style)
    }

    private static func formatted(_ date: Date, as format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func clockComponents(_ time: String) -> (hour: Int, minute: Int)? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [2, 2], parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), hour < 24, minute < 60 else { return nil }
        return (hour, minute)
    }
}
