import Foundation
import Darwin

@main
struct LocationCommandRecoveryTests {
    static func main() throws {
        checkFirstFailureIsSurfaced()
        try checkOneCommandPerConnection()
        checkQueuedResends()
        print("Single-attempt location command and resend checks passed")
    }

    private static func checkFirstFailureIsSurfaced() {
        let failures = [
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        ] + ["Socket(Custom { kind: UnexpectedEof })", "Socket timed out", "PairVerifyFailed",
             "DeveloperModeNotEnabled", "Wi-Fi heartbeat: Socket(ConnectionReset)"].map {
            NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: $0])
        }
        for failure in failures {
            var opens = 0
            var sends = 0
            var closes = 0
            do {
                try LocationCommandRecovery.withFreshConnection(open: { opens += 1; return opens },
                    close: { _ in closes += 1 }, operation: { (_: Int) throws -> Void in
                        sends += 1
                        throw failure
                    })
                fatalError("The first command failure must reach the caller")
            } catch let error as NSError {
                expect(error === failure, "Preserve the original error without replacing it")
                expect(opens == 1 && sends == 1 && closes == 1, "Release the failed command without retrying")
            }

            opens = 0
            sends = 0
            closes = 0
            do {
                try LocationCommandRecovery.withFreshConnection(open: { () throws -> Int in
                    opens += 1
                    throw failure
                }, close: { _ in closes += 1 }, operation: { _ in sends += 1 })
                fatalError("The first connection failure must reach the caller")
            } catch let error as NSError {
                expect(error === failure && opens == 1 && sends == 0 && closes == 0,
                       "Do not retry opening or send a command after a failed open")
            }
        }
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
        let failure = NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))
        do {
            try LocationCommandRecovery.withFreshConnection(open: open, close: { $0.closed = true }, operation: { (_: OneShotClient) throws -> Void in
                throw failure
            })
            fatalError("Do not swallow a failed send")
        } catch let error as NSError {
            expect(error === failure && opened.count == 1 && opened[0].closed, "Close the first failed connection without opening another")
            expect(applied == [1, 2, 3], "A failed command must not trigger a hidden send")
        }
        // Only an explicit subsequent call may open another connection and send again.
        try LocationCommandRecovery.withFreshConnection(open: open, close: { $0.closed = true }, operation: { send(4, on: $0) })
        expect(opened.count == 2 && opened.allSatisfy({ $0.closed }), "A manual retry owns a new connection")
        expect(applied == [1, 2, 3, 4], "An explicit subsequent command still works after a failure")
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
