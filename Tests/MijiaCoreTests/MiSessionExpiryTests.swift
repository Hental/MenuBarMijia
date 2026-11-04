import Foundation
import Testing
@testable import MijiaCore

struct MiSessionExpiryPolicyTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("An undated session is valid at any date; no lifetime is guessed")
    func undatedSessionNeverExpires() {
        #expect(MiSessionExpiryPolicy.state(expiresAt: nil, now: .distantPast) == .valid)
        #expect(MiSessionExpiryPolicy.state(expiresAt: nil, now: .distantFuture) == .valid)

        let undated = MiSession(userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "t")
        #expect(undated.expiresAt == nil)
        #expect(undated.expiryState(at: .distantFuture) == .valid)
    }

    @Test("Outside the lead is valid, inside and exactly at the lead warn, at or past the end expires")
    func leadTimeBoundaries() {
        let lead = MiSessionExpiryPolicy.warningLeadTime
        let now = Self.now

        let outside = now.addingTimeInterval(lead + 1)
        #expect(MiSessionExpiryPolicy.state(expiresAt: outside, now: now) == .valid)

        let inside = now.addingTimeInterval(lead - 1)
        #expect(MiSessionExpiryPolicy.state(expiresAt: inside, now: now) == .expiringSoon(expiresAt: inside))

        let exactlyAtLead = now.addingTimeInterval(lead)
        #expect(MiSessionExpiryPolicy.state(expiresAt: exactlyAtLead, now: now) == .expiringSoon(expiresAt: exactlyAtLead))

        #expect(MiSessionExpiryPolicy.state(expiresAt: now, now: now) == .expired)
        #expect(MiSessionExpiryPolicy.state(expiresAt: now.addingTimeInterval(-1), now: now) == .expired)
    }

    @Test("A dated session maps its stored end through expiryState")
    func datedSessionUsesStoredEnd() {
        let end = Self.now.addingTimeInterval(60)
        let session = MiSession(userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "t", expiresAt: end)
        #expect(session.expiryState(at: Self.now) == .expiringSoon(expiresAt: end))
        #expect(session.expiryState(at: end) == .expired)
    }

    @Test("A session saved before expiresAt existed still decodes as undated")
    func legacyJSONDecodesUndated() throws {
        let json = #"{"userId":"42","cUserId":"c","ssecurity":"s","serviceToken":"t","region":"cn"}"#
        let session = try JSONDecoder().decode(MiSession.self, from: Data(json.utf8))
        #expect(session.expiresAt == nil)
        #expect(session.expiryState(at: .distantFuture) == .valid)
    }
}

struct MiSessionRejectionTests {
    @Test("A rejection from a stale userId or serviceToken leaves the stored session untouched")
    func staleRejectionIsIgnored() throws {
        let suite = "com.jryang1997.MenuBarMijia.mi-rejection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let stored = MiSession(userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "current")
        #expect(MiSessionStore.save(stored, defaults: defaults))

        let olderToken = MiSession(userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "older")
        let otherUser = MiSession(userId: "43", cUserId: "c", ssecurity: "s", serviceToken: "current")
        #expect(MiSessionStore.markRejected(olderToken, at: Date(), defaults: defaults) == nil)
        #expect(MiSessionStore.markRejected(otherUser, at: Date(), defaults: defaults) == nil)
        #expect(MiSessionStore.load(defaults: defaults) == stored)
    }

    @Test("A rejection records its time over a stored future end for the current credential")
    func rejectionOverwritesFutureEnd() throws {
        let suite = "com.jryang1997.MenuBarMijia.mi-rejection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let future = Date(timeIntervalSince1970: 2_000_000_000)
        let stored = MiSession(userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "tok", expiresAt: future)
        #expect(MiSessionStore.save(stored, defaults: defaults))

        let rejectedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let updated = try #require(MiSessionStore.markRejected(stored, at: rejectedAt, defaults: defaults))
        #expect(updated.expiresAt == rejectedAt)
        #expect(MiSessionStore.load(defaults: defaults)?.expiresAt == rejectedAt)
    }
}

struct MiAccountLoginExpiryTests {
    @Test("Login captures the serviceToken cookie expiry when the response carries Max-Age")
    func loginCapturesCookieExpiry() async throws {
        let maxAge = 30 * 24 * 60 * 60
        let cookieEndsAt = Date().addingTimeInterval(TimeInterval(maxAge))
        let httpDate = DateFormatter()
        httpDate.locale = Locale(identifier: "en_US_POSIX")
        httpDate.timeZone = TimeZone(secondsFromGMT: 0)
        httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        // `Version=1` lets swift-corelibs-foundation apply Max-Age; `Expires` carries the same instant
        // for any parser that skips it.
        let setCookie = "serviceToken=tok123; Version=1; Max-Age=\(maxAge); Expires=\(httpDate.string(from: cookieEndsAt)); path=/"
        let transport = ScriptedTransport { request in
            let url = request.url!.absoluteString
            if url.hasPrefix("https://lp.example") {
                return (200, [:], #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","location":"https://sts.example/sts?x=1"}"#)
            }
            if url.hasPrefix("https://sts.example") {
                return (200, ["Set-Cookie": setCookie], "ok")
            }
            return (404, [:], "")
        }
        let login = MiAccountLogin(transport: transport, redirectlessTransport: transport)
        let ticket = QRLoginTicket(
            qrImageURL: URL(string: "https://qr.example")!,
            loginURL: URL(string: "https://login.example")!,
            longPollURL: URL(string: "https://lp.example/poll")!,
            timeout: 30
        )

        let session = try await login.waitForScan(ticket)
        #expect(session.serviceToken == "tok123")
        let expiresAt = try #require(session.expiresAt)
        #expect(abs(expiresAt.timeIntervalSince(cookieEndsAt)) < 120)
    }

    @Test("A serviceToken cookie without an end leaves the session undated")
    func loginWithoutCookieEndStaysUndated() async throws {
        let transport = ScriptedTransport { request in
            let url = request.url!.absoluteString
            if url.hasPrefix("https://lp.example") {
                return (200, [:], #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","location":"https://sts.example/sts?x=1"}"#)
            }
            if url.hasPrefix("https://sts.example") {
                return (200, ["Set-Cookie": "serviceToken=tok123; path=/"], "ok")
            }
            return (404, [:], "")
        }
        let login = MiAccountLogin(transport: transport, redirectlessTransport: transport)
        let ticket = QRLoginTicket(
            qrImageURL: URL(string: "https://qr.example")!,
            loginURL: URL(string: "https://login.example")!,
            longPollURL: URL(string: "https://lp.example/poll")!,
            timeout: 30
        )

        let session = try await login.waitForScan(ticket)
        #expect(session.serviceToken == "tok123")
        #expect(session.expiresAt == nil)
    }

    @Test("Max-Age without Version=1 or Expires is parsed directly from Set-Cookie")
    func maxAgeWithoutVersion1IsParsed() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = URL(string: "https://sts.example/sts")!
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "serviceToken=tok_max; Max-Age=3600; Path=/; HttpOnly"]
        ))
        let parsed = try #require(MiAccountLogin.serviceTokenCookie(in: response, url: url, now: now))
        #expect(parsed.token == "tok_max")
        #expect(parsed.expiresAt == now.addingTimeInterval(3600))
    }

    @Test("Max-Age takes precedence over Expires per RFC 6265")
    func maxAgeOverridesExpires() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = URL(string: "https://sts.example/sts")!
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Set-Cookie": "serviceToken=tok_rfc; Max-Age=7200; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/"
            ]
        ))
        let parsed = try #require(MiAccountLogin.serviceTokenCookie(in: response, url: url, now: now))
        #expect(parsed.token == "tok_rfc")
        #expect(parsed.expiresAt == now.addingTimeInterval(7200))
    }
}

struct MiSessionExpiryHomeStoreTests {
    @MainActor
    @Test("An expired stored session shows the slash icon and opens re-auth until a new login")
    func expiredStoredSessionSurfacesReauth() throws {
        let suite = "com.jryang1997.MenuBarMijia.mi-expiry-store.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let expiredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = MiSession(
            userId: "1234567890",
            cUserId: "cu",
            ssecurity: "s",
            serviceToken: "tok",
            expiresAt: expiredAt
        )
        #expect(MiSessionStore.save(expired, defaults: defaults))

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(store.homeBackend == .xiaomiCloud)
        #expect(store.miSessionExpiresAt == expiredAt)
        #expect(store.miSessionExpiryState == .expired)
        #expect(store.miSessionShowsExpired)
        #expect(store.miSessionExpiringSoonDate == nil)
        #expect(store.menuBarSymbolName == "house.slash")

        store.presentMiReauth()
        #expect(store.isShowingMiReauth)
        store.dismissMiReauth()
        #expect(!store.isShowingMiReauth)
        store.presentMiReauth()
        #expect(store.isShowingMiReauth)

        store.completeMiLogin(MiSession(userId: "1234567890", cUserId: "cu", ssecurity: "s", serviceToken: "new"))
        #expect(!store.isShowingMiReauth)
        #expect(store.miSessionExpiresAt == nil)
        #expect(!store.miSessionShowsExpired)
        #expect(store.menuBarSymbolName == "house")
    }

    @MainActor
    @Test("A session with a far-future end keeps the normal house icon and no warning")
    func farFutureSessionKeepsNormalIcon() throws {
        let suite = "com.jryang1997.MenuBarMijia.mi-expiry-store.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let farEnd = Date(timeIntervalSince1970: 4_000_000_000)
        let session = MiSession(
            userId: "1234567890",
            cUserId: "cu",
            ssecurity: "s",
            serviceToken: "tok",
            expiresAt: farEnd
        )
        #expect(MiSessionStore.save(session, defaults: defaults))

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(store.miSessionExpiresAt == farEnd)
        #expect(store.miSessionExpiryState == .valid)
        #expect(!store.miSessionShowsExpired)
        #expect(store.miSessionExpiringSoonDate == nil)
        #expect(store.menuBarSymbolName == "house")

        store.presentMiReauth()
        #expect(store.isShowingMiReauth)
    }

    @MainActor
    @Test("One expired account among several warns without slashing the menu bar icon until all expire")
    func partialAccountExpiryDoesNotBlockControl() throws {
        let suite = "com.jryang1997.MenuBarMijia.mi-expiry-multi.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let expiredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let farEnd = Date(timeIntervalSince1970: 4_000_000_000)
        let expiredCN = MiSession(
            userId: "10010001",
            cUserId: "c-cn",
            ssecurity: "s-cn",
            serviceToken: "tok-cn",
            region: "cn",
            expiresAt: expiredAt
        )
        let validDE = MiSession(
            userId: "20020002",
            cUserId: "c-de",
            ssecurity: "s-de",
            serviceToken: "tok-de",
            region: "de",
            expiresAt: farEnd
        )
        #expect(MiSessionStore.saveAccounts([MiAccount(session: expiredCN), MiAccount(session: validDE)], defaults: defaults))

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(store.miAccounts.count == 2)
        #expect(store.miSessionShowsExpired)
        #expect(!store.miSessionBlocksControl)
        #expect(store.menuBarSymbolName == "house")

        store.presentMiReauth()
        #expect(store.miCloudRegion == .cn)
        store.dismissMiReauth()

        let expiredDE = MiSession(
            userId: "20020002",
            cUserId: "c-de",
            ssecurity: "s-de",
            serviceToken: "tok-de",
            region: "de",
            expiresAt: expiredAt
        )
        #expect(MiSessionStore.saveAccounts([MiAccount(session: expiredCN), MiAccount(session: expiredDE)], defaults: defaults))
        let allExpiredStore = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(allExpiredStore.miSessionShowsExpired)
        #expect(allExpiredStore.miSessionBlocksControl)
        #expect(allExpiredStore.menuBarSymbolName == "house.slash")
    }
}
