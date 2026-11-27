import Foundation

public struct UDPPacket: Equatable, Sendable {
    public var sourceAddress: [UInt8]       // 4 bytes
    public var destinationAddress: [UInt8]  // 4 bytes
    public var sourcePort: UInt16
    public var destinationPort: UInt16
    public var payload: [UInt8]

    public init(sourceAddress: [UInt8], destinationAddress: [UInt8],
                sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) {
        self.sourceAddress = sourceAddress
        self.destinationAddress = destinationAddress
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.payload = payload
    }

    /// The packet you'd send back to whoever sent this one.
    public func reply(with payload: [UInt8]) -> UDPPacket {
        UDPPacket(sourceAddress: destinationAddress, destinationAddress: sourceAddress,
                  sourcePort: destinationPort, destinationPort: sourcePort, payload: payload)
    }
}

/// Minimal IPv4 + UDP encoder/decoder for the packet tunnel. Only handles what
/// a DNS-only tunnel needs: unfragmented IPv4 UDP datagrams.
public enum IPv4UDP {
    public static func parse(_ bytes: [UInt8]) -> UDPPacket? {
        guard bytes.count >= 28, bytes[0] >> 4 == 4 else { return nil }
        let ihl = Int(bytes[0] & 0x0F) * 4
        guard ihl >= 20, bytes.count >= ihl + 8 else { return nil }
        guard bytes[9] == 17 else { return nil } // UDP
        let fragment = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        guard fragment & 0x3FFF == 0 else { return nil } // MF set or offset != 0
        let totalLength = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        guard totalLength <= bytes.count, totalLength >= ihl + 8 else { return nil }

        let udpLength = Int(UInt16(bytes[ihl + 4]) << 8 | UInt16(bytes[ihl + 5]))
        guard udpLength >= 8, ihl + udpLength <= totalLength else { return nil }

        return UDPPacket(
            sourceAddress: Array(bytes[12..<16]),
            destinationAddress: Array(bytes[16..<20]),
            sourcePort: UInt16(bytes[ihl]) << 8 | UInt16(bytes[ihl + 1]),
            destinationPort: UInt16(bytes[ihl + 2]) << 8 | UInt16(bytes[ihl + 3]),
            payload: Array(bytes[(ihl + 8)..<(ihl + udpLength)])
        )
    }

    public static func build(_ packet: UDPPacket, identification: UInt16 = 0, ttl: UInt8 = 64) -> [UInt8] {
        let udpLength = 8 + packet.payload.count
        let totalLength = 20 + udpLength
        var out = [UInt8](repeating: 0, count: totalLength)

        // IPv4 header
        out[0] = 0x45
        out[2] = UInt8(totalLength >> 8); out[3] = UInt8(totalLength & 0xFF)
        out[4] = UInt8(identification >> 8); out[5] = UInt8(identification & 0xFF)
        out[6] = 0x40 // Don't fragment
        out[8] = ttl
        out[9] = 17
        out.replaceSubrange(12..<16, with: packet.sourceAddress)
        out.replaceSubrange(16..<20, with: packet.destinationAddress)
        let ipChecksum = checksum(out[0..<20])
        out[10] = UInt8(ipChecksum >> 8); out[11] = UInt8(ipChecksum & 0xFF)

        // UDP header
        out[20] = UInt8(packet.sourcePort >> 8); out[21] = UInt8(packet.sourcePort & 0xFF)
        out[22] = UInt8(packet.destinationPort >> 8); out[23] = UInt8(packet.destinationPort & 0xFF)
        out[24] = UInt8(udpLength >> 8); out[25] = UInt8(udpLength & 0xFF)
        out.replaceSubrange(28..<totalLength, with: packet.payload)

        // UDP checksum over pseudo-header + UDP segment
        var pseudo: UInt32 = 0
        pseudo += sum16(packet.sourceAddress[...])
        pseudo += sum16(packet.destinationAddress[...])
        pseudo += 17
        pseudo += UInt32(udpLength)
        var udpChecksum = checksum(out[20..<totalLength], initial: pseudo)
        if udpChecksum == 0 { udpChecksum = 0xFFFF }
        out[26] = UInt8(udpChecksum >> 8); out[27] = UInt8(udpChecksum & 0xFF)
        return out
    }

    /// RFC 1071 Internet checksum.
    public static func checksum(_ bytes: ArraySlice<UInt8>, initial: UInt32 = 0) -> UInt16 {
        var sum = initial &+ sum16(bytes)
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    static func sum16(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var sum: UInt32 = 0
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            sum &+= UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.endIndex { sum &+= UInt32(bytes[i]) << 8 }
        return sum
    }
}
