/// Spotify failures as our own messages with the likely cause and the next step (PLAN.md §4.7).
public enum SpotifyError: Error, Equatable, CustomStringConvertible {
    case stateMismatch
    case accessDenied
    case authorizationFailed(String)
    case loginTimedOut
    case invalidClientID
    case noClientID
    case forbidden
    case playlistNotYours
    case playlistNotFound
    case unexpectedArgument(String)
    case noCovers
    case quotaExceeded
    case unknownSource(String)
    case missingArgument(String)
    case badPlaylistLink(String)
    case artistNotFound(String)
    case rateLimited(retryAfter: Int?)
    case notLoggedIn
    case loginExpired
    case unknownClient
    case offline
    case http(Int)
    case unexpectedReply

    public var description: String {
        switch self {
        case .stateMismatch: "the browser's reply didn't match this login (stale tab?) — run `coverwall spotify login` again"
        case .accessDenied: "you declined access in the browser — run `coverwall spotify login` again to allow it"
        case .authorizationFailed(let reason): "Spotify refused the login (\(reason)) — run `coverwall spotify login` again"
        case .loginTimedOut: "no reply from the browser within 2 minutes. If Spotify showed \"Invalid redirect URI\", add exactly http://127.0.0.1/callback (no port) to your app in the developer dashboard, then run `coverwall spotify login` again"
        case .invalidClientID: "that doesn't look like a Client ID (32 characters, 0-9 and a-f) — copy it from your app's Settings in the Spotify developer dashboard"
        case .noClientID: "no Spotify Client ID yet — run `coverwall spotify setup` first"
        case .forbidden: "Spotify refused the request. Likely: (1) the app owner has no Premium (Development Mode needs it), (2) this account isn't on the app's User Management list, (3) the endpoint isn't available in Development Mode. Existing covers are kept"
        case .playlistNotYours: "Spotify refused this playlist. Likely: (1) it isn't yours — Spotify only shares playlists you own or collaborate on, so copy it into one of your own, (2) the app owner has no Premium, (3) this account isn't on the app's User Management list"
        case .playlistNotFound: "Spotify can't find this playlist (deleted or private?) — check the link, then `coverwall remove` the profile or add it again"
        case .unexpectedArgument(let source): "\(source) takes no extra argument — use: coverwall add <name> \(source)"
        case .noCovers: "Spotify returned no covers for this source — existing covers are kept; check the source with `coverwall list`"
        case .quotaExceeded: "this Spotify app's quota is used up for now — try again later (tomorrow at the latest); existing covers are kept"
        case .unknownSource(let source): "unknown source '\(source)' — use spotify:saved-albums, spotify:top-artists, spotify:artist \"<name>\" or spotify:playlist <link>"
        case .missingArgument(let source): source == "spotify:artist" ? "say which artist: coverwall add <name> spotify:artist \"Mac Miller\"" : "add the playlist link: coverwall add <name> spotify:playlist https://open.spotify.com/playlist/…"
        case .badPlaylistLink(let link): "'\(link)' isn't a Spotify playlist link — copy it via Share → Copy link to playlist"
        case .artistNotFound(let name): "Spotify found no artist named '\(name)' — check the spelling"
        case .rateLimited(let seconds): "Spotify's rate limit or quota is used up — try again " + (seconds.map { "in \($0) s" } ?? "later")
        case .notLoggedIn: "not logged in to Spotify — run `coverwall spotify login`"
        case .loginExpired: "your Spotify login expired or was revoked — run `coverwall spotify login`"
        case .unknownClient: "Spotify doesn't recognise the Client ID — check it in the developer dashboard and run `coverwall spotify setup`"
        case .offline: "can't reach Spotify (offline, DNS or Spotify down) — try again later; existing covers are kept"
        case .http(let status): "Spotify answered HTTP \(status) — try again later; existing covers are kept"
        case .unexpectedReply: "Spotify sent a reply coverwall doesn't understand — try again later, or update coverwall"
        }
    }
}
