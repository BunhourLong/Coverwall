import Foundation

/// All Spotify HTTP goes through this, so tests stub it and never touch the network (CLAUDE.md 13).
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPClient {
    /// Ephemeral: no cookies, no on-disk cache of anything token-bearing.
    public static let spotify = URLSession(configuration: .ephemeral)

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do { (data, response) = try await self.data(for: request) } catch is URLError { throw SpotifyError.offline }
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.offline }
        return (data, http)
    }
}

public struct Tokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String) {
        (self.accessToken, self.refreshToken, self.expiresAt, self.scope) = (accessToken, refreshToken, expiresAt, scope)
    }

    static let key = "tokens"

    public static func load(from store: any SecretStore) throws -> Tokens? {
        try store.read(key).map { try JSONDecoder().decode(Tokens.self, from: Data($0.utf8)) }
    }

    public func save(in store: any SecretStore) throws {
        try store.write(String(decoding: JSONEncoder().encode(self), as: UTF8.self), for: Self.key)
    }
}

/// `POST accounts.spotify.com/api/token`, form-encoded, no client secret (PKCE).
public enum TokenEndpoint {
    static let url = URL(string: "https://accounts.spotify.com/api/token")!

    public static func exchange(code: String, redirect: URL, verifier: String, clientID: String, http: any HTTPClient,
                                now: Date) async throws -> Tokens {
        let reply: Reply
        do {
            reply = try await post(["grant_type": "authorization_code", "code": code, "redirect_uri": redirect.absoluteString,
                                    "client_id": clientID, "code_verifier": verifier], http: http)
        } catch SpotifyError.loginExpired {
            throw SpotifyError.authorizationFailed("invalid_grant")  // a bad code or verifier, not an old login
        }
        guard let refresh = reply.refresh_token else { throw SpotifyError.authorizationFailed("no refresh token") }
        return Tokens(accessToken: reply.access_token, refreshToken: refresh, expiresAt: now.addingTimeInterval(reply.expires_in),
                      scope: reply.scope ?? "")
    }

    /// Spotify may or may not rotate the refresh token; keep the old one when the reply has none.
    public static func refresh(_ tokens: Tokens, clientID: String, http: any HTTPClient, now: Date) async throws -> Tokens {
        let reply = try await post(["grant_type": "refresh_token", "refresh_token": tokens.refreshToken, "client_id": clientID], http: http)
        return Tokens(accessToken: reply.access_token, refreshToken: reply.refresh_token ?? tokens.refreshToken,
                      expiresAt: now.addingTimeInterval(reply.expires_in), scope: reply.scope ?? tokens.scope)
    }

    private struct Reply: Decodable {
        var access_token: String
        var expires_in: Double
        var scope: String?
        var refresh_token: String?
    }

    private struct Failure: Decodable { var error: String }

    private static func post(_ fields: [String: String], http: any HTTPClient) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves '+' alone, which a form body would read as a space.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else {
            switch (try? JSONDecoder().decode(Failure.self, from: data))?.error {
            case "invalid_grant": throw SpotifyError.loginExpired
            case "invalid_client": throw SpotifyError.unknownClient
            default: throw SpotifyError.http(response.statusCode)
            }
        }
        do { return try JSONDecoder().decode(Reply.self, from: data) } catch { throw SpotifyError.unexpectedReply }
    }
}

/// Hands out a valid access token: refreshes ahead of expiry, one refresh at a time for all callers.
public actor TokenProvider {
    let clientID: String
    let store: any SecretStore
    let http: any HTTPClient
    let now: @Sendable () -> Date
    private var cached: Tokens?
    private var refreshing: Task<Tokens, Error>?

    public init(clientID: String, store: any SecretStore, http: any HTTPClient = URLSession.spotify,
                now: @escaping @Sendable () -> Date = Date.init) {
        (self.clientID, self.store, self.http, self.now) = (clientID, store, http, now)
    }

    /// `replacing`: the token Spotify just answered 401 for; refreshed unless another caller already did.
    public func accessToken(replacing rejected: String? = nil) async throws -> String {
        guard let tokens = try cached ?? Tokens.load(from: store) else { throw SpotifyError.notLoggedIn }
        cached = tokens
        if tokens.accessToken != rejected, tokens.expiresAt > now().addingTimeInterval(60) { return tokens.accessToken }
        return try await refresh(tokens).accessToken
    }

    private func refresh(_ tokens: Tokens) async throws -> Tokens {
        if let refreshing { return try await refreshing.value }
        let task = Task { [clientID, http, now] in try await TokenEndpoint.refresh(tokens, clientID: clientID, http: http, now: now()) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        cached = fresh  // before saving: if the keychain refuses, the old refresh token may already be rotated away
        try fresh.save(in: store)
        return fresh
    }
}
