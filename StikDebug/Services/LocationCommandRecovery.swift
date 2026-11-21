import Foundation

/// Executes each location command once and propagates its first error to the caller.
enum LocationCommandRecovery {
    /// Legacy dt.simulatelocation is one command per connection. Never reuse a client,
    /// even after a successful write: the write has no application-level acknowledgement.
    static func withFreshConnection<Client, Value>(
        open: () throws -> Client,
        close: (Client) -> Void,
        operation: (Client) throws -> Value
    ) throws -> Value {
        let client = try open()
        defer { close(client) }
        return try operation(client)
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
