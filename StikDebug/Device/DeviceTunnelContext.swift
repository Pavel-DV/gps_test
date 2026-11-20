//
//  DeviceTunnelContext.swift
//  StikDebug
//
//  Created by Stephen on 2026/3/30.
//

import Foundation
import idevice
import Darwin
import Network

final class RemotePairingPortResolver {
    static let fallback: UInt16 = 49152
    private static let overrideKey = "TunnelRemotePairingPort"
    private static let stateLock = NSLock()
    private static var selectedEndpoint = "Not attempted yet"

    /// The precise port and discovery method used for the latest connection attempt.
    static var lastAttemptDescription: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedEndpoint
    }

    private static func record(targetIPAddress: String, port: UInt16, source: String) {
        let endpoint = "\(targetIPAddress):\(port) (\(source))"
        stateLock.lock()
        selectedEndpoint = endpoint
        stateLock.unlock()
        NSLog("[StikDebug] Remote Pairing selected endpoint: %@", endpoint)
    }

    private let discoveryQueue = DispatchQueue(label: "com.stik.remotePairingDiscovery")
    private let completion = DispatchSemaphore(value: 0)
    private var browser: NWBrowser?
    private var resolvedPort: UInt16?
    private var finished = false
    private var remoteConnections: [NWEndpoint: NWConnection] = [:]

    static func resolve(targetIPAddress: String = DeviceConnectionContext.targetIPAddress, timeout: TimeInterval = 5) -> UInt16 {
        let override = (UserDefaults.standard.string(forKey: overrideKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty, let port = UInt16(override), port != 0 {
            record(targetIPAddress: targetIPAddress, port: port, source: "Manual")
            return port
        }
        if !override.isEmpty {
            NSLog("[StikDebug] Ignoring invalid manual Remote Pairing port: %@", override)
        }

        let result = discover(targetIPAddress: targetIPAddress, timeout: timeout)
        record(targetIPAddress: targetIPAddress, port: result.port, source: result.source)
        return result.port
    }

    static func discover(targetIPAddress: String = DeviceConnectionContext.targetIPAddress, timeout: TimeInterval = 5) -> (port: UInt16, source: String) {
        let worker = RemotePairingPortResolver()
        worker.discoveryQueue.async {
            worker.startDiscovery(targetIPAddress: targetIPAddress)
        }
        _ = worker.completion.wait(timeout: .now() + timeout)
        return worker.discoveryQueue.sync {
            worker.finishDiscovery()
            if let port = worker.resolvedPort {
                return (port, "Bonjour")
            }
            return (fallback, "Fallback")
        }
    }

    private func startDiscovery(targetIPAddress: String) {
        guard !finished else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let options = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            options.version = .v4
        }
        let browser = NWBrowser(
            for: .bonjour(type: "_remotepairing._tcp", domain: "local."),
            using: parameters
        )
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.finished else { return }
            // Accept a port only from the requested phone, never from a nearby device.
            for result in results where self.remoteConnections[result.endpoint] == nil {
                let connection = NWConnection(to: result.endpoint, using: parameters)
                self.remoteConnections[result.endpoint] = connection
                let inspect = { [weak self, weak connection] in
                    guard let self, let connection, !self.finished,
                          case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint,
                          case .ipv4(let address) = host,
                          address == IPv4Address(targetIPAddress), port.rawValue != 0 else { return }
                    self.resolvedPort = port.rawValue
                    self.finishDiscovery()
                }
                connection.pathUpdateHandler = { _ in inspect() }
                connection.stateUpdateHandler = { _ in inspect() }
                connection.start(queue: self.discoveryQueue)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.finishDiscovery()
            }
        }
        browser.start(queue: discoveryQueue)
    }

    private func finishDiscovery() {
        guard !finished else { return }
        finished = true
        browser?.cancel()
        remoteConnections.values.forEach { $0.cancel() }
        remoteConnections.removeAll()
        completion.signal()
    }

}

final class DeviceTunnelContext {
    static let shared = DeviceTunnelContext()

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?

        mutating func free() {
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

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private(set) var targetVersion: OperatingSystemVersion?

    private let tunnelLock = NSLock()
    private var tunnelConnecting = false
    private var tunnelSemaphore: DispatchSemaphore?
    private var lastTunnelError: NSError?

    var adapterHandle: OpaquePointer? { adapter }
    var handshakeHandle: OpaquePointer? { handshake }

    private init() {
        var path = Array(IdeviceLogFileManager.logURL.path.utf8CString)
        path.withUnsafeMutableBufferPointer { buffer in
            // Debug logging includes pairing-file credentials and protocol payloads.
            _ = idevice_init_logger(Info, Info, buffer.baseAddress)
        }
    }

    deinit {
        if let handshake {
            rsd_handshake_free(handshake)
        }
        if let adapter {
            adapter_free(adapter)
        }
    }

    private func makeError(_ message: String, code: Int = -1) -> NSError {
        NSError(
            domain: "StikDebug",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func nsString(from cString: UnsafePointer<CChar>?, fallback: String) -> String {
        guard let cString, let string = String(validatingUTF8: cString) else {
            return fallback
        }
        return string
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else {
            return makeError(fallback)
        }
        let detail = nsString(from: ffiError.pointee.message, fallback: fallback)
        let message = detail == fallback ? fallback : "\(fallback): \(detail)"
        let error = makeError(message, code: Int(ffiError.pointee.code))
        idevice_error_free(ffiError)
        return error
    }

    private func getPairingFile() throws -> OpaquePointer {
        let pairingFileURL = PairingFileStore.prepareURL()

        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw makeError("Pairing file not found!", code: -17)
        }

        var pairingFile: OpaquePointer?
        let ffiError = pairingFileURL.path.withCString { path in
            rp_pairing_file_read(path, &pairingFile)
        }

        if let ffiError {
            throw error(from: ffiError, fallback: "Failed to read pairing file!")
        }

        guard let pairingFile else {
            throw makeError("Failed to read pairing file!", code: -17)
        }

        return pairingFile
    }

    private func createTunnel(hostname: String) throws -> TunnelHandles {
        let deviceIP = DeviceConnectionContext.targetIPAddress
        if let message = DeviceConnectionContext.validationMessage(for: deviceIP) {
            throw ConnectionDiagnostics.annotate(makeError(message, code: -18), stage: .targetAddress, targetIP: deviceIP)
        }
        let pairingFile: OpaquePointer
        do {
            pairingFile = try getPairingFile()
        } catch {
            throw ConnectionDiagnostics.annotate(error as NSError, stage: .pairingFile, targetIP: deviceIP)
        }
        defer { rp_pairing_file_free(pairingFile) }

        var remotePairingPort: UInt16?
        let address: Data
        do {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
            guard parseResult == 1 else {
                throw ConnectionDiagnostics.annotate(makeError("Failed to parse target IP address.", code: -18), stage: .targetAddress, targetIP: deviceIP)
            }
            let port = RemotePairingPortResolver.resolve(targetIPAddress: deviceIP)
            remotePairingPort = port
            addr.sin_port = port.bigEndian
            address = withUnsafeBytes(of: &addr) { Data($0) }
        }

        var socketAddress = sockaddr_storage()
        guard address.count <= MemoryLayout<sockaddr_storage>.size else {
            throw makeError("Invalid target network address.", code: -18)
        }
        withUnsafeMutableBytes(of: &socketAddress) { _ = address.copyBytes(to: $0) }
        var tunnel = TunnelHandles()
        let ffiError = hostname.withCString { hostname in
            withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(address.count),
                        hostname,
                        pairingFile,
                        nil,
                        nil,
                        &tunnel.adapter,
                        &tunnel.handshake
                    )
                }
            }
        }

        if let ffiError {
            tunnel.free()
            throw ConnectionDiagnostics.annotate(error(from: ffiError, fallback: "Failed to create tunnel"), stage: .tunnel, targetIP: deviceIP, port: remotePairingPort)
        }

        guard tunnel.adapter != nil, tunnel.handshake != nil else {
            var incompleteTunnel = tunnel
            incompleteTunnel.free()
            throw makeError("Tunnel was created without valid handles")
        }

        return tunnel
    }

    func startTunnel() throws {
        tunnelLock.lock()
        if tunnelConnecting {
            let waitSemaphore = tunnelSemaphore
            tunnelLock.unlock()

            if let waitSemaphore {
                guard waitSemaphore.wait(timeout: .now() + .seconds(15)) == .success else {
                    throw makeError("Timed out waiting for the tunnel connection", code: -19)
                }
                waitSemaphore.signal()
            }

            if let lastTunnelError {
                throw lastTunnelError
            }
            return
        }

        tunnelConnecting = true
        let completionSemaphore = DispatchSemaphore(value: 0)
        tunnelSemaphore = completionSemaphore
        tunnelLock.unlock()

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        var finalError: NSError?

        defer {
            tunnelLock.lock()
            tunnelConnecting = false
            tunnelSemaphore = nil
            lastTunnelError = finalError
            tunnelLock.unlock()
            completionSemaphore.signal()
        }

        do {
            let newTunnel = try createTunnel(hostname: "StikDebug")
            newAdapter = newTunnel.adapter
            newHandshake = newTunnel.handshake
        } catch let tunnelError as NSError {
            finalError = tunnelError
            throw tunnelError
        }

        if let handshake {
            rsd_handshake_free(handshake)
        }
        if let adapter {
            adapter_free(adapter)
        }

        adapter = newAdapter
        handshake = newHandshake
        targetVersion = nil
        do {
            targetVersion = try readTargetVersion()
        } catch {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
            handshake = nil
            adapter = nil
            finalError = error as NSError
            throw error
        }
    }

    func ensureTunnel() throws {
        if adapter == nil || handshake == nil {
            try startTunnel()
        }
    }

}
