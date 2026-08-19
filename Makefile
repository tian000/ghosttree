SWIFT_CACHE := $(CURDIR)/.build/swift-cache
SWIFT_CONFIG := $(CURDIR)/.build/swift-config
SWIFT_SECURITY := $(CURDIR)/.build/swift-security
SWIFT_SCRATCH := $(CURDIR)/.build/swift
MODULE_CACHE := $(CURDIR)/.build/swift-module-cache
CLANG_CACHE := $(CURDIR)/.build/clang
PREFIX ?= /usr/local

.PHONY: build run test app install-cli clean

build:
	CLANG_MODULE_CACHE_PATH=$(CLANG_CACHE) SWIFTPM_MODULECACHE_OVERRIDE=$(MODULE_CACHE) swift build --disable-sandbox --cache-path $(SWIFT_CACHE) --config-path $(SWIFT_CONFIG) --security-path $(SWIFT_SECURITY) --scratch-path $(SWIFT_SCRATCH)

run:
	CLANG_MODULE_CACHE_PATH=$(CLANG_CACHE) SWIFTPM_MODULECACHE_OVERRIDE=$(MODULE_CACHE) swift run --disable-sandbox --cache-path $(SWIFT_CACHE) --config-path $(SWIFT_CONFIG) --security-path $(SWIFT_SECURITY) --scratch-path $(SWIFT_SCRATCH) ghosttree $(ARGS)

test:
	CLANG_MODULE_CACHE_PATH=$(CLANG_CACHE) SWIFTPM_MODULECACHE_OVERRIDE=$(MODULE_CACHE) swift test --disable-sandbox --cache-path $(SWIFT_CACHE) --config-path $(SWIFT_CONFIG) --security-path $(SWIFT_SECURITY) --scratch-path $(SWIFT_SCRATCH)

app:
	xcodebuild -project Ghosttree.xcodeproj -scheme Ghosttree -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build

install-cli:
	CLANG_MODULE_CACHE_PATH=$(CLANG_CACHE) SWIFTPM_MODULECACHE_OVERRIDE=$(MODULE_CACHE) swift build -c release --disable-sandbox --cache-path $(SWIFT_CACHE) --config-path $(SWIFT_CONFIG) --security-path $(SWIFT_SECURITY) --scratch-path $(SWIFT_SCRATCH)
	install -d $(PREFIX)/bin
	install -m 0755 $$(swift build --show-bin-path -c release --scratch-path $(SWIFT_SCRATCH))/ghosttree $(PREFIX)/bin/ghosttree

clean:
	swift package clean
