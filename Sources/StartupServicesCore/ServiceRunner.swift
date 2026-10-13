import Foundation

// The job launchd actually starts. It looks up one definition, applies its
// working directory, environment and umask, and then becomes the definition's
// own command in the same process. launchd therefore watches, signals, times
// out and restarts the command itself, exactly as it did before the takeover.
//
// A runner that stayed as the parent of the command was tried first. On a
// stop, launchd killed that parent at its exit timeout and left a command
// that had not yet exited running without a registration, so it is not used.
public enum ServiceRunner {
    // What launchd itself reports for a job it cannot start.
    public static let configurationFailure: Int32 = 78
    public static let temporaryFailure: Int32 = 75

    public static func run(label: String, paths: StartupServicesPaths,
                           processes: ProcessInspecting = SystemProcessInspector()) -> Never {
        let recordURL = paths.runRecord(label)
        var record = ServiceRunRecord(label: label, pid: getpid(), startedAt: Date())
        record.processStartTime = processes.startTime(of: getpid())

        func report(_ message: String) {
            FileHandle.standardError.write(Data("MacHelm service runner: \(message)\n".utf8))
        }
        func fail(_ message: String, _ status: Int32) -> Never {
            record.failure = message
            try? record.write(to: recordURL)
            report(message)
            exit(status)
        }

        // A process from an earlier run that is still alive still owns the
        // service's data. Its record is kept so the next attempt sees it too.
        if let previous = ServiceRunRecord.read(recordURL), previous.isAlive(processes) {
            report("The previous run's process (PID \(previous.pid)) is still alive; a second one was not started.")
            exit(temporaryFailure)
        }

        let definition: ServiceDefinition
        do {
            guard let found = try ServiceCatalogStore(paths: paths).read().service(label), found.isManaged else {
                fail("\(label) is not a managed service in the catalog.", configurationFailure)
            }
            definition = found
        } catch {
            fail("\(error)", configurationFailure)
        }

        let command = definition.command
        if let directory = command.workingDirectory, chdir(directory) != 0 {
            fail("Cannot enter the working directory \(directory): \(String(cString: strerror(errno)))", configurationFailure)
        }
        guard access(command.program, X_OK) == 0 else {
            fail("The program is missing or cannot be executed: \(command.program)", configurationFailure)
        }
        // Recorded before the command takes over this process: same PID, same start time.
        do { try record.write(to: recordURL) } catch {
            fail("Cannot record the start: \(error)", temporaryFailure)
        }
        if let mask = command.umask { umask(mode_t(mask)) }
        for (name, value) in command.environment { setenv(name, value, 1) }

        var argv: [UnsafeMutablePointer<CChar>?] = command.arguments.map { strdup($0) }
        argv.append(nil)
        execv(command.program, argv)
        // Only reached when the command could not take over.
        let reason = String(cString: strerror(errno))
        for pointer in argv { free(pointer) }
        fail("Cannot start \(command.program): \(reason)", configurationFailure)
    }
}
