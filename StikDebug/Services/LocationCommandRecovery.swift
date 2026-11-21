import Foundation
import Darwin

/// Setting an absolute coordinate and clearing it are idempotent. Retry once on a transport failure.
enum LocationCommandRecovery {
    static func run<Value>(operation: () throws -> Value, reset: () -> Void) throws -> Value {
        do {
            return try operation()
        } catch {
            guard isTransientConnectionError(error) else { throw error }
            reset()
            return try operation()
        }
    }

    /// Legacy dt.simulatelocation is one command per connection. Never reuse a client,
    /// even after a successful write: the write has no application-level acknowledgement.
    static func withFreshConnection<Client, Value>(
        open: () throws -> Client,
        close: (Client) -> Void,
        operation: (Client) throws -> Value
    ) throws -> Value {
        try run(operation: {
            let client = try open()
            defer { close(client) }
            return try operation(client)
        }, reset: {})
    }

    static func isTransientConnectionError(_ error: Error) -> Bool {
        let error = error as NSError
        let text = error.localizedDescription.lowercased()
        // Reopening a service cannot repair a failed heartbeat or rejected authorization.
        let permanent = ["heartbeat", "pairing file", "pairing record", "invalidhostid", "invalid host id",
                         "pairverify", "developer mode", "developermodenotenabled", "passwordprotected", "device locked", "devicelocked", "servicenotfound", "service not found"]
        guard !permanent.contains(where: text.contains) else { return false }
        if error.domain == NSPOSIXErrorDomain {
            return [Int(EPIPE), Int(ECONNRESET), Int(ECONNABORTED), Int(ENOTCONN), Int(ETIMEDOUT)].contains(error.code)
        }
        return ["broken pipe", "brokenpipe", "connection reset", "connectionreset", "connection aborted",
                "connectionaborted", "unexpectedeof", "unexpected eof", "peer closed", "not connected",
                "noestablishedconnection", "timed out"].contains(where: text.contains)
    }
}

/// Invalidates resends already waiting on the command queue when the user selects a new point or stops.
final class LocationResendGate {
    private let lock = NSLock()
    private var generation = UUID()

    func replace() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        generation = UUID()
        return generation
    }

    func invalidate() { _ = replace() }

    func isCurrent(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token
    }
}
