import Foundation
import Darwin

@main
struct FanAcceptanceMain {
    static func main() async {
        if CommandLine.arguments.dropFirst().contains("--help") {
            print(AcceptanceOptions.help)
            return
        }
        var log: AcceptanceJSONL?
        var client: XPCFanAcceptanceClient?
        do {
            let options = try AcceptanceOptions.parse(Array(CommandLine.arguments.dropFirst()))
            let evidence = try AcceptanceJSONL(path: options.outputPath); log = evidence
            try evidence.record("command_selected", details: ["command": options.command.rawValue,
                                "nativeWriteSelection": String(options.command == .roundTrip)])
            let context = try AcceptanceArtifactContext.capture(appPath: options.appPath,
                                        rejectedFixtureTeam: options.command == .rejectedClient ? options.expectedTeam : nil)
            try evidence.context(context)
            let primary = XPCFanAcceptanceClient(requirement: context.helperAuthenticationRequirement); client = primary
            let runner = FanAcceptanceRunner(primary: primary, makeSecondary: {
                XPCFanAcceptanceClient(requirement: context.helperAuthenticationRequirement)
            }, log: evidence)
            switch options.command {
            case .status: try await runner.status(samples: options.samples)
            case .hostileInputs: try await runner.hostileInputs()
            case .rejectedClient: try await runner.rejectedClient()
            case .roundTrip: try await runner.roundTrip(duration: options.duration!)
            }
            primary.close()
            if options.command == .rejectedClient {
                print("Untrusted-client rejection observed; corroborate the available authenticated service before accepting security. Evidence: \(options.outputPath)")
            } else { print("Selected qualification completed. Evidence: \(options.outputPath)") }
        } catch {
            try? log?.firstFailure(error.localizedDescription)
            client?.close()
            fputs("Fan acceptance stopped: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
