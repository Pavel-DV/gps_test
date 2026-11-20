import Foundation
import Darwin

enum DeviceConnectionContext {
    static let targetAddressKey = "TargetDeviceIPAddress"

    static var targetIPAddress: String {
        let saved = (UserDefaults.standard.string(forKey: targetAddressKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Older builds stored the same-device VPN address. Never reconnect to it.
        return saved == "10.7.0.1" ? "" : saved
    }

    static func validationMessage(for value: String) -> String? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return "Enter the remote iPhone's Wi-Fi IPv4 address, for example 192.168.1.25."
        }
        let hostAddress = UInt32(bigEndian: address.s_addr)
        guard hostAddress != 0, hostAddress < 0xE0000000,
              hostAddress >> 24 != 0, hostAddress >> 24 != 127, value != "10.7.0.1" else {
            return "Enter the remote iPhone's Wi-Fi address. Loopback and the old same-device VPN address cannot be used."
        }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else {
            return "Could not read this iPhone's network addresses. Try again."
        }
        defer { freeifaddrs(first) }
        var current = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let local = interface.pointee.ifa_addr,
                  local.pointee.sa_family == UInt8(AF_INET) else { continue }
            let localIP = UnsafeRawPointer(local).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            if localIP == address.s_addr {
                return "This address belongs to the controller iPhone. Enter the other iPhone's Wi-Fi address."
            }
        }
        return nil
    }
}
