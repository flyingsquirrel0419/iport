#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write project.gen.yml (XcodeGen) from project.yml.

    scripts/gen-project.py            the app without the Windows runtime
    scripts/gen-project.py --runtime  the app with Runtime/ linked in

Each "# @runtime-<name>" marker in project.yml becomes the runtime's lines;
without --runtime the markers stay comments. Runtime/ is what `make runtime`
unpacks (scripts/fetch-runtime.sh) or `make runtime-from-source` builds
(scripts/build-runtime.sh): guest/ (the DLL sets, shipped at the bundle root),
lib/ (static archives), src/ (Playport's host C, Madeira's Winios driver),
Frameworks/ (KosmicKrisp and Mesa) and Licenses/.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RT = os.path.join(ROOT, "Runtime")

# What Playport's app target links (vendor/playport/app/Package.swift, WineHost), in its order.
LIBS = ["wineserver", "ntdll_unix", "dxmt_combined", "win32u_unix", "gnutls", "hogweed", "nettle", "gmp",
        "winegstreamer_unix", "iconv", "resolv", "c++", "sqlite3"]
SDK_FRAMEWORKS = ["Foundation", "CoreFoundation", "Security", "CoreText", "CoreGraphics", "IOSurface",
                  "AudioToolbox", "IOKit", "Metal", "QuartzCore", "MetalFX", "VideoToolbox", "CoreMedia",
                  "CoreVideo", "AVFoundation", "AVFAudio", "OpenGLES", "AssetsLibrary", "UIKit", "ImageIO"]


def runtime_blocks():
    if not os.path.isdir(RT):
        sys.exit("Runtime/ is missing: run `make runtime` (download) or `make runtime-from-source` first.")
    guest = os.path.join(RT, "guest")
    entries = sorted(os.listdir(guest))
    src = ["      - path: Runtime/src", "        excludes: [\"**/tests/**\", \"**/*.h\"]"]
    for e in entries:
        # Every guest folder and file lands at the app bundle's root, where ntdll looks for them.
        src += [f"      - path: Runtime/guest/{e}", "        type: folder" if os.path.isdir(os.path.join(guest, e)) else "        type: file",
                "        buildPhase: resources"]
    if os.path.isdir(os.path.join(RT, "Licenses")):
        src += ["      - path: Runtime/Licenses", "        type: folder", "        buildPhase: resources"]

    inc = []
    for d in ("src/WineHost/include", "src/HostIO/include", "src/WinIOS", "src/WinIOS/include"):
        if os.path.isdir(os.path.join(RT, d)):
            inc.append(f'"$(SRCROOT)/Runtime/{d}"')
    headers = '        HEADER_SEARCH_PATHS: ["$(SRCROOT)/App/RuntimeBridge/include", ' + ", ".join(inc) + "]"

    settings = [
        '        GCC_PREPROCESSOR_DEFINITIONS: ["$(inherited)", "IPORT_WITH_WINE=1", "PLAYPORT_RELEASE=1"]',
        '        LIBRARY_SEARCH_PATHS: ["$(inherited)", "$(SRCROOT)/Runtime/lib"]',
        "        OTHER_LDFLAGS: [" + ", ".join(f'"-l{l}"' for l in LIBS) + "]",
        "        CLANG_ENABLE_OBJC_ARC: YES",
        # The runtime's JIT protocol needs iOS 26 (TXM debugger-blessed pages).
        '        IPHONEOS_DEPLOYMENT_TARGET: "26.0"',
        "        GCC_WARN_INHIBIT_ALL_WARNINGS: YES",
    ]
    deps = [f"      - sdk: {f}.framework" for f in SDK_FRAMEWORKS]
    fw = os.path.join(RT, "Frameworks")
    for x in sorted(os.listdir(fw)) if os.path.isdir(fw) else []:
        if x.endswith(".xcframework"):
            deps += [f"      - framework: Runtime/Frameworks/{x}", "        embed: true"]
    return {"sources": src, "headers": [headers], "settings": settings, "dependencies": deps}


def main():
    runtime = "--runtime" in sys.argv
    blocks = runtime_blocks() if runtime else {}
    out = []
    with open(os.path.join(ROOT, "project.yml")) as f:
        for line in f:
            marker = next((k for k in ("sources", "headers", "settings", "dependencies") if f"# @runtime-{k}" in line), None)
            if marker and runtime:
                out += [l + "\n" for l in blocks[marker]]
            else:
                out.append(line)
    with open(os.path.join(ROOT, "project.gen.yml"), "w") as f:
        f.writelines(out)
    print("project.gen.yml: " + ("with the Windows runtime" if runtime else "without the Windows runtime"))


main()
