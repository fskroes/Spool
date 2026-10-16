# Spool build commands. Works with the Command Line Tools only (no Xcode needed).

TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
SWIFT_TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)

.PHONY: build test test-quiet test-signing bench release app icon dmg install uninstall run clean e2e publish publish-dry publish-finish

build:
	swift build

# SigningScriptTests run scripts/make-signing-cert.sh against a fake keychain tool (fake-keychain-tool, set
# with SPOOL_SECURITY). On a managed Mac the endpoint security tool can still report its keychain-like
# arguments. The suite is opt-in (SPOOL_SIGNING_TESTS=1), so `make test` and a plain `swift test` do not run it.
# TEST_ARGS goes to swift test, for example `make test TEST_ARGS="--filter VerifyScriptTests"`.
test:
	swift test $(SWIFT_TEST_FLAGS) --skip SigningScriptTests $(TEST_ARGS)

# Only the suites that start no process and make no executable file (scripts/quiet-tests.sh). Use this lane
# on a managed Mac. `scripts/quiet-tests.sh --list` shows which files are in and why the others are out.
test-quiet:
	scripts/quiet-tests.sh
# Only on a Mac where keychain-like test activity is allowed.
test-signing:
	SPOOL_SIGNING_TESTS=1 swift test $(SWIFT_TEST_FLAGS) --filter SigningScriptTests

# Performance budgets from docs/SPEC.md, measured in an optimized build.
bench:
	SPOOL_BENCH=1 swift test -c release -Xswiftc -enable-testing $(SWIFT_TEST_FLAGS) --filter 'Benchmark'

release:
	swift build -c release

# Builds dist/Spool.app. Signs with the Developer ID of the team in Packaging/updates.env when it
# is in the keychain, else with "Striple Local Signing" (scripts/make-signing-cert.sh). With a team
# and neither identity, the build stops. SIGN_IDENTITY overrides (SIGN_IDENTITY=- for ad hoc).
# See docs/INSTALL.md.
app:
	./scripts/build-app.sh

# Live end-to-end test: runs dist/Spool.app for real against the windows of a test app and checks
# their frames. Never part of `make test`. Exit 2: refused (another Spool runs). See docs/E2E.md.
# E2E_ARGS passes options to the runner, for example E2E_ARGS="--out /tmp/spool/e2e/mine".
e2e: app
	swift build --product spool-e2e
	swift build --product spool-e2e-windows
	"$$(swift build --show-bin-path)/spool-e2e" --app dist/Spool.app $(E2E_ARGS)

# Draws the app icon into .build/icon/AppIcon.icns (make app does this when needed).
icon:
	swift scripts/make-icon.swift .build/icon

# Makes dist/Spool-<version>.dmg from dist/Spool.app.
dmg: app
	./scripts/make-dmg.sh

# Copies the app to /Applications and links the CLI to ~/.local/bin/spool.
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
	open dist/Spool.app

# Deletes the build output. Keeps dist/release/<version>/: `make publish-finish` needs it.
clean:
	rm -rf .build dist/release/dry-run
	if [ -d dist ]; then find dist -mindepth 1 -maxdepth 1 ! -name release -exec rm -rf {} +; fi
