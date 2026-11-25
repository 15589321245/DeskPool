import Darwin
import SystemConfiguration

enum LANAddress {
    static func current() -> String? {
        let state = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primary = state?[kSCDynamicStorePropNetPrimaryInterface as String] as? String
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return nil }
        defer { freeifaddrs(head) }

        var addresses: [(interface: String, address: String)] = []
        var node: UnsafeMutablePointer<ifaddrs>? = head
        while let next = node {
            let entry = next.pointee
            node = entry.ifa_next
            guard entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append((String(cString: entry.ifa_name), String(cString: buffer)))
            }
        }
        return preferred(from: addresses, primaryInterface: primary)
    }

    static func preferred(from addresses: [(interface: String, address: String)],
                          primaryInterface: String?) -> String? {
        let usable = addresses.filter { entry in
            guard entry.interface.hasPrefix("en") || entry.interface.hasPrefix("bridge") else { return false }
            let octets = entry.address.split(separator: ".").compactMap { UInt8($0) }
            return octets.count == 4 && (1..<224).contains(octets[0]) && octets[0] != 127 &&
                !(octets[0] == 169 && octets[1] == 254)
        }
        return usable.first { $0.interface == primaryInterface }?.address
            ?? usable.first { $0.interface.hasPrefix("en") }?.address
            ?? usable.first?.address
    }
}
