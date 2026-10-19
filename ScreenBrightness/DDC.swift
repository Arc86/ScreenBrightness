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
    typealias VCP = DDCProtocol.VCP

    private static let chipAddress: UInt32 = 0x37

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
            guard send(DDCProtocol.getVCP(code)) else { continue }
            usleep(40_000)
            if let reply = receive(DDCProtocol.vcpReplyLength),
               let value = DDCProtocol.parseVCPReply(reply, for: code) {
                return value
            }
            usleep(30_000)
        }
        return nil
    }

    /// Reads the MCCS capabilities string, e.g. `(prot(monitor)…vcp(10 12 60(11 12 0F 10))…)`.
    func readCapabilities() -> String? {
        var data: [UInt8] = []
        while data.count < 4096 {
            var chunk: [UInt8]?
            for _ in 0..<4 where chunk == nil {
                guard send(DDCProtocol.capabilitiesRequest(offset: data.count)) else { continue }
                usleep(50_000)
                chunk = receive(DDCProtocol.capabilitiesReplyLength).flatMap(DDCProtocol.parseCapabilitiesReply)
                if chunk == nil { usleep(50_000) }
            }
            guard let chunk else { return nil }
            if chunk.isEmpty { break }
            data += chunk
        }
        return DDCProtocol.capabilitiesString(from: data)
    }

    func write(_ code: VCP, value: Int) -> Bool {
        send(DDCProtocol.setVCP(code, value: value))
    }

    private func send(_ packet: [UInt8]) -> Bool {
        var packet = packet
        let result = packet.withUnsafeMutableBytes {
            IOAVServiceWriteI2C(service, Self.chipAddress, UInt32(DDCProtocol.dataAddress), $0.baseAddress!, UInt32($0.count))
        }
        return result == kIOReturnSuccess
    }

    private func receive(_ length: Int) -> [UInt8]? {
        var reply = [UInt8](repeating: 0, count: length)
        let result = reply.withUnsafeMutableBytes {
            IOAVServiceReadI2C(service, Self.chipAddress, UInt32(DDCProtocol.dataAddress), $0.baseAddress!, UInt32($0.count))
        }
        return result == kIOReturnSuccess ? reply : nil
    }
}

/// Serializes all DDC traffic on one queue and coalesces bursts of writes to the same
/// control (a dragged slider, a fade) so the monitor only ever sees the latest value.
final class DDCLink: @unchecked Sendable {
    typealias VCP = DDCProtocol.VCP

    private let queue = DispatchQueue(label: "com.jespermol.ScreenBrightness.ddc", qos: .userInitiated)

    // Only touched on `queue`.
    private var service: DDCService?
    private var pendingWrites: [VCP: Int] = [:]
    private var drainScheduled = false

    func read(_ code: VCP) async -> (current: Int, maximum: Int)? {
        await perform { $0.read(code) }
    }

    func readCapabilities() async -> String? {
        await perform { $0.readCapabilities() }
    }

    /// Writes immediately, after any queued traffic, and reports whether the monitor accepted it.
    func write(_ code: VCP, value: Int) async -> Bool {
        await perform { $0.write(code, value: value) ? true : nil } ?? false
    }

    /// Queues a write that later writes to the same control may replace before it is sent.
    func set(_ code: VCP, value: Int) {
        queue.async { [self] in
            pendingWrites[code] = value
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
        while let (code, value) = pendingWrites.popFirst() {
            _ = withService { $0.write(code, value: value) ? true : nil }
            // DDC/CI asks hosts to leave ~50 ms between commands.
            usleep(50_000)
        }
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
