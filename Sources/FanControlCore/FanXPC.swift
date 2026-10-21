import Foundation

public enum FanServiceIdentity {
    public static let app = "io.github.sergkhl.MacHelm"
    public static let helper = "io.github.sergkhl.MacHelm.FanControlHelper"
    public static let plist = helper + ".plist"
}

@objc public protocol FanControlXPC {
    func status(observe: Bool, reply: @escaping (Data) -> Void)
    func handshake(protocolVersion: Int, observe: Bool, reply: @escaping (Data) -> Void)
    func begin(profile: Data, reply: @escaping (Data) -> Void)
    func update(session: String, profile: Data, reply: @escaping (Data) -> Void)
    func renew(session: String, reply: @escaping (Bool) -> Void)
    func stop(reply: @escaping (Data) -> Void)
    func prepareForRemoval(reply: @escaping (Data) -> Void)
    func confirmExternalRecovery(recoveryID: String, reply: @escaping (Data) -> Void)
    // Protocol 4. One bounded attempt to return the recorded fans to automatic.
    func restoreAutomatic(recoveryID: String, reply: @escaping (Data) -> Void)
}
