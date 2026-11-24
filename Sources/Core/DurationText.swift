public enum DurationText {
    public static func parse(_ text: String) -> Duration? {
        guard let match = text.wholeMatch(of: #/(?:(\d{1,4})d)?(?:(\d{1,6})h)?(?:(\d{1,7})m)?(?:(\d{1,9})s)?/#) else { return nil }

        let parts = [(match.1, 86_400), (match.2, 3_600), (match.3, 60), (match.4, 1)]
            .compactMap { digits, unit in digits.flatMap { Int($0) }.map { $0 * unit } }
        let seconds = parts.reduce(0, +)
        guard !parts.isEmpty, seconds > 0 else { return nil }

        let duration = Duration.seconds(seconds)
        return duration <= SafetyLimit.maxOverrideDuration ? duration : nil
    }

    public static func format(_ duration: Duration) -> String {
        let total = max(0, Int(duration.components.seconds))
        let parts = [(total / 86_400, "d"), (total % 86_400 / 3_600, "h"), (total % 3_600 / 60, "m"), (total % 60, "s")]
            .filter { $0.0 > 0 }
            .map { "\($0.0)\($0.1)" }
        return parts.isEmpty ? "0s" : parts.joined()
    }
}
