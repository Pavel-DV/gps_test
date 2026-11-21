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
        try checkOneCommandPerConnection()
        checkQueuedResends()
        print("Location command recovery and resend checks passed")
    }

    private static func checkOneCommandPerConnection() throws {
        final class OneShotClient {
            var used = false
            var closed = false
        }
        var opened: [OneShotClient] = []
        var applied: [Int] = []
        func open() -> OneShotClient {
            let client = OneShotClient()
            opened.append(client)
            return client
        }
        // Model the actual failure: a second write to a consumed connection returns
        // without throwing, but no second command is applied by the peer.
        func send(_ value: Int, on client: OneShotClient) {
            expect(!client.closed, "A command must never use a closed resource")
            if client.used { return }
            client.used = true
            applied.append(value)
        }
        for point in [1, 2, 3] {
            try LocationCommandRecovery.withFreshConnection(open: open, close: { $0.closed = true }, operation: { send(point, on: $0) })
        }
        expect(applied == [1, 2, 3], "Consecutive successful writes must reach separate one-command connections")
        expect(opened.count == 3 && opened.allSatisfy({ $0.closed }), "Close each successful command instead of caching its client")

        opened = []
        var attempts = 0
        try LocationCommandRecovery.withFreshConnection(open: open, close: { $0.closed = true }, operation: { client in
            attempts += 1
            if attempts == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE)) }
            expect(opened.count == 2 && opened[0].closed, "Release the failed client before opening a retry")
            send(4, on: client)
        })
        expect(attempts == 2 && opened.allSatisfy({ $0.closed }), "Every retry owns and releases a new connection")
        expect(applied.last == 4, "A retried command must still apply the requested point")

        opened = []
        let permanent = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "DeveloperModeNotEnabled"])
        do {
            try LocationCommandRecovery.withFreshConnection(open: open, close: { $0.closed = true }, operation: { (_: OneShotClient) throws -> Void in throw permanent })
            fatalError("Do not swallow a permanent command failure")
        } catch let error as NSError {
            expect(error === permanent && opened.count == 1 && opened[0].closed, "Release permanent failures without retrying")
        }
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
