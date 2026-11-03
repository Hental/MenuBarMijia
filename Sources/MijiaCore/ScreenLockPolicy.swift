import Foundation

/// Interprets the current login session at launch so a Mac that is already locked never accepts
/// external controls before the first lock/unlock notification (#143 review).
public enum ScreenLockPolicy {
    /// `CGSessionCopyCurrentDictionary` carries `CGSSessionScreenIsLocked` only while the screen is
    /// locked (as `1`). Its absence, together with an on-console, completed login, means unlocked.
    /// Missing session information fails closed; so does another user's off-console session.
    public static func isLocked(session: [String: Any]?) -> Bool {
        guard let session else { return true }
        if let value = session["CGSSessionScreenIsLocked"] {
            return truthy(value)
        }
        let onConsole = truthy(session["kCGSSessionOnConsoleKey"])
        let loginDone = truthy(session["kCGSessionLoginDoneKey"])
        return !(onConsole && loginDone)
    }

    private static func truthy(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as Int:
            return value != 0
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame
        default:
            return false
        }
    }
}
