import Foundation
import Darwin
import idevice

/// Authenticated, direct TCP services used by an iOS 16 target. No RemoteXPC tunnel.
final class LegacyDeviceConnection {
    let provider: OpaquePointer
    let targetIP: String
    private var heartbeat: LegacyWiFiHeartbeat?

    init(targetIP: String, pairingURL: URL) throws {
        if let message = DeviceConnectionContext.validationMessage(for: targetIP) {
            throw IdeviceBridge.makeError(message: message)
        }
        var pairing: OpaquePointer?
        if let error = pairingURL.path.withCString({ idevice_pairing_file_read($0, &pairing) }) {
            throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to read Lockdown pairing file")
        }
        guard let pairing else { throw IdeviceBridge.makeError(message: "Lockdown pairing file was not loaded") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(62078).bigEndian
        guard targetIP.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            idevice_pairing_file_free(pairing)
            throw IdeviceBridge.makeError(message: "Invalid remote address")
        }
        var result: OpaquePointer?
        let error = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                idevice_tcp_provider_new($0, pairing, "StikDebugLegacy", &result)
            }
        }
        if let error {
            // The provider consumes the pairing handle only on success.
            idevice_pairing_file_free(pairing)
            throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to create Lockdown provider")
        }
        guard let result else { throw IdeviceBridge.makeError(message: "Lockdown provider was not created") }
        provider = result
        self.targetIP = targetIP
    }

    deinit {
        heartbeat?.stop()
        idevice_provider_free(provider)
    }

    func stopHeartbeat() { heartbeat?.stop() }

    func ensureHeartbeat() throws {
        guard let heartbeat else { throw IdeviceBridge.makeError(message: "The remote Wi-Fi heartbeat has not been started.") }
        try heartbeat.ensureAlive()
    }

    private func openAuthenticatedLockdown() throws -> OpaquePointer {
        let client = try IdeviceBridge.connectClient(
            fallback: "Cannot reach remote Lockdown on port 62078. Enable Wi-Fi syncing for the paired target on a computer, keep it unlocked, and check LAN access.",
            missingClientMessage: "Lockdown client was not created",
            connect: { lockdownd_connect(self.provider, $0) }
        )
        do {
            var pairing: OpaquePointer?
            if let error = idevice_provider_get_pairing_file(provider, &pairing) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to load Lockdown session credentials")
            }
            guard let pairing else { throw IdeviceBridge.makeError(message: "Missing Lockdown session credentials") }
            defer { idevice_pairing_file_free(pairing) }
            if let error = lockdownd_start_session(client, pairing) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "The remote iPhone did not accept the Lockdown session")
            }
            return client
        } catch {
            lockdownd_client_free(client)
            throw error
        }
    }

    func readDeviceInfo() throws -> RemoteDeviceInfo {
        let client = try openAuthenticatedLockdown()
        var sessionTransferred = false
        defer { if !sessionTransferred { lockdownd_client_free(client) } }
        let info = try IdeviceBridge.readDeviceInfo(client: client)
        if heartbeat == nil {
            var port: UInt16 = 0
            var usesTLS = false
            let socket = try openServiceSocket(lockdown: client, name: "com.apple.mobile.heartbeat", port: &port, usesTLS: &usesTLS)
            var handle: OpaquePointer?
            // heartbeat_new consumes the socket on entry.
            if let error = heartbeat_new(socket, &handle) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to initialize Wi-Fi heartbeat")
            }
            guard let handle else { throw IdeviceBridge.makeError(message: "Wi-Fi heartbeat client was not created") }
            sessionTransferred = true
            heartbeat = try LegacyWiFiHeartbeat(client: handle, lockdown: client)
            LogManager.shared.addInfoLog("[Legacy Wi-Fi] Heartbeat active: Marco received and Polo sent")
        }
        try ensureHeartbeat()
        return info
    }

    /// Uses the service's negotiated SSL flag and retains the session that started it.
    private func openServiceSocket(lockdown: OpaquePointer, name: String, port: inout UInt16, usesTLS: inout Bool) throws -> OpaquePointer {
        if let error = lockdownd_start_service(lockdown, name, &port, &usesTLS) {
            throw IdeviceBridge.consumeFFIError(error, fallback: "StartService(\(name)) failed")
        }
        guard port != 0 else { throw IdeviceBridge.makeError(message: "The remote service returned port zero") }
        LogManager.shared.addInfoLog("[Legacy Wi-Fi] \(name): endpoint=\(targetIP):\(port), TLS=\(usesTLS)")
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard targetIP.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw IdeviceBridge.makeError(message: "Invalid remote service address")
        }
        var socket: OpaquePointer?
        let connectError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                idevice_new_tcp_socket($0, socklen_t(MemoryLayout<sockaddr_in>.size), "StikDebugService", &socket)
            }
        }
        if let connectError { throw IdeviceBridge.consumeFFIError(connectError, fallback: "Remote service TCP connect failed") }
        guard let socket else { throw IdeviceBridge.makeError(message: "Remote service socket was not created") }
        var socketTransferred = false
        defer { if !socketTransferred { idevice_free(socket) } }
        if usesTLS {
            var pairing: OpaquePointer?
            if let error = idevice_provider_get_pairing_file(provider, &pairing) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to load service TLS credentials")
            }
            guard let pairing else { throw IdeviceBridge.makeError(message: "Missing service TLS credentials") }
            defer { idevice_pairing_file_free(pairing) }
            // iOS 16 does not use the pre-iOS-5 TLS compatibility mode.
            if let error = idevice_start_session(socket, pairing, false) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Remote service TLS handshake failed")
            }
        }
        socketTransferred = true
        return socket
    }

    private func openImageMounter(lockdown: OpaquePointer, port: inout UInt16, usesTLS: inout Bool) throws -> OpaquePointer {
        let socket = try openServiceSocket(lockdown: lockdown, name: "com.apple.mobile.mobile_image_mounter", port: &port, usesTLS: &usesTLS)
        var mounter: OpaquePointer?
        // image_mounter_new consumes a non-null IdeviceHandle on entry.
        let error = image_mounter_new(socket, &mounter)
        if let error { throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to wrap image-mounter socket") }
        guard let mounter else { throw IdeviceBridge.makeError(message: "Image mounter was not created") }
        return mounter
    }

    /// A dt.simulatelocation client is valid for one command, including a clear.
    func openLocationCommand() throws -> LegacyLocationCommandConnection {
        try ensureHeartbeat()
        let lockdown = try openAuthenticatedLockdown()
        var transferred = false
        defer { if !transferred { lockdownd_client_free(lockdown) } }
        var port: UInt16 = 0
        var usesTLS = false
        let socket = try openServiceSocket(lockdown: lockdown, name: "com.apple.dt.simulatelocation", port: &port, usesTLS: &usesTLS)
        var client: OpaquePointer?
        // This constructor takes ownership of the service socket on entry.
        if let error = lockdown_location_simulation_new(socket, &client) {
            throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to create a fresh iOS 16 location command")
        }
        guard let client else { throw IdeviceBridge.makeError(message: "The fresh location client was not created") }
        transferred = true
        return LegacyLocationCommandConnection(client: client, lockdown: lockdown)
    }

    func withImageMounter<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try ensureHeartbeat()
        var port: UInt16 = 0
        var usesTLS = false
        var stage = "authenticate Lockdown"
        do {
            return try LegacyImageMounterSession.withSession(
                openLockdown: { try self.openAuthenticatedLockdown() },
                closeLockdown: { lockdownd_client_free($0) },
                openMounter: { lockdown in
                    stage = "start/connect image mounter"
                    return try self.openImageMounter(lockdown: lockdown, port: &port, usesTLS: &usesTLS)
                },
                closeMounter: { image_mounter_free($0) },
                queryLockdown: { client in
                    stage = "query retained Lockdown session"
                    _ = try IdeviceBridge.readDeviceInfo(client: client)
                },
                operation: { client in
                    stage = "image-mounter command"
                    return try body(client)
                }
            )
        } catch {
            let error = error as NSError
            var info = error.userInfo
            let endpoint = port == 0 ? targetIP : "\(targetIP):\(port)"
            let tls = port == 0 ? "not negotiated" : String(usesTLS)
            info[NSLocalizedDescriptionKey] = "iOS 16 DDI [\(stage), endpoint=\(endpoint), TLS=\(tls)]: \(error.localizedDescription)"
            throw NSError(domain: error.domain, code: error.code, userInfo: info)
        }
    }

    func isImageMounted() throws -> Bool {
        try withImageMounter { client in
            var signature: UnsafeMutablePointer<UInt8>?
            var signatureLength = 0
            defer { if let signature { idevice_data_free(signature, UInt(signatureLength)) } }
            let error = image_mounter_lookup_image(client, "Developer", &signature, &signatureLength)
            let variant = error.flatMap { IdeviceBridge.string(from: $0.pointee.message) }
            let result = LegacyDeveloperImageLookup.outcome(signatureLength: signatureLength,
                                                           errorVariant: error == nil ? nil : (variant ?? "UnknownFFIError"))
            if let error {
                if result == .notMounted {
                    idevice_error_free(error)
                    LogManager.shared.addInfoLog("[Legacy DDI] LookupImage(Developer): not mounted")
                    return false
                }
                throw IdeviceBridge.consumeFFIError(error, fallback: "LookupImage(Developer) failed")
            }
            guard result == .mounted, signature != nil else {
                throw IdeviceBridge.makeError(message: "LookupImage(Developer) returned no signature and no explicit NotFound result")
            }
            LogManager.shared.addInfoLog("[Legacy DDI] LookupImage(Developer): mounted")
            return true
        }
    }

    func mountImage(from directory: URL) throws {
        let image = try IdeviceBridge.mappedFileData(atPath: directory.appendingPathComponent("DeveloperDiskImage.dmg").path, description: "iOS 16 developer image")
        let signature = try IdeviceBridge.mappedFileData(atPath: directory.appendingPathComponent("DeveloperDiskImage.dmg.signature").path, description: "iOS 16 developer image signature")
        try withImageMounter { client in
            let error = image.withUnsafeBytes { bytes in
                signature.withUnsafeBytes { signatureBytes in
                    image_mounter_mount_developer(client, bytes.bindMemory(to: UInt8.self).baseAddress, image.count,
                                                  signatureBytes.bindMemory(to: UInt8.self).baseAddress, signature.count)
                }
            }
            if let error { throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to mount remote iOS 16 developer image") }
        }
    }
}

/// Keeps the service's originating Lockdown session alive until its single command is closed.
final class LegacyLocationCommandConnection {
    let client: OpaquePointer
    private let lockdown: OpaquePointer
    private var isClosed = false

    init(client: OpaquePointer, lockdown: OpaquePointer) {
        self.client = client
        self.lockdown = lockdown
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        lockdown_location_simulation_free(client)
        lockdownd_client_free(lockdown)
    }

    deinit { close() }
}
