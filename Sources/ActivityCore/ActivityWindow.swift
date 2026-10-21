import Foundation

// One process over the window. A measure that could not be read is nil.
public struct ProcessAverage: Equatable, Sendable {
    public var description: ProcessDescription
    // Percent of one core.
    public var cpuPercent: Double?
    public var memoryBytes: Double?
    // Percent of GPU time.
    public var gpuPercent: Double?
    public var energyWatts: Double?
    // Read and written, together.
    public var diskBytesPerSecond: Double?
    // It was not in the latest reading.
    public var ended: Bool

    public init(description: ProcessDescription, cpuPercent: Double? = nil, memoryBytes: Double? = nil,
                gpuPercent: Double? = nil, energyWatts: Double? = nil, diskBytesPerSecond: Double? = nil, ended: Bool = false) {
        self.description = description
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.gpuPercent = gpuPercent
        self.energyWatts = energyWatts
        self.diskBytesPerSecond = diskBytesPerSecond
        self.ended = ended
    }
}

public struct ActivityAverages: Equatable, Sendable {
    // What the averages cover: the window's length once it is full.
    public var seconds: TimeInterval
    public var processes: [ProcessAverage]
    // Parent by process identifier, for finding what a service started.
    public var parents: [Int32: Int32]

    public init(seconds: TimeInterval, processes: [ProcessAverage], parents: [Int32: Int32]) {
        self.seconds = seconds
        self.processes = processes
        self.parents = parents
    }
}

// The readings of the last seconds or minutes, and the averages over them.
// CPU time, energy, disk bytes and GPU time are running totals, so an average
// needs only the readings at both ends; memory is averaged over every reading.
public struct ActivityWindow: Sendable {
    public static let lengths: [TimeInterval] = [5, 10, 30, 60, 300]
    public static let defaultLength: TimeInterval = 10
    // Nothing is ranked on less than this.
    public static let shortest: TimeInterval = 2
    // Half a tick, so a pass that came a little late does not drop the one
    // that opens the window. The reader allows its listings the same.
    static let tolerance: TimeInterval = 0.5

    // Changing it keeps the readings: a shorter window drops the older ones
    // at the next pass, a longer one fills from what it has.
    public var length: TimeInterval

    private struct Point: Sendable {
        var uptime: TimeInterval
        var cpu: Double
        var energy: Double?
        var disk: Double?
        var memory: Double?
    }

    // One process's readings inside the window, oldest first.
    private struct Track: Sendable {
        var description: ProcessDescription
        var points: [Point] = []
        // The oldest reading still inside the window.
        var head = 0
        var memorySum = 0.0
    }

    private struct SystemPass: Sendable {
        var uptime: TimeInterval
        var samples: [Int32: ProcessSample]
    }

    // When each pass inside the window was read.
    private var times: [TimeInterval] = []
    private var tracks: [ProcessIdentity: Track] = [:]
    // The latest process to hold an identifier, for its GPU time.
    private var holder: [Int32: ProcessIdentity] = [:]
    // GPU seconds by process identifier at each pass, and the latest count with when it was read.
    private var gpuPasses: [[Int32: Double]] = []
    private var gpuLatest: [Int32: GPUCount] = [:]
    // System processes are read less often; their passes are kept by their
    // own clock, so their window is full between two reads as well.
    private var systemPasses: [SystemPass] = []

    private struct GPUCount: Sendable {
        var seconds: Double
        var uptime: TimeInterval
    }

    public init(length: TimeInterval = ActivityWindow.defaultLength) {
        self.length = length
    }

    public mutating func add(_ pass: ProcessPass) {
        times.append(pass.uptime)
        gpuPasses.append(pass.gpuSeconds)
        for (pid, seconds) in pass.gpuSeconds { gpuLatest[pid] = GPUCount(seconds: seconds, uptime: pass.uptime) }
        for sample in pass.own {
            let identity = sample.description.identity
            var track = tracks[identity] ?? Track(description: sample.description)
            track.description = sample.description
            track.points.append(Point(uptime: pass.uptime, cpu: sample.cpuSeconds, energy: sample.energyJoules, disk: sample.diskBytes,
                                      memory: sample.memoryBytes.map { Double($0) }))
            track.memorySum += Double(sample.memoryBytes ?? 0)
            tracks[identity] = track
            holder[identity.pid] = identity
        }
        let dropped = Self.opening(of: times, length: length)
        if dropped > 0 {
            times.removeFirst(dropped)
            gpuPasses.removeFirst(dropped)
            if let oldest = times.first { forget(before: oldest) }
        }

        guard let system = pass.system else { return }
        systemPasses.append(SystemPass(uptime: pass.uptime,
                                       samples: Dictionary(system.map { ($0.description.identity.pid, $0) }) { first, _ in first }))
        systemPasses.removeFirst(Self.opening(of: systemPasses.map(\.uptime), length: length))
    }

    // How many of the oldest passes fall out. The window opens at the first
    // pass inside it. While less than half of it has been read since then,
    // as when quick readings follow slow ones or a pass came late, it opens
    // at the pass before instead, unless that one is from long ago.
    private static func opening(of times: [TimeInterval], length: TimeInterval) -> Int {
        guard let latest = times.last else { return 0 }
        guard var first = times.firstIndex(where: { $0 >= latest - length - tolerance }) else { return 0 }
        if first > 0, latest - times[first] < max(shortest, length / 2) - tolerance, latest - times[first - 1] <= 2 * length + tolerance {
            first -= 1
        }
        return first
    }

    // Drops the readings from before the window's oldest pass, and a process
    // that has none left.
    private mutating func forget(before oldest: TimeInterval) {
        for (identity, var track) in tracks {
            var head = track.head
            while head < track.points.count, track.points[head].uptime < oldest {
                track.memorySum -= track.points[head].memory ?? 0
                head += 1
            }
            guard head != track.head else { continue }
            guard head < track.points.count else {
                tracks[identity] = nil
                if holder[identity.pid] == identity { holder[identity.pid] = nil }
                continue
            }
            // The array gives its front back once that is most of it.
            if head > 32, head > track.points.count / 2 {
                track.points.removeFirst(head)
                head = 0
            }
            track.head = head
            tracks[identity] = track
        }
        gpuLatest = gpuLatest.filter { $0.value.uptime >= oldest }
    }

    public func averages() -> ActivityAverages? {
        guard let oldest = times.first, let latest = times.last else { return nil }
        let span = latest - oldest
        guard span >= Self.shortest - Self.tolerance / 2 else { return nil }

        // A process without a GPU count at the window's start had used none.
        let gpuAtStart = gpuPasses.first ?? [:]
        func gpuPercent(_ pid: Int32) -> Double? {
            guard let end = gpuLatest[pid] else { return nil }
            return max(0, end.seconds - (gpuAtStart[pid] ?? 0)) / span * 100
        }

        // Of every process in the window, so one that ended stays with what started it.
        var parents: [Int32: Int32] = [:]
        var processes: [ProcessAverage] = []
        processes.reserveCapacity(tracks.count)
        for (identity, track) in tracks {
            guard let end = track.points.last else { continue }
            let begin = track.points[track.head]
            let holds = holder[identity.pid] == identity
            if holds || parents[identity.pid] == nil { parents[identity.pid] = track.description.parent }
            // A process that started inside the window used nothing before it.
            // One that was only missed at the start is counted from where it was first seen.
            let startedInside = begin.uptime != oldest && (track.description.startedUptime.map { $0 > oldest } ?? false)
            func used(_ value: (Point) -> Double?) -> Double? {
                value(end).map { max(0, $0 - (startedInside ? 0 : value(begin) ?? 0)) / span }
            }
            processes.append(ProcessAverage(
                description: track.description,
                cpuPercent: max(0, end.cpu - (startedInside ? 0 : begin.cpu)) / span * 100,
                memoryBytes: end.memory == nil ? nil : track.memorySum / Double(times.count),
                gpuPercent: holds ? gpuPercent(identity.pid) : nil,
                energyWatts: used(\.energy),
                diskBytesPerSecond: used(\.disk),
                ended: end.uptime != latest))
        }

        // System processes: only those of the newest read, over the span their own passes cover.
        if let newest = systemPasses.last, latest - newest.uptime <= length + Self.tolerance {
            for (pid, end) in newest.samples where holder[pid] == nil {
                parents[pid] = end.description.parent
                var cpuPercent: Double?
                if let earliest = systemPasses.first(where: { $0.samples[pid]?.description.executablePath == end.description.executablePath }),
                   let begin = earliest.samples[pid], newest.uptime - earliest.uptime >= Self.shortest - Self.tolerance {
                    cpuPercent = max(0, end.cpuSeconds - begin.cpuSeconds) / (newest.uptime - earliest.uptime) * 100
                }
                let gpu = gpuPercent(pid)
                guard cpuPercent != nil || gpu != nil else { continue }
                processes.append(ProcessAverage(description: end.description, cpuPercent: cpuPercent, gpuPercent: gpu))
            }
        }
        return ActivityAverages(seconds: min(span, length), processes: processes, parents: parents)
    }
}

// How often the processes are read (ADR 0005, ADR 0006): at one pace in the
// background and at another, which can be set quicker, while the lists are on
// screen or the menu bar menu is open.
public enum ActivityPace {
    public static let background: [TimeInterval] = [2, 5, 10, 30]
    public static let onScreen: [TimeInterval] = [1, 2, 5]
    public static let defaultBackground: TimeInterval = 5
    public static let defaultOnScreen: TimeInterval = 5

    // The time between two readings. A pace is never longer than the window.
    public static func interval(watched: Bool, background: TimeInterval, onScreen: TimeInterval, window: TimeInterval) -> TimeInterval {
        let pace = watched ? (Self.onScreen.contains(onScreen) ? onScreen : defaultOnScreen)
                           : (Self.background.contains(background) ? background : defaultBackground)
        return min(pace, window)
    }
}
