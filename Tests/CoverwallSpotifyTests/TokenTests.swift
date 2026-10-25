import Foundation
import Testing
import CoverwallSpotify

/// Canned HTTP: every request is recorded; `reply` answers it after a short pause so concurrent callers overlap.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    let reply: @Sendable (URLRequest) -> (Int, String)

    init(reply: @escaping @Sendable (URLRequest) -> (Int, String)) { self.reply = reply }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        try await Task.sleep(for: .milliseconds(20))
        let (status, body) = reply(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class MemoryStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(_ key: String) throws -> String? { lock.withLock { values[key] } }
    func write(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

private let t0 = Date(timeIntervalSince1970: 2_000_000)

/// Decodes like a form parser does: '+' is a space.
private func form(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
    return Dictionary(uniqueKeysWithValues: (URLComponents(string: "?" + body)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private func storeWith(_ tokens: Tokens) throws -> MemoryStore {
    let store = MemoryStore()
    try tokens.save(in: store)
    return store
}

private let refreshed = #"{"access_token":"NEW","token_type":"Bearer","scope":"user-top-read","expires_in":3600}"#

@Test func codeExchangePostsThePKCEFormAndDecodesTheTokens() async throws {
    let http = StubHTTP { _ in (200, #"{"access_token":"A","token_type":"Bearer","scope":"user-top-read","expires_in":3600,"refresh_token":"R","extra":1}"#) }

    let tokens = try await TokenEndpoint.exchange(code: "C+/:=&", redirect: URL(string: "http://127.0.0.1:5000/callback")!, verifier: "V",
                                                  clientID: "id", http: http, now: t0)

    #expect(tokens == Tokens(accessToken: "A", refreshToken: "R", expiresAt: t0.addingTimeInterval(3600), scope: "user-top-read"))
    let request = try #require(http.requests.first)
    #expect(request.url?.absoluteString == "https://accounts.spotify.com/api/token" && request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(form(request) == ["grant_type": "authorization_code", "code": "C+/:=&", "redirect_uri": "http://127.0.0.1:5000/callback",
                              "client_id": "id", "code_verifier": "V"])
}

@Test func validTokenIsServedWithoutARequest() async throws {
    let http = StubHTTP { _ in (500, "") }
    let store = try storeWith(Tokens(accessToken: "OLD", refreshToken: "R", expiresAt: t0.addingTimeInterval(600), scope: ""))

    let provider = TokenProvider(clientID: "id", store: store, http: http, now: { t0 })

    #expect(try await provider.accessToken() == "OLD")
    #expect(http.requests.isEmpty)
}

@Test func concurrentCallersShareOneRefresh() async throws {
    let http = StubHTTP { _ in (200, refreshed) }
    let store = try storeWith(Tokens(accessToken: "OLD", refreshToken: "R", expiresAt: t0.addingTimeInterval(30), scope: ""))
    let provider = TokenProvider(clientID: "id", store: store, http: http, now: { t0 })

    let tokens = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<10 { group.addTask { try await provider.accessToken() } }
        return try await group.reduce(into: []) { $0.append($1) }
    }

    #expect(tokens == Array(repeating: "NEW", count: 10))
    #expect(http.requests.count == 1)
    #expect(form(http.requests[0]) == ["grant_type": "refresh_token", "refresh_token": "R", "client_id": "id"])
    // No new refresh token in the reply → the old one is kept.
    #expect(try Tokens.load(from: store) == Tokens(accessToken: "NEW", refreshToken: "R", expiresAt: t0.addingTimeInterval(3600),
                                                   scope: "user-top-read"))
}

@Test func rejectedTokenIsRefreshedOnceEvenIfSeveralCallersReportIt() async throws {
    let http = StubHTTP { _ in (200, #"{"access_token":"NEW","token_type":"Bearer","scope":"","expires_in":3600,"refresh_token":"R2"}"#) }
    let store = try storeWith(Tokens(accessToken: "OLD", refreshToken: "R", expiresAt: t0.addingTimeInterval(600), scope: ""))
    let provider = TokenProvider(clientID: "id", store: store, http: http, now: { t0 })

    #expect(try await provider.accessToken(replacing: "OLD") == "NEW")
    #expect(try await provider.accessToken(replacing: "OLD") == "NEW")  // a late 401 for the old token: no second refresh

    #expect(http.requests.count == 1)
    #expect(try Tokens.load(from: store)?.refreshToken == "R2")  // rotated refresh token stored
}

@Test func refreshFailuresMapToTheNextStep() async throws {
    let expired = Tokens(accessToken: "OLD", refreshToken: "R", expiresAt: t0, scope: "")
    for (body, error) in [(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#, SpotifyError.loginExpired),
                          (#"{"error":"invalid_client"}"#, SpotifyError.unknownClient)] {
        let provider = TokenProvider(clientID: "id", store: try storeWith(expired), http: StubHTTP { _ in (400, body) }, now: { t0 })
        await #expect(throws: error) { try await provider.accessToken() }
    }
    let provider = TokenProvider(clientID: "id", store: MemoryStore(), http: StubHTTP { _ in (500, "") }, now: { t0 })
    await #expect(throws: SpotifyError.notLoggedIn) { try await provider.accessToken() }
}

@Test func rejectedCodeAtTheExchangeIsALoginFailureNotAnExpiredLogin() async throws {
    let http = StubHTTP { _ in (400, #"{"error":"invalid_grant","error_description":"Invalid authorization code"}"#) }
    await #expect(throws: SpotifyError.authorizationFailed("invalid_grant")) {
        try await TokenEndpoint.exchange(code: "C", redirect: URL(string: "http://127.0.0.1:5000/callback")!, verifier: "V",
                                         clientID: "id", http: http, now: t0)
    }
}

/// Refuses to store tokens, like a locked keychain.
private final class ReadOnlyStore: SecretStore, @unchecked Sendable {
    let inner: MemoryStore
    init(_ inner: MemoryStore) { self.inner = inner }
    func read(_ key: String) throws -> String? { try inner.read(key) }
    func write(_ value: String, for key: String) throws { throw SecretStoreError.keychain(51) }
    func delete(_ key: String) throws {}
}

@Test func refreshedTokensStayInUseWhenTheyCantBeStored() async throws {
    let http = StubHTTP { _ in (200, #"{"access_token":"NEW","token_type":"Bearer","scope":"","expires_in":3600,"refresh_token":"R2"}"#) }
    let store = ReadOnlyStore(try storeWith(Tokens(accessToken: "OLD", refreshToken: "R", expiresAt: t0, scope: "")))
    let provider = TokenProvider(clientID: "id", store: store, http: http, now: { t0 })

    await #expect(throws: SecretStoreError.keychain(51)) { try await provider.accessToken() }
    #expect(try await provider.accessToken() == "NEW")  // not a second refresh with the rotated-away "R"
    #expect(http.requests.count == 1)
}

/// Fails every request the way URLSession does when the Mac is offline.
private final class OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@Test func urlSessionFailuresBecomeTheOfflineMessage() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflineProtocol.self]
    await #expect(throws: SpotifyError.offline) {
        try await URLSession(configuration: configuration).send(URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!))
    }
}

@Test func refreshRejectedBecauseAnotherProcessRotatedTheTokenRetriesWithTheStoredOne() async throws {
    let store = try storeWith(Tokens(accessToken: "OLD", refreshToken: "R", expiresAt: t0, scope: ""))
    let http = StubHTTP { request in
        if form(request)["refresh_token"] == "R" {
            // Meanwhile the scheduled sync refreshed and Spotify rotated R → R2.
            try? Tokens(accessToken: "OTHER", refreshToken: "R2", expiresAt: t0, scope: "").save(in: store)
            return (400, #"{"error":"invalid_grant"}"#)
        }
        return (200, #"{"access_token":"NEW","token_type":"Bearer","scope":"","expires_in":3600}"#)
    }
    let provider = TokenProvider(clientID: "id", store: store, http: http, now: { t0 })

    #expect(try await provider.accessToken() == "NEW")
    #expect(http.requests.map { form($0)["refresh_token"] } == ["R", "R2"])
    #expect(try Tokens.load(from: store)?.refreshToken == "R2")
}
