import Foundation
import zlib

struct WorkspaceZIP {
    let bytes: Data

    private struct Directory {
        let end: Int
        let start: Int
        let base: Int
        let count: Int
    }

    private static let localSignature = 0x04034b50
    private static let directorySignature = 0x02014b50
    private static let endSignature = 0x06054b50

    func entries() throws -> [WorkspaceArchive.Entry] {
        let directory = try directory()
        var offset = directory.start
        var expanded = 0
        var compressedBudget = directory.start - directory.base
        var entries: [WorkspaceArchive.Entry] = []
        let limit = WorkspaceArchive.expansionLimit(bytes.count)
        while offset < directory.end {
            try Task.checkCancellation()
            guard entries.count < WorkspaceArchive.entryLimit else { throw WorkspaceArchiveError.tooManyEntries }
            guard directory.end - offset >= 46, uint(offset, 4) == Self.directorySignature else {
                throw WorkspaceArchiveError.damaged
            }
            let flags = uint(offset + 8, 2)
            let method = uint(offset + 10, 2)
            guard flags & 0x41 == 0, method == 0 || method == 8 else { throw WorkspaceArchiveError.unsupportedZIP }
            let nameStart = offset + 46
            let nameLength = uint(offset + 28, 2)
            let extraStart = nameStart + nameLength
            let extraEnd = extraStart + uint(offset + 30, 2)
            let next = extraEnd + uint(offset + 32, 2)
            guard next <= directory.end else { throw WorkspaceArchiveError.damaged }
            guard nameLength <= WorkspaceArchive.pathLimit else { throw WorkspaceArchiveError.pathTooLong }
            let name = bytes[nameStart..<extraStart]
            let fields = try extraFields(extraStart..<extraEnd)
            let path: String
            if flags & 0x800 == 0, let unicode = fields[0x7075], unicode.count >= 5,
               bytes[unicode.lowerBound] == 1, uint(unicode.lowerBound + 1, 4) == crc(name) {
                path = String(decoding: bytes[(unicode.lowerBound + 5)..<unicode.upperBound], as: UTF8.self)
            } else {
                path = String(decoding: name, as: UTF8.self)
            }
            guard path.utf16.count <= WorkspaceArchive.pathLimit else { throw WorkspaceArchiveError.pathTooLong }
            guard !path.isEmpty, !path.utf8.contains(0) else { throw WorkspaceArchiveError.damaged }

            var zip64 = fields[1]
            let size = try zip64Value(uint(offset + 24, 4), from: &zip64)
            let compressed = try zip64Value(uint(offset + 20, 4), from: &zip64)
            let localOffset = try zip64Value(uint(offset + 42, 4), from: &zip64)
            guard uint(offset + 34, 2) == 0 else { throw WorkspaceArchiveError.unsupportedZIP }
            guard size <= limit - expanded, !path.hasSuffix(".xml") || size <= 8 * 1024 * 1024 else {
                throw WorkspaceArchiveError.expandedTooLarge
            }
            guard localOffset <= directory.start - directory.base else { throw WorkspaceArchiveError.damaged }
            let local = directory.base + localOffset
            guard directory.start - local >= 30, uint(local, 4) == Self.localSignature,
                  uint(local + 6, 2) == flags, uint(local + 8, 2) == method else {
                throw WorkspaceArchiveError.damaged
            }
            let payload = local + 30 + uint(local + 26, 2) + uint(local + 28, 2)
            guard payload <= directory.start, compressed <= directory.start - payload,
                  compressed <= compressedBudget else {
                throw WorkspaceArchiveError.damaged
            }
            compressedBudget -= compressed
            let input = bytes[payload..<(payload + compressed)]
            let content: Data
            if method == 0 {
                content = input
            } else {
                content = try WorkspaceArchive.inflate(input, wrapper: .zip, limit: size)
            }
            guard content.count == size, crc(content) == uint(offset + 16, 4) else {
                throw WorkspaceArchiveError.damaged
            }
            expanded += size
            let directoryFlag = path.hasSuffix("/") || uint(offset + 38, 1) & 0x10 != 0
            let kind: WorkspaceArchive.Entry.Kind = directoryFlag ? .directory :
                .file(size <= WorkspaceArchive.entryByteLimit ? Data(content) : nil)
            entries.append(.init(path: path, size: size,
                                 modified: date(day: uint(offset + 14, 2), time: uint(offset + 12, 2)), kind: kind))
            offset = next
        }
        guard entries.count == directory.count else { throw WorkspaceArchiveError.damaged }
        return entries
    }

    private func directory() throws -> Directory {
        guard bytes.count >= 22,
              let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
                .first(where: { uint($0, 4) == Self.endSignature && $0 + 22 + uint($0 + 20, 2) == bytes.count }) else {
            throw WorkspaceArchiveError.damaged
        }
        let count = uint(end + 10, 2)
        let size = uint(end + 12, 4)
        let start = uint(end + 16, 4)
        if count == 0xffff || size == 0xffffffff || start == 0xffffffff {
            return try zip64Directory(end: end)
        }
        guard uint(end + 4, 2) == 0, uint(end + 6, 2) == 0, uint(end + 8, 2) == count else {
            throw WorkspaceArchiveError.unsupportedZIP
        }
        return try directory(end: end, size: size, start: start, count: count)
    }

    private func zip64Directory(end: Int) throws -> Directory {
        let locator = end - 20
        let record = locator - 56
        guard record >= 0, uint(locator, 4) == 0x07064b50, uint(record, 4) == 0x06064b50,
              uint(record + 4, 8) == 44, uint(record + 16, 4) == 0, uint(record + 20, 4) == 0,
              uint(locator + 4, 4) == 0, uint(locator + 8, 8) == record, uint(locator + 16, 4) == 1 else {
            throw WorkspaceArchiveError.unsupportedZIP
        }
        let count = uint(record + 32, 8)
        guard uint(record + 24, 8) == count else { throw WorkspaceArchiveError.damaged }
        let result = try directory(end: record, size: uint(record + 40, 8), start: uint(record + 48, 8), count: count)
        guard result.base == 0 else { throw WorkspaceArchiveError.unsupportedZIP }
        return result
    }

    private func directory(end: Int, size: Int, start: Int, count: Int) throws -> Directory {
        guard count <= WorkspaceArchive.entryLimit else { throw WorkspaceArchiveError.tooManyEntries }
        guard size <= end, start <= end - size else { throw WorkspaceArchiveError.damaged }
        return Directory(end: end, start: end - size, base: end - size - start, count: count)
    }

    private func extraFields(_ range: Range<Int>) throws -> [Int: Range<Int>] {
        var offset = range.lowerBound
        var fields: [Int: Range<Int>] = [:]
        while offset < range.upperBound {
            guard range.upperBound - offset >= 4 else { throw WorkspaceArchiveError.damaged }
            let start = offset + 4
            let end = start + uint(offset + 2, 2)
            guard end <= range.upperBound else { throw WorkspaceArchiveError.damaged }
            let id = uint(offset, 2)
            if id == 1 || id == 0x7075 { fields[id] = start..<end }
            offset = end
        }
        return fields
    }

    private func zip64Value(_ value: Int, from field: inout Range<Int>?) throws -> Int {
        guard value == 0xffffffff else { return value }
        guard let range = field, range.count >= 8 else { throw WorkspaceArchiveError.damaged }
        field = (range.lowerBound + 8)..<range.upperBound
        return uint(range.lowerBound, 8)
    }

    private func uint(_ offset: Int, _ count: Int) -> Int {
        var value: UInt64 = 0
        for index in (offset..<(offset + count)).reversed() {
            value = (value << 8) | UInt64(bytes[index])
        }
        return Int(clamping: value)
    }

    private func crc(_ data: Data) -> Int {
        data.withUnsafeBytes { buffer in
            Int(crc32(0, buffer.bindMemory(to: UInt8.self).baseAddress, UInt32(buffer.count)))
        }
    }

    private func date(day: Int, time: Int) -> Date? {
        guard day & 31 > 0, (1...12).contains((day >> 5) & 15) else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(
            year: 1980 + (day >> 9), month: (day >> 5) & 15, day: day & 31,
            hour: time >> 11, minute: (time >> 5) & 63, second: (time & 31) * 2))
    }
}
