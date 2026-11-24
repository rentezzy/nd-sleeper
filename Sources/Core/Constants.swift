public enum BuildInfo {
    public static let version = "0.1.0"
}

public enum ServiceIdentifier {
    public static let helper = "com.nd.sleeper.helper"
    public static let agent = "com.nd.sleeper.agent"
}

public enum InstallPath {
    public static let binary = "/usr/local/libexec/nd-sleeper"
    public static let helperPlist = "/Library/LaunchDaemons/com.nd.sleeper.helper.plist"

    public enum HomeRelative {
        public static let agentPlist = "Library/LaunchAgents/com.nd.sleeper.agent.plist"
        public static let journalDirectory = "Library/Logs/nd-sleeper"
        public static let controlDirectory = "Library/Caches/nd-sleeper"
    }

    public static let controlSocketFileName = "control.sock"
}

public enum SafetyLimit {
    public static let lidClosedWindow: Duration = .seconds(30 * 60)
    public static let autoHelperDeadline: Duration = .seconds(31 * 60)
    public static let helperDeadlineMargin: Duration = .seconds(60)
    public static let untimedBatteryHoldCap: Duration = .seconds(4 * 60 * 60)
    public static let batteryFloorPercent = 20
    public static let maxOverrideDuration: Duration = .seconds(30 * 24 * 60 * 60)
    public static let sleepRequestRetry: Duration = .seconds(60)
}

public enum JournalFiles {
    public static let current = "journal.jsonl"
    public static let rotated = ["journal.1.jsonl", "journal.2.jsonl", "journal.3.jsonl"]
}
