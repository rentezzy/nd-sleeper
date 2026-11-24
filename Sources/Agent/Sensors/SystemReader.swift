import Core
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

enum SystemReader {
    static func readAll() -> SystemReadings {
        SystemReadings(power: power(), lid: lid(), batteryPercent: batteryPercent(), thermal: thermal())
    }

    static func power() -> PowerSource {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return .battery }
        return type == kIOPMACPowerKey ? .ac : .battery
    }

    static func lid() -> LidState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return .open }
        defer { IOObjectRelease(service) }

        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool == true ? .closed : .open
    }

    static func batteryPercent() -> Int? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        return list
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .compactMap { $0[kIOPSCurrentCapacityKey] as? Int }
            .first
    }

    static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }
}
