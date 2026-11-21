import Foundation
import Darwin

@main
struct RemoteConnectionTests {
    static func main() {
        checkImageMounterSessionLifetime()
        checkPairingFormats()
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

    private static func checkImageMounterSessionLifetime() {
        enum Failure: Error { case mounter, lockdown, query, operation }
        let scenarios: [Failure?] = [nil, .mounter, .lockdown, .query, .operation]
        for failure in scenarios {
            var events: [String] = []
            var mounterIsOpen = false
            var lockdownIsOpen = false
            var lockdownWasOpened = false
            do {
                let result = try LegacyImageMounterSession.withSession(
                    openMounter: { () throws -> Int in
                        events.append("open mounter")
                        if failure == .mounter { throw Failure.mounter }
                        mounterIsOpen = true
                        return 1
                    },
                    closeMounter: { _ in
                        expect(mounterIsOpen, "Mounter must close exactly once")
                        expect(!lockdownWasOpened || lockdownIsOpen, "Keep Lockdown alive until the mounter is released")
                        mounterIsOpen = false
                        events.append("close mounter")
                    },
                    openLockdown: { () throws -> Int in
                        expect(mounterIsOpen, "Open the follow-up Lockdown session after the mounter")
                        events.append("open lockdown")
                        if failure == .lockdown { throw Failure.lockdown }
                        lockdownIsOpen = true
                        lockdownWasOpened = true
                        return 2
                    },
                    closeLockdown: { _ in
                        expect(lockdownIsOpen && !mounterIsOpen, "Release Lockdown after the mounter")
                        lockdownIsOpen = false
                        events.append("close lockdown")
                    },
                    queryLockdown: { _ in
                        expect(mounterIsOpen && lockdownIsOpen, "Query a live session after opening the mounter")
                        events.append("query lockdown")
                        if failure == .query { throw Failure.query }
                    },
                    operation: { _ in
                        expect(mounterIsOpen && lockdownIsOpen, "Retain both connections throughout image operations")
                        events.append("operate")
                        if failure == .operation { throw Failure.operation }
                        return 42
                    }
                )
                expect(failure == nil && result == 42, "Return the operation result only on success")
            } catch let error as Failure {
                expect(error == failure, "Propagate the original error; never interpret a read failure as an unmounted image")
            } catch { fatalError("Unexpected session test error: \(error)") }
            expect(!mounterIsOpen && !lockdownIsOpen, "Release all opened handles on every exit path")
            let expected: [String]
            switch failure {
            case .mounter: expected = ["open mounter"]
            case .lockdown: expected = ["open mounter", "open lockdown", "close mounter"]
            case .query: expected = ["open mounter", "open lockdown", "query lockdown", "close mounter", "close lockdown"]
            case .operation, nil: expected = ["open mounter", "open lockdown", "query lockdown", "operate", "close mounter", "close lockdown"]
            }
            expect(events == expected, "Preserve the required startup, query, operation and cleanup order")
        }
    }

    private static func checkPairingFormats() {
        // Synthetic schemas only; no real certificates or device identifiers in tests.
        let lockdown: [String: Any] = ["HostID": "test-host", "SystemBUID": "test-system", "HostCertificate": Data([1]), "HostPrivateKey": Data([2])]
        let remote: [String: Any] = ["public_key": Data([1]), "private_key": Data([2]), "identifier": "test-peer"]
        do {
            for serialization in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
                let legacyData = try PropertyListSerialization.data(fromPropertyList: lockdown, format: serialization, options: 0)
                let remoteData = try PropertyListSerialization.data(fromPropertyList: remote, format: serialization, options: 0)
                expect(tryFormat(legacyData) == .lockdown, "Lockdown files do not require public_key")
                expect(tryFormat(remoteData) == .remotePairing, "Remote Pairing uses its own schema")
            }
            let incomplete = try PropertyListSerialization.data(fromPropertyList: ["HostID": "test"], format: .xml, options: 0)
            expect(tryFormat(incomplete) == nil, "Incomplete schemas must not start a connection")
            expect(tryFormat(Data("not a plist".utf8)) == nil, "Malformed files must be rejected")
            let legacyInfo = try RemoteDeviceInfo(productVersion: "16.7.12", productType: "iPhone10,6")
            expect(legacyInfo.legacyImageVersion == "16.7", "Choose DDI from target major/minor, not controller version or target patch")
            expect(legacyInfo.version.majorVersion == 16, "Remote iOS version remains distinct from controller")
            expect(legacyInfo.productType == "iPhone10,6", "Retain the actual remote model identifier")
            expect((try? RemoteDeviceInfo(productVersion: "16.bad.1", productType: "test"))?.productVersion == nil, "Reject malformed target versions")
        } catch { fatalError("Pairing schema test setup failed: \(error)") }
    }

    private static func tryFormat(_ data: Data) -> PairingFileFormat? {
        try? PairingFileFormat.detect(data: data)
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
