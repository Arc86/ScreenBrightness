import Foundation
import IOKit

// Private IOKit symbols used by every Apple Silicon DDC tool (MonitorControl, m1ddc, Lunar).
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                                 _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

/// One external display reachable over DDC/CI. Calls block for tens of milliseconds,
/// so only use an instance from a single background queue.
final class DDCService: @unchecked Sendable {
    enum VCP: UInt8 {
        case brightness = 0x10
        case input = 0x60
    }

    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    private static let hostAddress: UInt8 = 0x6E
    private static let replyChecksumSeed: UInt8 = 0x50

    private let service: CFTypeRef

    /// Finds the first external display that exposes an AV service.
    init?() {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var found: CFTypeRef?
        while found == nil {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "External" {
                found = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
            }
        }
        guard let found else { return nil }
        service = found
    }

    func read(_ code: VCP, attempts: Int = 3) -> (current: Int, maximum: Int)? {
        for _ in 0..<attempts {
            guard send([0x01, code.rawValue]) else { continue }
            usleep(40_000)

            var reply = [UInt8](repeating: 0, count: 11)
            let result = reply.withUnsafeMutableBytes {
                IOAVServiceReadI2C(service, Self.chipAddress, Self.dataAddress, $0.baseAddress!, UInt32($0.count))
            }
            let checksum = reply[0..<10].reduce(Self.replyChecksumSeed, ^)
            guard result == kIOReturnSuccess, checksum == reply[10],
                  reply[2] == 0x02, reply[3] == 0x00, reply[4] == code.rawValue else {
                usleep(30_000)
                continue
            }
            let maximum = Int(reply[6]) << 8 | Int(reply[7])
            let current = Int(reply[8]) << 8 | Int(reply[9])
            return (current, max(maximum, 1))
        }
        return nil
    }

    /// Reads the MCCS capabilities string, e.g. `(prot(monitor)…vcp(10 12 60(11 12 0F 10))…)`.
    func readCapabilities() -> String? {
        var data: [UInt8] = []
        while data.count < 4096 {
            var chunk: [UInt8]?
            for _ in 0..<4 where chunk == nil {
                let offset = UInt16(data.count)
                guard send([0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)]) else { continue }
                usleep(50_000)

                // Reply: source, length, 0xE3, offset (2 bytes), up to 32 data bytes, checksum.
                var reply = [UInt8](repeating: 0, count: 38)
                let result = reply.withUnsafeMutableBytes {
                    IOAVServiceReadI2C(service, Self.chipAddress, Self.dataAddress, $0.baseAddress!, UInt32($0.count))
                }
                let length = Int(reply[1] & 0x7F)
                if result == kIOReturnSuccess, reply[2] == 0xE3, (3...35).contains(length) {
                    chunk = Array(reply[5..<(2 + length)])
                } else {
                    usleep(50_000)
                }
            }
            guard let chunk else { return nil }
            if chunk.isEmpty { break }
            data += chunk
        }
        return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    }

    func write(_ code: VCP, value: Int) -> Bool {
        let value = UInt16(clamping: value)
        return send([0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Wraps a DDC command in the length prefix and checksum, then writes it.
    private func send(_ command: [UInt8]) -> Bool {
        var packet = [0x80 | UInt8(command.count)] + command
        packet.append(packet.reduce(Self.hostAddress ^ UInt8(Self.dataAddress), ^))
        let result = packet.withUnsafeMutableBytes {
            IOAVServiceWriteI2C(service, Self.chipAddress, Self.dataAddress, $0.baseAddress!, UInt32($0.count))
        }
        return result == kIOReturnSuccess
    }
}

/// Serializes all DDC traffic on one queue and coalesces bursts of brightness writes
/// (a dragged slider, a fade) so the monitor only ever sees the latest value.
final class DDCLink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jespermol.ScreenBrightness.ddc", qos: .userInitiated)

    // Only touched on `queue`.
    private var service: DDCService?
    private var pendingBrightness: Int?
    private var drainScheduled = false

    func read(_ code: DDCService.VCP) async -> (current: Int, maximum: Int)? {
        await perform { $0.read(code) }
    }

    func readCapabilities() async -> String? {
        await perform { $0.readCapabilities() }
    }

    func write(_ code: DDCService.VCP, value: Int) async -> Bool {
        await perform { $0.write(code, value: value) ? true : nil } ?? false
    }

    func setBrightness(_ percent: Int) {
        queue.async { [self] in
            pendingBrightness = percent
            guard !drainScheduled else { return }
            drainScheduled = true
            queue.async { [self] in drain() }
        }
    }

    /// Forgets the cached service, e.g. after a display reconnects.
    func reset() {
        queue.async { [self] in service = nil }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (DDCService) -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: withService(body))
            }
        }
    }

    private func drain() {
        drainScheduled = false
        guard let percent = pendingBrightness else { return }
        pendingBrightness = nil
        _ = withService { $0.write(.brightness, value: percent) ? true : nil }
        // DDC/CI asks hosts to leave ~50 ms between commands.
        usleep(50_000)
    }

    /// Runs `body` against the cached service, rediscovering it once if it fails.
    private func withService<T>(_ body: (DDCService) -> T?) -> T? {
        for _ in 0..<2 {
            if service == nil { service = DDCService() }
            guard let service else { return nil }
            if let value = body(service) { return value }
            self.service = nil
        }
        return nil
    }
}
