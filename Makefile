# Phase 0: saver only, built with plain swiftc (no Xcode project). Kit/CLI/HostApp come later.
SAVER   := build/Coverwall.saver
SOURCES := $(wildcard Saver/*.swift)

.PHONY: build install reload clean

build: $(SAVER)

$(SAVER): $(SOURCES) Saver/Info.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS
	cp Saver/Info.plist $@/Contents/Info.plist
	for arch in arm64 x86_64; do \
	  xcrun swiftc -swift-version 5 -O -parse-as-library -module-name Coverwall -target $$arch-apple-macos14.6 \
	    -emit-executable -Xlinker -bundle -o build/Coverwall-$$arch $(SOURCES) || exit 1; \
	done
	lipo -create build/Coverwall-arm64 build/Coverwall-x86_64 -output $@/Contents/MacOS/Coverwall
	codesign --force --sign - $@

install: build
	mkdir -p "$(HOME)/Library/Screen Savers"
	rm -rf "$(HOME)/Library/Screen Savers/Coverwall.saver"
	cp -R $(SAVER) "$(HOME)/Library/Screen Savers/"

reload:
	-killall legacyScreenSaver

clean:
	rm -rf build
