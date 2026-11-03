import CryptoKit
import Foundation
import Security

public struct QRLoginTicket: Equatable, Sendable {
    public let qrImageURL: URL
    public let loginURL: URL
    public let longPollURL: URL
    public let timeout: TimeInterval

    public init(qrImageURL: URL, loginURL: URL, longPollURL: URL, timeout: TimeInterval) {
        self.qrImageURL = qrImageURL
        self.loginURL = loginURL
        self.longPollURL = longPollURL
        self.timeout = timeout
    }
}

public struct MiSession: Codable, Equatable, Sendable {
    public var userId: String
    public var cUserId: String
    public var ssecurity: String
    public var serviceToken: String
    public var region: String
    /// The absolute end the login response carried (or the last server rejection time); nil means undated.
    public var expiresAt: Date?

    public init(
        userId: String,
        cUserId: String,
        ssecurity: String,
        serviceToken: String,
        region: String = "cn",
        expiresAt: Date? = nil
    ) {
        self.userId = userId
        self.cUserId = cUserId
        self.ssecurity = ssecurity
        self.serviceToken = serviceToken
        self.region = region
        self.expiresAt = expiresAt
    }

    /// `12****89` style mask so the UI can show which account is signed in without exposing the full id.
    public var maskedUserId: String {
        guard userId.count > 4 else { return String(repeating: "*", count: userId.count) }
        return "\(userId.prefix(2))****\(userId.suffix(2))"
    }

    /// Stable, non-reversible namespace identifier derived from the active session's region and full
    /// `userId`, so accounts sharing the same `maskedUserId` (e.g. `12345689` vs `12999989`) never
    /// collide while keeping the raw `userId` out of `UserDefaults`.
    public var historyScopeIdentifier: String {
        let normalizedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let effectiveRegion = normalizedRegion.isEmpty ? "cn" : normalizedRegion
        let digest = SHA256.hash(data: Data("\(effectiveRegion):\(userId)".utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "mi:\(effectiveRegion):\(hex)"
    }

    public var apiBaseURL: String {
        let r = region.lowercased()
        return r.isEmpty || r == "cn" ? "https://api.io.mi.com/app" : "https://\(r).api.io.mi.com/app"
    }
}

public enum MiLoginError: LocalizedError, Equatable, Sendable {
    case http(Int)
    case badResponse(String)
    case qrExpired
    case missingServiceToken

    public var errorDescription: String? {
        switch self {
        case .http(let code): return L10n.tr("小米账号服务返回 HTTP \(code)", "Xiaomi account service returned HTTP \(code)")
        case .badResponse(let what): return L10n.tr("小米账号服务响应异常：\(what)", "Invalid Xiaomi account response: \(what)")
        case .qrExpired: return L10n.tr("二维码已过期，请重新获取", "QR code expired; please refresh")
        case .missingServiceToken: return L10n.tr("登录成功但未拿到 serviceToken，请重试", "Signed in, but missing serviceToken; please retry")
        }
    }
}

/// Mi account QR login: get ticket → user scans in Mi Home → long-poll → exchange `location` for `serviceToken`.
public struct MiAccountLogin: Sendable {
    private let transport: any MiHTTPTransport
    private let redirectlessTransport: any MiHTTPTransport
    private let region: String
    private let pollRequestTimeout: TimeInterval

    public init(
        transport: any MiHTTPTransport = URLSessionMiTransport(),
        redirectlessTransport: (any MiHTTPTransport)? = nil,
        region: String = "cn",
        pollRequestTimeout: TimeInterval = 15
    ) {
        self.transport = transport
        self.redirectlessTransport = redirectlessTransport ?? URLSessionMiTransport(followRedirects: false)
        self.region = region
        self.pollRequestTimeout = pollRequestTimeout
    }

    public func start(now: Date = Date()) async throws -> QRLoginTicket {
        // `qs` is deliberately pre-encoded and then encoded again, exactly as the reference client sends it.
        let query = MiCloudCrypto.formURLEncode([
            ("_qrsize", "480"),
            ("qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue"),
            ("callback", "https://sts.api.io.mi.com/sts"),
            ("_hasLogo", "false"),
            ("sid", "xiaomiio"),
            ("serviceParam", ""),
            ("_locale", "zh_CN"),
            ("_dc", String(Int64(now.timeIntervalSince1970 * 1000))),
        ])
        var req = URLRequest(url: URL(string: "https://account.xiaomi.com/longPolling/loginUrl?\(query)")!)
        req.httpMethod = "GET"
        let (data, http) = try await transport.send(req)
        guard http.statusCode == 200 else { throw MiLoginError.http(http.statusCode) }
        return try Self.parseTicket(data)
    }

    public static func parseTicket(_ data: Data) throws -> QRLoginTicket {
        guard let json = MiResponseText.parseJSON(data) else { throw MiLoginError.badResponse("非 JSON") }
        guard let qr = json["qr"]?.stringValue.flatMap(URL.init(string:)),
              let login = json["loginUrl"]?.stringValue.flatMap(URL.init(string:)),
              let lp = json["lp"]?.stringValue.flatMap(URL.init(string:)) else {
            let code = json["code"]?.idString ?? "?"
            throw MiLoginError.badResponse("缺少二维码字段 (code \(code))")
        }
        let timeout = json["timeout"]?.doubleValue ?? 300
        return QRLoginTicket(qrImageURL: qr, loginURL: login, longPollURL: lp, timeout: timeout)
    }

    /// Long-polls until the QR code is scanned and confirmed, then fetches the service token.
    /// Honors task cancellation (throws `CancellationError`).
    public func waitForScan(_ ticket: QRLoginTicket) async throws -> MiSession {
        let deadline = Date().addingTimeInterval(ticket.timeout)
        var scanned: ScanResult?
        while scanned == nil {
            try Task.checkCancellation()
            guard Date() < deadline else { throw MiLoginError.qrExpired }
            var req = URLRequest(url: ticket.longPollURL)
            req.timeoutInterval = pollRequestTimeout
            do {
                let (data, http) = try await transport.send(req)
                if http.statusCode == 200 {
                    scanned = try Self.parseScanResult(data)
                } else {
                    try await Task.sleep(for: .seconds(1))
                }
            } catch let error as URLError where error.code == .timedOut {
                continue
            }
        }
        let serviceToken = try await fetchServiceToken(location: scanned!.location)
        return MiSession(
            userId: scanned!.userId,
            cUserId: scanned!.cUserId,
            ssecurity: scanned!.ssecurity,
            serviceToken: serviceToken.token,
            region: region,
            expiresAt: serviceToken.expiresAt
        )
    }

    public struct ScanResult: Equatable, Sendable {
        public var userId: String
        public var cUserId: String
        public var ssecurity: String
        public var location: URL
    }

    public static func parseScanResult(_ data: Data) throws -> ScanResult {
        guard let json = MiResponseText.parseJSON(data) else { throw MiLoginError.badResponse("非 JSON") }
        guard let userId = json["userId"]?.idString,
              let ssecurity = json["ssecurity"]?.stringValue,
              let location = json["location"]?.stringValue.flatMap(URL.init(string:)) else {
            let code = json["code"]?.idString ?? "?"
            throw MiLoginError.badResponse("扫码结果缺少字段 (code \(code))")
        }
        return ScanResult(
            userId: userId,
            cUserId: json["cUserId"]?.idString ?? "",
            ssecurity: ssecurity,
            location: location
        )
    }

    private func fetchServiceToken(location: URL) async throws -> (token: String, expiresAt: Date?) {
        var url = location
        for _ in 0..<5 {
            var req = URLRequest(url: url)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let (_, http) = try await redirectlessTransport.send(req)
            if let token = Self.serviceTokenCookie(in: http, url: url) {
                return token
            }
            guard (300...399).contains(http.statusCode),
                  let next = http.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0, relativeTo: url) }) else {
                break
            }
            url = next.absoluteURL
        }
        throw MiLoginError.missingServiceToken
    }

    static func cookie(named name: String, in response: HTTPURLResponse, url: URL) -> HTTPCookie? {
        var fields: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { fields[ks] = vs }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first { $0.name == name && !$0.value.isEmpty }
    }

    /// Extracts `serviceToken` and its declared expiry from `Set-Cookie`.
    /// Foundation's `HTTPCookie` ignores `Max-Age` unless `Version=1` is present; RFC 6265 §4.1.2.2
    /// specifies `Max-Age` (in seconds) takes precedence over `Expires` on all modern cookies.
    static func serviceTokenCookie(
        in response: HTTPURLResponse,
        url: URL,
        now: Date = Date()
    ) -> (token: String, expiresAt: Date?)? {
        guard let cookie = cookie(named: "serviceToken", in: response, url: url) else {
            return nil
        }
        let explicitExpiry = parseSetCookieExpiry(named: "serviceToken", in: response, now: now)
        return (cookie.value, explicitExpiry ?? cookie.expiresDate)
    }

    static func parseSetCookieExpiry(named name: String, in response: HTTPURLResponse, now: Date = Date()) -> Date? {
        var rawHeaders: [String] = []
        for (k, v) in response.allHeaderFields {
            guard let ks = k as? String, ks.caseInsensitiveCompare("Set-Cookie") == .orderedSame,
                  let vs = v as? String else { continue }
            rawHeaders.append(vs)
        }
        for header in rawHeaders {
            let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let first = parts.first,
                  let eq = first.firstIndex(of: "="),
                  first[..<eq].trimmingCharacters(in: .whitespaces) == name else {
                continue
            }
            var maxAgeSeconds: Int?
            var expiresDate: Date?
            for attr in parts.dropFirst() {
                guard let attrEq = attr.firstIndex(of: "=") else { continue }
                let attrName = attr[..<attrEq].trimmingCharacters(in: .whitespaces).lowercased()
                let attrVal = attr[attr.index(after: attrEq)...].trimmingCharacters(in: .whitespaces)
                if attrName == "max-age", let secs = Int(attrVal) {
                    maxAgeSeconds = secs
                } else if attrName == "expires", let parsed = parseHTTPDate(String(attrVal)) {
                    expiresDate = parsed
                }
            }
            if let secs = maxAgeSeconds {
                return secs <= 0 ? now : now.addingTimeInterval(TimeInterval(secs))
            }
            if let expiresDate {
                return expiresDate
            }
        }
        return nil
    }

    private static func parseHTTPDate(_ raw: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
            "EEE, dd-MMM-yyyy HH:mm:ss zzz"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }
}

/// One signed-in Xiaomi account. The same user in the same region stays one account across re-login.
public struct MiAccount: Equatable, Sendable, Identifiable {
    public var session: MiSession

    public init(session: MiSession) { self.session = session }

    /// Stable across re-login: the same user in the same region is one account.
    public var id: String { session.historyScopeIdentifier }
    public var maskedUserId: String { session.maskedUserId }
    public var region: MiCloudRegion { MiCloudRegion(rawValue: session.region.lowercased()) ?? .cn }
    public var displayName: String { "\(maskedUserId) · \(region.label)" }
}

/// Keychain persistence for the signed-in `MiAccount`s (service `com.jryang1997.MenuBarMijia`, account
/// `mi_session`). `.standard` stores them only in the Keychain (#16); any other suite keeps a test-only
/// copy in `UserDefaults` so store tests never touch the real Keychain.
public enum MiSessionStore {
    static let keychainAccount = "mi_session"
    /// Test seam for non-`.standard` suites. ≤1.0.6 also wrote this key for `.standard`; startup migration moves
    /// that plaintext copy into the Keychain and deletes it (#16).
    public static let fallbackDefaultsKey = "mi_session_fallback_v1"
    /// v2 payload: a versioned list in the slot that used to hold one bare `MiSession`.
    private struct Envelope: Codable {
        var version: Int
        var accounts: [MiSession]
    }
    private static let envelopeVersion = 2

    public static func loadAccounts(
        defaults: UserDefaults = .standard,
        vault: CredentialVault = .shared
    ) -> [MiAccount] {
        guard let data = storedData(defaults: defaults, vault: vault) else { return [] }
        // Every earlier build wrote one bare session here; rewrite the slot in the v2 envelope once
        // (#27, ADR-0004). A v2 envelope is never re-encoded, so a normal launch does not write the
        // Keychain just because JSONEncoder's key order changed.
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.version == envelopeVersion {
            let sessions = deduped(envelope.accounts)
            if sessions.count != envelope.accounts.count, let canonical = encode(sessions) {
                store(canonical, defaults: defaults, vault: vault)
            }
            return sessions.map { MiAccount(session: $0) }
        }
        guard let legacy = try? JSONDecoder().decode(MiSession.self, from: data) else { return [] }
        if let canonical = encode([legacy]) {
            store(canonical, defaults: defaults, vault: vault)
        }
        return [MiAccount(session: legacy)]
    }

    @discardableResult
    public static func saveAccounts(
        _ accounts: [MiAccount],
        defaults: UserDefaults = .standard,
        vault: CredentialVault = .shared
    ) -> Bool {
        let sessions = deduped(accounts.map(\.session))
        guard !sessions.isEmpty else {
            return clear(defaults: defaults, vault: vault)
        }
        guard let data = encode(sessions) else { return false }
        return store(data, defaults: defaults, vault: vault)
    }

    @discardableResult
    public static func save(
        _ session: MiSession,
        defaults: UserDefaults = .standard,
        vault: CredentialVault = .shared
    ) -> Bool {
        upsert(session, defaults: defaults, vault: vault)
    }

    public static func load(
        defaults: UserDefaults = .standard,
        vault: CredentialVault = .shared
    ) -> MiSession? {
        loadAccounts(defaults: defaults, vault: vault).first?.session
    }

    @discardableResult
    public static func upsert(
        _ session: MiSession,
        defaults: UserDefaults = .standard,
        vault: CredentialVault = .shared
    ) -> Bool {
        guard var accounts = readExistingAccounts(defaults: defaults, vault: vault) else {
            return false
        }
        let updated = MiAccount(session: session)
        if let index = accounts.firstIndex(where: { $0.id == updated.id }) {
            accounts[index] = updated
        } else {
            accounts.append(updated)
        }
        return saveAccounts(accounts, defaults: defaults, vault: vault)
    }

    @discardableResult
    public static func remove(
        accountID: String,
        defaults: UserDefaults = .standard,
        vault: CredentialVault = .shared
    ) -> Bool {
        guard let accounts = readExistingAccounts(defaults: defaults, vault: vault) else {
            return false
        }
        return saveAccounts(accounts.filter { $0.id != accountID }, defaults: defaults, vault: vault)
    }

    /// Records a server-classified rejection as the stored session's end. Compare before write: when the
    /// stored credential is no longer the rejected one (`userId` or `serviceToken` changed), a late
    /// failure must not condemn a newer scan. The updated session is returned even if the store refuses
    /// the write, so the running UI still reflects the rejection.
    public static func markRejected(
        _ rejected: MiSession,
        at date: Date = Date(),
        defaults: UserDefaults = .standard,
        vault: CredentialVault = .shared
    ) -> MiSession? {
        var accounts = loadAccounts(defaults: defaults, vault: vault)
        guard let index = accounts.firstIndex(where: {
            $0.session.userId == rejected.userId && $0.session.serviceToken == rejected.serviceToken
        }) else { return nil }
        accounts[index].session.expiresAt = date
        saveAccounts(accounts, defaults: defaults, vault: vault)
        return accounts[index].session
    }

    /// `vault` is the revocation test seam: when supplied, the delete is attempted against that
    /// vault even for a custom defaults suite. Production passes nil and keeps the suite behaviour.
    @discardableResult
    public static func clear(
        defaults: UserDefaults = .standard,
        vault: CredentialVault? = nil
    ) -> Bool {
        defaults.removeObject(forKey: fallbackDefaultsKey)
        if let vault {
            return KeychainHelper.writeKeychainData(nil, account: keychainAccount, vault: vault)
        }
        guard defaults === UserDefaults.standard else { return true }
        return KeychainHelper.writeKeychainData(nil, account: keychainAccount, vault: .shared)
    }

    /// Re-encodes a ≤1.0.6 `UserDefaults` session for the Keychain as a v2 envelope, dropping the
    /// `passToken` it carried (#27). Returns nil when the legacy data cannot be decoded.
    static func migratedData(fromLegacyDefaults data: Data) -> Data? {
        guard let sessions = decodeSessions(from: data) else { return nil }
        return encode(deduped(sessions))
    }

    /// Reads the current account list before a write (`upsert` / `remove`). Returns `nil` when the
    /// Keychain slot is unreadable or corrupt, so a failed read never overwrites existing accounts.
    private static func readExistingAccounts(
        defaults: UserDefaults,
        vault: CredentialVault
    ) -> [MiAccount]? {
        guard defaults === UserDefaults.standard else {
            if defaults.object(forKey: fallbackDefaultsKey) == nil { return [] }
            guard let data = defaults.data(forKey: fallbackDefaultsKey),
                  let sessions = decodeSessions(from: data) else {
                return nil
            }
            return deduped(sessions).map { MiAccount(session: $0) }
        }
        switch vault.lookup(keychainAccount, retryingUnavailable: true) {
        case .missing:
            return []
        case .unavailable:
            return nil
        case .value(let data):
            guard let sessions = decodeSessions(from: data) else { return nil }
            return deduped(sessions).map { MiAccount(session: $0) }
        }
    }

    /// Accepts the v2 envelope or the bare `MiSession` that every earlier build wrote.
    private static func decodeSessions(from data: Data) -> [MiSession]? {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == envelopeVersion {
            return envelope.accounts
        }
        if let session = try? JSONDecoder().decode(MiSession.self, from: data) {
            return [session]
        }
        return nil
    }

    private static func encode(_ sessions: [MiSession]) -> Data? {
        try? JSONEncoder().encode(Envelope(version: envelopeVersion, accounts: sessions))
    }

    private static func deduped(_ sessions: [MiSession]) -> [MiSession] {
        var seen = Set<String>()
        return sessions.filter { seen.insert(MiAccount(session: $0).id).inserted }
    }

    private static func storedData(defaults: UserDefaults, vault: CredentialVault) -> Data? {
        guard defaults === UserDefaults.standard else {
            return defaults.data(forKey: fallbackDefaultsKey)
        }
        return KeychainHelper.readKeychainData(account: keychainAccount, vault: vault)
    }

    /// `data` is already re-encoded through `MiSession` in a v2 envelope, so no `passToken` reaches the store.
    @discardableResult
    private static func store(_ data: Data, defaults: UserDefaults, vault: CredentialVault) -> Bool {
        guard defaults === UserDefaults.standard else {
            defaults.set(data, forKey: fallbackDefaultsKey)
            return true
        }
        // The vault item itself is `AfterFirstUnlockThisDeviceOnly`, so the session stays off backups.
        let written = KeychainHelper.writeKeychainData(data, account: keychainAccount, vault: vault)
        guard written else { return false }
        // The plaintext mirror is gone (#16): the Keychain is the only store.
        defaults.removeObject(forKey: fallbackDefaultsKey)
        return true
    }
}
