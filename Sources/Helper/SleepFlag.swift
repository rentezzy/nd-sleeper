public enum SleepFlag {
    public static func isOn() -> Bool? {
        PowerManagement.readSleepDisabled()
    }

    public static func clear() -> Bool {
        PowerManagement.setSleepDisabled(false) && PowerManagement.readSleepDisabled() == false
    }
}
