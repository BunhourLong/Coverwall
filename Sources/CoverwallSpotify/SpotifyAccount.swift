import Foundation

/// `coverwall spotify setup|login|logout|status` without the printing (PLAN.md §4.7, 7.2).
public struct SpotifyAccount: Sendable {
    /// Everything 7.3's sources read; asked for once at login.
    public static let scopes = ["user-library-read", "user-top-read", "playlist-read-private", "playlist-read-collaborative"]
    static let clientIDKey = "client-id"

    let store: any SecretStore
    let http: any HTTPClient
    let now: @Sendable () -> Date

    public init(store: any SecretStore = SecretStores.default, http: any HTTPClient = URLSession.spotify,
                now: @escaping @Sendable () -> Date = Date.init) {
        (self.store, self.http, self.now) = (store, http, now)
    }

    public func clientID() throws -> String? { try store.read(Self.clientIDKey) }

    /// Spotify Client IDs are 32 hex characters. Another app's ID drops the old app's login: its tokens can't refresh.
    public func setClientID(_ raw: String) throws {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.count == 32, id.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw SpotifyError.invalidClientID }
        if let old = try clientID(), old != id { try store.delete(Tokens.key) }
        try store.write(id, for: Self.clientIDKey)
    }

    /// Opens the consent page (via `open`), waits for the loopback callback, exchanges the code, stores the tokens.
    public func login(timeout: Duration = .seconds(120), open: (URL) -> Void) async throws -> Tokens {
        guard let clientID = try clientID() else { throw SpotifyError.noClientID }
        let listener = try LoopbackListener(), pkce = PKCE()
        let redirect = try await listener.redirect()
        open(Authorization.url(clientID: clientID, redirect: redirect, pkce: pkce, scopes: Self.scopes))
        let code = try Authorization.code(fromCallback: try await listener.callback(timeout: timeout), state: pkce.state)
        let tokens = try await TokenEndpoint.exchange(code: code, redirect: redirect, verifier: pkce.verifier, clientID: clientID,
                                                      http: http, now: now())
        try tokens.save(in: store)
        return tokens
    }

    /// Calls as the logged-in user; `trace` gets raw error replies (`--verbose`).
    public func api(wait: @escaping SpotifyAPI.Wait = SpotifyAPI.sleep, trace: SpotifyAPI.Trace? = nil) throws -> SpotifyAPI {
        guard let clientID = try clientID() else { throw SpotifyError.noClientID }
        return SpotifyAPI(tokens: TokenProvider(clientID: clientID, store: store, http: http, now: now), http: http, wait: wait, trace: trace)
    }

    /// Local only: Spotify has no revoke endpoint (SPIKE_NOTES Phase 7.0).
    public func logout(all: Bool) throws {
        try store.delete(Tokens.key)
        if all { try store.delete(Self.clientIDKey) }
    }

    public struct Status: Codable, Equatable, Sendable {
        public var clientID: Bool
        public var loggedIn: Bool
        public var scopes: [String]
        public var expiresAt: Date?
        /// Display name (or id) from the live check.
        public var user: String?
        /// Why the live check failed, as a next step.
        public var problem: String?

        public init(clientID: Bool, loggedIn: Bool, scopes: [String], expiresAt: Date?, user: String?, problem: String?) {
            (self.clientID, self.loggedIn, self.scopes, self.expiresAt, self.user, self.problem) = (clientID, loggedIn, scopes, expiresAt, user, problem)
        }
    }

    /// Stored state plus one live `GET /v1/me` (refreshing the token if needed).
    public func status() async throws -> Status {
        let id = try clientID()
        guard id != nil, try Tokens.load(from: store) != nil else {
            return Status(clientID: id != nil, loggedIn: false, scopes: [], expiresAt: nil, user: nil, problem: nil)
        }
        struct Me: Decodable { var id: String?; var display_name: String? }
        var user: String?, problem: String?
        do {
            let me = try JSONDecoder().decode(Me.self, from: await api().get("me"))
            user = me.display_name ?? me.id
        } catch let error as SpotifyError {
            problem = error.description
        } catch let error as SecretStoreError {
            problem = error.description
        } catch {
            problem = SpotifyError.unexpectedReply.description
        }
        let stored = try Tokens.load(from: store)  // after a refresh in the live check
        return Status(clientID: true, loggedIn: stored != nil, scopes: stored?.scope.split(separator: " ").map(String.init) ?? [],
                      expiresAt: stored?.expiresAt, user: user, problem: problem)
    }
}
