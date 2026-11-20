import Foundation
import Darwin

enum DeviceConnectionContext {
    static let defaultTargetIPAddress = "10.7.0.1"
    static let targetAddressKey = "TargetDeviceIPAddress"

    static var targetIPAddress: String {
        UserDefaults.standard.string(forKey: targetAddressKey) ?? defaultTargetIPAddress
    }

    static func isValidIPv4Address(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
            && address.s_addr != INADDR_ANY && address.s_addr != INADDR_BROADCAST
    }
}
