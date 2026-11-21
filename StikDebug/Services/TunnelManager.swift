import Foundation
import Combine
import UIKit

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var isConnected = false
    @Published private(set) var isStarting = false
    @Published private(set) var lastError: NSError?
    @Published private(set) var lastDiagnosis: ConnectionDiagnosis?
    @Published private(set) var connectionTarget: String?
    @Published private(set) var remoteDeviceDescription: String?

    private init() {}

    func markDisconnected() {
        precondition(Thread.isMainThread)
        guard !isStarting, !MountingProgress.shared.isPreparing,
              !LocationSimulationSession.shared.preventsConnectionChanges else { return }
        isConnected = false
        connectionTarget = nil
        remoteDeviceDescription = nil
        lastError = nil
        lastDiagnosis = nil
        MountingProgress.shared.reset()
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !isStarting, !MountingProgress.shared.isPreparing,
              !LocationSimulationSession.shared.preventsConnectionChanges else { return }
        markDisconnected()
        let targetIP = DeviceConnectionContext.targetIPAddress
        connectionTarget = targetIP.isEmpty ? nil : targetIP
        if let message = DeviceConnectionContext.validationMessage(for: targetIP) {
            finishStart(.failure(ConnectionDiagnostics.annotate(
                NSError(domain: "StikDebug", code: -18, userInfo: [NSLocalizedDescriptionKey: message]),
                stage: .targetAddress, targetIP: targetIP)), targetIP: targetIP)
            return
        }
        guard FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) else {
            finishStart(.failure(ConnectionDiagnostics.annotate(
                NSError(domain: "StikDebug", code: -17, userInfo: [NSLocalizedDescriptionKey: "Import the remote iPhone's Remote Pairing file."]),
                stage: .pairingFile, targetIP: targetIP)), targetIP: targetIP)
            return
        }
        isStarting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try DeviceTunnelContext.shared.startTunnel() }
            DispatchQueue.main.async {
                self.finishStart(result, targetIP: targetIP)
            }
        }
    }

    private func finishStart(_ result: Result<Void, Error>, targetIP: String) {
        isStarting = false
        switch result {
        case .success:
            lastError = nil
            lastDiagnosis = nil
            if let info = DeviceTunnelContext.shared.targetInfo {
                remoteDeviceDescription = "\(DeviceModelName.name(for: info.productType)) - iOS \(info.productVersion)"
            }
            isConnected = true
            LogManager.shared.addInfoLog("Connected to remote iPhone at \(targetIP)")
            MountingProgress.shared.pubMount()
        case .failure(let error):
            let error = error as NSError
            lastDiagnosis = ConnectionDiagnostics.diagnose(error, targetIP: targetIP)
            lastError = error
            isConnected = false
            LogManager.shared.addErrorLog("Remote connection to \(targetIP) failed: \(error.localizedDescription) (code \(error.code))")
        }
    }
}

func connectionDiagnosticDetails() -> String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    var systemInfo = utsname()
    uname(&systemInfo)
    let model = withUnsafePointer(to: &systemInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }

    return """
    Controller app version: \(version)
    Controller OS: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
    Controller model: \(DeviceModelName.name(for: model))
    """
}
