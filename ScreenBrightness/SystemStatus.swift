import CoreAudio
import IOKit
import IOKit.pwr_mgt

/// Read-only probes of system state the controller reacts to.
enum SystemStatus {
    /// Seconds since the last keyboard, mouse or trackpad input.
    static func secondsSinceLastInput() -> TimeInterval? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        return value.map { $0.doubleValue / 1_000_000_000 }
    }

    /// Names of apps keeping the display awake, e.g. a video player.
    static func appsPreventingDisplaySleep() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let processes = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let names = processes.values.flatMap { assertions in
            assertions.compactMap { assertion -> String? in
                guard assertion[kIOPMAssertionTypeKey] as? String == kIOPMAssertPreventUserIdleDisplaySleep
                        || assertion[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypeNoDisplaySleep else { return nil }
                return assertion["Process Name"] as? String
            }
        }
        return Array(Set(names)).sorted()
    }

    /// True when sound plays through an HDMI or DisplayPort device whose volume macOS can't change,
    /// which is how a monitor's speakers or headphone jack show up.
    static func isOutputtingToDisplayAudio() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return false
        }

        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort else {
            return false
        }

        address.mSelector = kAudioDevicePropertyVolumeScalar
        address.mScope = kAudioDevicePropertyScopeOutput
        for element in [kAudioObjectPropertyElementMain, 1] {
            address.mElement = element
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &address),
               AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue {
                return false
            }
        }
        return true
    }
}
