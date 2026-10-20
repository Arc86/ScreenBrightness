import Testing

@Suite struct MonitorCapabilitiesTests {
    /// Read from an MSI MPG321CX OLED.
    static let msi = "(prot(monitor)type(lcd)model(FALCON)cmds(01 02 03 07 0C 4E F3 E3)vcp(02 04 05 08 0B 0C 10 12 14(01 04 05 06 07 08 0A 0B) 16 18 1A 6C 6E 70 AC AE B6 C0 C6 C8 C9 CA CC(00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0F 12 13 14 16 18 19 1A 1D 1E 21 23 25) D6(05) DC(00 01 02 03 04) DF 60(11 12 0F 10) 62 8D FF)mswhql(1)mccs_ver(2.0)asset_eep(32)mpu_ver(01))"

    @Test func findsSupportedControls() {
        let capabilities = MonitorCapabilities(parsing: Self.msi)
        for code in [DDCProtocol.VCP.brightness, .contrast, .input, .volume, .mute] {
            #expect(capabilities.supports(code), "\(code)")
        }
        #expect(capabilities.vcpCodes.contains(0xFF), "last code before the closing parenthesis")
        #expect(capabilities.vcpCodes.contains(0x02), "first code after vcp(")
    }

    @Test func ignoresValueLists() {
        let capabilities = MonitorCapabilities(parsing: Self.msi)
        // 0x0A and 0x23 only appear inside the 14(…) and CC(…) value lists.
        #expect(!capabilities.vcpCodes.contains(0x0A))
        #expect(!capabilities.vcpCodes.contains(0x23))
        // cmds(…) comes before vcp(…) and isn't a list of VCP codes.
        #expect(!capabilities.vcpCodes.contains(0xF3))
    }

    @Test func listsInputsByName() {
        let names = MonitorCapabilities(parsing: Self.msi).inputs.map(\.name)
        #expect(names == ["DisplayPort", "HDMI 1", "HDMI 2", "USB-C (DP 2)"])
    }

    @Test func handlesMissingLists() {
        let empty = MonitorCapabilities(parsing: "")
        #expect(empty.vcpCodes.isEmpty && empty.inputs.isEmpty)

        let noInputs = MonitorCapabilities(parsing: "(vcp(10 12))")
        #expect(noInputs.vcpCodes == [0x10, 0x12])
        #expect(noInputs.inputs.isEmpty)
    }

    @Test func namesUnknownInputs() {
        #expect(MonitorInput(code: 0x30).name == "Input 0x30")
    }
}

@Suite struct ColorPresetTests {
    @Test func listsColorPresetsFromTheCapabilities() {
        let presets = MonitorCapabilities(parsing: MonitorCapabilitiesTests.msi).colorPresets
        #expect(presets.map(\.name) == ["sRGB", "5000 K", "6500 K", "7500 K", "8200 K", "9300 K", "11500 K", "User 1"])
    }

    @Test func keepsOtherValueLists() {
        let capabilities = MonitorCapabilities(parsing: MonitorCapabilitiesTests.msi)
        #expect(capabilities.valueLists[0xD6] == [0x05])
        #expect(capabilities.valueLists[0xDC] == [0, 1, 2, 3, 4])
    }

    @Test func noColorPresetsWithoutAList() {
        #expect(MonitorCapabilities(parsing: "(vcp(10 12 14))").colorPresets.isEmpty)
    }

    @Test func translatesTheMSIReadings() {
        let msi = "13929-15830"
        // Measured: writing 0x08 (9300 K) reads back as 4, writing 0x01 (sRGB) as 77.
        #expect(ColorPreset.fromReading(4, monitor: msi) == 0x08)
        #expect(ColorPreset.fromReading(77, monitor: msi) == 0x01)
        #expect(ColorPreset.fromReading(5, monitor: msi) == 0x05)
        // Other monitors read back what was written.
        #expect(ColorPreset.fromReading(4, monitor: "1-2") == 0x04)
        #expect(ColorPreset.fromReading(4, monitor: nil) == 0x04)
    }
}
