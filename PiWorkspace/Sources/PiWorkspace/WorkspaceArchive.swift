import Foundation
import zlib

enum WorkspaceArchiveError: LocalizedError, Equatable {
    case tooLarge, expandedTooLarge, tooManyEntries, pathTooLong
    case damaged, unsupportedZIP, unsupportedTARNumber, metadataTooLarge, empty
    case changed, entryTooLarge, unsupportedEntry

    var errorDescription: String? {
        switch self {
        case .tooLarge: "Preview limited to archives of 50 MiB or smaller."
        case .expandedTooLarge: "This archive expands beyond the preview limit."
        case .tooManyEntries: "Preview limited to 2,048 archive entries."
        case .pathTooLong: "An archive entry path exceeds the preview limit."
        case .damaged: "This archive is unreadable or damaged."
        case .unsupportedZIP: "This ZIP uses encryption or an unsupported ZIP feature."
        case .unsupportedTARNumber: "This TAR uses an unsupported numeric format."
        case .metadataTooLarge: "Archive metadata is too large."
        case .empty: "This archive has no readable entries."
        case .changed: "The archive changed on disk. Retry to reopen it."
        case .entryTooLarge: "Entry previews are limited to 10 MiB."
        case .unsupportedEntry: "Only UTF-8 text and images can be opened inside an archive."
        }
    }
}

struct WorkspaceArchive: Sendable {
    static let byteLimit = 50 * 1024 * 1024
    static let entryLimit = 2_048
    static let pathLimit = 1_024
    static let entryByteLimit = 10 * 1024 * 1024

    struct Entry: Sendable {
        let path: String
        let size: Int
        let modified: Date?
        let kind: Kind

        enum Kind: Sendable {
            case directory
            case file(Data?)
        }
    }

    enum Format {
        case zip, tar, gzip, compressedTAR

        init?(name: String) {
            let name = name.lowercased()
            if name.hasSuffix(".tar.gz") { self = .compressedTAR; return }
            switch name.split(separator: ".", omittingEmptySubsequences: false).dropFirst().last {
            case "zip", "jar": self = .zip
            case "tar": self = .tar
            case "gz": self = .gzip
            case "tgz": self = .compressedTAR
            default: return nil
            }
        }

        func read(_ bytes: Data, name: String) throws -> [Entry] {
            guard bytes.count <= WorkspaceArchive.byteLimit else { throw WorkspaceArchiveError.tooLarge }
            let signature = bytes.prefix(4)
            if self == .zip || signature == Data([0x50, 0x4b, 0x03, 0x04]) ||
                signature == Data([0x50, 0x4b, 0x05, 0x06]) {
                return try WorkspaceZIP(bytes: bytes).entries()
            }
            if self == .gzip || self == .compressedTAR || bytes.first == 0x1f {
                let expanded = try WorkspaceArchive.inflate(bytes, wrapper: .gzip,
                                                            limit: WorkspaceArchive.expansionLimit(bytes.count))
                if self == .compressedTAR || self == .tar { return try WorkspaceArchive.tarEntries(expanded) }
                let path = name.lowercased().hasSuffix(".gz") ? String(name.dropLast(3)) : name
                return [Entry(path: path.isEmpty ? "contents" : path, size: expanded.count, modified: nil,
                              kind: .file(expanded.count <= WorkspaceArchive.entryByteLimit ? expanded : nil))]
            }
            return try WorkspaceArchive.tarEntries(bytes)
        }
    }

    static func expansionLimit(_ inputSize: Int) -> Int {
        min(byteLimit, inputSize * 200)
    }

    enum DeflateWrapper: Int32 {
        case zip = -15
        case gzip = 31
    }

    static func inflate(_ bytes: Data, wrapper: DeflateWrapper, limit: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, wrapper.rawValue, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WorkspaceArchiveError.damaged
        }
        defer { inflateEnd(&stream) }

        return try bytes.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(input.count)
            var scratch = [UInt8](repeating: 0, count: 64 * 1024)
            var output = Data()
            while true {
                try Task.checkCancellation()
                let capacity = min(scratch.count, limit - output.count + 1)
                let result = scratch.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = UInt32(capacity)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let count = capacity - Int(stream.avail_out)
                guard output.count + count <= limit else { throw WorkspaceArchiveError.expandedTooLarge }
                output.append(contentsOf: scratch.prefix(count))
                if result == Z_STREAM_END {
                    if stream.avail_in == 0 { return output }
                    // GZIP may contain multiple members. A ZIP member has one raw DEFLATE stream.
                    guard wrapper == .gzip, inflateReset(&stream) == Z_OK else { throw WorkspaceArchiveError.damaged }
                } else if result != Z_OK {
                    throw WorkspaceArchiveError.damaged
                }
            }
        }
    }

    private static func tarEntries(_ bytes: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var files: [Data: Entry] = [:]
        var global: [String: String] = [:]
        var local: [String: String] = [:]
        var longPath: String?
        var longLink: String?
        var offset = 0

        while offset + 512 <= bytes.count {
            try Task.checkCancellation()
            let header = bytes[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) { break }
            guard entries.count < entryLimit else { throw WorkspaceArchiveError.tooManyEntries }
            let checksum = header.prefix(148).reduce(8 * 32) { $0 + Int($1) } +
                header.dropFirst(156).reduce(0) { $0 + Int($1) }
            guard try tarNumber(header, 148, 8) == checksum else { throw WorkspaceArchiveError.damaged }

            let type = header[offset + 156]
            let metadata = [UInt8(76), 75, 120, 103].contains(type)
            let attributes = metadata ? [:] : global.merging(local) { _, value in value }
            let size: Int
            if let value = attributes["size"], !value.isEmpty {
                guard value.utf8.allSatisfy({ (48...57).contains($0) }), let decimal = Int(value) else {
                    throw WorkspaceArchiveError.damaged
                }
                size = decimal
            } else {
                size = try tarNumber(header, 124, 12)
            }
            let start = offset + 512
            guard size <= byteLimit, size <= bytes.count - start else { throw WorkspaceArchiveError.damaged }
            offset = start + (size + 511) / 512 * 512

            if metadata {
                let content = bytes[start..<(start + size)]
                switch type {
                case 76: longPath = archiveString(content.prefix { $0 != 0 })
                case 75: longLink = archiveString(content.prefix { $0 != 0 })
                case 120: local.merge(try paxAttributes(content)) { _, value in value }
                default:
                    for (key, value) in try paxAttributes(content) {
                        global[key] = value.isEmpty && key != "linkpath" ? nil : value
                    }
                }
                continue
            }

            let prefix = tarString(header, 257, 6) == "ustar" && tarString(header, 263, 2) == "00"
                ? tarString(header, 345, 155) : ""
            let name = tarString(header, 0, 100)
            let defaultPath = prefix.isEmpty ? name : prefix + "/" + name
            let path = attributes["path"].flatMap { $0.isEmpty ? nil : $0 } ?? longPath ?? defaultPath
            let link = attributes["linkpath"] ?? longLink ?? tarString(header, 157, 100)
            longPath = nil
            longLink = nil
            local.removeAll()
            guard path.utf16.count <= pathLimit else { throw WorkspaceArchiveError.pathTooLong }

            let key = Data(path.utf8)
            let linked = type == 49 ? files[Data(link.utf8)] : nil
            guard [UInt8(0), 48, 53].contains(type) || linked != nil else {
                files[key] = nil
                continue
            }
            let modified: Double
            if let value = attributes["mtime"], !value.isEmpty {
                guard value.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                      let seconds = Double(value), seconds.isFinite else { throw WorkspaceArchiveError.damaged }
                modified = seconds
            } else {
                modified = Double(try tarNumber(header, 136, 12))
            }

            let kind: Entry.Kind
            if type == 53 {
                kind = .directory
            } else if let linked {
                kind = linked.kind
            } else {
                kind = .file(size <= entryByteLimit ? bytes.subdata(in: start..<(start + size)) : nil)
            }
            let date = abs(modified) <= 8.64e12 ? Date(timeIntervalSince1970: modified) : nil
            let entry = Entry(path: path, size: linked?.size ?? size, modified: date, kind: kind)
            entries.append(entry)
            if case .directory = kind {
                files[key] = nil
                files[Data(path.utf8.reversed().drop(while: { $0 == 47 }).reversed())] = nil
            } else {
                files[key] = entry
            }
        }
        guard !entries.isEmpty else { throw WorkspaceArchiveError.empty }
        return entries
    }

    private static func tarString(_ header: Data, _ offset: Int, _ count: Int) -> String {
        let start = header.startIndex + offset
        return archiveString(header[start..<(start + count)].prefix { $0 != 0 })
    }

    private static func tarNumber(_ header: Data, _ offset: Int, _ count: Int) throws -> Int {
        let text = tarString(header, offset, count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.allSatisfy({ (48...55).contains($0) }), let value = Int(text.isEmpty ? "0" : text, radix: 8) else {
            throw WorkspaceArchiveError.unsupportedTARNumber
        }
        return value
    }

    private static func paxAttributes(_ bytes: Data) throws -> [String: String] {
        guard bytes.count <= 65_536 else { throw WorkspaceArchiveError.metadataTooLarge }
        var attributes: [String: String] = [:]
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            guard let space = bytes[cursor..<min(cursor + 11, bytes.endIndex)].firstIndex(of: 32),
                  space > cursor, bytes[cursor] != 48,
                  bytes[cursor..<space].allSatisfy({ (48...57).contains($0) }),
                  let length = Int(archiveString(bytes[cursor..<space])), length <= bytes.endIndex - cursor,
                  cursor + length > space + 1 else { throw WorkspaceArchiveError.damaged }
            let end = cursor + length
            guard bytes[end - 1] == 10,
                  let equals = bytes[(space + 1)..<(end - 1)].firstIndex(of: 61),
                  equals > space + 1 else { throw WorkspaceArchiveError.damaged }
            let key = archiveString(bytes[(space + 1)..<equals])
            if ["path", "linkpath", "size", "mtime"].contains(key) {
                attributes[key] = archiveString(bytes[(equals + 1)..<(end - 1)])
            }
            cursor = end
        }
        return attributes
    }
}

func archiveString(_ bytes: Data) -> String {
    String(decoding: bytes, as: UTF8.self)
}
