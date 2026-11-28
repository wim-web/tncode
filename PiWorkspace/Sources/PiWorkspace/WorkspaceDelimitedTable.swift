import Foundation

struct WorkspaceDelimitedTable: Sendable {
    enum Delimiter: UInt8, Sendable {
        case comma = 44
        case tab = 9
        case semicolon = 59
    }

    enum ParseError: LocalizedError {
        case unclosedQuote(row: Int)
        case charactersAfterQuote(row: Int, byte: UInt8)

        var errorDescription: String? {
            switch self {
            case .unclosedQuote(let row): String(localized: "Unclosed quoted field in row \(row).")
            case .charactersAfterQuote(let row, _): String(localized: "Unexpected characters after a quoted field in row \(row).")
            }
        }
    }

    private enum Field {
        case unquoted
        case quoted
        case closedQuote
    }

    private static let columnLimit = 1024
    let rows: [[String]]
    let columnCount: Int
    let clippedColumns: Bool

    init(text: String, delimiter: Delimiter) throws {
        let bytes = Array(text.utf8)
        let start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        let separator = delimiter == .comma ? Self.csvDelimiter(bytes[start...]) : delimiter
        do {
            self = try Self(bytes: bytes, start: start, separator: separator)
        } catch let original as ParseError {
            guard delimiter == .comma, case let .charactersAfterQuote(_, byte) = original,
                  let alternate = Delimiter(rawValue: byte), alternate == .comma || alternate == .semicolon else {
                throw original
            }
            do { self = try Self(bytes: bytes, start: start, separator: alternate) }
            catch is ParseError { throw original }
        }
    }

    private init(bytes: [UInt8], start: Int, separator: Delimiter) throws {
        var index = start
        var recordStart = start
        var field = Field.unquoted
        var cell: [UInt8] = []
        var row: [String] = []
        var rows: [[String]] = []
        var columns = 0
        var clipped = false

        func endCell() {
            if row.count < Self.columnLimit {
                row.append(String(decoding: cell, as: UTF8.self))
            } else {
                clipped = true
            }
            cell.removeAll(keepingCapacity: true)
            field = .unquoted
        }

        func endRow() {
            columns = max(columns, row.count)
            rows.append(row)
            row = []
        }

        while index < bytes.count {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                switch field {
                case .quoted: field = .closedQuote
                case .closedQuote:
                    cell.append(byte)
                    field = .quoted
                case .unquoted:
                    if cell.isEmpty { field = .quoted } else { cell.append(byte) }
                }
            } else if field == .quoted {
                cell.append(byte)
            } else if byte == separator.rawValue {
                endCell()
            } else if byte == 10 || byte == 13 {
                endCell()
                endRow()
                if byte == 13, index < bytes.count, bytes[index] == 10 { index += 1 }
                recordStart = index
            } else {
                guard field != .closedQuote else { throw ParseError.charactersAfterQuote(row: rows.count + 1, byte: byte) }
                cell.append(byte)
            }
        }

        guard field != .quoted else { throw ParseError.unclosedQuote(row: rows.count + 1) }
        if recordStart < bytes.count {
            endCell()
            endRow()
        }
        self.rows = rows
        columnCount = columns
        clippedColumns = clipped
    }

    private static func csvDelimiter(_ bytes: ArraySlice<UInt8>) -> Delimiter {
        // Compare the first two logical records. Delimiters inside quoted fields do not count.
        var commas = [0, 0]
        var semicolons = [0, 0]
        var row = 0
        var hasSecondRow = false
        var quoted = false
        var fieldStart = true
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            if quoted {
                if byte == 34 {
                    if index < bytes.endIndex, bytes[index] == 34 { index += 1 }
                    else { quoted = false }
                }
                continue
            }
            if byte == 10 || byte == 13 {
                if row == 1 { break }
                if byte == 13, index < bytes.endIndex, bytes[index] == 10 { index += 1 }
                row = 1
                fieldStart = true
                continue
            }
            hasSecondRow = row == 1
            if byte == 34 && fieldStart { quoted = true }
            if byte == Delimiter.comma.rawValue { commas[row] += 1 }
            if byte == Delimiter.semicolon.rawValue { semicolons[row] += 1 }
            fieldStart = byte == Delimiter.comma.rawValue || byte == Delimiter.semicolon.rawValue
        }
        guard semicolons[0] > commas[0] else { return .comma }
        let consistentCommas = commas[0] > 0 && commas[0] == commas[1]
        return !hasSecondRow || (semicolons[0] == semicolons[1] && !consistentCommas) ? .semicolon : .comma
    }
}
