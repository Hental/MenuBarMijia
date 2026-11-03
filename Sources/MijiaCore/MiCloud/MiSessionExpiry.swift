import Foundation

public enum MiSessionExpiryState: Equatable, Sendable {
    case valid
    case expiringSoon(expiresAt: Date)
    case expired
}

public enum MiSessionExpiryPolicy {
    /// The product's reading of "a few days" in issue #181, not a Xiaomi lifetime; it only applies to
    /// an end the login response carried.
    public static let warningLeadTime: TimeInterval = 3 * 24 * 60 * 60

    /// An undated session (`expiresAt == nil`) never warns and never expires on a guess.
    public static func state(
        expiresAt: Date?,
        now: Date,
        warningLeadTime: TimeInterval = MiSessionExpiryPolicy.warningLeadTime
    ) -> MiSessionExpiryState {
        guard let expiresAt else { return .valid }
        if now >= expiresAt { return .expired }
        if expiresAt.timeIntervalSince(now) <= warningLeadTime { return .expiringSoon(expiresAt: expiresAt) }
        return .valid
    }
}

extension MiSession {
    public func expiryState(at now: Date = Date()) -> MiSessionExpiryState {
        MiSessionExpiryPolicy.state(expiresAt: expiresAt, now: now)
    }
}
