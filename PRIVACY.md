# Privacy

Coverwall has no telemetry, analytics or crash reporting. Nothing leaves your Mac except the Spotify calls
described below, and only if you connect Spotify.

## What is stored, and where

| What | Where |
|---|---|
| Profiles and settings (`config.json`) | `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Coverwall/` |
| Downsized copies of your covers | `profiles/<name>/tiles/` in that same folder. Your own folders are only read, never changed. |
| Spotify Client ID and login tokens (optional) | Your login keychain, item `com.bunhourlong.Coverwall` (accounts `client-id` and `tokens`), written through `/usr/bin/security` with the value on stdin. If `/usr/bin/security` is missing: `~/Library/Application Support/coverwall/secrets.json`, readable only by you (0600). |
| Covers from Spotify (optional) | The profile's `tiles/` folder, only until they expire: 72 hours after the last sync. Expired covers are never shown and are deleted at the next `coverwall` run. |

Tokens never go into `config.json`, the cover cache, command-line arguments or logs.

Spotify access asked for at login, read-only: `user-library-read` (saved albums), `user-top-read` (top artists),
`playlist-read-private` and `playlist-read-collaborative` (your playlists).

## Network

- The screen saver never makes a network call.
- The `coverwall` command talks to Spotify only during `coverwall spotify …` commands and syncs of Spotify
  profiles: `accounts.spotify.com` (login, token refresh), `api.spotify.com` (your library) and `i.scdn.co`
  (cover images). Logging in opens a listener on `127.0.0.1` only, which closes after the browser's reply or
  2 minutes.
- Folder profiles never touch the network.

## Removing everything

1. `coverwall spotify logout --all` deletes the tokens and Client ID from this Mac.
2. On your Spotify account page: Manage apps → Remove access. Spotify has no way for apps to do this for you.
3. `coverwall uninstall`, then delete the data folder above.
