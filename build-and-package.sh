#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="Vpngate"
CONFIGURATION="Release"
ARCHIVE_PATH="build/Vpngate.xcarchive"

rm -rf build
mkdir -p build

# CI (see .github/workflows/release.yml) sets these to sign with a certificate
# imported into a temporary keychain instead of Xcode's interactive Automatic
# signing, which needs an Apple ID session that CI doesn't have. Unset locally,
# so local builds keep using the project's default Automatic signing.
EXTRA_XCODEBUILD_ARGS=()
if [[ -n "${CODE_SIGN_STYLE_OVERRIDE:-}" ]]; then
  EXTRA_XCODEBUILD_ARGS+=("CODE_SIGN_STYLE=$CODE_SIGN_STYLE_OVERRIDE")
fi
if [[ -n "${CODE_SIGN_IDENTITY_OVERRIDE:-}" ]]; then
  EXTRA_XCODEBUILD_ARGS+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY_OVERRIDE")
fi

xcodebuild \
  -project Vpngate.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  "${EXTRA_XCODEBUILD_ARGS[@]+"${EXTRA_XCODEBUILD_ARGS[@]}"}" \
  archive

# xcodebuild -exportArchive requires a paid Developer account's distribution
# profiles to resolve an export method; a free/personal-team Apple ID has
# none, so it always fails with "expected one {} but found development".
# The archive step already produces a validly Development-signed .app, so
# copy it straight out instead of exporting.
cp -R "$ARCHIVE_PATH/Products/Applications/VPNGate.app" build/VPNGate.app

cd build
zip -r VPNGate.zip VPNGate.app
echo "Built build/VPNGate.zip"
