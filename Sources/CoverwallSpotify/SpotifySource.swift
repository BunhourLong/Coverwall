import CoverwallKit
import Foundation

extension SourcePolicy {
    /// Spotify's rules (SPIKE_NOTES Phase 7.0): resize but never crop, attribute with the logo, cache only
    /// temporarily (72 h with the daily sync), never next to other services' covers.
    public static let spotify = SourcePolicy(crop: .none, attribution: .spotify, cacheTTL: 72 * 3600, mixable: false)
}

/// Album covers from the user's Spotify library. Item = the image URL (content-addressed on i.scdn.co), so a
/// re-sync downloads only new covers.
public struct SpotifySource: CoverSource {
    public enum Kind: Equatable, Sendable {
        case savedAlbums, topArtists, artist(String), playlist(String)

        /// From `Profile.source` (already validated by `Config`).
        public init?(source: String) {
            let parts = source.split(separator: ":").map(String.init)
            switch (parts.first, parts.dropFirst().first, parts.count) {
            case ("spotify", "saved-albums", 2): self = .savedAlbums
            case ("spotify", "top-artists", 2): self = .topArtists
            case ("spotify", "artist", 3): self = .artist(parts[2])
            case ("spotify", "playlist", 3): self = .playlist(parts[2])
            default: return nil
            }
        }
    }

    public let kind: Kind
    let api: SpotifyAPI
    public var policy: SourcePolicy { .spotify }
    public var maxConcurrentReads: Int { 6 }

    public init(_ kind: Kind, api: SpotifyAPI) {
        (self.kind, self.api) = (kind, api)
    }

    struct Image: Decodable { var url: String?; var width: Int? }
    struct Album: Decodable { var images: [Image]? }

    public func items() async throws -> [CoverItem] {
        var albums: [Album] = []
        switch kind {
        case .savedAlbums:
            struct Saved: Decodable { var album: Album }
            albums = try await api.pages("me/albums?limit=50", of: Saved.self).map(\.album)
        case .topArtists:
            struct Artist: Decodable { var id: String }
            // First page of each: bounded quota cost (§4.7 corrections).
            for artist in try await api.pages("me/top/artists?limit=50", all: false, of: Artist.self) {
                albums += try await api.pages("artists/\(artist.id)/albums?include_groups=album&limit=10", all: false, of: Album.self)
            }
        case .artist(let id):
            albums = try await api.pages("artists/\(id)/albums?include_groups=album&limit=10", of: Album.self)
        case .playlist(let id):
            struct Entry: Decodable {
                struct Item: Decodable { var type: String?; var album: Album? }
                var is_local: Bool?
                var item: Item
            }
            do {
                albums = try await api.pages("playlists/\(id)/items?limit=50&additional_types=track", of: Entry.self)
                    .filter { $0.is_local != true && $0.item.type == "track" }.compactMap(\.item.album)
            } catch SpotifyError.forbidden {
                throw SpotifyError.playlistNotYours
            } catch SpotifyError.http(404) {
                throw SpotifyError.playlistNotFound
            }
        }
        // Largest image (docs: widest first; checked anyway), each cover once, in Spotify's order.
        var seen = Set<String>()
        let urls = albums.compactMap { album in
            (album.images ?? []).max { ($0.width ?? 0) < ($1.width ?? 0) }?.url
        }.filter { seen.insert($0).inserted }
        guard !urls.isEmpty else { throw SpotifyError.noCovers }
        return urls.map { CoverItem(source: $0, mtime: 0) }
    }

    /// Images are public CDN URLs: no token sent.
    public func data(for item: CoverItem) async throws -> Data? {
        guard let url = URL(string: item.source) else { throw UnreadableCover() }
        let (data, response) = try await api.http.send(URLRequest(url: url))
        switch response.statusCode {
        case 200: return data
        case 404, 410: throw UnreadableCover()
        default: throw SpotifyError.http(response.statusCode)
        }
    }
}

/// `coverwall add <name> spotify:…` and the Store's source factory.
public enum SpotifySources {
    /// The source to store, and what an artist name matched (printed so the user can check it).
    public static func resolve(_ kind: String, _ argument: String?, api: SpotifyAPI) async throws -> (source: String, match: String?) {
        switch kind {
        case "spotify:saved-albums", "spotify:top-artists":
            guard argument == nil else { throw SpotifyError.unexpectedArgument(kind) }
            return (kind, nil)
        case "spotify:artist":
            guard let name = argument, !name.isEmpty else { throw SpotifyError.missingArgument(kind) }
            struct Found: Decodable { struct Artists: Decodable { var items: [Lenient<Artist>]? }; var artists: Artists? }
            struct Artist: Decodable { var id: String; var name: String? }
            var query = URLComponents()
            query.queryItems = [.init(name: "q", value: name), .init(name: "type", value: "artist"), .init(name: "limit", value: "1")]
            // URLComponents leaves '+' alone, which the server would read as a space.
            let data = try await api.get("search?" + (query.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B"))
            let found = try? JSONDecoder().decode(Found.self, from: data)
            guard let artist = found?.artists?.items?.compactMap(\.value).first else { throw SpotifyError.artistNotFound(name) }
            return ("spotify:artist:\(artist.id)", artist.name ?? name)
        case "spotify:playlist":
            guard let link = argument, !link.isEmpty else { throw SpotifyError.missingArgument(kind) }
            let id = link.components(separatedBy: "playlist/").dropFirst().first.map { String($0.prefix { $0 != "?" && $0 != "#" && $0 != "/" }) }
                ?? (link.hasPrefix("spotify:playlist:") ? String(link.dropFirst("spotify:playlist:".count)) : link)
            guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw SpotifyError.badPlaylistLink(link) }
            return ("spotify:playlist:\(id)", nil)
        default:
            guard SpotifySource.Kind(source: kind) != nil else { throw SpotifyError.unknownSource(kind) }
            return (kind, nil)  // already resolved, e.g. spotify:artist:<id>
        }
    }

    /// Folders as before; `spotify:` profiles get a `SpotifySource` logged in as the stored account (created only then).
    public static func factory(trace: SpotifyAPI.Trace? = nil) -> Store.SourceFactory {
        { profile in
            guard let kind = SpotifySource.Kind(source: profile.source) else { return LocalFolderSource(folder: profile.source) }
            return SpotifySource(kind, api: try SpotifyAccount().api(trace: trace))
        }
    }
}
