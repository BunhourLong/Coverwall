#!/bin/sh
# Phase 0 spike: put one test image + config.json where the saver looks.
#   spike/seed.sh [container|shared|both] [image]
# container = legacyScreenSaver container's Application Support (default), shared = /Users/Shared.
set -eu

where=${1:-container}
image=${2:-"/System/Library/Desktop Pictures/Mac Blue.heic"}
container="$HOME/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Coverwall"
shared="/Users/Shared/Coverwall"

seed() {
  mkdir -p "$1"
  sips -s format jpeg -Z 1024 "$image" --out "$1/test.jpg" >/dev/null
  printf '{ "version": 1, "image": "test.jpg" }\n' > "$1/config.json"
  echo "seeded $1"
  ls -l "$1"
}

case $where in
  container) seed "$container" ;;
  shared)    seed "$shared" ;;
  both)      seed "$container"; seed "$shared" ;;
  *) echo "usage: $0 [container|shared|both] [image]" >&2; exit 2 ;;
esac
