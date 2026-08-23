import Darwin
import Foundation

public struct LANNetworkInterfaceSnapshot: Equatable, Sendable {
    public let name: String
    public let address: String
    public let isUp: Bool
    public let isRunning: Bool

    public init(name: String, address: String, isUp: Bool, isRunning: Bool) {
        self.name = name
        self.address = address
        self.isUp = isUp
        self.isRunning = isRunning
    }
}

public struct LANNetworkAddress: Equatable, Hashable, Sendable {
    public let interfaceName: String
    public let host: String

    public init(interfaceName: String, host: String) {
        self.interfaceName = interfaceName
        self.host = host
    }
}

public enum LANNetworkInterfaceResolution: Equatable, Sendable {
    case unavailable
    case automatic(LANNetworkAddress)
    case selectionRequired([LANNetworkAddress])
}

public enum LANNetworkInterfaceResolverError: Error, Equatable, Sendable {
    case enumerationFailed(Int32)
    case invalidOrUnavailableSelection(String)
}

public enum LANNetworkInterfaceResolver {
    public static func current() throws -> LANNetworkInterfaceResolution {
        resolve(try currentSnapshots())
    }

    static func currentSnapshots() throws -> [LANNetworkInterfaceSnapshot] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else {
            throw LANNetworkInterfaceResolverError.enumerationFailed(errno)
        }
        defer { freeifaddrs(pointer) }

        var snapshots: [LANNetworkInterfaceSnapshot] = []
        var cursor = pointer
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET)
                    || socketAddress.pointee.sa_family == UInt8(AF_INET6) else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let flags = Int32(interface.ifa_flags)
            snapshots.append(.init(
                name: String(cString: interface.ifa_name),
                address: String(
                    decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
                    as: UTF8.self
                ),
                isUp: flags & IFF_UP != 0,
                isRunning: flags & IFF_RUNNING != 0
            ))
        }
        return snapshots
    }

    public static func resolve(
        _ snapshots: [LANNetworkInterfaceSnapshot]
    ) -> LANNetworkInterfaceResolution {
        let addresses = eligibleAddresses(from: snapshots)
        switch addresses.count {
        case 0: return .unavailable
        case 1: return .automatic(addresses[0])
        default: return .selectionRequired(addresses)
        }
    }

    public static func requireExactAddress(
        _ selectedHost: String,
        from snapshots: [LANNetworkInterfaceSnapshot]
    ) throws -> LANNetworkAddress {
        guard LANIPAddress.parseUsableCanonical(selectedHost) != nil,
              let match = eligibleAddresses(from: snapshots).first(where: {
                  $0.host == selectedHost
              }) else {
            throw LANNetworkInterfaceResolverError
                .invalidOrUnavailableSelection(selectedHost)
        }
        return match
    }

    static func eligibleAddresses(
        from snapshots: [LANNetworkInterfaceSnapshot]
    ) -> [LANNetworkAddress] {
        Array(Set(snapshots.compactMap { snapshot in
            guard snapshot.isUp,
                  snapshot.isRunning,
                  LANIPAddress.parseUsableCanonical(snapshot.address) != nil else {
                return nil
            }
            return LANNetworkAddress(
                interfaceName: snapshot.name,
                host: snapshot.address
            )
        })).sorted {
            ($0.interfaceName, $0.host) < ($1.interfaceName, $1.host)
        }
    }
}

enum LANIPAddress: Equatable, Sendable {
    case v4(in_addr)
    case v6(in6_addr)

    static func parseCanonical(_ value: String) -> Self? {
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("%") else {
            return nil
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            let parsed = Self.v4(ipv4)
            return parsed.canonicalHost == value ? parsed : nil
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            let parsed = Self.v6(ipv6)
            return parsed.canonicalHost == value ? parsed : nil
        }
        return nil
    }

    static func parseUsableCanonical(
        _ value: String,
        allowingLoopback: Bool = false
    ) -> Self? {
        guard let address = parseCanonical(value),
              address.isUsable(allowingLoopback: allowingLoopback) else {
            return nil
        }
        return address
    }

    var canonicalHost: String {
        switch self {
        case var .v4(address):
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
                return ""
            }
            return Self.decodeCString(buffer)
        case var .v6(address):
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
                return ""
            }
            return Self.decodeCString(buffer)
        }
    }

    var isIPv6: Bool {
        if case .v6 = self { return true }
        return false
    }

    func isUsable(allowingLoopback: Bool) -> Bool {
        switch self {
        case let .v4(address):
            let hostOrder = UInt32(bigEndian: address.s_addr)
            let first = UInt8((hostOrder >> 24) & 0xff)
            let second = UInt8((hostOrder >> 16) & 0xff)
            let isLoopback = first == 127
            return hostOrder != 0
                && hostOrder != UInt32.max
                && first != 0
                && (allowingLoopback || !isLoopback)
                && first < 224
                && !(first == 169 && second == 254)
        case var .v6(address):
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            let isUnspecified = bytes.allSatisfy { $0 == 0 }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 }
                && bytes.last == 1
            let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            let isMulticast = bytes[0] == 0xff
            let isIPv4Mapped = bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xff
                && bytes[11] == 0xff
            let isIPv4Compatible = bytes.prefix(12).allSatisfy { $0 == 0 }
            return !isUnspecified
                && (allowingLoopback || !isLoopback)
                && !isLinkLocal
                && !isMulticast
                && !isIPv4Mapped
                && (!isIPv4Compatible || isLoopback)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (var .v4(lhsAddress), var .v4(rhsAddress)):
            return withUnsafeBytes(of: &lhsAddress) { lhsBytes in
                withUnsafeBytes(of: &rhsAddress) { rhsBytes in
                    lhsBytes.elementsEqual(rhsBytes)
                }
            }
        case (var .v6(lhsAddress), var .v6(rhsAddress)):
            return withUnsafeBytes(of: &lhsAddress) { lhsBytes in
                withUnsafeBytes(of: &rhsAddress) { rhsBytes in
                    lhsBytes.elementsEqual(rhsBytes)
                }
            }
        default:
            return false
        }
    }

    private static func decodeCString(_ buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
    }
}
