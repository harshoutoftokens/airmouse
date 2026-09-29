DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
SWIFT = DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun swift

.PHONY: all build test bundle run clean

all: build

build:
	$(SWIFT) build

test:
	$(SWIFT) test

bundle: build
	@mkdir -p AirTrackpad.app/Contents/MacOS
	@mkdir -p AirTrackpad.app/Contents/Resources
	@cp .build/arm64-apple-macosx/debug/AirTrackpad AirTrackpad.app/Contents/MacOS/AirTrackpad 2>/dev/null || \
	 cp .build/debug/AirTrackpad AirTrackpad.app/Contents/MacOS/AirTrackpad 2>/dev/null || \
	 cp .build/out/Products/Debug/AirTrackpad AirTrackpad.app/Contents/MacOS/AirTrackpad
	@cp Info.plist AirTrackpad.app/Contents/Info.plist
	@codesign -s - --force --deep AirTrackpad.app 2>/dev/null || true
	@echo "AirTrackpad.app created successfully."

run: bundle
	@killall AirTrackpad 2>/dev/null || true
	@sleep 0.5
	open AirTrackpad.app

clean:
	$(SWIFT) package clean
	rm -rf AirTrackpad.app
