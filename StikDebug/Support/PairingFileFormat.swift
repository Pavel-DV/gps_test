import Foundation

enum PairingFileFormat: String {
    case remotePairing
    case lockdown

    var displayName: String {
        switch self {
        case .remotePairing: return "Remote Pairing (iOS 17.4 or later)"
        case .lockdown: return "Lockdown (iOS 16)"
        }
    }

    static func detect(at url: URL) throws -> PairingFileFormat {
        try detect(data: Data(contentsOf: url))
    }

    static func detect(data: Data) throws -> PairingFileFormat {
        guard let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let fields = decoded as? [String: Any] else {
            throw formatError()
        }
        // Inspect the schema only. Never log certificates, keys or identifiers.
        if ["public_key", "private_key", "identifier"].allSatisfy({ fields[$0] != nil }) { return .remotePairing }
        if ["HostID", "SystemBUID", "HostCertificate", "HostPrivateKey"].allSatisfy({ fields[$0] != nil }) { return .lockdown }
        throw formatError()
    }

    private static func formatError() -> NSError {
        NSError(domain: "StikDebug", code: -17, userInfo: [NSLocalizedDescriptionKey:
            "Unrecognized pairing file. Import the target's Lockdown record for iOS 16, or Remote Pairing record for iOS 17.4 or later."])
    }
}

struct RemoteDeviceInfo {
    let productVersion: String
    let productType: String
    let version: OperatingSystemVersion

    init(productVersion: String, productType: String) throws {
        let components = productVersion.split(separator: ".", omittingEmptySubsequences: false)
        let parts = components.compactMap { Int($0) }
        guard parts.count >= 2, parts.count <= 3, parts.count == components.count, !productType.isEmpty,
              parts[0] > 0, parts.allSatisfy({ $0 >= 0 }) else {
            throw NSError(domain: "StikDebug", code: -20, userInfo: [NSLocalizedDescriptionKey: "Invalid remote iOS version."])
        }
        self.productVersion = productVersion
        self.productType = productType
        self.version = OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts[1], patchVersion: parts.count > 2 ? parts[2] : 0)
    }

    var legacyImageVersion: String { "\(version.majorVersion).\(version.minorVersion)" }
}
