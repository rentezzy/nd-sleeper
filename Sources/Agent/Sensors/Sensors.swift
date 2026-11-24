import Core
import Dispatch
import IOKit.ps

enum SensorEvent: Sendable {
    case powerSourceChanged
    case systemPower(SystemPowerEvent)
    case lidChanged
    case thermalChanged
    case batteryChanged
}

final class Sensors {
    private let powerSource: NotifySensor
    private let systemPower: SystemPowerSensor
    private let lid: LidSensor
    private let thermal: ThermalSensor
    private let battery: NotifySensor

    init(queue: DispatchQueue, onEvent: @escaping @Sendable (SensorEvent) -> Void) {
        powerSource = NotifySensor(name: kIOPSNotifyPowerSource, queue: queue) { onEvent(.powerSourceChanged) }
        systemPower = SystemPowerSensor(queue: queue) { onEvent(.systemPower($0)) }
        lid = LidSensor(queue: queue) { onEvent(.lidChanged) }
        thermal = ThermalSensor(queue: queue) { onEvent(.thermalChanged) }
        battery = NotifySensor(name: kIOPSNotifyAnyPowerSource, queue: queue) { onEvent(.batteryChanged) }
    }

    var detectsDarkWake: Bool {
        systemPower.detectsDarkWake
    }

    func apply(_ demand: Set<DemandInput>) {
        toggle(demand.contains(.powerSource), arm: powerSource.arm, disarm: powerSource.disarm)
        toggle(demand.contains(.systemPower), arm: systemPower.arm, disarm: systemPower.disarm)
        toggle(demand.contains(.lid), arm: lid.arm, disarm: lid.disarm)
        toggle(demand.contains(.thermal), arm: thermal.arm, disarm: thermal.disarm)
        toggle(demand.contains(.batteryPercent), arm: battery.arm, disarm: battery.disarm)
    }

    private func toggle(_ wanted: Bool, arm: () -> Void, disarm: () -> Void) {
        if wanted {
            arm()
        } else {
            disarm()
        }
    }
}
