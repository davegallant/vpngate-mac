# Uses a clean, non-nix environment pointed at real Xcode -- this machine's
# nix profile puts a nix xcrun/SDK shim ahead of the real one on PATH, which
# breaks `swift build`/`swift test`/`xcodebuild` with SDK-mismatch errors
# (see AGENTS.md). Per-invocation `env` overrides are what actually stick;
# exporting DEVELOPER_DIR alone in a nix shell does not.
clean_env := "env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"

# Run the VpngateShared package test suite.
test:
    cd Shared && {{clean_env}} swift test

# Run a subset of the VpngateShared test suite, e.g. `just test-filter ManagementClientTests`.
test-filter filter:
    cd Shared && {{clean_env}} swift test --filter {{filter}}

# Build the VpngateShared package.
build:
    cd Shared && {{clean_env}} swift build

# Archive and package the macOS app (VPNGate.zip) via Xcode.
package:
    {{clean_env}} ./build-and-package.sh

# Tag and push a release, e.g. `just release 0.0.1-rc1`. Pushing the tag
# triggers .github/workflows/release.yml, which tests, builds, signs, and
# publishes VPNGate.zip as a GitHub Release. Update CHANGELOG.md and commit
# it before running this.
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n $(git status --porcelain) ]]; then
        echo "Working tree is not clean; commit or stash changes first." >&2
        exit 1
    fi
    git tag -a "v{{version}}" -m "v{{version}}"
    git push origin "v{{version}}"
