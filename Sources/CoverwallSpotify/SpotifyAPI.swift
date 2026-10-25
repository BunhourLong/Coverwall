import Foundation

/// Authenticated Web API calls: bearer token, one refresh + retry on 401, short `Retry-After` waits, Spotify errors
/// mapped to our own messages (PLAN.md §4.7). Docs checked 2026-10-25.
public struct SpotifyAPI: Sendable {
    public typealias Wait = @Sendable (Duration) async throws -> Void
    public typealias Trace = @Sendable (String) -> Void
    public static let sleep: Wait = { try await Task.sleep(for: $0) }
    static let base = URL(string: "https://api.spotify.com/v1/")!
    /// Longer `Retry-After`s stop the sync instead of waiting.
    static let longestWait = 30, retries = 3

    let tokens: TokenProvider
    let http: any HTTPClient
    let wait: Wait
    let trace: Trace?

    public init(tokens: TokenProvider, http: any HTTPClient = URLSession.spotify, wait: @escaping Wait = SpotifyAPI.sleep, trace: Trace? = nil) {
        (self.tokens, self.http, self.wait, self.trace) = (tokens, http, wait, trace)
    }

    /// `path` is relative to `/v1/` or a full `next` URL from a page.
    public func get(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: Self.base)?.absoluteURL, url.host == "api.spotify.com" else { throw SpotifyError.unexpectedReply }
        var token = try await tokens.accessToken(), refreshed = false, waited = 0
        while true {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await http.send(request)
            if response.statusCode == 200 { return data }
            trace?("Spotify: HTTP \(response.statusCode) for GET \(url.path): \(String(decoding: data.prefix(500), as: UTF8.self))")
            switch response.statusCode {
            case 401 where !refreshed:
                token = try await tokens.accessToken(replacing: token)
                refreshed = true
            case 401: throw SpotifyError.loginExpired
            case 403: throw SpotifyError.forbidden
            case 429:
                if String(decoding: data, as: UTF8.self).contains("QUOTA_EXCEEDED") { throw SpotifyError.quotaExceeded }
                let header = response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }, seconds = header ?? 1
                guard seconds <= Self.longestWait, waited < Self.retries else { throw SpotifyError.rateLimited(retryAfter: header) }
                try await wait(.seconds(seconds))
                waited += 1
            default: throw SpotifyError.http(response.statusCode)
            }
        }
    }

    /// Every page from `first` on (`all: false`: just the first), decoded leniently.
    func pages<Item: Decodable>(_ first: String, all: Bool = true, of _: Item.Type) async throws -> [Item] {
        var items: [Item] = [], next: String? = first, count = 0
        while let path = next {
            count += 1
            guard count <= 1000 else { throw SpotifyError.unexpectedReply }  // a `next` that never ends
            let page: Page<Item>
            do { page = try JSONDecoder().decode(Page<Item>.self, from: await get(path)) } catch is DecodingError { throw SpotifyError.unexpectedReply }
            items += (page.items ?? []).compactMap(\.value)
            next = all ? page.next : nil
        }
        return items
    }
}

struct Page<Item: Decodable>: Decodable {
    var items: [Lenient<Item>]?
    var next: String?
}

/// One list entry that doesn't decode (or is `null`) is dropped, not the whole page (CLAUDE.md 12).
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
