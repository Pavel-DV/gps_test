import Foundation
import Darwin

@main
struct LocationCommandRecoveryTests {
    static func main() throws {
        var attempts = 0
        var resets = 0
        var sentCoordinates: [Double] = []
        let requestedLatitude = 12.345
        let result = try LocationCommandRecovery.run(operation: {
            attempts += 1
            sentCoordinates.append(requestedLatitude)
            if attempts == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE)) }
            return "sent"
        }, reset: { resets += 1 })
        expect(result == "sent" && attempts == 2 && resets == 1, "A stale service gets exactly one reset and retry")
        expect(sentCoordinates == [requestedLatitude, requestedLatitude], "A retry must send the same requested point")

        attempts = 0
        resets = 0
        let finalError = NSError(domain: "Test", code: 99, userInfo: [NSLocalizedDescriptionKey: "Socket(ConnectionReset)"])
        do {
            _ = try LocationCommandRecovery.run(operation: { () throws -> Bool in
                attempts += 1
                if attempts == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET)) }
                throw finalError
            }, reset: { resets += 1 })
            fatalError("The second failure must reach the caller")
        } catch let error as NSError {
            expect(error === finalError && attempts == 2 && resets == 1, "Do not loop; preserve the final error for diagnostics")
        }

        for detail in ["PairVerifyFailed", "InvalidHostID", "DeveloperModeNotEnabled", "PasswordProtected",
                       "Wi-Fi heartbeat: Socket(ConnectionReset)", "DeviceLocked: Socket(ConnectionReset)",
                       "ServiceNotFound: Socket(ConnectionReset)", "UnexpectedResponse", "Missing pairing file"] {
            attempts = 0
            resets = 0
            let permanent = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
            do {
                _ = try LocationCommandRecovery.run(operation: { () throws -> Bool in
                    attempts += 1
                    throw permanent
                }, reset: { resets += 1 })
                fatalError("Permanent failures must be surfaced")
            } catch let error as NSError {
                expect(error === permanent && attempts == 1 && resets == 0, "Never retry authorization, heartbeat or protocol errors")
            }
        }
        for detail in ["Socket(Custom { kind: UnexpectedEof })", "BrokenPipe", "ConnectionReset", "peer closed connection", "Socket timed out"] {
            expect(LocationCommandRecovery.isTransientConnectionError(NSError(domain: "Test", code: 1,
                   userInfo: [NSLocalizedDescriptionKey: detail])), "Recognize wrapped transient socket errors")
        }
        checkQueuedResends()
        print("Location command recovery and resend checks passed")
    }

    private static func checkQueuedResends() {
        let gate = LocationResendGate()
        let queue = DispatchQueue(label: "test.location-resends")
        let release = DispatchSemaphore(value: 0)
        let staleWasSent = DispatchSemaphore(value: 0)
        let currentWasSent = DispatchSemaphore(value: 0)
        let old = gate.replace()
        queue.async {
            release.wait()
            if gate.isCurrent(old) { staleWasSent.signal() }
        }
        let current = gate.replace()
        queue.async { if gate.isCurrent(current) { currentWasSent.signal() } }
        release.signal()
        queue.sync {}
        expect(staleWasSent.wait(timeout: .now()) == .timedOut, "A queued old coordinate must not run after changing the point")
        expect(currentWasSent.wait(timeout: .now()) == .success, "The current coordinate must remain eligible")

        let releaseStop = DispatchSemaphore(value: 0)
        let sentAfterStop = DispatchSemaphore(value: 0)
        queue.async {
            releaseStop.wait()
            if gate.isCurrent(current) { sentAfterStop.signal() }
        }
        gate.invalidate()
        releaseStop.signal()
        queue.sync {}
        expect(sentAfterStop.wait(timeout: .now()) == .timedOut, "Stop must invalidate even a resend already waiting in the queue")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
