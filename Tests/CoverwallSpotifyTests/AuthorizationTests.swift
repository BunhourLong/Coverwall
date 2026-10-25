import Foundation
import Testing
import CoverwallSpotify

@Test func pkceChallengeMatchesTheRFC7636TestVector() {
    #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func freshVerifiersAreLongUnreservedAndUnique() {
    let a = PKCE(), b = PKCE()
    #expect(a.verifier != b.verifier && a.state != b.state)
    #expect((43...128).contains(a.verifier.count))
    #expect(a.verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    #expect(a.challenge == PKCE.challenge(for: a.verifier))
}

@Test func authorizeURLCarriesEveryPKCEParameter() throws {
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s1")
    let url = Authorization.url(clientID: "abc123", redirect: URL(string: "http://127.0.0.1:54321/callback")!, pkce: pkce,
                                scopes: ["user-library-read", "user-top-read"])

    let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(parts.scheme == "https" && parts.host == "accounts.spotify.com" && parts.path == "/authorize")
    let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query == ["client_id": "abc123", "response_type": "code", "redirect_uri": "http://127.0.0.1:54321/callback",
                      "code_challenge_method": "S256", "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                      "state": "s1", "scope": "user-library-read user-top-read"])
}

@Test func callbackYieldsTheCodeOnlyForTheExpectedState() throws {
    #expect(try Authorization.code(fromCallback: "/callback?code=XYZ&state=s1", state: "s1") == "XYZ")
    #expect(throws: SpotifyError.stateMismatch) { try Authorization.code(fromCallback: "/callback?code=XYZ&state=evil", state: "s1") }
    #expect(throws: SpotifyError.stateMismatch) { try Authorization.code(fromCallback: "/callback?code=XYZ", state: "s1") }
}

@Test func declinedOrBrokenCallbacksSayWhatHappened() {
    #expect(throws: SpotifyError.accessDenied) { try Authorization.code(fromCallback: "/callback?error=access_denied&state=s1", state: "s1") }
    #expect(throws: SpotifyError.authorizationFailed("server_error")) {
        try Authorization.code(fromCallback: "/callback?error=server_error&state=s1", state: "s1")
    }
    #expect(throws: SpotifyError.authorizationFailed("no code")) { try Authorization.code(fromCallback: "/callback?state=s1", state: "s1") }
}
