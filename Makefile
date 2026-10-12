# Striple build commands. Works with the Command Line Tools only (no Xcode needed).

TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
SWIFT_TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)

.PHONY: build test bench release app icon dmg install uninstall run clean publish publish-dry

build:
	swift build

test:
	swift test $(SWIFT_TEST_FLAGS)

# Performance budgets from docs/SPEC.md, measured in an optimized build.
bench:
	swift test -c release -Xswiftc -enable-testing $(SWIFT_TEST_FLAGS) --filter 'Benchmark'

release:
	swift build -c release

# Builds dist/Striple.app. Signs with "Striple Local Signing" when that identity exists
# (scripts/make-signing-cert.sh), else ad hoc. SIGN_IDENTITY overrides. See docs/INSTALL.md.
app:
	./scripts/build-app.sh

# Draws the app icon into .build/icon/AppIcon.icns (make app does this when needed).
icon:
	swift scripts/make-icon.swift .build/icon

# Makes dist/Striple-<version>.dmg from dist/Striple.app.
dmg: app
	./scripts/make-dmg.sh

# Copies the app to /Applications and links the CLI to ~/.local/bin/striple.
install: app
	./scripts/install.sh

# Removes the app and the CLI link. Keeps settings and logs.
uninstall:
	./scripts/install.sh --uninstall

# Builds and checks a release in dist/release/<version>/. Uploads nothing. See docs/RELEASING.md.
publish-dry:
	./scripts/release.sh --dry-run

# Publishes VERSION to the GitHub releases repository in Packaging/updates.env.
publish:
	./scripts/release.sh

run: app
	open dist/Striple.app

clean:
	rm -rf .build dist
