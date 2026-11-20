import Foundation
import Darwin

@main
struct RemoteConnectionTests {
    static func main() {
        let defaults = UserDefaults.standard
        let key = DeviceConnectionContext.targetAddressKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        expect(DeviceConnectionContext.targetIPAddress.isEmpty, "A new install must not default to the controller VPN")
        defaults.set("10.7.0.1", forKey: key)
        expect(DeviceConnectionContext.targetIPAddress.isEmpty, "An old saved VPN endpoint must not be reused")
        defaults.set(" 192.0.2.25 \n", forKey: key)
        expect(DeviceConnectionContext.targetIPAddress == "192.0.2.25", "Retain an explicit remote address")

        for address in ["", "localhost", "::1", "192.168.1.999", "0.0.0.0", "0.1.2.3", "127.0.0.1", "127.42.0.1", "224.0.0.1", "255.255.255.255", "10.7.0.1"] {
            expect(DeviceConnectionContext.validationMessage(for: address) != nil, "Reject invalid or local target: \(address)")
        }
        expect(DeviceConnectionContext.validationMessage(for: "192.0.2.25") == nil, "Accept a remote IPv4 address")
        checkControllerInterfaces()

        let reset = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        expect(ConnectionDiagnostics.knownProblem(reset) == .connectionInterrupted, "A POSIX reset is not pairing rejection")
        let ffiReset = error("Failed to create tunnel: Socket(Os { code: 54, message: Connection reset by peer })", stage: .tunnel)
        expect(ConnectionDiagnostics.knownProblem(ffiReset) == .connectionInterrupted, "An FFI reset is not pairing rejection")
        expect(ConnectionDiagnostics.knownProblem(error("PairVerifyFailed", stage: .tunnel)) == .pairingRejected, "Explicit authentication rejection remains visible")
        expect(ConnectionDiagnostics.knownProblem(error("InvalidHostID", stage: .tunnel)) == .pairingRejected, "Explicit host rejection remains visible")
        expect(ConnectionDiagnostics.knownProblem(error("plist missing field public_key", stage: .pairingFile)) == .pairingFile, "An incompatible file is a file-format error")
        expect(ConnectionDiagnostics.knownProblem(error("invalid", stage: .targetAddress)) == .invalidAddress, "Address errors precede pairing")
        expect(ConnectionDiagnostics.knownProblem(error("DeveloperModeNotEnabled", stage: .tunnel)) == .developerMode, "Developer Mode failures remain distinct")
        expect(ConnectionDiagnostics.knownProblem(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))) == .serviceUnreachable, "Timeouts are network failures")
        expect(ConnectionDiagnostics.knownProblem(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))) == .connectionRefused, "Refusal is distinct from authentication")
        expect(ConnectionDiagnostics.diagnose(error("Unexpected response", stage: .tunnel), targetIP: "192.0.2.25").problem == .unknown, "Do not guess authentication failure")
        let annotated = ConnectionDiagnostics.annotate(reset, stage: .tunnel, targetIP: "192.0.2.25", port: 50123)
        expect(annotated.userInfo["ConnectionTargetIP"] as? String == "192.0.2.25", "Preserve the selected remote endpoint")
        expect(annotated.userInfo["ConnectionPort"] as? Int == 50123, "Preserve the attempted port")
        print("Remote connection regression checks passed")
    }

    private static func checkControllerInterfaces() {
        var first: UnsafeMutablePointer<ifaddrs>?
        expect(getifaddrs(&first) == 0, "Read controller interfaces")
        defer { freeifaddrs(first) }
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            var address = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                fatalError("Could not format controller address")
            }
            let string = String(cString: buffer)
            expect(DeviceConnectionContext.validationMessage(for: string) != nil, "Reject controller's own address: \(string)")
        }
    }

    private static func error(_ message: String, stage: ConnectionDiagnostics.Stage) -> NSError {
        ConnectionDiagnostics.annotate(NSError(domain: "StikDebug", code: -1,
                                               userInfo: [NSLocalizedDescriptionKey: message]),
                                       stage: stage, targetIP: "192.0.2.25")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
