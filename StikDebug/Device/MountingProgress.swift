import Foundation
import Combine

final class MountingProgress: ObservableObject {
    static let shared = MountingProgress()

    @Published private(set) var isPreparing = false
    @Published private(set) var coolisMounted = false
    @Published private(set) var lastError: String?

    private init() {}

    func reset() {
        precondition(Thread.isMainThread)
        guard !isPreparing else { return }
        coolisMounted = false
        lastError = nil
    }

    func pubMount() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.pubMount() }
            return
        }
        guard TunnelManager.shared.isConnected, !isPreparing,
              !LocationSimulationSession.shared.preventsConnectionChanges else { return }
        isPreparing = true
        coolisMounted = false
        lastError = nil

        Task { @MainActor in
            defer { isPreparing = false }
            do {
                // Check the target before downloading potentially large assets.
                let mounted = try await performDeviceOperation {
                    try DeviceTunnelContext.shared.isDeveloperDiskImageMounted()
                }
                if mounted {
                    coolisMounted = true
                    return
                }
                try await DeveloperDiskImageService.shared.downloadMissingFiles()
                try await performDeviceOperation {
                    if let error = mountDeveloperDiskImage(from: DeveloperDiskImageService.directoryURL.path) {
                        // Some devices finish installing despite a late transport error.
                        guard (try? DeviceTunnelContext.shared.isDeveloperDiskImageMounted()) == true else {
                            throw NSError(domain: "StikDebug", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: error])
                        }
                    }
                    guard try DeviceTunnelContext.shared.isDeveloperDiskImageMounted() else {
                        throw NSError(domain: "StikDebug", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "The target did not confirm that the DDI is mounted."])
                    }
                }
                coolisMounted = true
            } catch {
                lastError = error.localizedDescription
                LogManager.shared.addErrorLog("Failed to prepare target DDI: \(error.localizedDescription)")
            }
        }
    }

    private func performDeviceOperation<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}
