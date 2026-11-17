#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Collect what Playport's pipeline staged in vendor/playport/app/ into
# Runtime/ and dist/iport-runtime-<commit>.tar.gz (see scripts/gen-project.py
# for the layout). Runs after scripts/build-runtime.sh, or on a tree someone
# else staged.
set -euo pipefail
cd "$(dirname "$0")/.."
P=vendor/playport/app
[[ -d $P/Staged/lib && -d $P/Sources/S1Probe/Runtime ]] || { echo "pack-runtime: nothing staged in $P (run scripts/build-runtime.sh)"; exit 1; }

rm -rf Runtime && mkdir -p Runtime/{guest,lib,src,Frameworks}
cp -a $P/Sources/S1Probe/Runtime/. Runtime/guest/
for a in $P/Staged/lib/*.a; do
    case "$(basename "$a")" in libidevice_ffi.a) ;; *) cp -a "$a" Runtime/lib/ ;; esac   # iPort does not relaunch itself
done
for d in WineHost HostIO WinIOS; do cp -a $P/Sources/$d Runtime/src/; done
for x in KosmicKrisp MesaEGL MesaGallium; do
    [[ -d $P/Staged/$x.xcframework ]] && cp -a $P/Staged/$x.xcframework Runtime/Frameworks/
done
[[ -d $P/Staged/Licenses ]] && cp -a $P/Staged/Licenses Runtime/Licenses
COMMIT=$(git -C vendor/playport rev-parse --short=12 HEAD)
echo "playport $COMMIT, packed $(date -u +%Y-%m-%d)" > Runtime/VERSION

mkdir -p dist
OUT=dist/iport-runtime-$COMMIT.tar.gz
tar -C Runtime -czf "$OUT" .
SUM=$( (command -v sha256sum >/dev/null && sha256sum "$OUT" || shasum -a 256 "$OUT") | cut -d' ' -f1)
echo "pack-runtime: $OUT ($(du -h "$OUT" | cut -f1)) sha256=$SUM"
echo "Publish it and put url=<URL> and sha256=$SUM in runtime.lock."
