import Foundation
import SQLite3

enum WorkspaceSQLiteError: LocalizedError, Equatable {
    case invalidDatabase
    case tooLarge
    case tooManyTables
    case journaled
    case changed
    case unavailableTable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidDatabase: String(localized: "Could not read this SQLite database.")
        case .tooLarge: String(localized: "SQLite preview is limited to 50 MiB.")
        case .tooManyTables: String(localized: "SQLite preview supports up to 100 tables.")
        case .journaled: String(localized: "This database uses a journal or WAL. Open a standalone SQLite copy to preview it.")
        case .changed: String(localized: "The database changed on disk. Retry to reopen it.")
        case .unavailableTable: String(localized: "This table or page is unavailable.")
        case .timedOut: String(localized: "This database took too long to preview.")
        }
    }
}

struct WorkspaceSQLite: Sendable {
    static let byteLimit = 50 * 1024 * 1024
    static let rowsPerPage = 50
    private static let tableLimit = 100
    private static let columnLimit = 50
    private static let cellLimit = 1024
    private static let signature = Data("SQLite format 3\0".utf8)
    static let signatureLength = signature.count
    // SQLite asks callers to pad untrusted serialized data for malformed records.
    private static let padding = 32

    struct Table: Sendable {
        let name: String
        let rowCount: Int64
    }

    struct Page: Sendable {
        let columns: [String]
        let rows: [[String]]
    }

    private let bytes: Data

    static func recognizes(_ header: Data, name: String) -> Bool {
        header.starts(with: signature) ||
            ["db", "sqlite", "sqlite3"].contains((name as NSString).pathExtension.lowercased())
    }

    init(bytes: Data) throws {
        if !bytes.isEmpty {
            guard bytes.count >= 512, bytes.starts(with: Self.signature) else {
                throw WorkspaceSQLiteError.invalidDatabase
            }
            let writeVersion = bytes[bytes.startIndex + 18]
            let readVersion = bytes[bytes.startIndex + 19]
            if writeVersion == 2 || readVersion == 2 { throw WorkspaceSQLiteError.journaled }
            guard writeVersion == 1, readVersion == 1 else { throw WorkspaceSQLiteError.invalidDatabase }
        }
        self.bytes = bytes.isEmpty ? bytes : bytes + Data(count: Self.padding)
    }

    func tables() throws -> [Table] {
        try withDatabase { db in
            var names: [String] = []
            try query(db, "PRAGMA main.table_list") { row in
                let name = try identifier(row, 1)
                if string(row, 2) == "table", !name.hasPrefix("sqlite_") {
                    guard names.count < Self.tableLimit else { throw WorkspaceSQLiteError.tooManyTables }
                    names.append(name)
                }
            }
            return try names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { name in
                var count: Int64 = 0
                try query(db, "SELECT count(*) FROM main.\(quote(name))") { count = sqlite3_column_int64($0, 0) }
                return Table(name: name, rowCount: count)
            }
        }
    }

    func page(of table: Table, index: Int) throws -> Page {
        guard index >= 0, Int64(index) <= max(0, (table.rowCount - 1) / Int64(Self.rowsPerPage)) else {
            throw WorkspaceSQLiteError.unavailableTable
        }
        return try withDatabase { db in
            var columns: [String] = []
            let tableName = quote(table.name)
            try query(db, "PRAGMA main.table_xinfo(\(tableName))") { row in
                if sqlite3_column_int(row, 6) != 1, columns.count < Self.columnLimit {
                    columns.append(try identifier(row, 1))
                }
            }
            guard !columns.isEmpty else { throw WorkspaceSQLiteError.unavailableTable }
            let fields = columns.map { name in
                let column = quote(name)
                return """
                    CASE WHEN typeof(\(column)) = 'blob' THEN '[blob: ' || length(\(column)) || ' bytes]'
                    ELSE substr(CAST(\(column) AS TEXT), 1, \(Self.cellLimit)) END
                    """
            }
            var rows: [[String]] = []
            let offset = Int64(index) * Int64(Self.rowsPerPage)
            try query(db, """
                SELECT \(fields.joined(separator: ",")) FROM main.\(tableName) NOT INDEXED
                LIMIT \(Self.rowsPerPage) OFFSET \(offset)
                """) { row in
                rows.append(columns.indices.map { string(row, Int32($0)) ?? "NULL" })
            }
            return Page(columns: columns, rows: rows)
        }
    }

    private func withDatabase<Value>(_ body: (OpaquePointer) throws -> Value) throws -> Value {
        try Task.checkCancellation()
        return try bytes.withUnsafeBytes { buffer in
            var connection: OpaquePointer?
            defer { sqlite3_close(connection) }
            guard sqlite3_open(":memory:", &connection) == SQLITE_OK, let db = connection else {
                throw WorkspaceSQLiteError.invalidDatabase
            }
            if let base = buffer.bindMemory(to: UInt8.self).baseAddress, !buffer.isEmpty {
                let code = sqlite3_deserialize(db, "main", UnsafeMutablePointer(mutating: base),
                                               Int64(buffer.count - Self.padding), Int64(buffer.count),
                                               UInt32(SQLITE_DESERIALIZE_READONLY))
                guard code == SQLITE_OK else { throw WorkspaceSQLiteError.invalidDatabase }
            }
            try query(db, "PRAGMA query_only=ON")
            try query(db, "PRAGMA trusted_schema=OFF")
            try query(db, "PRAGMA temp_store=MEMORY")
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(Self.byteLimit))
            var deadline = ContinuousClock.now.advanced(by: .seconds(5))
            return try withUnsafeMutablePointer(to: &deadline) { context in
                sqlite3_progress_handler(db, 1_000, { context in
                    guard let context else { return 1 }
                    let deadline = context.assumingMemoryBound(to: ContinuousClock.Instant.self).pointee
                    return Task.isCancelled || ContinuousClock.now >= deadline ? 1 : 0
                }, context)
                defer { sqlite3_progress_handler(db, 0, nil, nil) }
                return try body(db)
            }
        }
    }

    private func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) throws -> Void = { _ in }) throws {
        try Task.checkCancellation()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_NO_VTAB), &statement, nil)
        guard prepared == SQLITE_OK, let statement else { try fail(prepared) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            case let code: try fail(code)
            }
        }
    }

    private func fail(_ code: Int32) throws -> Never {
        try Task.checkCancellation()
        if code == SQLITE_INTERRUPT { throw WorkspaceSQLiteError.timedOut }
        throw WorkspaceSQLiteError.invalidDatabase
    }

    private func string(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(row, column) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))),
                      as: UTF8.self)
    }

    private func identifier(_ row: OpaquePointer, _ column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(row, column),
              let name = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))),
                                encoding: .utf8),
              !name.utf8.contains(0) else { throw WorkspaceSQLiteError.invalidDatabase }
        return name
    }

    private func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
