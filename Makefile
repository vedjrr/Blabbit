# Utter build entry points. See docs/ARCHITECTURE.md ADR-001 for why this is
# SwiftPM + Makefile rather than an .xcodeproj.

SHELL := /bin/bash
export PATH := $(HOME)/.cargo/bin:$(PATH)
# The macOS deployment target (14.0) is set for cargo in core/.cargo/config.toml
# and for Swift in app/Package.swift. Do not export MACOSX_DEPLOYMENT_TARGET here:
# with Command Line Tools it stops Swift Testing's macro plugin from loading.

ROOT      := $(CURDIR)
CORE      := $(ROOT)/core
APP       := $(ROOT)/app
BUILD     := $(ROOT)/build
RUST_OUT  := $(CORE)/target/release
BINDINGS  := $(BUILD)/bindings
APP_NAME  := Utter
BUNDLE    := $(BUILD)/$(APP_NAME).app
# SwiftPM's default "swiftbuild" backend intermittently fails under the CLT
# ("plugin for module 'TestingMacros' not found", "unable to resolve Swift module
# dependency"); the native backend is reliable here (ADR-001).
SWIFT_FLAGS := -c release --arch arm64 --build-system native
CLT_TESTING := /Library/Developer/CommandLineTools/Library/Developer
SWIFT_TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT_TESTING)/Frameworks -Xlinker -F -Xlinker $(CLT_TESTING)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_TESTING)/Frameworks -Xlinker -rpath -Xlinker $(CLT_TESTING)/usr/lib
SWIFT_OUT = $(shell cd "$(APP)" && swift build $(SWIFT_FLAGS) --show-bin-path)

# Dev signing: a local "Apple Development" identity keeps the designated
# requirement stable so macOS privacy grants survive rebuilds; else ad-hoc.
SIGN_ID ?= $(or $(UTTER_SIGN_IDENTITY),$(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"'),-)

.PHONY: build core bindings app bundle test test-rust test-swift bench models dmg dmg-preflight clean

build: bundle

core:
	cd "$(CORE)" && cargo build --release --workspace

bindings: core
	cd "$(CORE)" && ./target/release/uniffi-bindgen generate \
		--library target/release/libutter_ffi.a --language swift --out-dir "$(BINDINGS)"
	mkdir -p "$(APP)/Sources/UtterFFI/include" "$(APP)/Sources/UtterCore"
	install -m 644 "$(BINDINGS)/UtterFFI.h" "$(APP)/Sources/UtterFFI/include/UtterFFI.h"
	install -m 644 "$(BINDINGS)/UtterFFI.modulemap" "$(APP)/Sources/UtterFFI/include/module.modulemap"
	install -m 644 "$(BINDINGS)/UtterCore.swift" "$(APP)/Sources/UtterCore/UtterCore.swift"

app: bindings
	cd "$(APP)" && swift build $(SWIFT_FLAGS)

bundle: app
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	install -m 755 "$(SWIFT_OUT)/$(APP_NAME)" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	install -m 644 "$(APP)/Resources/Info.plist" "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_ID)" --options runtime \
		--entitlements "$(APP)/Resources/Utter.entitlements" "$(BUNDLE)"
	@echo "Built $(BUNDLE)"

test: test-rust test-swift

test-rust: models
	cd "$(CORE)" && cargo test --release --workspace

test-swift: bindings
	cd "$(APP)" && UTTER_LOG_FILE="$${TMPDIR:-/tmp}/utter-tests.log" swift test $(SWIFT_FLAGS) $(SWIFT_TEST_FLAGS)

bench: build
	cd "$(APP)" && swift build $(SWIFT_FLAGS) --product utter-bench
	cd "$(APP)" && swift build $(SWIFT_FLAGS) --product UtterAXHost
	"$(APP)/.build/arm64-apple-macosx/release/utter-bench"

models:
	./scripts/fetch-models.sh

# Fail fast on missing release credentials before the rebuild.
dmg-preflight:
	@test -n "$$UTTER_DEVELOPER_ID" || { echo "Cannot make a release DMG: set UTTER_DEVELOPER_ID to your 'Developer ID Application: …' signing identity." >&2; exit 2; }
	@test -n "$$UTTER_NOTARY_PROFILE" || { echo "Cannot notarise: set UTTER_NOTARY_PROFILE to a profile created with 'xcrun notarytool store-credentials'." >&2; exit 2; }

dmg: dmg-preflight bundle
	./scripts/make-dmg.sh

clean:
	cd "$(CORE)" && cargo clean
	rm -rf "$(APP)/.build" "$(BUILD)"
