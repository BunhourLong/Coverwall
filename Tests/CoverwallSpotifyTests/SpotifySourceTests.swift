import CoverwallKit
import Foundation
import ImageIO
import Testing
import CoverwallSpotify

private let t0 = Date(timeIntervalSince1970: 4_000_000)

/// Records every wait instead of sleeping.
private final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    var all: [Duration] { lock.withLock { recorded } }
    var wait: SpotifyAPI.Wait { { [self] d in lock.withLock { recorded.append(d) } } }
}

/// An API whose access token is valid; `routes` answers by URL (path + query) on api.spotify.com and i.scdn.co.
private func makeAPI(_ waits: Waits = Waits(), routes: @escaping @Sendable (URL) -> (Int, String)) throws -> (SpotifyAPI, StubHTTP) {
    let store = MemoryStore()
    try Tokens(accessToken: "A", refreshToken: "R", expiresAt: t0.addingTimeInterval(3600), scope: "").save(in: store)
    let http = StubHTTP { routes($0.url!) }
    return (SpotifyAPI(tokens: TokenProvider(clientID: "id", store: store, http: http, now: { t0 }), http: http, wait: waits.wait), http)
}

private func album(_ id: String) -> String {
    #"{"album":{"id":"\#(id)","images":[{"url":"https://i.scdn.co/image/\#(id)-640","width":640,"height":640},{"url":"https://i.scdn.co/image/\#(id)-64","width":64,"height":64}]}}"#
}

private func path(_ url: URL) -> String { url.path + (url.query.map { "?" + $0 } ?? "") }

@Test func savedAlbumsFollowEveryPageAndTakeTheLargestImage() async throws {
    let (api, _) = try makeAPI { url in
        switch path(url) {
        case "/v1/me/albums?limit=50": (200, #"{"items":[\#(album("a")),\#(album("b"))],"next":"https://api.spotify.com/v1/me/albums?offset=50&limit=50","total":3}"#)
        case "/v1/me/albums?offset=50&limit=50": (200, #"{"items":[\#(album("c")),\#(album("a")),{"album":null}],"next":null}"#)
        default: (404, "")
        }
    }

    let items = try await SpotifySource(.savedAlbums, api: api).items()

    #expect(items.map(\.source) == ["https://i.scdn.co/image/a-640", "https://i.scdn.co/image/b-640", "https://i.scdn.co/image/c-640"])
    #expect(items.allSatisfy { $0.mtime == 0 })
}

@Test func topArtistsGiveTheFirstPageOfEachArtistsAlbums() async throws {
    let (api, http) = try makeAPI { url in
        switch path(url) {
        case "/v1/me/top/artists?limit=50": (200, #"{"items":[{"id":"x1","name":"One"},{"id":"x2"}],"next":"https://api.spotify.com/v1/me/top/artists?offset=50"}"#)
        case "/v1/artists/x1/albums?include_groups=album&limit=10":
            (200, #"{"items":[{"images":[{"url":"https://i.scdn.co/image/p","width":300},{"url":"https://i.scdn.co/image/q","width":640}]}],"next":"https://api.spotify.com/v1/artists/x1/albums?offset=10"}"#)
        case "/v1/artists/x2/albums?include_groups=album&limit=10": (200, #"{"items":[{"images":[]},{"images":[{"url":"https://i.scdn.co/image/r"}]}],"next":null}"#)
        default: (404, "")
        }
    }

    let items = try await SpotifySource(.topArtists, api: api).items()

    #expect(items.map(\.source) == ["https://i.scdn.co/image/q", "https://i.scdn.co/image/r"])
    #expect(http.requests.count == 3)  // no second page of artists or albums
}

@Test func playlistSkipsLocalFilesAndEpisodesAndSaysWhenItIsntYours() async throws {
    let id = "37i9dQZF1DXcBWIGoYBM5M"
    let (api, _) = try makeAPI { url in
        guard path(url).hasPrefix("/v1/playlists/\(id)/items?limit=50") else { return (404, "") }
        return (200, #"{"items":[{"is_local":false,"item":{"type":"track","album":{"images":[{"url":"https://i.scdn.co/image/t"}]}}},{"is_local":true,"item":{"type":"track","album":{"images":[{"url":"https://i.scdn.co/image/local"}]}}},{"is_local":false,"item":{"type":"episode","images":[{"url":"https://i.scdn.co/image/e"}]}},{"is_local":false,"item":null}],"next":null}"#)
    }
    #expect(try await SpotifySource(.playlist(id), api: api).items().map(\.source) == ["https://i.scdn.co/image/t"])

    let (other, _) = try makeAPI { _ in (403, #"{"error":{"status":403,"message":"Forbidden"}}"#) }
    await #expect(throws: SpotifyError.playlistNotYours) { try await SpotifySource(.playlist(id), api: other).items() }
}

@Test func noCoversIsAFailureSoTheOldCacheStays() async throws {
    let (api, _) = try makeAPI { _ in (200, #"{"items":[],"next":null}"#) }
    await #expect(throws: SpotifyError.noCovers) { try await SpotifySource(.savedAlbums, api: api).items() }
}

@Test func shortRateLimitsAreWaitedOutLongOnesAndQuotaStop() async throws {
    nonisolated(unsafe) var calls = 0
    let waits = Waits()
    let (api, _) = try makeAPI(waits) { _ in
        calls += 1
        return calls < 3 ? (429, "") : (200, #"{"items":[\#(album("a"))],"next":null}"#)
    }
    _ = try await SpotifySource(.savedAlbums, api: api).items()  // Retry-After missing → treated as 1 s
    #expect(waits.all == [.seconds(1), .seconds(1)])

    let (long, _) = try makeAPI { _ in (429, "") }
    await #expect(throws: SpotifyError.rateLimited(retryAfter: nil)) { try await SpotifySource(.savedAlbums, api: long).items() }

    let quotaWaits = Waits()
    let (quota, _) = try makeAPI(quotaWaits) { _ in (429, #"{"error":{"status":429,"message":"Too many requests","reason":"QUOTA_EXCEEDED"}}"#) }
    await #expect(throws: SpotifyError.quotaExceeded) { try await SpotifySource(.savedAlbums, api: quota).items() }
    #expect(quotaWaits.all.isEmpty)
}

@Test func retryAfterHeaderDecidesBetweenWaitingAndStopping() async throws {
    for (seconds, waited) in [(5, true), (3600, false)] {
        let waits = Waits()
        let store = MemoryStore()
        try Tokens(accessToken: "A", refreshToken: "R", expiresAt: t0.addingTimeInterval(3600), scope: "").save(in: store)
        nonisolated(unsafe) var calls = 0
        let http = HeaderHTTP { _ in
            calls += 1
            return calls == 1 ? (429, ["Retry-After": "\(seconds)"], "") : (200, [:], #"{"items":[\#(album("a"))],"next":null}"#)
        }
        let api = SpotifyAPI(tokens: TokenProvider(clientID: "id", store: store, http: http, now: { t0 }), http: http, wait: waits.wait)
        if waited {
            _ = try await SpotifySource(.savedAlbums, api: api).items()
            #expect(waits.all == [.seconds(seconds)])
        } else {
            await #expect(throws: SpotifyError.rateLimited(retryAfter: seconds)) { try await SpotifySource(.savedAlbums, api: api).items() }
            #expect(waits.all.isEmpty)
        }
    }
}

/// Like StubHTTP, with response headers.
private final class HeaderHTTP: HTTPClient, @unchecked Sendable {
    let reply: @Sendable (URLRequest) -> (Int, [String: String], String)
    init(reply: @escaping @Sendable (URLRequest) -> (Int, [String: String], String)) { self.reply = reply }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, headers, body) = reply(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

@Test func coverDownloadsSkipMissingImagesAndAbortOnOtherFailures() async throws {
    let (api, http) = try makeAPI { url in
        switch url.lastPathComponent {
        case "ok": (200, "JPEG")
        case "gone": (404, "")
        default: (503, "")
        }
    }
    let source = SpotifySource(.savedAlbums, api: api)
    func item(_ name: String) -> CoverItem { CoverItem(source: "https://i.scdn.co/image/\(name)", mtime: 0) }

    #expect(try await source.data(for: item("ok")) == Data("JPEG".utf8))
    #expect(http.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)  // the CDN gets no token
    await #expect(throws: UnreadableCover.self) { try await source.data(for: item("gone")) }
    await #expect(throws: SpotifyError.http(503)) { try await source.data(for: item("down")) }
    #expect(source.policy == .spotify && source.maxConcurrentReads == 6)
}

@Test func addResolvesArtistNamesAndPlaylistLinks() async throws {
    let (api, http) = try makeAPI { url in
        path(url).hasPrefix("/v1/search?") ? (200, #"{"artists":{"items":[{"id":"4LLpKhyESsyAXpc4laK94U","name":"Mac Miller"}],"next":null}}"#) : (404, "")
    }

    let artist = try await SpotifySources.resolve("spotify:artist", "mac miller", api: api)
    #expect(artist.source == "spotify:artist:4LLpKhyESsyAXpc4laK94U" && artist.match == "Mac Miller")
    let query = URLComponents(url: try #require(http.requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(Set(query.map { "\($0.name)=\($0.value ?? "")" }) == ["q=mac miller", "type=artist", "limit=1"])

    let id = "37i9dQZF1DXcBWIGoYBM5M"
    for link in ["https://open.spotify.com/playlist/\(id)?si=abc", "https://open.spotify.com/intl-de/playlist/\(id)", "spotify:playlist:\(id)", id] {
        #expect(try await SpotifySources.resolve("spotify:playlist", link, api: api) == ("spotify:playlist:\(id)", nil), "\(link)")
    }
    #expect(try await SpotifySources.resolve("spotify:saved-albums", nil, api: api) == ("spotify:saved-albums", nil))
    #expect(try await SpotifySources.resolve("spotify:artist:\(id)", nil, api: api) == ("spotify:artist:\(id)", nil))

    await #expect(throws: SpotifyError.badPlaylistLink("https://example.com/x")) { try await SpotifySources.resolve("spotify:playlist", "https://example.com/x", api: api) }
    await #expect(throws: SpotifyError.unknownSource("spotify:liked")) { try await SpotifySources.resolve("spotify:liked", nil, api: api) }
    await #expect(throws: SpotifyError.missingArgument("spotify:artist")) { try await SpotifySources.resolve("spotify:artist", nil, api: api) }

    let (nobody, _) = try makeAPI { _ in (200, #"{"artists":{"items":[]}}"#) }
    await #expect(throws: SpotifyError.artistNotFound("zzz")) { try await SpotifySources.resolve("spotify:artist", "zzz", api: nobody) }
}

/// Answers with raw bytes (images), counting requests per host.
private final class BytesHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []
    let reply: @Sendable (URL) -> (Int, Data)
    init(reply: @escaping @Sendable (URL) -> (Int, Data)) { self.reply = reply }
    func count(_ host: String) -> Int { lock.withLock { hosts.filter { $0 == host }.count } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { hosts.append(request.url?.host ?? "") }
        let (status, body) = reply(request.url!)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func pngData() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let out = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return out as Data
}

@Test func spotifyProfileFillsTheCacheAndResyncDownloadsNothingNew() async throws {
    let data = FileManager.default.temporaryDirectory.appendingPathComponent("coverwall-spotify-\(UUID().uuidString)")
    let png = try pngData()
    let http = BytesHTTP { url in
        // Trailing bytes keep the hashes distinct; ImageIO ignores them.
        url.host == "i.scdn.co" ? (200, png + Data(url.lastPathComponent.utf8)) : (200, Data(#"{"items":[\#(album("a")),\#(album("b"))],"next":null}"#.utf8))
    }
    let store = MemoryStore()
    try Tokens(accessToken: "A", refreshToken: "R", expiresAt: t0.addingTimeInterval(3600), scope: "").save(in: store)
    let api = SpotifyAPI(tokens: TokenProvider(clientID: "id", store: store, http: http, now: { t0 }), http: http)

    let first = try await TileCache.sync("sp", from: SpotifySource(.savedAlbums, api: api), tileMaxPixels: 512, dataDir: data, now: t0)
    let again = try await TileCache.sync("sp", from: SpotifySource(.savedAlbums, api: api), tileMaxPixels: 512, dataDir: data, now: t0)

    #expect(first.images == 2 && again.images == 2 && again.added == 0)
    #expect(http.count("i.scdn.co") == 2)  // the re-sync downloaded nothing
    let manifest = try JSONDecoder().decode(CacheManifest.self, from: Data(contentsOf: Paths.manifest("sp", in: data)))
    #expect(manifest.policy == .spotify && manifest.expiresAt == t0.timeIntervalSince1970 + 72 * 3600)
}

@Test func artistSearchReportsSpotifyErrorsNotAMissingArtist() async throws {
    let (api, _) = try makeAPI { _ in (403, #"{"error":{"status":403,"message":"Forbidden"}}"#) }
    await #expect(throws: SpotifyError.forbidden) { try await SpotifySources.resolve("spotify:artist", "Mac Miller", api: api) }
}

@Test func searchEncodesPlusAndStrayArgumentsAreRejected() async throws {
    let (api, http) = try makeAPI { _ in (200, #"{"artists":{"items":[{"id":"4LLpKhyESsyAXpc4laK94U","name":"Florence + the Machine"}]}}"#) }
    _ = try await SpotifySources.resolve("spotify:artist", "Florence + the Machine", api: api)
    #expect(http.requests.last?.url?.query?.contains("q=Florence%20%2B%20the%20Machine") == true)

    await #expect(throws: SpotifyError.unexpectedArgument("spotify:saved-albums")) {
        try await SpotifySources.resolve("spotify:saved-albums", "extra", api: api)
    }
}

@Test func brokenNextLinkIsAnUnexpectedReplyNotACrash() async throws {
    let (api, _) = try makeAPI { _ in (200, #"{"items":[\#(album("a"))],"next":""}"#) }
    await #expect(throws: SpotifyError.unexpectedReply) { try await SpotifySource(.savedAlbums, api: api).items() }
}

@Test func deletedPlaylistSaysSo() async throws {
    let (api, _) = try makeAPI { _ in (404, #"{"error":{"status":404,"message":"Not found."}}"#) }
    await #expect(throws: SpotifyError.playlistNotFound) { try await SpotifySource(.playlist("37i9dQZF1DXcBWIGoYBM5M"), api: api).items() }
    #expect(SpotifyError.playlistNotYours.description.contains("Premium"))
}
