import AppKit
import IOKit

/// Identity of the external display, read from its EDID-derived attributes in the IORegistry.
struct ExternalDisplay: Equatable, Sendable {
    let name: String
    let vendorID: UInt32
    let productID: UInt32

    static func current() -> ExternalDisplay? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let product = attributes["ProductAttributes"] as? [String: Any],
                  let name = product["ProductName"] as? String else { continue }
            return ExternalDisplay(
                name: name,
                vendorID: (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0,
                productID: (product["ProductID"] as? NSNumber)?.uint32Value ?? 0)
        }
        return nil
    }

    /// Key for per-monitor cached data such as the capabilities string.
    var storageKey: String { "\(vendorID)-\(productID)" }

    var displayID: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayVendorNumber($0) == vendorID && CGDisplayModelNumber($0) == productID }
    }

    @MainActor
    var screen: NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    /// True while macOS drives the monitor in HDR mode.
    @MainActor
    var isHDRActive: Bool {
        (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }
}
