//
//  AppBootstrapper.swift
//  StikDebug
//

import Foundation
import ObjectiveC.runtime
import UIKit

enum AppBootstrapper {
    static func configure() {
        IdeviceLogFileManager.shared.prepareForLogging()
        removeLegacyConnectionSettings()
        registerDefaultSettings()
        applyDocumentPickerCopyWorkaround()
    }

    private static func removeLegacyConnectionSettings() {
        let defaults = UserDefaults.standard
        let address = defaults.string(forKey: DeviceConnectionContext.targetAddressKey)
        if address == nil || address == "10.7.0.1" {
            defaults.removeObject(forKey: DeviceConnectionContext.targetAddressKey)
            defaults.removeObject(forKey: "TunnelRemotePairingPort")
        }
        defaults.removeObject(forKey: "keepAliveLocation")
    }

    private static func registerDefaultSettings() {
        UserDefaults.standard.register(defaults: [
            "keepAliveAudio": true
        ])
    }

    private static func applyDocumentPickerCopyWorkaround() {
        let fixedSelector = NSSelectorFromString("fix_initForOpeningContentTypes:asCopy:")
        let originalSelector = #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))

        guard let fixedMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, fixedSelector),
              let originalMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, originalSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, fixedMethod)
    }
}
