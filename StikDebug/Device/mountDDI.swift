//
//  mountDDI.swift
//  StikDebug
//
//  Created by Stossy11 on 29/03/2025.
//

import Foundation

typealias RpPairingFileHandle = OpaquePointer

enum MountCheckResult {
    case mounted
    case notMounted
    case unreachable
}

func checkMountStatus() -> MountCheckResult {
    do {
        return try DeviceTunnelContext.shared.isDeveloperDiskImageMounted() ? .mounted : .notMounted
    } catch {
        LogManager.shared.addErrorLog("Failed to check DDI mount status: \(error.localizedDescription)")
        return .unreachable
    }
}

func mountDeveloperDiskImage(from directoryPath: String) -> String? {
    do {
        if let legacy = DeviceTunnelContext.shared.legacyConnection {
            try legacy.mountImage(from: URL(fileURLWithPath: directoryPath))
        } else if DeveloperDiskImageService.usesCryptexDDI {
            try DeviceTunnelContext.shared.installCryptexDDI(from: directoryPath)
        } else {
            try DeviceTunnelContext.shared.mountPersonalDDI(
                withImagePath: URL(fileURLWithPath: directoryPath).appendingPathComponent("Image.dmg").path,
                trustcachePath: URL(fileURLWithPath: directoryPath).appendingPathComponent("Image.dmg.trustcache").path,
                manifestPath: URL(fileURLWithPath: directoryPath).appendingPathComponent("BuildManifest.plist").path
            )
        }
    } catch {
        return error.localizedDescription
    }
    return nil
}
