import Foundation
import Darwin
import idevice

enum IdeviceBridge {

    static func makeError(
        domain: String = "StikDebug",
        code: Int = -1,
        message: String
    ) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func string(from cString: UnsafePointer<CChar>?) -> String? {
        guard let cString else { return nil }
        return String(validatingUTF8: cString)
    }

    static func consumeFFIError(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
        fallback: String,
        domain: String = "StikDebug"
    ) -> NSError {
        guard let ffiError else {
            return makeError(domain: domain, message: fallback)
        }

        let code = Int(ffiError.pointee.code)
        let detail = string(from: ffiError.pointee.message) ?? fallback
        let message = detail == fallback ? fallback : "\(fallback): \(detail)"
        idevice_error_free(ffiError)
        return makeError(domain: domain, code: code, message: message)
    }

    static func mappedFileData(atPath path: String, description: String) throws -> Data {
        let url = URL(fileURLWithPath: path)

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else {
                throw makeError(message: "\(description) is empty")
            }
            return data
        } catch let error as NSError {
            throw makeError(code: error.code, message: "Failed to read \(description): \(error.localizedDescription)")
        }
    }

    static func uint64Value(from plist: plist_t?, fieldName: String) throws -> UInt64 {
        guard let plist else {
            throw makeError(message: "\(fieldName) was not returned by lockdownd")
        }

        var value: UInt64 = 0
        plist_get_uint_val(plist, &value)

        guard value != 0 else {
            throw makeError(message: "Failed to decode \(fieldName)")
        }

        return value
    }

    static func withTunnelHandles<T>(
        for context: DeviceTunnelContext,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        let handles = try activeTunnelHandles(for: context)
        return try body(handles.adapter, handles.handshake)
    }

    static func connectClient(
        fallback: String,
        missingClientMessage: String,
        domain: String = "StikDebug",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws -> OpaquePointer {
        var client: OpaquePointer?
        if let ffiError = connect(&client) {
            throw consumeFFIError(ffiError, fallback: fallback, domain: domain)
        }

        guard let client else {
            throw makeError(domain: domain, message: missingClientMessage)
        }

        return client
    }

    static func withConnectedClient<T>(
        fallback: String,
        missingClientMessage: String,
        domain: String = "StikDebug",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: (OpaquePointer) -> Void,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let client = try connectClient(
            fallback: fallback,
            missingClientMessage: missingClientMessage,
            domain: domain,
            connect: connect
        )
        defer { cleanup(client) }
        return try body(client)
    }

    static func activeTunnelHandles(for context: DeviceTunnelContext) throws -> (adapter: OpaquePointer, handshake: OpaquePointer) {
        try context.ensureTunnel()

        guard let adapterHandle = context.adapterHandle,
              let handshakeHandle = context.handshakeHandle else {
            throw makeError(message: "Tunnel is not connected")
        }

        return (adapterHandle, handshakeHandle)
    }
}

extension IdeviceBridge {
    static func readDeviceInfo(client: OpaquePointer) throws -> RemoteDeviceInfo {
        func stringValue(_ key: String) throws -> String {
            var value: plist_t?
            defer { plist_free(value) }
            let error = key.withCString { lockdownd_get_value(client, $0, nil, &value) }
            if let error { throw consumeFFIError(error, fallback: "Failed to read remote \(key)") }
            guard let value, let result = string(from: plist_get_string_ptr(value, nil)) else {
                throw makeError(message: "Remote \(key) was not returned")
            }
            return result
        }
        return try RemoteDeviceInfo(productVersion: stringValue("ProductVersion"), productType: stringValue("ProductType"))
    }
}

extension DeviceTunnelContext {
    func readTargetInfo() throws -> RemoteDeviceInfo {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to target lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) }, cleanup: { lockdownd_client_free($0) }
            ) { try IdeviceBridge.readDeviceInfo(client: $0) }
        }
    }

    func isDeveloperDiskImageMounted() throws -> Bool {
        if let legacyConnection { return try legacyConnection.isImageMounted() }
        return try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            var cryptexQuerySucceeded = false
            var cryptexQueryError: NSError?
            if DeveloperDiskImageService.usesCryptexDDI {
                var installed: UnsafeMutablePointer<InstalledCryptexC>?
                defer { cryptexd_free_installed_cryptex(installed) }
                if let ffiError = cryptexd_installed_ddi(adapter, handshake, &installed) {
                    cryptexQueryError = IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query installed DDI cryptex")
                } else {
                    cryptexQuerySucceeded = true
                    if installed != nil {
                        return true
                    }
                }
            }

            do {
                return try IdeviceBridge.withConnectedClient(
                    fallback: "Failed to connect to image mounter",
                    missingClientMessage: "Image mounter client was not created",
                    connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                    cleanup: { image_mounter_free($0) }
                ) { client in
                    var devices: UnsafeMutablePointer<plist_t?>?
                    var deviceCount = 0
                    if let error = image_mounter_copy_devices(client, &devices, &deviceCount) {
                        throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to fetch mounted devices")
                    }
                    if let devices {
                        for index in 0..<deviceCount {
                            plist_free(devices[index])
                        }
                        idevice_data_free(
                            UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                            UInt(deviceCount * MemoryLayout<plist_t?>.stride)
                        )
                    }
                    return deviceCount > 0
                }
            } catch {
                if cryptexQuerySucceeded {
                    return false
                }
                throw cryptexQueryError ?? (error as NSError)
            }
        }
    }

    func installCryptexDDI(from directoryPath: String) throws {
        var assets: OpaquePointer?
        if let ffiError = cryptex1_assets_load(directoryPath, &assets) {
            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to load DDI cryptex assets")
        }

        guard let assets else {
            throw IdeviceBridge.makeError(message: "DDI cryptex assets were not loaded")
        }
        defer { cryptex1_assets_free(assets) }

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            if let ffiError = cryptexd_install_ddi(adapter, handshake, assets, nil) {
                throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to install DDI cryptex")
            }
        }
    }

    func mountPersonalDDI(withImagePath imagePath: String, trustcachePath: String, manifestPath: String) throws {
        let imageData = try IdeviceBridge.mappedFileData(atPath: imagePath, description: "developer disk image")
        let trustcacheData = try IdeviceBridge.mappedFileData(atPath: trustcachePath, description: "developer disk image trust cache")
        let manifestData = try IdeviceBridge.mappedFileData(atPath: manifestPath, description: "developer disk image manifest")

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            let uniqueChipID = try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
                cleanup: { lockdownd_client_free($0) }
            ) { lockdownClient in
                var uniqueChipIDPlist: plist_t?
                if let ffiError = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &uniqueChipIDPlist) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query UniqueChipID")
                }
                defer { plist_free(uniqueChipIDPlist) }
                return try IdeviceBridge.uint64Value(from: uniqueChipIDPlist, fieldName: "UniqueChipID")
            }

            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to image mounter",
                missingClientMessage: "Image mounter client was not created",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { imageMounterClient in
                let ffiError = imageData.withUnsafeBytes { imageBuffer in
                    trustcacheData.withUnsafeBytes { trustcacheBuffer in
                        manifestData.withUnsafeBytes { manifestBuffer in
                            image_mounter_mount_personalized_rsd(
                                imageMounterClient,
                                adapter,
                                handshake,
                                imageBuffer.bindMemory(to: UInt8.self).baseAddress,
                                imageData.count,
                                trustcacheBuffer.bindMemory(to: UInt8.self).baseAddress,
                                trustcacheData.count,
                                manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                                manifestData.count,
                                nil,
                                uniqueChipID
                            )
                        }
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to mount personalized DDI")
                }
            }
        }
    }

}

private enum LocationSimulationStatus {
    static let ok: Int32 = 0
    static let invalidIP: Int32 = 1
    static let pairingRead: Int32 = 2
    static let providerCreate: Int32 = 3
    static let remoteServer: Int32 = 9
    static let locationSimulation: Int32 = 10
    static let locationSet: Int32 = 11
    static let locationClear: Int32 = 12
}

private enum LocationSimulationState {
    static var adapter: OpaquePointer?
    static var handshake: OpaquePointer?
    static var remoteServer: OpaquePointer?
    static var locationSimulation: OpaquePointer?

    static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }
}

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "com.stik.location-sim", qos: .userInitiated)
    // Read/write only on shared, and capture before dispatching a result to the UI.
    private(set) static var lastFailureDetail: String?

    static func beginCommand() { lastFailureDetail = nil }

    static func recordFailure(_ error: Error) {
        lastFailureDetail = error.localizedDescription
        LogManager.shared.addErrorLog(error.localizedDescription)
    }

    static func recordFFIFailure(_ error: UnsafeMutablePointer<IdeviceFfiError>, context: String) {
        recordFailure(IdeviceBridge.consumeFFIError(error, fallback: context))
    }
}

private enum LegacyLocationCommands {
    static func set(deviceIP: String, latitude: Double, longitude: Double) -> Int32 {
        do {
            guard let legacy = DeviceTunnelContext.shared.legacyConnection,
                  legacy.targetIP == deviceIP else {
                throw IdeviceBridge.makeError(message: "The selected legacy target is not connected")
            }
            try LocationCommandRecovery.withFreshConnection(
                open: { try legacy.openLocationCommand() },
                close: { $0.close() },
                operation: { command in
                    try legacy.ensureHeartbeat()
                    let error = String(latitude).withCString { lat in
                        String(longitude).withCString { lon in lockdown_location_simulation_set(command.client, lat, lon) }
                    }
                    if let error { throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to send remote iOS 16 location") }
                }
            )
            // This protocol does not return a GPS/application acknowledgement.
            return LocationSimulationStatus.ok
        } catch {
            LocationSimulationCommandQueue.recordFailure(error)
            return LocationSimulationStatus.locationSet
        }
    }

    static func clear(on legacy: LegacyDeviceConnection) -> Int32 {
        do {
            try LocationCommandRecovery.withFreshConnection(
                open: { try legacy.openLocationCommand() },
                close: { $0.close() },
                operation: { command in
                    try legacy.ensureHeartbeat()
                    if let error = lockdown_location_simulation_clear(command.client) {
                        throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to send remote iOS 16 location clear")
                    }
                }
            )
            return LocationSimulationStatus.ok
        } catch {
            LocationSimulationCommandQueue.recordFailure(error)
            return LocationSimulationStatus.locationClear
        }
    }
}

func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    LocationSimulationCommandQueue.beginCommand()
    if let message = DeviceConnectionContext.validationMessage(for: deviceIP) {
        LocationSimulationCommandQueue.recordFailure(IdeviceBridge.makeError(message: message))
        return LocationSimulationStatus.invalidIP
    }
    if DeviceTunnelContext.shared.legacyConnection != nil {
        return LegacyLocationCommands.set(deviceIP: deviceIP, latitude: latitude, longitude: longitude)
    }
    if let locationSimulation = LocationSimulationState.locationSimulation {
        if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
            LocationSimulationCommandQueue.recordFFIFailure(ffiError, context: "Failed to update location through the existing remote service")
            LocationSimulationState.cleanup()
            return LocationSimulationStatus.locationSet
        } else {
            return LocationSimulationStatus.ok
        }
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(RemotePairingPortResolver.resolve(targetIPAddress: deviceIP)).bigEndian

    let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    guard inetResult == 1 else {
        return LocationSimulationStatus.invalidIP
    }

    var pairingHandle: OpaquePointer?
    let pairingError = pairingFile.withCString { rp_pairing_file_read($0, &pairingHandle) }
    if let pairingError {
        LocationSimulationCommandQueue.recordFFIFailure(pairingError, context: "Failed to read Remote Pairing file")
        return LocationSimulationStatus.pairingRead
    }

    guard let pairingHandle else {
        return LocationSimulationStatus.pairingRead
    }

    defer { rp_pairing_file_free(pairingHandle) }

    let providerError = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            tunnel_create_rppairing(
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.stride),
                "StikDebugLocation",
                pairingHandle,
                nil,
                nil,
                &LocationSimulationState.adapter,
                &LocationSimulationState.handshake
            )
        }
    }

    if let providerError {
        LocationSimulationCommandQueue.recordFFIFailure(providerError, context: "Failed to create location tunnel")
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.providerCreate
    }

    let remoteServerError = remote_server_connect_rsd(
        LocationSimulationState.adapter,
        LocationSimulationState.handshake,
        &LocationSimulationState.remoteServer
    )
    if let remoteServerError {
        LocationSimulationCommandQueue.recordFFIFailure(remoteServerError, context: "Failed to connect remote location server")
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.remoteServer
    }

    let locationSimulationError = location_simulation_new(
        LocationSimulationState.remoteServer,
        &LocationSimulationState.locationSimulation
    )
    if let locationSimulationError {
        LocationSimulationCommandQueue.recordFFIFailure(locationSimulationError, context: "Failed to open remote location simulation service")
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSimulation
    }

    LocationSimulationState.remoteServer = nil

    let locationSetError = location_simulation_set(
        LocationSimulationState.locationSimulation,
        latitude,
        longitude
    )
    if let locationSetError {
        LocationSimulationCommandQueue.recordFFIFailure(locationSetError, context: "Failed to set remote location")
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSet
    }

    return LocationSimulationStatus.ok
}

func clear_simulated_location() -> Int32 {
    LocationSimulationCommandQueue.beginCommand()
    if let legacy = DeviceTunnelContext.shared.legacyConnection {
        return LegacyLocationCommands.clear(on: legacy)
    }
    guard let locationSimulation = LocationSimulationState.locationSimulation else {
        return LocationSimulationStatus.locationClear
    }

    let ffiError = location_simulation_clear(locationSimulation)
    LocationSimulationState.cleanup()

    if let ffiError {
        LocationSimulationCommandQueue.recordFFIFailure(ffiError, context: "Failed to clear remote location")
        return LocationSimulationStatus.locationClear
    }

    return LocationSimulationStatus.ok
}
