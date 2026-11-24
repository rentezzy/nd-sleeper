import Foundation
import IOKit
import IOKit.pwr_mgt

final class LidSensor {
    private static let clamshellStateChange: UInt32 = 0xE003_4100

    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    func arm() {
        guard port == nil else { return }

        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return }
        defer { IOObjectRelease(rootDomain) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }

        IONotificationPortSetDispatchQueue(port, queue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { refcon, _, messageType, _ in
            guard messageType == LidSensor.clamshellStateChange, let refcon else { return }
            Unmanaged<LidSensor>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }, refcon, &notifier)
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return
        }
        self.port = port
    }

    func disarm() {
        guard let port else { return }
        IOObjectRelease(notifier)
        notifier = 0
        IONotificationPortDestroy(port)
        self.port = nil
    }
}
