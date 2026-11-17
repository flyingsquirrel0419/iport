#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the Windows runtime from source, once, on an x86-64 Linux machine,
# with Playport's own pipeline (vendor/playport, pinned): Wine with its
# 200+ iOS patches, FEX, DXMT, DXVK, vkd3d-proton, KosmicKrisp, the Steam API
# emulator. Then pack it as dist/iport-runtime-<commit>.tar.gz.
#
# This is the heavy part (hours, ~100 GB, the toolchains in
# vendor/playport/docs/BUILDING.md: llvm-mingw, an iOS SDK from Xcode's .xip
# via xtool, ld64, Rust). You build it once per Playport pin and publish the
# archive; everyone else runs `make runtime` (a download) and builds the
# app in minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

[[ "$(uname -s)" == Linux ]] || { echo "build-runtime: runs on x86-64 Linux (Playport's pipeline); on a Mac use make runtime"; exit 1; }
git submodule update --init vendor/playport
# Playport's own submodule (upstream/madeira: Wine's iOS port) and the trees it pins.
git -C vendor/playport submodule update --init --recursive

cd vendor/playport
if ! ./pp setup --check >/dev/null 2>&1; then
    echo "build-runtime: recording this machine's toolchains (vendor/playport/docs/BUILDING.md, Prerequisites)"
    ./pp setup
fi
# Every tree, staged into vendor/playport/app/, with the notices; the app stage is Playport's own and not needed.
PLAYPORT_VARIANT=release ./pp build --variant release --to notices
cd "$ROOT"
scripts/pack-runtime.sh
