import Foundation

enum SidebarThreadSection: Hashable {
    case pinned, active, snoozed, settled

    init(_ thread: Conversation, at now: Date) {
        if thread.snoozeStatus(at: now)?.isSnoozed == true {
            self = .snoozed
        } else {
            switch thread.threadShelf {
            case .active: self = .active
            case .pinned: self = .pinned
            case .settled: self = .settled
            }
        }
    }

    enum OrderedShelf: Hashable {
        case pinned, active

        var threadShelf: ThreadShelf { self == .pinned ? .pinned : .active }
        var section: SidebarThreadSection { self == .pinned ? .pinned : .active }
    }

    var orderedShelf: OrderedShelf? {
        switch self {
        case .pinned: .pinned
        case .active: .active
        case .settled, .snoozed: nil
        }
    }
}

struct SidebarThreadPlacement: Hashable {
    enum Slot: Hashable { case first, row(UUID), last }

    let shelf: SidebarThreadSection.OrderedShelf
    let slot: Slot

    func order(moving source: UUID, from section: SidebarThreadSection, among visible: [UUID]) -> [UUID]? {
        var order = visible.filter { $0 != source }
        switch slot {
        case .first: order.insert(source, at: 0)
        case .last: order.append(source)
        case .row(let target):
            guard target != source, let index = visible.firstIndex(of: target) else { return nil }
            // The original takes the target's index before removing the source. Across
            // shelves, a source below Pinned lands above its target, and vice versa.
            let offset = section == .pinned && shelf == .active ? 1 : 0
            order.insert(source, at: index + offset)
        }
        return order == visible ? nil : order
    }
}

struct SidebarThreadDragOrigin: Equatable {
    let projectID: UUID
    let threadID: UUID
    let section: SidebarThreadSection
    let snoozedUntil: Date?
    let projectScope: Set<UUID>
}

enum SidebarThreadOrder {
    typealias Shelf = SidebarThreadSection.OrderedShelf

    static func arrange(_ rows: [SidebarThread], on shelf: Shelf) -> [SidebarThread] {
        rows.map { (row: $0, key: key(for: $0.thread, on: shelf)) }.sorted { left, right in
            if let a = left.key, let b = right.key, a != b { return a < b }
            if (left.key == nil) != (right.key == nil) { return left.key != nil }
            if left.key == nil {
                let a = left.row.thread.sidebarAnchorAt ?? left.row.thread.lastActiveAt ?? .distantPast
                let b = right.row.thread.sidebarAnchorAt ?? right.row.thread.lastActiveAt ?? .distantPast
                if a != b { return a > b }
            }
            return left.row.id.uuidString < right.row.id.uuidString
        }.map(\.row)
    }

    static func key(for thread: Conversation, on shelf: Shelf) -> String? {
        if shelf == .pinned { return thread.sidebarPinOrder.flatMap(validKey) }
        if let key = thread.sidebarActiveOrder.flatMap(validKey) { return key }
        // Keep undragged Active rows in date order. The prefix leaves room to
        // insert a manual key between two date-derived keys without touching either row.
        let date = thread.sidebarAnchorAt ?? thread.lastActiveAt ?? .distantPast
        let span: Int64 = 3_670_344_486_987_776 // 26^11
        let milliseconds = date.timeIntervalSince1970 * 1000
        let value = (span / 2) - Int64(min(Double(span / 2), max(Double(1 - span / 2), milliseconds)))
        return "0" + digits(value, width: 11) + "n"
    }

    static func assignments(for order: [UUID], moving source: UUID,
                            on shelf: Shelf, threads: [Conversation]) -> [UUID: String] {
        let visible = Set(order)
        let keys = threads.reduce(into: [UUID: String]()) { keys, thread in
            if visible.contains(thread.id) {
                keys[thread.id] = key(for: thread, on: shelf)
            }
        }
        let reserved = Set(threads.filter { !visible.contains($0.id) }.compactMap { thread in
            (shelf == .pinned ? thread.sidebarPinOrder : thread.sidebarActiveOrder).flatMap(validKey)
        })
        guard let index = order.firstIndex(of: source) else { return [:] }
        let before = index > 0 ? keys[order[index - 1]] : nil
        let after = index + 1 < order.count ? keys[order[index + 1]] : nil
        if (index == 0 || before != nil), (index == order.count - 1 || after != nil) {
            var key = between(before, after)
            while let taken = key, reserved.contains(taken) { key = between(taken, after) }
            if let key { return [source: key] }
        }

        // Keyless Pinned neighbors and equal date keys require ranking the visible
        // rows together. Leave keys belonging to filtered or parked rows reserved.
        let count = order.count + reserved.count
        var width = 2
        var space: Int64 = 26 * 26
        while space <= (count + 1) * 2 {
            width += 1
            space *= 26
        }
        let keysToAssign = (1...count).lazy.map { index in
            let value = Int64((Double(space) / Double(count + 1) * Double(index)).rounded())
            return digits(value % 26 == 0 ? value + 1 : value, width: width)
        }.filter { !reserved.contains($0) }
        return Dictionary(uniqueKeysWithValues: zip(order, keysToAssign))
    }

    static func firstPin(among threads: [Conversation]) -> String? {
        between(nil, threads.compactMap { $0.sidebarPinOrder.flatMap(validKey) }.min())
    }

    private static func validKey(_ key: String) -> String? {
        let digits = key.hasPrefix("0") ? key.utf8.dropFirst() : key.utf8[...]
        guard let last = digits.last, last != 97, digits.allSatisfy({ (97...122).contains($0) }) else {
            return nil
        }
        return key
    }

    private static func between(_ before: String?, _ after: String?) -> String? {
        if let before, let after, before >= after { return nil }
        let a = before ?? ""
        let b = after ?? ""
        if b.hasPrefix("0") {
            return "0" + midpoint(a.dropFirst(a.hasPrefix("0") ? 1 : 0), b.dropFirst())
        }
        if a.hasPrefix("0") {
            return "0" + midpoint(a.dropFirst(), "")
        }
        return midpoint(a[...], b[...])
    }

    private static func midpoint(_ a: Substring, _ b: Substring) -> String {
        var a = a.utf8[...]
        var b = b.utf8[...]
        var result: [UInt8] = []
        while true {
            let low = a.popFirst() ?? 97
            let high = b.popFirst() ?? 123
            if high - low > 1 {
                result.append(UInt8((Int(low) + Int(high) + 1) / 2))
                return String(decoding: result, as: UTF8.self)
            }
            if low != high && !b.isEmpty && b.contains(where: { $0 != 97 }) {
                result.append(high)
                return String(decoding: result, as: UTF8.self)
            }
            result.append(low)
            if low != high { b = b[b.endIndex...] }
        }
    }

    private static func digits(_ number: Int64, width: Int) -> String {
        var value = number
        var result = [UInt8](repeating: 97, count: width)
        for index in result.indices.reversed() {
            result[index] += UInt8(value % 26)
            value /= 26
        }
        return String(decoding: result, as: UTF8.self)
    }
}
