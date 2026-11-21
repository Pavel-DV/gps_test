import Darwin
import Foundation

struct ConnectionDiagnosis: Equatable {
    enum Problem {
        case pairingFile, invalidAddress, pairingRejected, deviceLocked, developerMode
        case developerService, connectionInterrupted, serviceUnreachable, connectionRefused, unknown
    }

    let problem: Problem

    var title: String {
        switch problem {
        case .pairingFile: return String(localized: "Pairing file unavailable")
        case .invalidAddress: return String(localized: "Invalid target address")
        case .pairingRejected: return "Remote iPhone rejected pairing"
        case .deviceLocked: return String(localized: "Device is locked")
        case .developerMode: return String(localized: "Developer Mode is off")
        case .developerService: return String(localized: "Developer service unavailable")
        case .connectionInterrupted: return "Connection interrupted"
        case .serviceUnreachable: return String(localized: "Device isn’t reachable")
        case .connectionRefused: return String(localized: "Connection refused")
        case .unknown: return String(localized: "Couldn’t connect to the device")
        }
    }

    var systemImage: String {
        switch problem {
        case .pairingFile, .pairingRejected: return "doc.badge.xmark"
        case .invalidAddress: return "network"
        case .deviceLocked: return "lock.fill"
        case .developerMode: return "hammer.fill"
        case .developerService: return "externaldrive.badge.exclamationmark"
        case .connectionInterrupted, .serviceUnreachable, .connectionRefused: return "antenna.radiowaves.left.and.right.slash"
        case .unknown: return "exclamationmark.triangle"
        }
    }

    var message: String {
        switch problem {
        case .pairingFile:
            return "Import the target iPhone's pairing record: Lockdown for iOS 16, Remote Pairing for iOS 17.4 or later. The file does not need to match the controller iPhone."
        case .pairingRejected:
            return "Check the remote iPhone's address and use the pairing file created for that phone. This is a response from the selected remote device; the file is not checked against the controller iPhone."
        case .invalidAddress:
            return "Enter the other iPhone's Wi-Fi IPv4 address in Remote iPhone settings."
        case .deviceLocked:
            return String(localized: "Unlock the target device and try again.")
        case .developerMode:
            return String(localized: "Enable Developer Mode in the target device’s Settings → Privacy & Security, then follow its restart instructions.")
        case .developerService:
            return "Enable Developer Mode on the remote iPhone and retry. Its Developer Disk Image is prepared automatically after connecting."
        case .connectionInterrupted:
            return "The selected remote endpoint closed the connection. Check its address and Remote Pairing port, unlock the remote iPhone and retry. This error alone does not mean the pairing file was rejected."
        case .serviceUnreachable:
            return "Check the remote iPhone's address and network access. iOS 16 uses Lockdown port 62078 and requires Wi-Fi syncing enabled for the paired device. Remote Pairing targets use the configured or discovered port."
        case .connectionRefused:
            return "The remote endpoint refused the connection. Check the Remote Pairing port and keep the remote iPhone unlocked."
        case .unknown:
            return "Check the remote address, Remote Pairing port and Developer Mode. The original error is shown below."
        }
    }
}

enum ConnectionDiagnostics {
    enum Stage: String {
        case pairingFile, targetAddress, tunnel
    }

    static func annotate(_ error: NSError, stage: Stage, targetIP: String, port: UInt16? = nil) -> NSError {
        var info = error.userInfo
        info["ConnectionStage"] = stage.rawValue
        info["ConnectionTargetIP"] = targetIP
        if let port { info["ConnectionPort"] = Int(port) }
        return NSError(domain: error.domain, code: error.code, userInfo: info)
    }

    static func diagnose(_ error: NSError, targetIP: String) -> ConnectionDiagnosis {
        ConnectionDiagnosis(problem: knownProblem(error) ?? .unknown)
    }

    static func knownProblem(_ error: NSError) -> ConnectionDiagnosis.Problem? {
        let stage = error.userInfo["ConnectionStage"] as? String
        let detail = error.localizedDescription.lowercased()
        if stage == Stage.pairingFile.rawValue ||
            (detail.contains("plist") && detail.contains("missing field") && detail.contains("public_key")) {
            return .pairingFile
        }
        if stage == Stage.targetAddress.rawValue { return .invalidAddress }
        if detail.contains("invalidhostid") || detail.contains("invalid host id") || detail.contains("pairverifyfailed") {
            return .pairingRejected
        }
        if detail.contains("devicelocked") || detail.contains("device locked") || detail.contains("passwordprotected") { return .deviceLocked }
        if detail.contains("developermodenotenabled") || detail.contains("developer mode is not enabled") { return .developerMode }
        if detail.contains("servicenotfound") || detail.contains("service not found") || detail.contains("imagenotmounted") || detail.contains("image not mounted") { return .developerService }
        if (error.domain == NSPOSIXErrorDomain && error.code == Int(ECONNRESET)) || detail.contains("connection reset") {
            return .connectionInterrupted
        }
        if (error.domain == NSPOSIXErrorDomain && error.code == Int(ECONNREFUSED)) || detail.contains("connection refused") {
            return .connectionRefused
        }
        if (error.domain == NSPOSIXErrorDomain && [Int(ETIMEDOUT), Int(EHOSTUNREACH), Int(ENETUNREACH)].contains(error.code)) ||
            detail.contains("timed out") || detail.contains("no route to host") {
            return .serviceUnreachable
        }
        return nil
    }
}
