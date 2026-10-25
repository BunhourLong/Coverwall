# Kit + CLI via SwiftPM; saver + HostApp built with plain swiftc (no Xcode project).
SAVER   := build/Coverwall.saver
HOST    := build/CoverwallHost
# CLI -> $(PREFIX)/bin, saver -> $(PREFIX)/share/coverwall (same layout as the Homebrew formula).
PREFIX  ?= $(HOME)/.local
# Only the Kit files the saver may use (CLAUDE.md constraint 8): no Store/TileCache, no networking.
KIT     := $(addprefix Sources/CoverwallKit/,Config.swift Paths.swift GridLayout.swift ShuffleBag.swift \
             CacheManifest.swift SaverActivity.swift SaverContent.swift)
SOURCES := $(wildcard Saver/*.swift) $(KIT)
# Spotify's official logos, unmodified (attribution for Spotify profiles, PLAN.md 7.4).
RESOURCES := $(wildcard Saver/Resources/*)

.PHONY: build kit test install uninstall reload host clean

build: kit $(SAVER) $(HOST)

kit:
	swift build

test:
	swift test
	# Release too: Homebrew ships it, and a release-only TaskGroup miscompile once hung `add` (Phase 7.3).
	swift test -c release

$(SAVER): $(SOURCES) $(RESOURCES) Saver/Info.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources
	cp Saver/Info.plist $@/Contents/Info.plist
	cp $(RESOURCES) $@/Contents/Resources/
	for arch in arm64 x86_64; do \
	  xcrun swiftc -swift-version 5 -O -parse-as-library -module-name Coverwall -target $$arch-apple-macos14.6 \
	    -emit-executable -Xlinker -bundle -o build/Coverwall-$$arch $(SOURCES) || exit 1; \
	done
	lipo -create build/Coverwall-arm64 build/Coverwall-x86_64 -output $@/Contents/MacOS/Coverwall
	codesign --force --sign - $@

$(HOST): $(SOURCES) $(RESOURCES) HostApp/HostApp.swift
	mkdir -p build
	cp $(RESOURCES) build/  # a bare executable's Bundle.main resources are its own folder
	xcrun swiftc -swift-version 5 -parse-as-library -module-name CoverwallHost -target $$(uname -m)-apple-macos14.6 \
	  -o $@ $(SOURCES) HostApp/HostApp.swift

host: $(HOST)
	./$(HOST) $(ARGS)

install: build
	swift build -c release
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/share/coverwall"
	cp "$$(swift build -c release --show-bin-path)/coverwall" "$(PREFIX)/bin/"
	rm -rf "$(PREFIX)/share/coverwall/Coverwall.saver"
	cp -R $(SAVER) "$(PREFIX)/share/coverwall/"
	"$(PREFIX)/bin/coverwall" install
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; *) echo "note: $(PREFIX)/bin is not on your PATH — add it to use \`coverwall\`";; esac

uninstall:
	-"$(PREFIX)/bin/coverwall" uninstall
	rm -rf "$(PREFIX)/bin/coverwall" "$(PREFIX)/share/coverwall"

reload:
	-killall legacyScreenSaver

clean:
	rm -rf build
