import Core
import Foundation

public struct ConfigError: Error, Equatable, Sendable {
    public let message: String
}

public enum ConfigLoader {
    private static let maxFileBytes = 64 * 1024
    private static let windowKey = "battery_window"
    private static let floorKey = "battery_floor"

    public static func path(home: String = NSHomeDirectory()) -> String {
        "\(home)/\(InstallPath.HomeRelative.config)"
    }

    public static func load(home: String = NSHomeDirectory()) -> Result<ConfigStatus, ConfigError> {
        let file = path(home: home)
        guard FileManager.default.fileExists(atPath: file) else {
            return .success(ConfigStatus(settings: .defaults, source: .defaults, error: nil))
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int
        guard let size, size <= maxFileBytes,
              let data = FileManager.default.contents(atPath: file),
              data.count <= maxFileBytes,
              let text = String(data: data, encoding: .utf8)
        else { return .failure(ConfigError(message: "config.toml could not be read as UTF-8 text under 64 KB")) }

        do {
            let table = try TOMLParser.parse(text)
            return .success(ConfigStatus(settings: try settings(from: table), source: .file, error: nil))
        } catch let error as TOMLError {
            return .failure(ConfigError(message: "config.toml line \(error.line): \(error.message)"))
        } catch let error as ConfigError {
            return .failure(error)
        } catch {
            return .failure(ConfigError(message: "config.toml could not be parsed"))
        }
    }

    static func settings(from table: [String: TOMLValue]) throws -> PolicySettings {
        let unknown = table.keys.filter { $0 != windowKey && $0 != floorKey }.sorted()
        guard unknown.isEmpty else {
            throw ConfigError(message: "config.toml: unknown setting \(unknown.joined(separator: ", ")). Known settings are \(windowKey) and \(floorKey).")
        }

        let defaults = PolicySettings.defaults
        let window = try integer(table[windowKey], key: windowKey, unit: "seconds", range: SafetyLimit.batteryWindowSeconds)
        let floor = try integer(table[floorKey], key: floorKey, unit: "percent", range: SafetyLimit.batteryFloorPercent)
        return PolicySettings(batteryWindow: window ?? defaults.batteryWindow, batteryFloor: floor ?? defaults.batteryFloor)
    }

    private static func integer(_ value: TOMLValue?, key: String, unit: String, range: ClosedRange<Int>) throws -> Int? {
        guard let value else { return nil }
        guard case let .integer(number) = value, range.contains(number) else {
            throw ConfigError(message: "config.toml: \(key) must be a whole number of \(unit) from \(range.lowerBound) to \(range.upperBound)")
        }
        return number
    }
}
