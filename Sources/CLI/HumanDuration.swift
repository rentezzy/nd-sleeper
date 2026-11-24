enum HumanDuration {
    static func format(_ seconds: Double, precise: Bool = false) -> String {
        let total: Int = max(0, Int(seconds.rounded()))
        if total < 60 {
            return "\(total) sec"
        }
        if total < 3_600 {
            return minutes(total, precise: precise)
        }
        if total < 86_400 {
            let seconds: Int = total % 60
            guard precise, seconds != 0 else { return compound(total / 3_600, "h", total % 3_600 / 60, "m") }
            return "\(total / 3_600)h \(total % 3_600 / 60)m \(seconds)s"
        }
        return compound(total / 86_400, "d", total % 86_400 / 3_600, "h")
    }

    private static func minutes(_ total: Int, precise: Bool) -> String {
        let remainder: Int = total % 60
        guard precise, remainder != 0 else { return "\(total / 60) min" }
        return "\(total / 60) min \(remainder) sec"
    }

    private static func compound(_ major: Int, _ majorUnit: String, _ minor: Int, _ minorUnit: String) -> String {
        minor == 0 ? "\(major)\(majorUnit)" : "\(major)\(majorUnit) \(minor)\(minorUnit)"
    }
}
