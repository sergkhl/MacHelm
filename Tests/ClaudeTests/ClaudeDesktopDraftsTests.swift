import Foundation
import XCTest
@testable import ClaudeCore

final class ClaudeDesktopDraftsTests: XCTestCase {
    private let first = "local_9ead3883-563f-420c-beb9-a1187e7960d6"
    private let second = "local_436ff054-4f6e-47c9-b849-3f2eff669088"
    private let third = "local_39b18cab-0e17-42e7-a4df-3530188f993a"
    private let owner = "2b983c53-acc0-4a8c-ba0d-24184a854b1e"
    private let savedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testCurrentDraftObservationsExcludeClearsBlankInputsAndOtherOrigins() throws {
        let home = try temporaryHome()
        let current = batch(sequence: 12, entries: [
            (key("epitaxy-" + first), value("old editor text")),
            (key("epitaxy-" + first), nil),
            (key("epitaxy-" + second), value("historical editor text")),
            (key("epitaxy-" + second), value(" \n\t ")),
            (key("pane:\(owner):" + third), value("私の入力", dated: true, wide: true)),
            (key("epitaxy-" + first, origin: "https://example.org"), value("test input")),
            (key("epitaxy-draft"), value("new composer without a session"))
        ])
        let old = batch(sequence: 1, entries: [(key("popout:" + first), value("obsolete journal"))])
        try writeDatabase(in: home, files: [
            "MANIFEST-000001": record(manifest(firstLog: 5)),
            "000004.log": record(old),
            "000005.log": record(current)
        ])

        let result = ClaudeDesktopDrafts.read(home: home)
        XCTAssertEqual(result.quality, .complete)
        XCTAssertEqual(result.value, [ClaudeDesktopID(third)!: [.init(savedAt: savedAt, ownerID: owner)]])
    }

    func testCompactedDraftsSurviveAndJournalDeletesTakePrecedence() throws {
        let home = try temporaryHome()
        let active = table(entries: [
            (internalKey(key("epitaxy-" + first), sequence: 3), value("kept in a compacted block")),
            (internalKey(key("epitaxy-" + second), sequence: 4), value("cleared after compaction"))
        ])
        let obsolete = table(entries: [
            (internalKey(key("epitaxy-" + third), sequence: 2), value("removed table"))
        ])
        let privateBlobs: [String: [UInt8]] = [
            "MANIFEST-000001": record(manifest(firstLog: 6, tables: [(4, obsolete.count), (5, active.count)]))
                + record([6, 0, 4]), // Remove the old table from the manifest.
            "000004.ldb": obsolete,
            "000005.ldb": active,
            "000006.log": record(batch(sequence: 7, entries: [(key("epitaxy-" + second), nil)]))
        ]
        try writeDatabase(in: home, files: privateBlobs)

        let result = ClaudeDesktopDrafts.read(home: home)
        XCTAssertEqual(result.quality, .complete)
        XCTAssertEqual(result.value, [ClaudeDesktopID(first)!: [.init(savedAt: nil, ownerID: owner)]])
    }

    func testJournalReassemblesDraftFromTwoPhysicalBlocks() throws {
        let home = try temporaryHome()
        let logical = batch(sequence: 12, entries: [
            (key("pane:\(owner):" + first), value(String(repeating: "x", count: 34_000), dated: true))
        ])
        let start = record(Array(logical.prefix(32_761)), type: 2)
        let end = record(Array(logical.dropFirst(32_761)), type: 4)
        try writeDatabase(in: home, files: ["MANIFEST-000001": record(manifest(firstLog: 5)), "000005.log": start + end])

        let result = ClaudeDesktopDrafts.read(home: home)
        XCTAssertEqual(result.quality, .complete)
        XCTAssertEqual(result.value, [ClaudeDesktopID(first)!: [.init(savedAt: savedAt, ownerID: owner)]])
    }

    func testDamagedJournalReturnsPartialWithoutResurrectingAnEarlierPut() throws {
        let home = try temporaryHome()
        let draft = key("epitaxy-" + first)
        let put = record(batch(sequence: 10, entries: [(draft, value("previous unsent text"))]))
        let incompleteDelete = record(batch(sequence: 11, entries: [(draft, nil)])).dropLast()
        try writeDatabase(in: home, files: [
            "MANIFEST-000001": record(manifest(firstLog: 5)),
            "000005.log": put + incompleteDelete
        ])

        let result = ClaudeDesktopDrafts.read(home: home)
        XCTAssertEqual(result.quality, .partial)
        XCTAssertTrue(result.value.isEmpty)
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return home
    }

    private func writeDatabase(in home: URL, files: [String: [UInt8]]) throws {
        let database = home.appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try Data("MANIFEST-000001\n".utf8).write(to: database.appendingPathComponent("CURRENT"))
        for (name, bytes) in files { try Data(bytes).write(to: database.appendingPathComponent(name)) }
    }

    private func key(_ name: String, origin: String = "https://claude.ai") -> [UInt8] {
        Array("_\(origin)\0\u{1}composer-draft:\(name)".utf8)
    }

    private func value(_ text: String, dated: Bool = false, wide: Bool = false) -> [UInt8] {
        let date = dated ? ",\"storedAt\":1700000000000" : ""
        let escaped = text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        let json = "{\"text\":\"\(escaped)\",\"owner\":\"\(owner)\"\(date)}"
        if wide { return [0] + json.utf16.flatMap { fixed(UInt64($0), width: 2) } }
        return [1] + json.utf8
    }

    private func batch(sequence: UInt64, entries: [([UInt8], [UInt8]?)]) -> [UInt8] {
        var bytes = fixed(sequence, width: 8) + fixed(UInt64(entries.count), width: 4)
        for (key, value) in entries {
            bytes += [value == nil ? 0 : 1] + prefixed(key)
            if let value { bytes += prefixed(value) }
        }
        return bytes
    }

    private func manifest(firstLog: UInt8, tables: [(UInt8, Int)] = []) -> [UInt8] {
        var bytes: [UInt8] = [1] + prefixed(Array("leveldb.BytewiseComparator".utf8)) + [2, firstLog, 3, 25, 4, 6, 9, 0]
        for (number, size) in tables {
            bytes += [7, 0, number] + varint(size) + prefixed([0]) + prefixed([0])
        }
        return bytes
    }

    private func internalKey(_ key: [UInt8], sequence: UInt64) -> [UInt8] {
        key + fixed(sequence << 8 | 1, width: 8)
    }

    private func table(entries: [([UInt8], [UInt8])]) -> [UInt8] {
        let data = compressedBlock(entries)
        let metaindex = block([])
        let dataHandle = varint(0) + varint(data.count - 5)
        let index = compressedBlock([(entries.last!.0, dataHandle)])
        var footer = varint(data.count) + varint(metaindex.count - 5)
        footer += varint(data.count + metaindex.count) + varint(index.count - 5)
        footer += Array(repeating: 0, count: 40 - footer.count)
        footer += fixed(0xdb4775248b80fb57, width: 8)
        return data + metaindex + index + footer
    }

    private func blockEntries(_ entries: [([UInt8], [UInt8])]) -> [UInt8] {
        var previous: [UInt8] = []
        var bytes: [UInt8] = []
        for (key, value) in entries {
            let shared = zip(previous, key).prefix { $0 == $1 }.count
            bytes += varint(shared) + varint(key.count - shared) + varint(value.count)
            bytes += Array(key.dropFirst(shared)) + value
            previous = key
        }
        return bytes + fixed(0, width: 4) + fixed(1, width: 4)
    }

    private func block(_ entries: [([UInt8], [UInt8])]) -> [UInt8] {
        let payload = blockEntries(entries) + [0]
        return payload + fixed(UInt64(checksum(payload)), width: 4)
    }

    private func compressedBlock(_ entries: [([UInt8], [UInt8])]) -> [UInt8] {
        let raw = blockEntries(entries)
        let literal = UInt64(raw.count - 1)
        let tag = literal < 256 ? [UInt8(60 << 2)] + fixed(literal, width: 1)
            : [UInt8(61 << 2)] + fixed(literal, width: 2)
        let payload = varint(raw.count) + tag + raw + [1]
        return payload + fixed(UInt64(checksum(payload)), width: 4)
    }

    private func record(_ data: [UInt8], type: UInt8 = 1) -> [UInt8] {
        let payload = [type] + data
        return fixed(UInt64(checksum(payload)), width: 4) + fixed(UInt64(data.count), width: 2) + payload
    }

    private func prefixed(_ bytes: [UInt8]) -> [UInt8] { varint(bytes.count) + bytes }

    private func varint(_ value: Int) -> [UInt8] {
        if value < 128 { return [UInt8(value)] }
        return [UInt8(value & 127 | 128)] + varint(value >> 7)
    }

    private func fixed(_ value: UInt64, width: Int) -> [UInt8] {
        (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0x82f63b78 : crc >> 1 }
        }
        crc = ~crc
        return ((crc << 17) | (crc >> 15)) &+ 0xa282ead8
    }
}
