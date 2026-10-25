# Coverwall

A macOS screen saver that fills your screen with a shifting grid of album covers — from a
**folder on your Mac**, not a streaming service.

Point it at any folder of cover art, pick a grid size, and Coverwall shuffles the images across
the screen, flipping or fading tiles one at a time. Inspired by [MusaicFM](https://github.com/obrhoff/MusaicFM),
but offline and fully under your control from the terminal.

> **Status:** v0.1 — install with Homebrew or from source.

## How it works

Coverwall has two parts:

- **`coverwall` (CLI)** — the control surface. It manages *profiles* (a name pointing at a
  folder), grid size, timing and transitions. When you add or sync a profile, it scans the folder,
  removes duplicates, crops each image to a square, downsizes it and writes it into a cache.
- **`Coverwall.saver`** — a lightweight renderer. It reads the cache and `config.json` and draws
  the grid. It never touches your own folders.

```
~/Pictures/Covers/*.jpg|png|heic|webp
        │   read by the CLI only
        ▼
coverwall ──► dedupe → square crop → resize → JPEG
        │
        ▼
<data dir>/config.json + profiles/<name>/tiles/*.jpg
        │   read-only
        ▼
Coverwall.saver ──► grid of tiles, swapped on a timer
```

The split exists because macOS runs screen savers inside a sandbox (`legacyScreenSaver`) that
can't reliably read `~/Documents`, `~/Music` and so on. The CLI runs with your Terminal's
permissions and copies what the saver needs into the saver's own container:

```
~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Coverwall/
```

## Features

- **Any local folder** of jpg, jpeg, png, heic, webp or tiff images. Unreadable files are skipped and reported.
- **Or your music folder.** Cover art embedded in mp3, m4a and flac files is used too, one tile per album
  (tracks sharing a cover are deduplicated). Tracks without art are ignored.
- **Any grid** from `1x1` to `16x16`. Whole tiles fill the screen edge to edge; each cover fills its
  tile (center-cropped). Give only `--columns` and the rows fit each screen. `1x1` is a single cover.
- **Hero tiles.** `--heroes 3` mixes in up to three 2×2 covers, placed where they fit without touching,
  like the old iTunes saver. Their positions change at every start. The cache then stores hero-size tiles so
  they stay sharp; `--heroes 0` turns them off.
- **Smart shuffling.** With more images than tiles (say 100 images on a 7×5 grid), no cover
  appears twice on screen. Tiles that just changed aren't picked again right away.
- **Flip or fade** transitions, identical on every tile. Reduce Motion always fades.
- **Multiple profiles**, switched with one command.
- **Multi-display aware** — each screen gets its own shuffle and is decoded at its own resolution.
- **Cold when idle** — no timers or decoded images unless the saver is actually on screen.
- **Calm by default** — a missing or empty profile shows a dark screen with a one-line hint, never a crash.
- **Offline.** No network, no telemetry.

## Requirements

- macOS 14.6 or later (Apple Silicon or Intel)
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

## Install

With Homebrew (builds from source, a minute or so):

```sh
brew install bunhourlong/tap/coverwall
coverwall install
```

Homebrew can't write to `~/Library`, so `coverwall install` copies the saver into
`~/Library/Screen Savers`. Run it again after every `brew upgrade coverwall`, and run
`coverwall uninstall` before `brew uninstall coverwall`.

From source:

```sh
git clone https://github.com/BunhourLong/Coverwall.git
cd Coverwall
make install
```

This builds everything, puts `coverwall` in `~/.local/bin` and the saver bundle in
`~/.local/share/coverwall`, then runs `coverwall install`, which copies `Coverwall.saver` into
`~/Library/Screen Savers` and restarts the screen saver host. Install somewhere else with
`make install PREFIX=/usr/local`. If `make` says the `bin` folder isn't on your `PATH`, add it.

Locally built bundles aren't quarantined, so no Gatekeeper workarounds are needed.

## First run

```sh
coverwall add macmiller ~/Documents/MacMiller --grid 7x5
# macmiller: 100 images (3 skipped, 2 duplicates) → 7x5 grid, 35 visible

coverwall settings    # pick Coverwall (under "Other")
coverwall preview     # start the screen saver now
```

`coverwall settings` opens **System Settings → Wallpaper** on macOS 26 (the screen saver picker
moved there) and **System Settings → Screen Saver** on macOS 14–15. The first profile you add
becomes the active one.

## Commands

| Command | What it does |
|---|---|
| `coverwall add <name> <folder> [--grid CxR \| --columns C] [--interval s] [--transition flip\|fade] [--heroes N] [--tile-max px]` | Create a profile and build its cache |
| `coverwall use <name>` | Set the active profile — shows the next time the saver starts |
| `coverwall set [<name>] [--grid ...] [--columns ...] [--interval ...] [--transition ...] [--heroes N] [--tile-max ...]` | Change a profile's settings (default: the active one) |
| `coverwall sync [<name>]` | Re-scan the folder after you add, change or delete covers |
| `coverwall list` | List profiles; `*` marks the active one |
| `coverwall remove <name>` | Delete a profile and its cache (your folder is untouched) |
| `coverwall install` / `uninstall` | Add or remove `Coverwall.saver` in `~/Library/Screen Savers` |
| `coverwall preview` | Start the screen saver now |
| `coverwall settings` | Open the screen saver settings |
| `coverwall reload` | Restart `legacyScreenSaver` so macOS loads the newest bundle |
| `coverwall doctor` | Check install, data dir, config, caches and stray processes |
| `coverwall add <name> spotify:saved-albums \| spotify:top-artists \| spotify:artist "<name>" \| spotify:playlist <link>` | A profile from your Spotify library (after `coverwall spotify setup` + `login`); `sync` refreshes it |
| `coverwall spotify setup` / `login` / `logout [--all]` / `status [--json]` | Connect your own Spotify app (the app owner needs Premium). See [PRIVACY.md](PRIVACY.md) |

`add`, `sync`, `list` and `doctor` take `--json` for scripting. Every command exits non-zero on
error, and the error says what to do next. `coverwall help <command>` shows all options.

### Configuration

Profiles live in a versioned `config.json` in the data dir. The CLI manages it, but it's plain JSON:

```json
{
  "version": 1,
  "activeProfile": "macmiller",
  "profiles": {
    "macmiller": {
      "source": "/Users/you/Documents/MacMiller",
      "grid": { "columns": 7, "rows": 5 },
      "intervalSeconds": 4,
      "swapsPerTick": 1,
      "transition": "flip",
      "tileMaxPixels": 1024,
      "background": "#000000",
      "gapPoints": 0
    }
  }
}
```

## Troubleshooting

Start with `coverwall doctor`: every ✗ line says how to fix it.

| Symptom | Fix |
|---|---|
| Coverwall isn't in the screen saver list | `coverwall install`, then quit and reopen System Settings |
| Apple's default saver shows instead of Coverwall | macOS sometimes drops the selection after a reload — pick Coverwall again (`coverwall settings`) |
| Old profile or settings still showing | `coverwall reload` |
| Dark screen saying "no profile" | `coverwall add <name> <folder>` or `coverwall use <name>` |
| New covers in the folder don't show | `coverwall sync` |
| `doctor` reports several `legacyScreenSaver` processes | `coverwall reload` |

## Uninstall

```sh
coverwall uninstall   # removes the saver; profiles and cache stay
make uninstall        # (in the source folder) also removes coverwall from ~/.local
```

To delete profiles and cached covers too, remove the data dir shown above.

## Development

```sh
make build    # Kit + CLI + Coverwall.saver + dev host app, into build/
make test     # swift test
make host     # run the saver in a normal window for fast iteration
make install  # as above
make reload   # killall legacyScreenSaver
make clean    # remove build/
```

```
Sources/CoverwallKit/   shared, pure Swift: config, grid math, shuffling, paths, cache, install
Sources/coverwall/      CLI (Swift Argument Parser)
Saver/                  CoverwallView (ScreenSaverView) + Info.plist
HostApp/                dev-only app that shows the saver in a normal window
Tests/CoverwallKitTests/
```

## Not in scope (v1)

- Last.fm or Apple Music integration — use MusaicFM for that. (An optional, CLI-side Spotify
  source may come later; the saver stays offline either way.)
- A GUI preferences app. The terminal is the interface.
- Selecting Coverwall as the active screen saver automatically. `coverwall settings` opens the pane instead.

## Roadmap

1. ~~Platform spike~~, ~~`CoverwallKit`~~, ~~CLI + cache pipeline~~, ~~saver renderer + dev host app~~, ~~install flow~~
2. ~~Homebrew tap~~ (`brew install bunhourlong/tap/coverwall && coverwall install`)
3. Later: cover art pulled from audio files, hero tiles

## License

MIT — see [LICENSE](LICENSE).

The Spotify logos in `Saver/Resources/` are Spotify's trademarks, bundled unmodified from
[Spotify's design guidelines](https://developer.spotify.com/documentation/design) to attribute covers from Spotify.
They are not covered by the MIT license.
