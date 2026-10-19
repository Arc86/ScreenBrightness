/// DDC/CI (MCCS) packet encoding and decoding. Free of IOKit so it can be unit tested.
enum DDCProtocol {
    /// VCP feature codes this app uses.
    enum VCP: UInt8, Sendable {
        case brightness = 0x10
        case contrast = 0x12
        case input = 0x60
        case volume = 0x62
        /// 1 = muted, 2 = unmuted.
        case mute = 0x8D
    }

    static let hostAddress: UInt8 = 0x6E
    static let dataAddress: UInt8 = 0x51
    static let replyChecksumSeed: UInt8 = 0x50
    /// Size of a "Get VCP Feature" reply, including the checksum.
    static let vcpReplyLength = 11
    /// Largest "Capabilities" reply: header (5) + 32 data bytes + checksum.
    static let capabilitiesReplyLength = 38

    static func getVCP(_ code: VCP) -> [UInt8] {
        packet([0x01, code.rawValue])
    }

    static func setVCP(_ code: VCP, value: Int) -> [UInt8] {
        let value = UInt16(clamping: value)
        return packet([0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    static func capabilitiesRequest(offset: Int) -> [UInt8] {
        let offset = UInt16(clamping: offset)
        return packet([0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)])
    }

    /// Wraps a command in its length prefix and checksum.
    static func packet(_ command: [UInt8]) -> [UInt8] {
        var packet = [0x80 | UInt8(command.count)] + command
        packet.append(packet.reduce(hostAddress ^ dataAddress, ^))
        return packet
    }

    /// Decodes a "Get VCP Feature" reply: source, length, 0x02, result, code, type, max (2), current (2), checksum.
    static func parseVCPReply(_ reply: [UInt8], for code: VCP) -> (current: Int, maximum: Int)? {
        guard reply.count >= vcpReplyLength,
              reply[0..<10].reduce(replyChecksumSeed, ^) == reply[10],
              reply[2] == 0x02, reply[3] == 0x00, reply[4] == code.rawValue else { return nil }
        let maximum = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        return (current, max(maximum, 1))
    }

    /// Decodes one "Capabilities" reply into its data bytes; an empty array marks the end of the string.
    static func parseCapabilitiesReply(_ reply: [UInt8]) -> [UInt8]? {
        guard reply.count >= 6 else { return nil }
        let length = Int(reply[1] & 0x7F)
        guard reply[2] == 0xE3, (3...35).contains(length), 2 + length <= reply.count else { return nil }
        return Array(reply[5..<(2 + length)])
    }

    static func capabilitiesString(from data: [UInt8]) -> String {
        String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    }
}
