import Foundation

/// A parsed AI endpoint address, used to decide which provider a URL belongs to and whether an API key may be sent to it.
///
/// Provider detection only trusts exact hosts or subdomains of a provider-owned domain. Substring checks
/// (`host.contains("openrouter.ai")`) would also match `openrouter.ai.evil.com` and hand the saved key to it (#19).
public struct AssistantEndpoint: Equatable, Sendable {
    public let scheme: String
    /// Lowercased host without IPv6 brackets or a trailing dot.
    public let host: String
    public let port: Int?
    /// URL path such as `/coding/v1`; empty when the URL has no path.
    public let path: String

    /// Parses a user-typed endpoint. A missing scheme means https (`api.deepseek.com/v1`).
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased() else {
            return nil
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = components.port
        self.path = components.path
    }

    /// Host plus explicit port. A custom endpoint's key is bound to this value.
    public var identity: String {
        guard let port else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// `domain` itself or one of its subdomains: `api.openrouter.ai` matches `openrouter.ai`, `openrouter.ai.evil.com` does not.
    public func hostMatches(domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// Kimi Code's coding API (https://www.kimi.com/code/docs/kimi-code/models.html) only accepts the
    /// model-default temperature (1). The documented `/coding` path segment is required — host-only
    /// matching would also catch unrelated `api.kimi.com` endpoints.
    public var isKimiCodeEndpoint: Bool {
        guard hostMatches(domain: "kimi.com") || hostMatches(domain: "kimi.ai") else { return false }
        let lowerPath = path.lowercased()
        return lowerPath == "/coding" || lowerPath.hasPrefix("/coding/")
    }

    /// Traffic never leaves this computer.
    public var isLoopback: Bool {
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" {
            return true
        }
        return Self.ipv4Octets(host)?.first == 127
    }

    /// Loopback, private LAN (RFC 1918), link-local, CGNAT/Tailscale (100.64.0.0/10), IPv6 ULA/link-local, or mDNS `.local` names.
    public var isLocalNetwork: Bool {
        if isLoopback || host.hasSuffix(".local") {
            return true
        }
        if let octets = Self.ipv4Octets(host) {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if host.contains(":") {
            // fc00::/7 unique-local and fe80::/10 link-local.
            return host.hasPrefix("fc") || host.hasPrefix("fd")
                || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
        }
        return false
    }

    /// API keys only travel over https, or over plain http that stays on the local network.
    public var allowsSendingSecrets: Bool {
        scheme == "https" || isLocalNetwork
    }

    /// Four dotted decimal octets, or nil when `host` is not an IPv4 literal (so `10.evil.com` is not a LAN address).
    static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ ("0"..."9").contains($0) }),
                  let value = Int(part), value <= 255 else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }
}
