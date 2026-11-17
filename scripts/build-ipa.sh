#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build dist/iPort.ipa on a Mac with Xcode: unsigned for the store, ad-hoc
# signed with iPort's entitlements, for SideStore / AltStore / Sideloadly /
# LiveContainer to re-sign with your Apple ID.
#
#   scripts/build-ipa.sh            without the Windows runtime (UI, Steam, downloads, controls)
#   RUNTIME=1 scripts/build-ipa.sh  with Runtime/ (make runtime first)
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(uname)" == Darwin ]] || { echo "build-ipa: needs macOS with Xcode (or use the GitHub Actions workflow: no Mac needed)"; exit 1; }
command -v xcodebuild >/dev/null || { echo "build-ipa: install Xcode"; exit 1; }
if ! command -v xcodegen >/dev/null; then
    command -v brew >/dev/null || { echo "build-ipa: install Homebrew or XcodeGen (https://github.com/yonaskolb/XcodeGen)"; exit 1; }
    brew install xcodegen
fi
[[ -f vendor/playport/app/SteamClient/Package.swift ]] || git submodule update --init vendor/playport

if [[ "${RUNTIME:-0}" == 1 ]]; then python3 scripts/gen-project.py --runtime; else python3 scripts/gen-project.py; fi
xcodegen generate --spec project.gen.yml --project . --quiet

CONFIG="${CONFIG:-Release}"
DD=build/DerivedData
rm -rf build/Payload dist/iPort.ipa
xcodebuild -project iPort.xcodeproj -scheme iPort -configuration "$CONFIG" \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    -skipPackagePluginValidation build | { command -v xcbeautify >/dev/null && xcbeautify || cat; }

APP="$DD/Build/Products/$CONFIG-iphoneos/iPort.app"
[[ -d "$APP" ]] || { echo "build-ipa: $APP was not built"; exit 1; }
mkdir -p build/Payload dist
cp -R "$APP" build/Payload/
# Ad-hoc signature carrying the entitlements (increased memory limit, get-task-allow):
# sideloaders read them from here when they re-sign.
if [[ -d build/Payload/iPort.app/Frameworks ]]; then
    find build/Payload/iPort.app/Frameworks -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) \
        -exec codesign --force --sign - {} \;
fi
codesign --force --sign - --entitlements App/iPort.entitlements build/Payload/iPort.app
(cd build && zip -qry ../dist/iPort.ipa Payload)
echo "build-ipa: dist/iPort.ipa ($(du -h dist/iPort.ipa | cut -f1))$([[ "${RUNTIME:-0}" == 1 ]] && echo ', with the Windows runtime' || echo ', without the Windows runtime')"
