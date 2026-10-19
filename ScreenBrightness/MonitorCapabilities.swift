import Foundation

/// What the monitor says it supports, parsed from its MCCS capabilities string,
/// e.g. `(prot(monitor)…vcp(10 12 60(11 12 0F 10) 62 8D)…)`.
struct MonitorCapabilities: Equatable, Sendable {
    let vcpCodes: Set<UInt8>
    let inputs: [MonitorInput]

    init(parsing capabilities: String) {
        var codes: Set<UInt8> = []
        var inputCodes: [Int] = []
        if let vcpStart = capabilities.range(of: "vcp(") {
            // Walk the vcp(…) list. Codes sit at depth 1; a code followed by "(…)" lists its allowed values.
            var depth = 1
            var token = ""
            var lastCode: UInt8?
            func endToken() {
                if depth == 1, let code = UInt8(token, radix: 16) {
                    codes.insert(code)
                    lastCode = code
                } else if depth == 2, lastCode == DDCProtocol.VCP.input.rawValue, let value = Int(token, radix: 16) {
                    inputCodes.append(value)
                }
                token = ""
            }
            for character in capabilities[vcpStart.upperBound...] {
                switch character {
                case "(":
                    endToken()
                    depth += 1
                case ")":
                    endToken()
                    depth -= 1
                case " ":
                    endToken()
                default:
                    token.append(character)
                }
                if depth == 0 { break }
            }
        }
        vcpCodes = codes
        inputs = inputCodes
            .map(MonitorInput.init(code:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func supports(_ code: DDCProtocol.VCP) -> Bool {
        vcpCodes.contains(code.rawValue)
    }
}

/// A video input on the monitor, identified by its MCCS input source value (VCP 0x60).
struct MonitorInput: Identifiable, Equatable, Sendable {
    let code: Int

    var id: Int { code }

    var name: String {
        switch code {
        case 0x01, 0x02: "VGA \(code)"
        case 0x03, 0x04: "DVI \(code - 2)"
        case 0x0F: "DisplayPort"
        // On monitors with one DisplayPort and one USB-C port, the USB-C port reports as DP 2.
        case 0x10: "USB-C (DP 2)"
        case 0x11: "HDMI 1"
        case 0x12: "HDMI 2"
        case 0x1B: "USB-C"
        default: String(format: "Input 0x%02X", code)
        }
    }
}
