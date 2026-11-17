#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Download a prebuilt Windows runtime into Runtime/ (no toolchains needed).
#
# The runtime is Wine + FEX + DXVK/vkd3d-proton/DXMT + KosmicKrisp, built from
# vendor/playport's pins by scripts/build-runtime.sh and packed by
# scripts/pack-runtime.sh into iport-runtime-<playport commit>.tar.gz.
# runtime.lock names the archive to use (url + sha256); IPORT_RUNTIME_URL /
# IPORT_RUNTIME_SHA256 override it, and a local path works as the URL.
set -euo pipefail
cd "$(dirname "$0")/.."

URL="${IPORT_RUNTIME_URL:-}"
SHA="${IPORT_RUNTIME_SHA256:-}"
if [[ -z "$URL" && -f runtime.lock ]]; then
    URL=$(awk -F= '$1=="url"{print $2}' runtime.lock)
    SHA=$(awk -F= '$1=="sha256"{print $2}' runtime.lock)
fi
if [[ -z "$URL" ]]; then
    cat <<MSG
fetch-runtime: no runtime archive is configured.
  Build one once on Linux:   make runtime-from-source   (see docs/RUNTIME.md)
  then publish dist/iport-runtime-*.tar.gz (e.g. as a GitHub Release asset) and put
      url=<its URL>
      sha256=<its sha256>
  in runtime.lock, or export IPORT_RUNTIME_URL / IPORT_RUNTIME_SHA256.
MSG
    exit 1
fi

mkdir -p build
ARCHIVE=build/runtime.tar.gz
if [[ -f "$URL" ]]; then cp "$URL" "$ARCHIVE"; else curl -fL --retry 3 -o "$ARCHIVE" "$URL"; fi
if [[ -n "$SHA" ]]; then
    GOT=$( (command -v sha256sum >/dev/null && sha256sum "$ARCHIVE" || shasum -a 256 "$ARCHIVE") | cut -d' ' -f1)
    [[ "$GOT" == "$SHA" ]] || { echo "fetch-runtime: sha256 mismatch: $GOT != $SHA"; exit 1; }
fi
rm -rf Runtime.new && mkdir Runtime.new
tar -xzf "$ARCHIVE" -C Runtime.new
[[ -d Runtime.new/guest && -d Runtime.new/lib ]] || { echo "fetch-runtime: not an iPort runtime archive"; exit 1; }
rm -rf Runtime && mv Runtime.new Runtime
echo "fetch-runtime: Runtime/ ready ($(cat Runtime/VERSION 2>/dev/null || echo unknown version))"
