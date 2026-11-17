// SPDX-License-Identifier: GPL-3.0-or-later
// iPort: Windows games from your Steam library, downloaded to the phone and
// played on it — ARM builds when the store has them, x86 through FEX otherwise —
// with a controller or an on-screen Xbox pad.

import SwiftUI
import UIKit

@main
struct IPortApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.36, green: 0.80, blue: 0.29))   // Xbox green
                .onAppear {
                    SteamAccount.shared.start()
                    _ = ControllerHub.shared
                    _ = NetworkMonitor.shared
                    Notifier.requestPermission()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            GameSession.shared.focus(phase == .active)
            if phase == .active { Downloads.shared.enteredForeground() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Landscape only: a gamepad-first app, and the game surface never rotates mid-play.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }
}
