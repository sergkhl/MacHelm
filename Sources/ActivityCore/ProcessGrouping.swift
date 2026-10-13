import Foundation

public enum ProcessGroupKind: Hashable, Sendable {
    // A startup service, by its launchd label.
    case service(id: String)
    case windowsProgram
    // Wine's own background processes.
    case wineBackground
    case app(bundlePath: String)
    // A program outside any app bundle.
    case process
    case system
}

// What one row of Activity stands for.
public struct ProcessGroupID: Hashable, Sendable {
    public var kind: ProcessGroupKind
    public var name: String
    // Who started this copy of the app; empty for a copy that launchd started and for every other kind.
    public var origin: [String]

    public init(kind: ProcessGroupKind, name: String, origin: [String] = []) {
        self.kind = kind
        self.name = name
        self.origin = origin
    }
}

// The process launchd started for a startup service.
public struct ServiceRoot: Equatable, Sendable {
    public var id: String
    public var name: String
    public var pid: Int32
    // Whether Startup Services can stop it: a service that is only shown there cannot be.
    public var canStop: Bool

    public init(id: String, name: String, pid: Int32, canStop: Bool = true) {
        self.id = id
        self.name = name
        self.pid = pid
        self.canStop = canStop
    }
}

public enum ProcessGrouping {
    // In this order: a system process stands alone; then a startup service
    // takes its process and everything that process started; then a Windows
    // program; then an app with its helpers, one row for each origin; then a
    // program by its name.
    public static func group(of process: ProcessDescription, parents: [Int32: Int32], services: [Int32: ServiceRoot]) -> ProcessGroupID {
        guard process.isOwn else { return ProcessGroupID(kind: .system, name: process.name) }
        if let service = service(above: process.identity.pid, parents: parents, services: services) {
            return ProcessGroupID(kind: .service(id: service.id), name: service.name)
        }
        switch process.wine {
        case .program(let name): return ProcessGroupID(kind: .windowsProgram, name: name)
        case .background: return ProcessGroupID(kind: .wineBackground, name: "Wine")
        case nil: break
        }
        // A copy of an app that another program started is a row of its own,
        // and a helper that launchd started counts toward its responsible app.
        if let bundle = bundlePath(in: process.executablePath) ?? process.adoptedBy {
            return ProcessGroupID(kind: .app(bundlePath: bundle), name: ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension,
                                  origin: process.origin)
        }
        return ProcessGroupID(kind: .process, name: process.name)
    }

    private static func service(above pid: Int32, parents: [Int32: Int32], services: [Int32: ServiceRoot]) -> ServiceRoot? {
        var current = pid
        // A chain of parents is short; the bound guards against a loop in a stale table.
        var steps = 0
        while current > 1, steps < 64 {
            if let service = services[current] { return service }
            guard let parent = parents[current] else { return nil }
            current = parent
            steps += 1
        }
        return nil
    }

    // The outermost app bundle, so a helper inside an app counts as that app.
    static func bundlePath(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}
