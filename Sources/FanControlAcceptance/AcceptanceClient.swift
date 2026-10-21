import Foundation
import FanControlCore

enum AcceptanceError: Error, LocalizedError {
    case failed(String)
    case helperReply(String)
    var errorDescription: String? {
        switch self { case .failed(let message), .helperReply(let message): return message }
    }
}

protocol AcceptanceClient: AnyObject {
    var peerPID: Int32? { get }
    func status(observe: Bool) async throws -> FanStatus
    func begin(profile: Data) async throws -> FanStatus
    func update(session: String, profile: Data) async throws -> FanStatus
    func renew(session: String) async throws -> Bool
    func stop() async throws -> FanStatus
    func close()
}

// Each RPC finishes once, including late replies after a timeout. A timeout
// rejects the evidence; it does not claim that the remote operation was undone.
final class AcceptanceReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

final class XPCFanAcceptanceClient: AcceptanceClient, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var transportError: String?
    private let timeout: TimeInterval
    var peerPID: Int32? { connection.processIdentifier > 0 ? connection.processIdentifier : nil }

    init(requirement: String, timeout: TimeInterval = 3) {
        self.timeout = timeout
        connection = NSXPCConnection(machServiceName: FanServiceIdentity.helper, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPC.self)
        // Same audit-backed helper identifier/team requirement as the GUI. The
        // separately recorded static cdhash is expected artifact context only.
        connection.setCodeSigningRequirement(requirement)
        connection.invalidationHandler = { [weak self] in self?.failed("Authenticated XPC connection invalidated.") }
        connection.interruptionHandler = { [weak self] in self?.failed("Authenticated XPC connection interrupted.") }
        connection.resume()
    }

    deinit { connection.invalidate() }
    func close() { connection.invalidate() }
    private func failed(_ message: String) {
        lock.lock(); transportError = message; lock.unlock()
    }
    private func currentError() -> String? {
        lock.lock(); defer { lock.unlock() }; return transportError
    }

    private func request<Value>(_ label: String, timeout: TimeInterval? = nil,
                                send: @escaping (FanControlXPC, @escaping (Value) -> Void) -> Void) async throws -> Value {
        if let error = currentError() { throw AcceptanceError.failed(error) }
        return try await withCheckedThrowingContinuation { continuation in
            let receipt = AcceptanceReply(continuation)
            let limit = timeout ?? self.timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                receipt.finish(.failure(AcceptanceError.failed("\(label) did not reply within \(limit) seconds. No receipt is inferred.")))
            }
            guard let proxy = self.connection.remoteObjectProxyWithErrorHandler({ error in
                receipt.finish(.failure(error))
            }) as? FanControlXPC else {
                receipt.finish(.failure(AcceptanceError.failed("Authenticated fan XPC proxy is unavailable.")))
                return
            }
            send(proxy) { receipt.finish(.success($0)) }
        }
    }

    private func decode(_ data: Data) throws -> FanStatus {
        guard data.count <= 262_144 else { throw AcceptanceError.helperReply("Oversized helper status reply.") }
        let status: FanStatus
        do { status = try JSONDecoder().decode(FanStatus.self, from: data) }
        catch { throw AcceptanceError.helperReply("Malformed helper status reply: \(error.localizedDescription)") }
        guard status.protocolVersion == FanStatus.currentProtocolVersion else {
            throw AcceptanceError.helperReply("Incompatible helper status protocol \(status.protocolVersion).")
        }
        return status
    }
    func status(observe: Bool) async throws -> FanStatus {
        let status = try decode(await request("handshake") {
            $0.handshake(protocolVersion: FanStatus.currentProtocolVersion, observe: observe, reply: $1)
        })
        if let error = status.requestError { throw AcceptanceError.helperReply(error) }
        return status
    }
    func begin(profile: Data) async throws -> FanStatus {
        _ = try await status(observe: false)
        return try decode(await request("begin", timeout: 6) { $0.begin(profile: profile, reply: $1) })
    }
    func update(session: String, profile: Data) async throws -> FanStatus {
        _ = try await status(observe: false)
        return try decode(await request("update") { $0.update(session: session, profile: profile, reply: $1) })
    }
    func renew(session: String) async throws -> Bool {
        _ = try await status(observe: false)
        return try await request("renew") { $0.renew(session: session, reply: $1) }
    }
    func stop() async throws -> FanStatus {
        _ = try await status(observe: false)
        return try decode(await request("stop", timeout: 6) { $0.stop(reply: $1) })
    }
}
