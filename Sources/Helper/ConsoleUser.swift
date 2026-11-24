import Darwin
import SystemConfiguration

enum ConsoleUser {
    static func uid() -> uid_t? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
              name != "loginwindow"
        else { return nil }
        return uid
    }

    static func isAllowed(euid: uid_t) -> Bool {
        euid == 0 || euid == uid()
    }
}
