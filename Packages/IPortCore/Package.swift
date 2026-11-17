// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// IPortCore: everything in iPort that does not need UIKit, Steam or the Wine
// runtime — the XInput pad model, the touch layout and its touch resolver,
// the controller arbiter (who owns slot 0, when the touch pad hides), the
// download queue, the ARM-first depot policy and the launch plan.
// Pure Swift, so `swift test` runs it on Linux or macOS in seconds.

import PackageDescription

let package = Package(
    name: "IPortCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "IPortCore", targets: ["IPortCore"])],
    targets: [
        .target(name: "IPortCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "IPortCoreTests", dependencies: ["IPortCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
