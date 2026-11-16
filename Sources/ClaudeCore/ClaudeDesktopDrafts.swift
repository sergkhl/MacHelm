import Darwin
import Foundation

struct ClaudeSavedDraft: Equatable, Sendable {
    let savedAt: Date?
    let ownerID: String?
}

enum ClaudeDesktopDrafts {
    static func read(home: URL) -> ClaudeRead<[ClaudeDesktopID: [ClaudeSavedDraft]]> {
        do {
            guard let database = try DraftDatabase.open(home: home) else { return .init(value: [:]) }
            defer { close(database) }
            var snapshot = DraftDatabase(directory: database)
            return .init(value: try snapshot.read())
        } catch {
            return .init(value: [:], quality: .partial)
        }
    }
}

// Claude Desktop's default Chromium Local Storage database. Inspect the committed
// LevelDB manifest, active tables and journals without opening the database as a client.
private struct DraftDatabase {
    enum InvalidSnapshot: Error { case invalid }

    private static let maxSnapshotBytes = 32 * 1_024 * 1_024
    private static let maxExpandedBytes = 64 * 1_024 * 1_024
    private static let maxBlockBytes = 8 * 1_024 * 1_024
    private let directory: Int32
    private var readBytes = 0
    private var expandedBytes = 0
    private var stamps: [String: Stamp] = [:]
    private var latest: [String: DraftEntry] = [:]

    init(directory: Int32) { self.directory = directory }

    private struct Stamp: Equatable {
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int

        init(_ info: stat) {
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private struct DraftEntry: Equatable {
        let session: ClaudeDesktopID
        let sequence: UInt64
        let draft: ClaudeSavedDraft?
    }

    private struct ComposerValue: Decodable {
        let hasText: Bool
        let draft: ClaudeSavedDraft

        private enum CodingKeys: String, CodingKey { case text, storedAt, owner }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let text = try? values.decode(String.self, forKey: .text)
            hasText = text?.contains(where: { !$0.isWhitespace }) == true
            let milliseconds = try? values.decode(Double.self, forKey: .storedAt)
            let savedAt = milliseconds.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1_000) : nil }
            let owner = try? values.decode(String.self, forKey: .owner)
            draft = ClaudeSavedDraft(savedAt: savedAt, ownerID: owner)
        }
    }

    static func open(home: URL) throws -> Int32? {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = openat(AT_FDCWD, home.path, flags)
        guard fd >= 0 else { throw InvalidSnapshot.invalid }
        for name in ["Library", "Application Support", "Claude", "Local Storage", "leveldb"] {
            let next = openat(fd, name, flags)
            let missing = errno == ENOENT
            close(fd)
            if next < 0 && missing { return nil }
            guard next >= 0 else { throw InvalidSnapshot.invalid }
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else {
            close(fd)
            throw InvalidSnapshot.invalid
        }
        return fd
    }

    mutating func read() throws -> [ClaudeDesktopID: [ClaudeSavedDraft]] {
        let current = try file("CURRENT", limit: 128)
        let name = String(decoding: current, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard name.hasPrefix("MANIFEST-"), Self.fileNumber(String(name.dropFirst(9))) != nil else {
            throw InvalidSnapshot.invalid
        }
        var manifest = Manifest()
        try Self.records(in: file(name, limit: 4 * 1_024 * 1_024)) { try manifest.apply($0) }
        guard let firstLog = manifest.log else { throw InvalidSnapshot.invalid }
        let logs = try activeLogs(first: firstLog, previous: manifest.previousLog)
        for expected in [firstLog, manifest.previousLog] where expected != 0 {
            guard logs.contains(Self.numberString(expected) + ".log") else { throw InvalidSnapshot.invalid }
        }
        let names = try names()
        for (number, size) in manifest.tables {
            let digits = Self.numberString(number)
            let candidates = [digits + ".ldb", digits + ".sst"].filter(names.contains)
            guard candidates.count == 1, let table = candidates.first, size <= UInt64(Self.maxSnapshotBytes) else {
                throw InvalidSnapshot.invalid
            }
            let bytes = try file(table, limit: Int(size))
            guard bytes.count == Int(size) else { throw InvalidSnapshot.invalid }
            try readTable(bytes)
        }
        for log in logs.sorted() {
            let bytes = try file(log, limit: Self.maxSnapshotBytes)
            try Self.records(in: bytes) { try applyBatch($0) }
        }
        // A compaction or append may invalidate the snapshot while it is being read.
        guard logs == (try activeLogs(first: firstLog, previous: manifest.previousLog)),
              stamps.allSatisfy({ name, stamp in Self.stamp(name, in: directory) == stamp }) else {
            throw InvalidSnapshot.invalid
        }
        var drafts: [ClaudeDesktopID: [ClaudeSavedDraft]] = [:]
        for entry in latest.values {
            if let draft = entry.draft, !drafts[entry.session, default: []].contains(draft) {
                drafts[entry.session, default: []].append(draft)
            }
        }
        return drafts
    }

    private mutating func file(_ name: String, limit: Int) throws -> [UInt8] {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw InvalidSnapshot.invalid }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Self.isOwnedFile(info), info.st_size >= 0,
              info.st_size <= min(limit, Self.maxSnapshotBytes - readBytes) else { throw InvalidSnapshot.invalid }
        let stamp = Stamp(info)
        let size = Int(info.st_size)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: size + 1) ?? Data()
        guard data.count == size else { throw InvalidSnapshot.invalid }
        readBytes += size
        stamps[name] = stamp
        return Array(data)
    }

    private static func isOwnedFile(_ info: stat) -> Bool {
        info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFREG
    }

    private static func stamp(_ name: String, in directory: Int32) -> Stamp? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, isOwnedFile(info) else { return nil }
        return Stamp(info)
    }

    private func names() throws -> Set<String> {
        let fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw InvalidSnapshot.invalid }
        guard let entries = fdopendir(fd) else {
            close(fd)
            throw InvalidSnapshot.invalid
        }
        defer { closedir(entries) }
        var names: Set<String> = []
        while true {
            errno = 0
            guard let entry = readdir(entries) else {
                guard errno == 0 else { throw InvalidSnapshot.invalid }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            if let name { names.insert(name) }
            guard names.count <= 1_024 else { throw InvalidSnapshot.invalid }
        }
    }

    private func activeLogs(first: UInt64, previous: UInt64) throws -> Set<String> {
        let logs = try names().filter { name in
            guard name.hasSuffix(".log"), let number = Self.fileNumber(String(name.dropLast(4))) else { return false }
            return number >= first || number == previous
        }
        return Set(logs)
    }

    private static func fileNumber(_ digits: String) -> UInt64? {
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(digits)
    }

    private static func numberString(_ number: UInt64) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    private struct Manifest {
        var log: UInt64?
        var previousLog: UInt64 = 0
        var tables: [UInt64: UInt64] = [:]

        mutating func apply(_ bytes: ArraySlice<UInt8>) throws {
            var edit = Bytes(bytes)
            while !edit.isEmpty {
                switch try edit.varint() {
                case 1:
                    guard try edit.prefixed().elementsEqual("leveldb.BytewiseComparator".utf8) else {
                        throw InvalidSnapshot.invalid
                    }
                case 2: log = try edit.varint()
                case 3, 4: _ = try edit.varint() // next file number, last sequence
                case 5:
                    _ = try edit.varint() // level
                    _ = try edit.prefixed() // compaction pointer
                case 6:
                    _ = try edit.varint() // level
                    tables.removeValue(forKey: try edit.varint())
                case 7:
                    _ = try edit.varint() // level
                    let number = try edit.varint()
                    tables[number] = try edit.varint()
                    _ = try edit.prefixed() // smallest internal key
                    _ = try edit.prefixed() // largest internal key
                case 9: previousLog = try edit.varint()
                default: throw InvalidSnapshot.invalid
                }
            }
        }
    }

    private static func records(in bytes: [UInt8], _ consume: (ArraySlice<UInt8>) throws -> Void) throws {
        let blockSize = 32_768
        var position = 0
        var fragmented: [UInt8]?
        while position < bytes.count {
            let remainingInBlock = blockSize - position % blockSize
            if remainingInBlock < 7 {
                let blockEnd = min(bytes.count, position + remainingInBlock)
                guard bytes[position..<blockEnd].allSatisfy({ $0 == 0 }) else { throw InvalidSnapshot.invalid }
                position = blockEnd
                continue
            }
            var header = Bytes(bytes[position...])
            let checksum = UInt32(try header.fixed(4))
            let length = Int(try header.fixed(2))
            guard length <= remainingInBlock - 7 else { throw InvalidSnapshot.invalid }
            let type = try header.byte()
            let data = try header.take(length)
            let end = position + 7 + length
            if type == 0, length == 0, checksum == 0 {
                let blockEnd = min(bytes.count, position + remainingInBlock)
                guard bytes[end..<blockEnd].allSatisfy({ $0 == 0 }) else { throw InvalidSnapshot.invalid }
                position = blockEnd
                continue
            }
            guard checksum == crc(bytes[(position + 6)..<end]) else { throw InvalidSnapshot.invalid }
            switch type {
            case 1:
                guard fragmented == nil else { throw InvalidSnapshot.invalid }
                try consume(data)
            case 2:
                guard fragmented == nil else { throw InvalidSnapshot.invalid }
                fragmented = Array(data)
            case 3, 4:
                guard fragmented != nil else { throw InvalidSnapshot.invalid }
                fragmented?.append(contentsOf: data)
                if type == 4, let record = fragmented {
                    try consume(record[...])
                    fragmented = nil
                }
            default: throw InvalidSnapshot.invalid
            }
            position = end
        }
        guard fragmented == nil else { throw InvalidSnapshot.invalid }
    }

    private mutating func applyBatch(_ data: ArraySlice<UInt8>) throws {
        var batch = Bytes(data)
        let sequence = try batch.fixed(8)
        let count = Int(try batch.fixed(4))
        let maxSequence = UInt64.max >> 8
        guard sequence <= maxSequence, UInt64(count) <= maxSequence - sequence + 1,
              count <= batch.remaining / 2 else { throw InvalidSnapshot.invalid }
        for offset in 0..<count {
            let type = try batch.byte()
            guard type <= 1 else { throw InvalidSnapshot.invalid }
            let key = try batch.prefixed()
            let value = type == 1 ? try batch.prefixed() : nil
            try apply(key, value: value, sequence: sequence + UInt64(offset))
        }
        guard batch.isEmpty else { throw InvalidSnapshot.invalid }
    }

    private mutating func readTable(_ bytes: [UInt8]) throws {
        guard bytes.count >= 48 else { throw InvalidSnapshot.invalid }
        let footerStart = bytes.count - 48
        var magic = Bytes(bytes[(bytes.count - 8)...])
        guard try magic.fixed(8) == 0xdb4775248b80fb57 else { throw InvalidSnapshot.invalid }
        var footer = Bytes(bytes[footerStart...])
        _ = try BlockHandle(&footer) // metaindex
        let indexHandle = try BlockHandle(&footer)
        let index = try block(indexHandle, in: bytes, before: footerStart)
        var handles: [BlockHandle] = []
        try Self.blockEntries(index) { _, value in
            var reader = Bytes(value)
            handles.append(try BlockHandle(&reader))
        }
        var previousEnd = 0
        for handle in handles {
            guard handle.offset >= previousEnd else { throw InvalidSnapshot.invalid }
            let data = try block(handle, in: bytes, before: indexHandle.offset)
            previousEnd = handle.offset + handle.size + 5
            try Self.blockEntries(data) { key, value in
                guard key.count >= 8 else { throw InvalidSnapshot.invalid }
                var trailer = Bytes(key.suffix(8))
                let tag = try trailer.fixed(8)
                guard tag & 255 <= 1 else { throw InvalidSnapshot.invalid }
                try apply(key.dropLast(8)[...], value: tag & 255 == 1 ? value : nil, sequence: tag >> 8)
            }
        }
    }

    private struct BlockHandle {
        let offset: Int
        let size: Int

        init(_ input: inout Bytes) throws {
            offset = try input.length()
            size = try input.length()
        }
    }

    private mutating func block(_ handle: BlockHandle, in bytes: [UInt8], before limit: Int) throws -> [UInt8] {
        guard handle.offset <= limit - 5, handle.size <= limit - 5 - handle.offset else {
            throw InvalidSnapshot.invalid
        }
        let end = handle.offset + handle.size
        var trailer = Bytes(bytes[end..<(end + 5)])
        let compression = try trailer.byte()
        guard try UInt32(trailer.fixed(4)) == Self.crc(bytes[handle.offset...end]) else { throw InvalidSnapshot.invalid }
        let payload = bytes[handle.offset..<end]
        let maxSize = min(Self.maxBlockBytes, Self.maxExpandedBytes - expandedBytes)
        let result: [UInt8]
        switch compression {
        case 0:
            guard payload.count <= maxSize else { throw InvalidSnapshot.invalid }
            result = Array(payload)
        case 1: result = try Self.snappy(payload, limit: maxSize)
        default: throw InvalidSnapshot.invalid
        }
        expandedBytes += result.count
        return result
    }

    private static func blockEntries(_ data: [UInt8], _ consume: (ArraySlice<UInt8>, ArraySlice<UInt8>) throws -> Void) throws {
        guard data.count >= 8 else { throw InvalidSnapshot.invalid }
        var footer = Bytes(data.suffix(4))
        let restarts = Int(try footer.fixed(4))
        guard restarts > 0, restarts <= (data.count - 4) / 4 else { throw InvalidSnapshot.invalid }
        var bytes = Bytes(data.prefix(data.count - 4 - restarts * 4))
        var key: [UInt8] = []
        while !bytes.isEmpty {
            let shared = try bytes.length()
            let suffix = try bytes.length()
            let valueLength = try bytes.length()
            guard shared <= key.count, suffix <= 16_384 - shared else { throw InvalidSnapshot.invalid }
            key.removeLast(key.count - shared)
            key.append(contentsOf: try bytes.take(suffix))
            try consume(key[...], bytes.take(valueLength))
        }
    }

    private mutating func apply(_ rawKey: ArraySlice<UInt8>, value: ArraySlice<UInt8>?, sequence: UInt64) throws {
        guard let (key, session) = Self.target(rawKey) else { return }
        if let old = latest[key], old.sequence > sequence { return }
        var draft: ClaudeSavedDraft?
        if let value {
            guard let text = Self.domString(value),
                  let payload = try? JSONDecoder().decode(ComposerValue.self, from: Data(text.utf8)) else {
                throw InvalidSnapshot.invalid
            }
            if payload.hasText { draft = payload.draft }
        }
        let entry = DraftEntry(session: session, sequence: sequence, draft: draft)
        if let old = latest[key], old.sequence == sequence, old != entry { throw InvalidSnapshot.invalid }
        latest[key] = entry
    }

    private static let latinKey = Array("_https://claude.ai\0\u{1}composer-draft:".utf8)
    private static let wideKey = Array("_https://claude.ai\0\0".utf8) + Array("composer-draft:".utf16.flatMap { [UInt8($0), 0] })

    private static func target(_ bytes: ArraySlice<UInt8>) -> (String, ClaudeDesktopID)? {
        guard bytes.count < 512, bytes.starts(with: latinKey) || bytes.starts(with: wideKey),
              let key = domString(bytes.dropFirst("_https://claude.ai\0".utf8.count)) else { return nil }
        let suffix = key.dropFirst("composer-draft:".count)
        let host: String
        if suffix.hasPrefix("epitaxy-") {
            let candidate = String(suffix.dropFirst(8))
            host = candidate.hasSuffix(":dialog") ? String(candidate.dropLast(7)) : candidate
        } else if suffix.hasPrefix("popout:") {
            host = String(suffix.dropFirst(7))
        } else if suffix.hasPrefix("pane:"), let colon = suffix.lastIndex(of: ":"),
                  colon > suffix.index(suffix.startIndex, offsetBy: 5) {
            host = String(suffix[suffix.index(after: colon)...])
        } else {
            return nil
        }
        guard let session = ClaudeDesktopID(host) else { return nil }
        return (key, session)
    }

    private static func domString(_ bytes: ArraySlice<UInt8>) -> String? {
        guard bytes.count <= 2 * 1_024 * 1_024 else { return nil }
        switch bytes.first {
        case 0: return String(data: Data(bytes.dropFirst()), encoding: .utf16LittleEndian)
        case 1:
            let text = bytes.dropFirst()
            if text.allSatisfy({ $0 < 128 }) { return String(decoding: text, as: UTF8.self) }
            return String(text.lazy.map { Character(Unicode.Scalar($0)) })
        default: return nil
        }
    }

    private static func snappy(_ bytes: ArraySlice<UInt8>, limit: Int) throws -> [UInt8] {
        var input = Bytes(bytes)
        let size = try input.length()
        guard size <= limit else { throw InvalidSnapshot.invalid }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(size)
        while !input.isEmpty {
            let tag = try input.byte()
            let length: Int
            let offset: Int
            switch tag & 3 {
            case 0:
                let code = Int(tag >> 2)
                let count = code < 60 ? code + 1 : Int(try input.fixed(code - 59)) + 1
                guard count <= size - decoded.count else { throw InvalidSnapshot.invalid }
                decoded.append(contentsOf: try input.take(count))
                continue
            case 1:
                length = 4 + Int((tag >> 2) & 7)
                offset = (Int(tag & 224) << 3) | Int(try input.byte())
            case 2, 3:
                length = 1 + Int(tag >> 2)
                offset = Int(try input.fixed(tag & 3 == 2 ? 2 : 4))
            default: throw InvalidSnapshot.invalid
            }
            guard offset > 0, offset <= decoded.count, length <= size - decoded.count else { throw InvalidSnapshot.invalid }
            for _ in 0..<length { decoded.append(decoded[decoded.count - offset]) }
        }
        guard decoded.count == size else { throw InvalidSnapshot.invalid }
        return decoded
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        (0..<8).reduce(UInt32(value)) { crc, _ in (crc >> 1) ^ (crc & 1 != 0 ? 0x82f63b78 : 0) }
    }

    private static func crc(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        let sum = ~bytes.reduce(UInt32.max) { crc, byte in
            (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)]
        }
        return ((sum >> 15) | (sum << 17)) &+ 0xa282ead8
    }

    private struct Bytes {
        private let bytes: ArraySlice<UInt8>
        private var index: Int
        var remaining: Int { bytes.endIndex - index }
        var isEmpty: Bool { remaining == 0 }

        init(_ bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            index = bytes.startIndex
        }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= remaining else { throw InvalidSnapshot.invalid }
            defer { index += count }
            return bytes[index..<(index + count)]
        }

        mutating func byte() throws -> UInt8 {
            guard !isEmpty else { throw InvalidSnapshot.invalid }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func fixed(_ count: Int) throws -> UInt64 {
            try take(count).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }

        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                let byte = try byte()
                guard shift < 63 || byte <= 1 else { throw InvalidSnapshot.invalid }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw InvalidSnapshot.invalid
        }

        mutating func length() throws -> Int {
            guard let size = Int(exactly: try varint()) else { throw InvalidSnapshot.invalid }
            return size
        }

        mutating func prefixed() throws -> ArraySlice<UInt8> {
            let count = try length()
            return try take(count)
        }
    }
}
