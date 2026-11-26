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
    enum Unit: String, CaseIterable, Identifiable {
        case minutes = "Minutes"
        case hours = "Hours"
        case days = "Days"

        var id: Self { self }
        var seconds: TimeInterval {
            switch self {
            case .minutes: 60
            case .hours: 3600
            case .days: 86400
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

    static func presets(at now: Date, calendar: Calendar = localCalendar) -> [Preset] {
        let daysToMonday = (9 - calendar.component(.weekday, from: now)) % 7
        var presets = [
            Preset(id: "one-hour", label: "In 1 hour", shownDeadline: now.addingTimeInterval(3600), elapsed: 3600),
            Preset(id: "three-hours", label: "In 3 hours", shownDeadline: now.addingTimeInterval(10800), elapsed: 10800)
        ]
        let localTimes = [
            ("this-evening", "This evening", 0, 18),
            ("tomorrow", "Tomorrow", 1, 9),
            ("next-week", daysToMonday == 1 ? "Tomorrow" : "Next week", daysToMonday == 0 ? 7 : daysToMonday, 9)
        ]
        for (id, label, days, hour) in localTimes {
            if let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)),
               let deadline = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day,
                                             matchingPolicy: .nextTimePreservingSmallerComponents),
               deadline > now {
                presets.append(Preset(id: id, label: label, shownDeadline: deadline))
            }
        }
        var minutes = Set<Double>()
        let wakeMinute: (Preset) -> Double = { floor($0.shownDeadline.timeIntervalSince1970 / 60) }
        return presets.sorted { wakeMinute($0) < wakeMinute($1) }
            .filter { minutes.insert(wakeMinute($0)).inserted }
    }

    static func localFields(for date: Date, calendar: Calendar = localCalendar) -> (date: String, time: String) {
        (formatted(date, as: "yyyy-MM-dd", calendar: calendar),
         formatted(date, as: "HH:mm", calendar: calendar))
    }

    static func deadline(date: String, time: String, after now: Date, calendar: Calendar = localCalendar) -> Date? {
        let dayParts = date.split(separator: "-", omittingEmptySubsequences: false)
        let timeParts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard dayParts.map(\.count) == [4, 2, 2], timeParts.map(\.count) == [2, 2],
              let year = Int(dayParts[0]), let month = Int(dayParts[1]), let day = Int(dayParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute),
              let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              let wake = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start,
                                       matchingPolicy: .strict, repeatedTimePolicy: .first),
              localFields(for: wake, calendar: calendar) == (date, time),
              isFuture(wake, after: now) else { return nil }
        return wake
    }

    static func deadline(amount: String, unit: Unit, after now: Date) -> Date? {
        guard let amount = Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)), amount > 0 else { return nil }
        let wake = now.addingTimeInterval(amount * unit.seconds)
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
}
