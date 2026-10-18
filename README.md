# Coverwall

A macOS screen saver that fills your screen with a shifting grid of album covers — from a
**folder on your Mac**, not a streaming service.

Point it at any folder of cover art, pick a grid size, and Coverwall shuffles the images across
the screen, flipping or fading tiles one at a time. Inspired by [MusaicFM](https://github.com/obrhoff/MusaicFM),
but offline and fully under your control from the terminal.

> **Status: early development.** The screen saver spike builds and installs; the `coverwall` CLI
> is not written yet. The commands below describe the intended v1.

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

## Features (v1)

- **Any local folder** of jpg, jpeg, png, heic, webp or tiff images. Unreadable files are skipped and reported.
- **Any grid** from `1x1` to `16x16`. Tiles are always square; the grid scales to cover the
  screen and is centered, with overflow cropped. `1x1` is a single crossfading cover.
- **Smart shuffling.** With more images than tiles (say 100 images on a 7×5 grid), no cover
  appears twice on screen. Tiles that just changed aren't picked again right away.
- **Flip or fade** transitions, with configurable interval and swaps per tick.
- **Multiple profiles**, switched with one command.
- **Multi-display aware** — each screen gets its own shuffle and is decoded at its own resolution.
- **Calm by default** — a missing or empty profile shows a dark screen with a one-line hint, never a crash.
- **Offline.** No network, no telemetry.

## Requirements

- macOS 14.6 or later (Apple Silicon or Intel)
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

## Install

From source:

```sh
git clone https://github.com/BunhourLong/Coverwall.git
cd Coverwall
make install   # builds Coverwall.saver and copies it into ~/Library/Screen Savers
make reload    # makes macOS pick up the new bundle
```

Then open **System Settings → Screen Saver** and choose **Coverwall** under *Other*.

Locally built bundles aren't quarantined, so no Gatekeeper workarounds are needed.
A Homebrew tap (`brew install bunhourlong/tap/coverwall && coverwall install`) is planned.

## Usage (planned)

```sh
coverwall add macmiller ~/Documents/MacMiller --grid 7x5
# macmiller: 100 images (3 skipped, 2 duplicates) → 7x5 grid, 35 visible

coverwall use macmiller      # make it the active profile
coverwall preview            # start the screen saver now
```

| Command | What it does |
|---|---|
| `coverwall add <name> <folder> [--grid CxR \| --columns C] [--interval s] [--transition flip\|fade] [--tile-max px]` | Create a profile and build its cache |
| `coverwall use <name>` | Set the active profile |
| `coverwall set [<name>] [--grid ...] [--interval ...] [--transition ...]` | Change a profile's settings |
| `coverwall sync [<name>]` | Re-scan the source folder (incremental) |
| `coverwall list [--json]` | List profiles |
| `coverwall remove <name>` | Delete a profile and its cache |
| `coverwall install` / `uninstall` | Add or remove `Coverwall.saver` in `~/Library/Screen Savers` |
| `coverwall preview` | Start the screen saver now |
| `coverwall settings` | Open System Settings → Screen Saver |
| `coverwall reload` | Restart `legacyScreenSaver` so changes take effect |
| `coverwall doctor [--json]` | Check install, data dir, config, cache and stray processes |

Every command prints readable output by default, takes `--json` for scripting, and exits
non-zero on error.

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

## Development

```sh
make build    # build Coverwall.saver into build/
make install  # copy it into ~/Library/Screen Savers
make reload   # killall legacyScreenSaver
make clean    # remove build/
```

Project layout (target):

```
Sources/CoverwallKit/   shared, pure Swift: config, grid math, shuffling, paths, cache manifest
Sources/coverwall/      CLI (Swift Argument Parser)
Saver/                  CoverwallView (ScreenSaverView) + Info.plist
HostApp/                dev-only app that shows the saver in a normal window
Tests/CoverwallKitTests/
```

## Not in scope (v1)

- Spotify, Last.fm or Apple Music integration — use MusaicFM for that.
- A GUI preferences app. The terminal is the interface.
- Selecting Coverwall as the active screen saver automatically. `coverwall settings` opens the pane instead.

## Roadmap

1. Platform spike — saver loads images from its container, survives the Sonoma/Tahoe lifecycle *(in progress)*
2. `CoverwallKit` — config, grid layout, shuffle bag, with tests
3. `coverwall` CLI and the image cache pipeline
4. Full saver renderer, transitions, multi-display, dev host app
5. Install flow and Homebrew tap
6. Later: cover art pulled from audio files, hero tiles, Ken Burns mode
