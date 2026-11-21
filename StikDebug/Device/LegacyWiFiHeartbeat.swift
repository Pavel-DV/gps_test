import Foundation
import idevice

/// One network heartbeat for the entire legacy device connection, not per service.
final class LegacyWiFiHeartbeat {
    private let state: State

    /// Takes ownership of both handles, including when the initial exchange fails.
    init(client: OpaquePointer, lockdown: OpaquePointer) throws {
        let state = State(client: client, lockdown: lockdown)
        self.state = state
        let interval: UInt64
        do {
            interval = try state.exchange(wait: 10)
        } catch {
            state.finish()
            throw error
        }
        let thread = Thread { state.run(initialInterval: interval) }
        thread.name = "StikDebug Wi-Fi heartbeat"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func ensureAlive() throws { try state.ensureAlive() }

    /// Called on the connection worker, before replacing a device/heartbeat.
    /// Waiting prevents a late close of the old heartbeat from killing the new host services.
    func stop() { state.stopAndWait() }

    deinit { state.stopAndWait() }

    private final class State {
        private let client: OpaquePointer
        private let lockdown: OpaquePointer
        private let lock = NSLock()
        private let finished = DispatchGroup()
        private var stopping = false
        private var closed = false
        private var failure: NSError?

        init(client: OpaquePointer, lockdown: OpaquePointer) {
            self.client = client
            self.lockdown = lockdown
            finished.enter()
        }

        func exchange(wait: UInt64) throws -> UInt64 {
            var nextInterval: UInt64 = 0
            if let error = heartbeat_get_marco(client, wait, &nextInterval) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Wi-Fi heartbeat: failed to receive Marco")
            }
            if let error = heartbeat_send_polo(client) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Wi-Fi heartbeat: failed to send Polo")
            }
            return nextInterval
        }

        private var shouldStop: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopping
        }

        func run(initialInterval: UInt64) {
            defer { finish() }
            var interval = initialInterval
            while !shouldStop {
                do {
                    interval = try exchange(wait: min(30, max(10, interval > 25 ? 30 : interval + 5)))
                } catch {
                    lock.lock()
                    let intentional = stopping
                    if !intentional { failure = error as NSError }
                    lock.unlock()
                    if !intentional { LogManager.shared.addErrorLog("Legacy Wi-Fi heartbeat stopped: \(error.localizedDescription)") }
                    return
                }
            }
        }

        func ensureAlive() throws {
            lock.lock()
            let error = failure
            let inactive = stopping || closed
            lock.unlock()
            if let error { throw error }
            if inactive {
                throw IdeviceBridge.makeError(message: "The remote Wi-Fi heartbeat is no longer active. Reconnect to the target iPhone.")
            }
        }

        func stopAndWait() {
            lock.lock()
            stopping = true
            lock.unlock()
            finished.wait()
        }

        func finish() {
            lock.lock()
            guard !closed else { lock.unlock(); return }
            closed = true
            lock.unlock()
            heartbeat_client_free(client)
            lockdownd_client_free(lockdown)
            finished.leave()
        }
    }
}
