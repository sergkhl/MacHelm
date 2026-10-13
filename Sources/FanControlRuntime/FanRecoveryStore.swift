import Foundation
#if canImport(FanControlCore)
import FanControlCore
#endif

public final class FanRecoveryStore: FanRecoveryPersistence {
    private let directory: URL
    private let requiredUID: uid_t
    private let name = "ownership.json"
    private let retirementName = "ownership-retiring.json"
    // Injectable only through the Swift module's internal test seam; never XPC.
    var directorySync: (Int32) -> Int32 = { fsync($0) }
    var fileSync: (Int32) -> Int32 = { fsync($0) }

    public init(directory: URL = URL(fileURLWithPath: "/Library/Application Support/io.github.sergkhl.MacHelm.FanControlHelper"),
                requiredUID: uid_t = 0) throws {
        self.directory = directory; self.requiredUID = requiredUID
        guard geteuid() == requiredUID else { throw FanControlError.ownership("Recovery store must be accessed by its service owner.") }
        // The fixed parent is outside the user's writable app bundle.
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw failure("create recovery directory") }
        close(try openDirectory())
    }

    public func load() throws -> FanRecoveryRecord? {
        let directoryFD = try openDirectory(); defer { close(directoryFD) }
        let primary = try load(name, directoryFD: directoryFD)
        let retiring = try load(retirementName, directoryFD: directoryFD)
        return try retainedRecord(primary: primary, retiring: retiring)
    }

    private func retainedRecord(primary: FanRecoveryRecord?, retiring: FanRecoveryRecord?) throws -> FanRecoveryRecord? {
        guard let primary, let retiring, primary != retiring else { return primary ?? retiring }
        // The same pending intent with and without a self-recovery decision:
        // a save of that decision was interrupted before the older copy was
        // deleted. It is one uncertainty, and the decision stands.
        if primary.sameUncertainty(as: retiring) { return primary.automaticRecoveryClosed ? primary : retiring }
        if primary.acknowledgesPendingOperation(in: retiring) {
            // Acknowledgement leaves a pending copy through its post-save
            // checks. On restart that original uncertainty stays authoritative
            // until a newer durable pending operation has superseded it.
            return primary.pending == nil ? retiring : primary
        }
        throw FanControlError.ownership("Recovery retirement is ambiguous. Fan writes and helper removal remain blocked.")
    }

    private func load(_ filename: String, directoryFD: Int32) throws -> FanRecoveryRecord? {
        let fd = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("open recovery record") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == requiredUID,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 65_536 else {
            throw FanControlError.ownership("Recovery record has unsafe ownership, permissions, or size.")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let total = bytes.count
        var offset = 0
        while offset < total {
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), total - offset) }
            guard count > 0 else { throw failure("read recovery record") }
            offset += count
        }
        let record: FanRecoveryRecord
        do { record = try JSONDecoder().decode(FanRecoveryRecord.self, from: Data(bytes)) }
        catch is DecodingError {
            throw FanControlError.ownership("Unsupported or malformed fan recovery record. Fan writes and helper removal remain blocked; manual recovery is required before replacing the helper.")
        }
        try record.validate()
        return record
    }

    public func save(_ record: FanRecoveryRecord) throws {
        let directoryFD = try openDirectory(); defer { close(directoryFD) }
        let primary = try load(name, directoryFD: directoryFD)
        let retiring = try load(retirementName, directoryFD: directoryFD)
        if let retiring {
            let retained = try retainedRecord(primary: primary, retiring: retiring)
            // A self-recovery decision on the retained pending intent keeps
            // that intent, so it may replace the acknowledged primary. This
            // clause compares with what a restart would load, not with an
            // older copy that a newer pending intent has superseded. The
            // clauses beside it are older and are not narrowed by it.
            guard record == retiring || retained.map({ record.sameUncertainty(as: $0) }) == true || (primary.map {
                record.sameLineage(as: $0) && FanRecoveryRecord.matches($0.acknowledged, record.acknowledged)
                    && (record.pending != nil || record.acknowledged == $0.acknowledged)
            } == true) else {
                throw FanControlError.ownership("A new record cannot overwrite retained fan uncertainty.")
            }
        }
        try save(record, filename: name, directoryFD: directoryFD)
        if retiring != nil && record.pending != nil {
            // The newer intent is durable before removing the pending copy.
            // Even a cleanup failure now leaves startup-visible uncertainty.
            guard unlinkat(directoryFD, retirementName, 0) == 0,
                  directorySync(directoryFD) == 0 else { throw failure("supersede retained fan uncertainty") }
        }
    }

    public func acknowledgeManualMode(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                                       validate: () throws -> Void) throws {
        try pending.validate(); try acknowledged.validate()
        guard pending.pending != nil, acknowledged.pending == nil,
              acknowledged.acknowledgesManualMode(in: pending),
              pending.restorationStarted == acknowledged.restorationStarted else {
            throw FanControlError.ownership("The manual-mode acknowledgement does not match its pending intent.")
        }
        try stageAcknowledgement(pending: pending, acknowledged: acknowledged, validate: validate)
    }

    // Ordinary targets, zero release targets and mode releases use the same
    // staged crash copy as manual entry. Unlike manual entry, the actuator
    // retires it once its in-memory publication has succeeded.
    public func acknowledgeBoundedOperation(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                                            validate: () throws -> Void) throws {
        try pending.validate(); try acknowledged.validate()
        guard let operation = pending.pending, acknowledged.pending == nil,
              FanRecoveryRecord.usesBoundedAcknowledgement(operation),
              acknowledged.acknowledgesPendingOperation(in: pending),
              pending.restorationStarted == acknowledged.restorationStarted else {
            throw FanControlError.ownership("The fan acknowledgement does not match its pending intent.")
        }
        try stageAcknowledgement(pending: pending, acknowledged: acknowledged, validate: validate)
    }

    // Called only after a successful publication. Any mismatch or failed
    // deletion leaves the pending copy, which conservatively wins on restart.
    public func retireAcknowledgementMarker(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord) throws {
        guard let operation = pending.pending, acknowledged.pending == nil,
              FanRecoveryRecord.usesBoundedAcknowledgement(operation),
              acknowledged.acknowledgesPendingOperation(in: pending) else {
            throw FanControlError.ownership("The acknowledged fan record does not match its pending copy.")
        }
        let fd = try openDirectory(); defer { close(fd) }
        guard try load(name, directoryFD: fd) == acknowledged,
              try load(retirementName, directoryFD: fd) == pending else {
            throw FanControlError.ownership("The acknowledged fan record changed before its pending copy was retired.")
        }
        guard unlinkat(fd, retirementName, 0) == 0, directorySync(fd) == 0 else {
            throw failure("retire the acknowledged pending copy")
        }
    }

    private func stageAcknowledgement(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                                      validate: () throws -> Void) throws {
        let fd = try openDirectory(); defer { close(fd) }
        guard try load(name, directoryFD: fd) == pending,
              try load(retirementName, directoryFD: fd) == nil else {
            throw FanControlError.ownership("The pending fan record changed before acknowledgement.")
        }
        try validate()
        // The primary is already a durable pending intent. Move that file
        // into the conservative crash marker instead of rewriting and syncing
        // the same bytes again inside the acknowledgement deadline. Exclusive
        // rename refuses an unexpected marker; a crash at any point retains
        // the pending intent under at least one of the two names.
        guard renameatx_np(fd, name, fd, retirementName, UInt32(RENAME_EXCL)) == 0,
              directorySync(fd) == 0 else { throw failure("stage the durable pending fan record") }
        guard try load(name, directoryFD: fd) == nil,
              try load(retirementName, directoryFD: fd) == pending else {
            throw FanControlError.ownership("The pending fan record changed while staging acknowledgement.")
        }
        try validate()
        try save(acknowledged, filename: name, directoryFD: fd)
        guard try load(name, directoryFD: fd) == acknowledged,
              try load(retirementName, directoryFD: fd) == pending else {
            throw FanControlError.ownership("The fan acknowledgement changed during durable publication.")
        }
        try validate()
        // Do not unlink this conservative copy here. A failed/late save or a
        // crash before publication must never expose pending=nil. The live
        // actuator alone knows that all acknowledgement checks passed; manual
        // entry keeps the copy until the next durable intent supersedes it.
    }

    private func save(_ record: FanRecoveryRecord, filename: String, directoryFD: Int32) throws {
        try record.validate()
        let data = try JSONEncoder().encode(record)
        guard data.count <= 65_536 else { throw FanControlError.invalid("Recovery record exceeds its size limit.") }
        let temporary = ".ownership-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("create durable recovery record") }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            guard count > 0 else { throw failure("write recovery record") }
            offset += count
        }
        guard fileSync(fd) == 0, renameat(directoryFD, temporary, directoryFD, filename) == 0,
              directorySync(directoryFD) == 0 else { throw failure("acknowledge durable recovery record") }
    }

    public func remove() throws {
        let fd = try openDirectory(); defer { close(fd) }
        let primary = try load(name, directoryFD: fd)
        let retiring = try load(retirementName, directoryFD: fd)
        guard let record = try retainedRecord(primary: primary, retiring: retiring) else { return }
        // Commit a startup-visible copy before unlinking the active journal.
        // Failed unlink/fsync therefore cannot turn an uncertain intent into
        // absence on restart. A malformed or unsafe record is never removed.
        try save(record, filename: retirementName, directoryFD: fd)
        if unlinkat(fd, name, 0) != 0 && errno != ENOENT { throw failure("remove recovery record") }
        guard directorySync(fd) == 0 else { throw failure("acknowledge recovery removal") }
        // Primary deletion is durable now. Cleanup failure may conservatively
        // re-expose the marker after restart, but cannot lose an uncommitted
        // intent. It does not invalidate the completed retirement transaction.
        if unlinkat(fd, retirementName, 0) == 0 { _ = directorySync(fd) }
    }

    private func openDirectory() throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("open recovery directory") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == requiredUID,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            close(fd)
            throw FanControlError.ownership("Recovery directory is not private to the service owner.")
        }
        return fd
    }

    private func failure(_ operation: String) -> FanControlError {
        .ownership("Cannot \(operation) (errno \(errno)); fan writes remain disarmed.")
    }
}
