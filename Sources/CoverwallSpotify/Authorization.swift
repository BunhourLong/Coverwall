import CryptoKit
import Foundation

/// RFC 7636 PKCE pair plus the `state` that ties a callback to this login.
public struct PKCE: Sendable {
    public let verifier: String
    public let state: String
    public var challenge: String { Self.challenge(for: verifier) }

    public init(verifier: String = Self.random(bytes: 64), state: String = Self.random(bytes: 16)) {
        (self.verifier, self.state) = (verifier, state)
    }

    /// base64url(SHA-256(verifier)), no padding (S256).
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// `bytes` of randomness as base64url: only unreserved characters, 64 bytes → 86 chars.
    public static func random(bytes: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &rng) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Authorization Code + PKCE against accounts.spotify.com (docs checked 2026-10-25, SPIKE_NOTES Phase 7.0).
public enum Authorization {
    public static func url(clientID: String, redirect: URL, pkce: PKCE, scopes: [String]) -> URL {
        var parts = URLComponents(string: "https://accounts.spotify.com/authorize")!
        parts.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect.absoluteString), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: pkce.challenge), .init(name: "state", value: pkce.state),
            .init(name: "scope", value: scopes.joined(separator: " ")),
        ]
        return parts.url!
    }

    /// The `code` from the redirect's request target (`/callback?code=…&state=…`); the state is checked first.
    public static func code(fromCallback target: String, state: String) throws -> String {
        let query = Dictionary((URLComponents(string: target)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        guard query["state"] == state else { throw SpotifyError.stateMismatch }
        if let error = query["error"] { throw error == "access_denied" ? SpotifyError.accessDenied : SpotifyError.authorizationFailed(error) }
        guard let code = query["code"], !code.isEmpty else { throw SpotifyError.authorizationFailed("no code") }
        return code
    }
}
