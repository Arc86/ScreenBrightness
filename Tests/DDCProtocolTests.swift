import Testing

@Suite struct DDCProtocolTests {
    /// Builds a reply the way a monitor does: source address, length, payload, checksum.
    private func reply(_ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x6E, 0x80 | UInt8(payload.count)] + payload
        bytes.append(bytes.reduce(DDCProtocol.replyChecksumSeed, ^))
        return bytes
    }

    @Test func getVCPPacket() {
        #expect(DDCProtocol.getVCP(.brightness) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test func setVCPPacket() {
        #expect(DDCProtocol.setVCP(.brightness, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    @Test func setVCPClampsToSixteenBits() {
        let packet = DDCProtocol.setVCP(.volume, value: 70_000)
        #expect(packet[3] == 0xFF && packet[4] == 0xFF)
        #expect(DDCProtocol.setVCP(.volume, value: -5)[3...4].allSatisfy { $0 == 0 })
    }

    @Test func capabilitiesRequestCarriesOffset() {
        #expect(Array(DDCProtocol.capabilitiesRequest(offset: 0x0120)[0...3]) == [0x83, 0xF3, 0x01, 0x20])
    }

    @Test func parsesBrightnessReplyFromMSI() throws {
        // Captured from an MSI MPG321CX OLED at 13 of 100.
        let bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x0D, 0xCD]
        let value = try #require(DDCProtocol.parseVCPReply(bytes, for: .brightness))
        #expect(value.current == 13)
        #expect(value.maximum == 100)
    }

    @Test func rejectsBadReplies() {
        let good = reply([0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x0D])
        #expect(DDCProtocol.parseVCPReply(good, for: .brightness) != nil)

        var corrupted = good
        corrupted[9] ^= 0x01
        #expect(DDCProtocol.parseVCPReply(corrupted, for: .brightness) == nil, "checksum mismatch")

        let unsupported = reply([0x02, 0x01, 0x10, 0x00, 0x00, 0x64, 0x00, 0x0D])
        #expect(DDCProtocol.parseVCPReply(unsupported, for: .brightness) == nil, "monitor reports unsupported code")

        #expect(DDCProtocol.parseVCPReply(good, for: .contrast) == nil, "reply for a different code")
        #expect(DDCProtocol.parseVCPReply(Array(good.prefix(8)), for: .brightness) == nil, "too short")
    }

    @Test func zeroMaximumBecomesOne() throws {
        let bytes = reply([0x02, 0x00, 0x62, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(try #require(DDCProtocol.parseVCPReply(bytes, for: .volume)).maximum == 1)
    }

    @Test func parsesCapabilitiesChunks() {
        let text = Array("(prot(monitor)".utf8)
        #expect(DDCProtocol.parseCapabilitiesReply(reply([0xE3, 0x00, 0x00] + text)) == text)
        #expect(DDCProtocol.parseCapabilitiesReply(reply([0xE3, 0x00, 0x40])) == [], "empty chunk ends the string")
        #expect(DDCProtocol.parseCapabilitiesReply(reply([0x02, 0x00, 0x10])) == nil, "not a capabilities reply")
    }

    @Test func capabilitiesStringDropsPadding() {
        #expect(DDCProtocol.capabilitiesString(from: Array("vcp(10)".utf8) + [0, 0]) == "vcp(10)")
    }
}
