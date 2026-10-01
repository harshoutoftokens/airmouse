DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
SWIFT = DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun swift

# Detect persistent code signing identity:
# 1. Look for Apple Development / Mac Developer / Developer ID certificate
# 2. Look for local self-signed "AirTrackpad Development" cert
# 3. Fallback to any valid codesigning cert in keychain
# 4. Fallback to ad-hoc (-) with warning
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -E "Apple Development|Developer ID Application|Mac Developer" | head -n 1 | sed 's/.*"\(.*\)".*/\1/')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep "AirTrackpad Development" | head -n 1 | sed 's/.*"\(.*\)".*/\1/')
endif
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep ')' | head -n 1 | sed 's/.*"\(.*\)".*/\1/')
endif
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := -
endif

.PHONY: all build test bundle run clean setup-cert

all: build

build:
	$(SWIFT) build

test:
	$(SWIFT) test

setup-cert:
	@./scripts/setup_dev_cert.sh

bundle: build
	@killall AirTrackpad 2>/dev/null || true
	@mkdir -p AirTrackpad.app/Contents/MacOS
	@mkdir -p AirTrackpad.app/Contents/Resources
	@cp .build/arm64-apple-macosx/debug/AirTrackpad AirTrackpad.app/Contents/MacOS/AirTrackpad 2>/dev/null || \
	 cp .build/debug/AirTrackpad AirTrackpad.app/Contents/MacOS/AirTrackpad 2>/dev/null || \
	 cp .build/out/Products/Debug/AirTrackpad AirTrackpad.app/Contents/MacOS/AirTrackpad
	@cp Info.plist AirTrackpad.app/Contents/Info.plist
	@if [ "$(SIGN_IDENTITY)" != "-" ]; then \
		echo "Signing AirTrackpad.app with persistent identity: [$(SIGN_IDENTITY)]"; \
		codesign --force --deep --sign "$(SIGN_IDENTITY)" --entitlements AirTrackpad.entitlements --timestamp=none AirTrackpad.app; \
	else \
		echo "⚠️ WARNING: No code signing certificate found in keychain. Falling back to ad-hoc signing (-)."; \
		echo "⚠️ NOTE: macOS TCC invalidates Accessibility permissions on rebuild with ad-hoc signing."; \
		echo "👉 Run 'make setup-cert' to install a persistent local development certificate."; \
		codesign --force --deep --sign - --entitlements AirTrackpad.entitlements AirTrackpad.app; \
	fi
	@echo "AirTrackpad.app created successfully."

run: bundle
	@sleep 0.5
	open AirTrackpad.app

clean:
	$(SWIFT) package clean
	rm -rf AirTrackpad.app
