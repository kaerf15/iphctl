.PHONY: all build test package test-package
.DELETE_ON_ERROR:

SOURCES := $(wildcard Sources/*.swift)
VERSION := $(shell node -p "require('./package.json').version" 2>/dev/null)

all: test
	@cp .build/iphctl .build/iphctl-install
	@mv .build/iphctl-install iphctl

build: .build/iphctl

.build/iphctl: $(SOURCES)
	@mkdir -p .build
	xcrun swiftc -O $(SOURCES) -o $@ -framework AppKit -framework CoreGraphics -framework ImageIO
	codesign --force --sign - $@
	codesign --verify --strict $@

test: build .build/control-tests
	.build/control-tests
	python3 tests/test_cli.py .build/iphctl

.build/control-tests: Sources/Models.swift Sources/Control.swift tests/ControlTests.swift
	@mkdir -p .build
	xcrun swiftc Sources/Models.swift Sources/Control.swift tests/ControlTests.swift -o $@ -framework CoreGraphics

.build/release/iphctl-arm64: $(SOURCES) Makefile
	@mkdir -p .build/release
	xcrun swiftc -O -target arm64-apple-macosx15.0 $(SOURCES) -o $@ -framework AppKit -framework CoreGraphics -framework ImageIO

.build/release/iphctl-x86_64: $(SOURCES) Makefile
	@mkdir -p .build/release
	xcrun swiftc -O -target x86_64-apple-macosx15.0 $(SOURCES) -o $@ -framework AppKit -framework CoreGraphics -framework ImageIO

.build/release/iphctl: .build/release/iphctl-arm64 .build/release/iphctl-x86_64
	xcrun lipo -create $^ -output $@
	codesign --force --sign - --identifier io.github.kaerf15.iphctl $@
	codesign --verify --strict $@

package: all .build/release/iphctl
	@mkdir -p native
	@cp .build/release/iphctl native/iphctl

test-package: package
	npm pack --ignore-scripts --pack-destination .build
	python3 tests/test_package.py .build/iphctl-$(VERSION).tgz

