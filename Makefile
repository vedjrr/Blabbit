# Utter build entry points. See docs/ARCHITECTURE.md ADR-001 for why this is
# SwiftPM + Makefile rather than an .xcodeproj.

SHELL := /bin/bash
export PATH := $(HOME)/.cargo/bin:$(PATH)
# Must match LSMinimumSystemVersion and Package.swift platforms.
export MACOSX_DEPLOYMENT_TARGET := 14.0

ROOT      := $(CURDIR)
CORE      := $(ROOT)/core
APP       := $(ROOT)/app
BUILD     := $(ROOT)/build
RUST_OUT  := $(CORE)/target/release
BINDINGS  := $(BUILD)/bindings
APP_NAME  := Utter
BUNDLE    := $(BUILD)/$(APP_NAME).app
SWIFT_OUT = $(shell cd "$(APP)" && swift build -c release --arch arm64 --show-bin-path)

.PHONY: build core bindings app bundle test test-rust test-swift clean

build: bundle

core:
	cd "$(CORE)" && cargo build --release --workspace

bindings: core
	cd "$(CORE)" && ./target/release/uniffi-bindgen generate \
		--library target/release/libutter_ffi.a --language swift --out-dir "$(BINDINGS)"
	install -m 644 "$(BINDINGS)/UtterFFI.h" "$(APP)/Sources/UtterFFI/include/UtterFFI.h"
	install -m 644 "$(BINDINGS)/UtterFFI.modulemap" "$(APP)/Sources/UtterFFI/include/module.modulemap"
	install -m 644 "$(BINDINGS)/UtterCore.swift" "$(APP)/Sources/UtterCore/UtterCore.swift"

app: bindings
	cd "$(APP)" && swift build -c release --arch arm64

bundle: app
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	install -m 755 "$(SWIFT_OUT)/$(APP_NAME)" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	install -m 644 "$(APP)/Resources/Info.plist" "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign "$${UTTER_SIGN_IDENTITY:--}" --options runtime \
		--entitlements "$(APP)/Resources/Utter.entitlements" "$(BUNDLE)"
	@echo "Built $(BUNDLE)"

test: test-rust test-swift

test-rust:
	cd "$(CORE)" && cargo test --release --workspace

test-swift: bindings
	cd "$(APP)" && swift test -c release --arch arm64

clean:
	cd "$(CORE)" && cargo clean
	rm -rf "$(APP)/.build" "$(BUILD)"
