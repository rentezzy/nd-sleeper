import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

enum PowerManagement {
    static func readSleepDisabled() -> Bool? {
        rootDomainProperty("SleepDisabled").map { $0 as? Bool ?? false }
    }

    static func isLidClosed() -> Bool {
        rootDomainProperty("AppleClamshellState")?.flatMap { $0 as? Bool } ?? false
    }

    static func isOnBattery() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type != kIOPMACPowerKey
    }

    static func setSleepDisabled(_ on: Bool) -> Bool {
        if let setSystemPowerSetting,
           setSystemPowerSetting("SleepDisabled" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == kIOReturnSuccess,
           waitForFlag(on) {
            return true
        }
        runPmset(["-a", "disablesleep", on ? "1" : "0"])
        return waitForFlag(on)
    }

    static func sleepSystem() -> Bool {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        if port != 0 {
            defer { IOServiceClose(port) }
            if IOPMSleepSystem(port) == kIOReturnSuccess { return true }
        }
        return runPmset(["sleepnow"])
    }

    private typealias SetSystemPowerSetting = @convention(c) (CFString, CFTypeRef) -> IOReturn

    private static let setSystemPowerSetting: SetSystemPowerSetting? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let symbol = dlsym(handle, "IOPMSetSystemPowerSetting")
        else { return nil }
        return unsafeBitCast(symbol, to: SetSystemPowerSetting.self)
    }()

    private static func rootDomainProperty(_ key: String) -> Any?? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return .some(value)
    }

    private static func waitForFlag(_ on: Bool) -> Bool {
        let attempts = 100
        let stepMicroseconds: useconds_t = 5_000
        return (0..<attempts).contains { attempt in
            if attempt > 0 { usleep(stepMicroseconds) }
            return readSleepDisabled() == on
        }
    }

    @discardableResult
    private static func runPmset(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
