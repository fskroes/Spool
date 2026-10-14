# Striple build commands. Works with the Command Line Tools only (no Xcode needed).

TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
SWIFT_TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)

.PHONY: build test test-quiet test-signing bench release app icon dmg install uninstall run clean e2e publish publish-dry publish-finish

build:
	swift build

# SigningScriptTests run scripts/make-signing-cert.sh against a fake keychain tool (fake-keychain-tool, set
# with STRIPLE_SECURITY). On a managed Mac the endpoint security tool can still report its keychain-like
# arguments. The suite is opt-in (STRIPLE_SIGNING_TESTS=1), so `make test` and a plain `swift test` do not run it.
test:
	swift test $(SWIFT_TEST_FLAGS) --skip SigningScriptTests

# Only the suites that start no process and make no executable file (scripts/quiet-tests.sh). Use this lane
# on a managed Mac. `scripts/quiet-tests.sh --list` shows which files are in and why the others are out.
test-quiet:
	scripts/quiet-tests.sh
# Only on a Mac where keychain-like test activity is allowed.
test-signing:
	STRIPLE_SIGNING_TESTS=1 swift test $(SWIFT_TEST_FLAGS) --filter SigningScriptTests

# Performance budgets from docs/SPEC.md, measured in an optimized build.
bench:
	STRIPLE_BENCH=1 swift test -c release -Xswiftc -enable-testing $(SWIFT_TEST_FLAGS) --filter 'Benchmark'

release:
	swift build -c release

# Builds dist/Striple.app. Signs with "Striple Local Signing" when that identity exists
# (scripts/make-signing-cert.sh), else ad hoc. With a pin in Packaging/updates.env, a missing
# identity stops the build. SIGN_IDENTITY overrides (SIGN_IDENTITY=- for ad hoc). See docs/INSTALL.md.
app:
	./scripts/build-app.sh

# Live end-to-end test: runs dist/Striple.app for real against the windows of a test app and checks
# their frames. Never part of `make test`. Exit 2: refused (another Striple runs). See docs/E2E.md.
# E2E_ARGS passes options to the runner, for example E2E_ARGS="--out /tmp/striple/e2e/mine".
e2e: app
	swift build --product striple-e2e
	swift build --product striple-e2e-windows
	"$$(swift build --show-bin-path)/striple-e2e" --app dist/Striple.app $(E2E_ARGS)

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

# Builds and checks a release in dist/release/dry-run/<version>/. Uploads nothing. See docs/RELEASING.md.
publish-dry:
	./scripts/release.sh --dry-run

# Publishes VERSION to the GitHub releases repository in Packaging/updates.env.
publish:
	./scripts/release.sh

# Checks and tags a release that a stopped `make publish` made public already.
publish-finish:
	./scripts/release.sh --finish

run: app
	open dist/Striple.app

# Deletes the build output. Keeps dist/release/<version>/: `make publish-finish` needs it.
clean:
	rm -rf .build dist/release/dry-run
	if [ -d dist ]; then find dist -mindepth 1 -maxdepth 1 ! -name release -exec rm -rf {} +; fi
