# Striple build commands. Works with the Command Line Tools only (no Xcode needed).

TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
SWIFT_TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)

.PHONY: build test bench release app install run clean

build:
	swift build

test:
	swift test $(SWIFT_TEST_FLAGS)

# Performance budgets from docs/SPEC.md, measured in an optimized build.
bench:
	swift test -c release -Xswiftc -enable-testing $(SWIFT_TEST_FLAGS) --filter 'Benchmark'

release:
	swift build -c release

# Builds dist/Striple.app (signed ad hoc unless SIGN_IDENTITY is set).
app:
	./scripts/build-app.sh

# Copies the app to /Applications and links the CLI to ~/.local/bin/striple.
install: app
	./scripts/install.sh

run: app
	open dist/Striple.app

clean:
	rm -rf .build dist
