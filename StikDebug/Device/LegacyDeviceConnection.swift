import Foundation
import Darwin
import idevice

/// Authenticated, direct TCP services used by an iOS 16 target. No RemoteXPC tunnel.
final class LegacyDeviceConnection {
    let provider: OpaquePointer

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
    }

    deinit { idevice_provider_free(provider) }

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
        defer { lockdownd_client_free(client) }
        return try IdeviceBridge.readDeviceInfo(client: client)
    }

    func withImageMounter<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        // Opening the mounter alone is insufficient on legacy devices. Query Lockdown
        // AFTER it connects, and retain that authenticated session until the mounter closes.
        try LegacyImageMounterSession.withSession(
            openMounter: {
                try IdeviceBridge.connectClient(
                    fallback: "Failed to connect to remote iOS 16 image mounter",
                    missingClientMessage: "Image mounter was not created",
                    connect: { image_mounter_connect(self.provider, $0) }
                )
            },
            closeMounter: { image_mounter_free($0) },
            openLockdown: { try self.openAuthenticatedLockdown() },
            closeLockdown: { lockdownd_client_free($0) },
            queryLockdown: { client in
                _ = try IdeviceBridge.readDeviceInfo(client: client)
            },
            operation: body
        )
    }

    func isImageMounted() throws -> Bool {
        try withImageMounter { client in
            var devices: UnsafeMutablePointer<plist_t?>?
            var count = 0
            if let error = image_mounter_copy_devices(client, &devices, &count) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to inspect remote developer images")
            }
            defer {
                if let devices {
                    for index in 0..<count { plist_free(devices[index]) }
                    idevice_data_free(UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self), UInt(count * MemoryLayout<plist_t?>.stride))
                }
            }
            return count > 0
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
