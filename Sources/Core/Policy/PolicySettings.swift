public struct PolicySettings: Codable, Equatable, Sendable {
    public let batteryWindow: Int
    public let batteryFloor: Int

    public static let defaults = PolicySettings(batteryWindow: 1_800, batteryFloor: 20)

    public init(batteryWindow: Int, batteryFloor: Int) {
        self.batteryWindow = batteryWindow
        self.batteryFloor = batteryFloor
    }

    public var windowDuration: Duration {
        .seconds(batteryWindow)
    }
}

public enum SettingsSource: String, Codable, Sendable {
    case file
    case defaults
}

public struct ConfigStatus: Codable, Equatable, Sendable {
    public let settings: PolicySettings
    public let source: SettingsSource
    public let error: String?

    public init(settings: PolicySettings, source: SettingsSource, error: String?) {
        self.settings = settings
        self.source = source
        self.error = error
    }
}
