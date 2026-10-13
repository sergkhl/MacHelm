import Foundation

// One run of the cleanup script (ADR 0004). Every line it prints is looked
// through for an event as it comes, and a root removal it asks for is
// answered with one line back.
public final class StorageRunner: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let callbacks: DispatchQueue
    // Keeps what was read in the order it was read.
    private let reading = DispatchQueue(label: "MacHelm.storage.run")
    private var pending = Data()
    private var errors = Data()
    private var status: Int32?
    private var outputClosed = false
    private var errorsClosed = false
    private var finished = false
    private var event: (@Sendable (StorageEvent) -> Void)?
    private var ended: (@Sendable (Int32, String) -> Void)?

    // How much of what the script wrote as errors is kept: the end of it says what went wrong.
    private static let errorLimit = 16_384
    // A program the script started may hold the output open after the script has gone.
    private static let patience: TimeInterval = 2

    // `event` and `ended` are called on `callbacks`, in the order the lines came.
    public init(callbacks: DispatchQueue = .main) {
        self.callbacks = callbacks
    }

    public func start(executable: String, arguments: [String], directory: URL? = nil,
                      event: @escaping @Sendable (StorageEvent) -> Void,
                      ended: @escaping @Sendable (_ status: Int32, _ errors: String) -> Void) -> Bool {
        let output = Pipe(), failures = Pipe()
        self.event = event
        self.ended = ended
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = failures
        // An answer written when nobody reads any more must fail, not end the
        // app: by default such a write raises a signal that does. This sets
        // it for this one descriptor only.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Nothing more to read is how the end of the output shows.
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.reading.async { self?.read(data) }
        }
        // Read as it comes, so that a script with much to complain about is not held back by a full pipe.
        failures.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.reading.async {
                guard let self else { return }
                guard !data.isEmpty else {
                    self.errorsClosed = true
                    return self.finishIfDone()
                }
                self.errors.append(data)
                if self.errors.count > Self.errorLimit { self.errors.removeFirst(self.errors.count - Self.errorLimit) }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            self?.reading.async {
                guard let self else { return }
                self.status = status
                self.finishIfDone()
                // Not held meanwhile: a run that has ended is let go at once.
                self.reading.asyncAfter(deadline: .now() + Self.patience) { [weak self] in self?.finish() }
            }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            failures.fileHandleForReading.readabilityHandler = nil
            // Nothing will end this run, so what it was handed is let go here.
            reading.sync {
                self.event = nil
                self.ended = nil
            }
            return false
        }
        return true
    }

    private func read(_ data: Data) {
        guard !data.isEmpty else {
            outputClosed = true
            // What came after the last line break is a line too.
            if !pending.isEmpty { deliver(String(decoding: pending, as: UTF8.self)) }
            pending.removeAll()
            return finishIfDone()
        }
        pending.append(data)
        while let end = pending.firstIndex(of: 0x0A) {
            deliver(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...end)
        }
    }

    private func deliver(_ line: String) {
        guard !finished, let found = StorageProtocol.event(in: line), let event else { return }
        callbacks.async { event(found) }
    }

    // The run has ended when the process has gone and all it wrote has been read, its complaints too.
    private func finishIfDone() {
        if status != nil, outputClosed, errorsClosed { finish() }
    }

    private func finish() {
        guard !finished, let status, let ended else { return }
        finished = true
        // The handler holds this run, and the run holds the process: let go.
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        let said = String(decoding: errors, as: UTF8.self)
        // Whoever started the run holds it in what it handed over: let go, or the run stays for good.
        event = nil
        self.ended = nil
        callbacks.async { ended(status, said) }
    }

    // The answer to a root removal the script asked for. One that comes after
    // the script has gone is dropped.
    public func answer(_ line: String) {
        // On the queue that closes the pipe when the run ends, so the two cannot cross.
        reading.async { [self] in
            guard !finished else { return }
            try? input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
        }
    }

    // Asks the run to stop. The login shell ignores that while it starts, so
    // a run that is still there half a second later is ended.
    public func cancel() {
        guard process.isRunning else { return }
        process.terminate()
        reading.asyncAfter(deadline: .now() + 0.5) { [self] in end() }
    }

    // Ends the run at once, as at Quit, where nothing waits for a script to take the hint.
    public func end() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
