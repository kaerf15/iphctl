.PHONY: all build test
.DELETE_ON_ERROR:

SOURCES := $(wildcard Sources/*.swift)

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

