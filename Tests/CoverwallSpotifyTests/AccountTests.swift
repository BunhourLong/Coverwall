import Foundation
import Testing
import CoverwallSpotify

private let t0 = Date(timeIntervalSince1970: 3_000_000)
private let clientID = "0123456789abcdef0123456789abcdef"
private let tokenReply = #"{"access_token":"A","token_type":"Bearer","scope":"user-library-read user-top-read","expires_in":3600,"refresh_token":"R"}"#

private func query(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

@Test func setupAcceptsOnlyAClientIDShapedValue() throws {
    let account = SpotifyAccount(store: MemoryStore(), http: StubHTTP { _ in (500, "") }, now: { t0 })
    for bad in ["", "abc", "0123456789abcdef0123456789abcdeg", clientID + "0", "https://open.spotify.com",
                "０１２３４５６７８９ａｂｃｄｅｆ０１２３４５６７８９ａｂｃｄｅｆ"] {
        #expect(throws: SpotifyError.invalidClientID) { try account.setClientID(bad) }
    }
    try account.setClientID(" \(clientID)\n")
    #expect(try account.clientID() == clientID)
}

@Test func loginRunsThePKCEFlowOverTheLoopbackRedirectAndStoresTheTokens() async throws {
    let store = MemoryStore(), http = StubHTTP { _ in (200, tokenReply) }
    let account = SpotifyAccount(store: store, http: http, now: { t0 })
    try account.setClientID(clientID)

    // The "browser": approve at once by calling the redirect with the code and the state from the authorize URL.
    nonisolated(unsafe) var authorize: [String: String] = [:]
    let tokens = try await account.login(timeout: .seconds(5)) { url in
        authorize = query(url)
        let q = authorize
        Task { _ = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "\(q["redirect_uri"]!)?code=C&state=\(q["state"]!)")!) }
    }

    #expect(tokens == Tokens(accessToken: "A", refreshToken: "R", expiresAt: t0.addingTimeInterval(3600), scope: "user-library-read user-top-read"))
    #expect(try Tokens.load(from: store) == tokens)
    #expect(authorize["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
    #expect(authorize["scope"] == SpotifyAccount.scopes.joined(separator: " "))
    let body = String(decoding: try #require(http.requests.first?.httpBody), as: UTF8.self)
    let form = Dictionary(uniqueKeysWithValues: (URLComponents(string: "?" + body)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(form["code"] == "C" && form["redirect_uri"] == authorize["redirect_uri"])
    #expect(PKCE.challenge(for: form["code_verifier"] ?? "") == authorize["code_challenge"])
}

@Test func loginAsksForTheClientIDFirstAndLogoutForgetsWhatItShould() async throws {
    let store = MemoryStore()
    let account = SpotifyAccount(store: store, http: StubHTTP { _ in (500, "") }, now: { t0 })
    await #expect(throws: SpotifyError.noClientID) { try await account.login(timeout: .seconds(1)) { _ in } }

    try account.setClientID(clientID)
    try Tokens(accessToken: "A", refreshToken: "R", expiresAt: t0, scope: "").save(in: store)
    try account.logout(all: false)
    #expect(try Tokens.load(from: store) == nil && account.clientID() == clientID)
    try account.logout(all: true)
    #expect(try account.clientID() == nil)
}

@Test func statusChecksTheLoginLiveAndRetriesOnceAfterA401() async throws {
    let http = StubHTTP { request in
        if request.url?.host == "accounts.spotify.com" { return (200, #"{"access_token":"B","token_type":"Bearer","scope":"user-top-read","expires_in":3600}"#) }
        return request.value(forHTTPHeaderField: "Authorization") == "Bearer B" ? (200, #"{"id":"u1","display_name":"Capon","account_id":"x"}"#) : (401, "")
    }
    let store = MemoryStore()
    let account = SpotifyAccount(store: store, http: http, now: { t0 })
    #expect(try await account.status() == SpotifyAccount.Status(clientID: false, loggedIn: false, scopes: [], expiresAt: nil, user: nil, problem: nil))
    #expect(http.requests.isEmpty)  // nothing to check live

    try account.setClientID(clientID)
    try Tokens(accessToken: "A", refreshToken: "R", expiresAt: t0.addingTimeInterval(600), scope: "user-top-read").save(in: store)
    let status = try await account.status()

    #expect(status == SpotifyAccount.Status(clientID: true, loggedIn: true, scopes: ["user-top-read"],
                                            expiresAt: t0.addingTimeInterval(3600), user: "Capon", problem: nil))
    #expect(http.requests.map { $0.url!.absoluteString } == ["https://api.spotify.com/v1/me", "https://accounts.spotify.com/api/token",
                                                             "https://api.spotify.com/v1/me"])
}

@Test func statusReportsA403WithItsLikelyCauses() async throws {
    let store = MemoryStore()
    let account = SpotifyAccount(store: store, http: StubHTTP { _ in (403, #"{"error":{"status":403,"message":"Forbidden"}}"#) }, now: { t0 })
    try account.setClientID(clientID)
    try Tokens(accessToken: "A", refreshToken: "R", expiresAt: t0.addingTimeInterval(600), scope: "").save(in: store)

    #expect(try await account.status().problem == SpotifyError.forbidden.description)
    #expect(SpotifyError.forbidden.description.contains("Premium") && SpotifyError.forbidden.description.contains("User Management"))
}

@Test func anotherClientIDDropsTheOldAppsTokens() throws {
    let store = MemoryStore()
    let account = SpotifyAccount(store: store, http: StubHTTP { _ in (500, "") }, now: { t0 })
    try account.setClientID(clientID.uppercased())
    #expect(try account.clientID() == clientID)  // stored lowercase
    try Tokens(accessToken: "A", refreshToken: "R", expiresAt: t0, scope: "").save(in: store)

    try account.setClientID(clientID)  // same app: login kept
    #expect(try Tokens.load(from: store) != nil)
    try account.setClientID("ffffffffffffffffffffffffffffffff")  // another app: its tokens can't refresh
    #expect(try Tokens.load(from: store) == nil)
}
