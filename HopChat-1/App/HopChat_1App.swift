//
//  HopChat_1App.swift
//  HopChat-1
//
//  App entry point (contract §7). The old `voip` keepalive is gone: the app
//  no longer keeps a socket alive in the background. Background delivery is a
//  single `BGAppRefreshTask` that drains the encrypted relay queue.
//

import SwiftUI
import UIKit

@main
struct HopChat_1App: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var service = KademliaService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(service)
        }
        .onChange(of: scenePhase) { _, phase in
            handle(phase)
        }
    }

    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            AppLock.shared.appDidEnterBackground()
            BackgroundRefresh.schedule()
            Task { await KademliaService.shared.flushPendingWrites() }

        case .active:
            AppLock.shared.appWillEnterForeground()

        case .inactive:
            break

        @unknown default:
            break
        }
    }
}
