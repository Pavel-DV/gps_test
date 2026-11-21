//
//  DeveloperDiskImageService.swift
//  StikDebug
//

import Foundation

final class DeveloperDiskImageService {
    static let shared = DeveloperDiskImageService()
    static var directoryURL: URL {
        let root = URL.documentsDirectory.appendingPathComponent("DDI", isDirectory: true)
        if let info = DeviceTunnelContext.shared.targetInfo, info.version.majorVersion == 16 {
            return root.appendingPathComponent("Legacy-\(info.legacyImageVersion)", isDirectory: true)
        }
        return root
    }

    static var filesAreReady: Bool {
        DeviceTunnelContext.shared.targetVersion != nil && downloadItems.allSatisfy {
            FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent($0.fileName).path)
        } && UserDefaults.standard.string(forKey: mountMethodKey) == cacheKey
    }

    static var usesCryptexDDI: Bool {
        mountMethod == .cryptex
    }

    private let fileManager: FileManager
    private let session: URLSession

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
    }

    @MainActor private var downloadTask: Task<Void, Error>?

    @MainActor
    func downloadMissingFiles() async throws {
        guard DeviceTunnelContext.shared.targetInfo != nil else {
            throw NSError(domain: "StikDebug", code: -20, userInfo: [NSLocalizedDescriptionKey: "Connect to the remote iPhone before downloading its developer image."])
        }
        if let downloadTask {
            try await downloadTask.value
            return
        }
        let task = Task { try await self.downloadFiles() }
        downloadTask = task
        defer { downloadTask = nil }
        try await task.value
    }

    private func downloadFiles() async throws {
        let installedMethod = UserDefaults.standard.string(forKey: Self.mountMethodKey)
            ?? (try? String(contentsOf: Self.mountMethodURL, encoding: .utf8))
        let replaceFiles = installedMethod != Self.cacheKey
        try removeObsoleteFiles()
        if replaceFiles {
            UserDefaults.standard.removeObject(forKey: Self.mountMethodKey)
        }

        if !Self.usesCryptexDDI {
            try removeCryptexOnlyFiles()
        }

        for item in Self.downloadItems {
            let destinationURL = Self.directoryURL.appendingPathComponent(item.fileName)
            guard replaceFiles || !fileManager.fileExists(atPath: destinationURL.path) else {
                continue
            }
            try await downloadFile(from: item.urlString, to: destinationURL)
        }
        UserDefaults.standard.set(Self.cacheKey, forKey: Self.mountMethodKey)
    }

    func downloadFile(from urlString: String, to destinationURL: URL) async throws {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https" else {
            throw DDIDownloadError.invalidURL(urlString)
        }

        let (temporaryURL, response) = try await session.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DDIDownloadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DDIDownloadError.badStatus(httpResponse.statusCode)
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func removeObsoleteFiles() throws {
        let legacyDirectory = Self.directoryURL.deletingLastPathComponent()
            .appendingPathComponent("DDI_Cryptex", isDirectory: true)
        for url in [Self.mountMethodURL, legacyDirectory] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func removeCryptexOnlyFiles() throws {
        for fileName in Self.cryptexOnlyFileNames {
            let fileURL = Self.directoryURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    private static var mountMethod: DDIMountMethod {
        // The controller and target may run different iOS releases.
        guard let version = DeviceTunnelContext.shared.targetVersion else { return .personalized }
        if version.majorVersion == 16 { return .legacy }
        return version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
            ? .cryptex
            : .personalized
    }

    private static var cacheKey: String {
        if mountMethod == .legacy, let info = DeviceTunnelContext.shared.targetInfo {
            return "legacy-\(info.legacyImageVersion)"
        }
        return mountMethod.rawValue
    }

    private static let mountMethodKey = "DDIMountMethod"
    private static var mountMethodURL: URL { directoryURL.appendingPathComponent("MountMethod") }
    private static let cryptexOnlyFileNames = ["Image.dmg.cryptex_info", "Image.dmg.root_hash"]

    private static var downloadItems: [DDIDownloadItem] {
        switch mountMethod {
        case .legacy:
            guard let info = DeviceTunnelContext.shared.targetInfo else { return [] }
            let root = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/DeveloperDiskImages/\(info.legacyImageVersion)"
            return ["DeveloperDiskImage.dmg", "DeveloperDiskImage.dmg.signature"].map {
                DDIDownloadItem(fileName: $0, urlString: "\(root)/\($0)")
            }
        case .cryptex:
            return cryptexDownloadItems
        case .personalized:
            return personalizedDownloadItems
        }
    }

    private static let cryptexDownloadItems: [DDIDownloadItem] = [
        .init(
            fileName: "BuildManifest.plist",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/BuildManifest.plist"
        ),
        .init(
            fileName: "Image.dmg",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg"
        ),
        .init(
            fileName: "Image.dmg.trustcache",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.trustcache"
        ),
        .init(
            fileName: "Image.dmg.cryptex_info",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.cryptex_info"
        ),
        .init(
            fileName: "Image.dmg.root_hash",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.root_hash"
        )
    ]

    private static let personalizedDownloadItems: [DDIDownloadItem] = [
        .init(
            fileName: "BuildManifest.plist",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist"
        ),
        .init(
            fileName: "Image.dmg",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg"
        ),
        .init(
            fileName: "Image.dmg.trustcache",
            urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache"
        )
    ]
}

private enum DDIMountMethod: String {
    case legacy
    case cryptex
    case personalized
}

private struct DDIDownloadItem {
    let fileName: String
    let urlString: String
}

enum DDIDownloadError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let string):
            return "Invalid download URL: \(string)"
        case .invalidResponse:
            return "The DDI server returned an invalid response."
        case .badStatus(let statusCode):
            return "The DDI server returned HTTP \(statusCode)."
        }
    }
}
