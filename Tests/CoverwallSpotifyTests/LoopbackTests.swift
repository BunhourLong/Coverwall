import Foundation
import Testing
import CoverwallSpotify

@Test func onlyAGetOfTheCallbackPathIsTheCallback() {
    let callback = LoopbackListener.answer("GET /callback?code=c&state=s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    #expect(callback.target == "/callback?code=c&state=s" && callback.reply.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(callback.reply.contains("close this tab"))

    for request in ["GET /favicon.ico HTTP/1.1\r\n\r\n", "POST /callback?code=c HTTP/1.1\r\n\r\n", "GET /callbackx HTTP/1.1\r\n\r\n", ""] {
        let other = LoopbackListener.answer(request)
        #expect(other.target == nil && other.reply.hasPrefix("HTTP/1.1 404 Not Found\r\n"), "\(request)")
    }
}

private func get(_ url: URL) async throws -> Int {
    let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
}

@Test func listenerOnLoopbackIgnoresOtherPathsAndStopsAfterTheCallback() async throws {
    let listener = try LoopbackListener()
    let redirect = try await listener.redirect()
    #expect(redirect.scheme == "http" && redirect.host == "127.0.0.1" && redirect.path == "/callback" && (redirect.port ?? 0) > 0)

    async let target = listener.callback(timeout: .seconds(5))
    #expect(try await get(redirect.deletingLastPathComponent().appendingPathComponent("favicon.ico")) == 404)
    #expect(try await get(URL(string: redirect.absoluteString + "?code=c&state=s")!) == 200)

    #expect(try await target == "/callback?code=c&state=s")
    await #expect(throws: (any Error).self) { _ = try await get(redirect) }  // closed
}

@Test func noCallbackInTimeIsATimeoutWithTheRedirectHint() async throws {
    let listener = try LoopbackListener()
    _ = try await listener.redirect()
    await #expect(throws: SpotifyError.loginTimedOut) { try await listener.callback(timeout: .milliseconds(100)) }
}
