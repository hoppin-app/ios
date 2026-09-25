//
//  BackgroundRefresh.swift
//  HopChat-1
//
//  The app's only background mechanism: a `BGAppRefreshTask` that drains the
//  encrypted relay queue. The identifier is declared in Info.plist under
//  `BGTaskSchedulerPermittedIdentifiers`.
//
//  `register()` must run inside `application(_:didFinishLaunchingWithOptions:)`
//  — iOS raises an exception for a handler registered after launch finishes.
//

import Foundation
import BackgroundTasks
import os

nonisolated enum BackgroundRefresh {

    /// iOS never schedules an app refresh more often than this anyway.
    private static let minimumInterval: TimeInterval = 15 * 60

    // MARK: - Registration

    static func register() {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: KademliaService.backgroundTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }

        if !registered {
            Log.app.error("BGTaskScheduler refused to register \(KademliaService.backgroundTaskIdentifier, privacy: .public)")
        }
    }

    // MARK: - Scheduling

    /// Asks the system for another refresh. Safe to call repeatedly; a new
    /// request replaces the pending one.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: KademliaService.backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Common and harmless in the simulator and when the user has
            // Background App Refresh switched off.
            Log.app.debug("Could not schedule background refresh: \(String(describing: error), privacy: .public)")
        }
    }

    static func cancelAll() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: KademliaService.backgroundTaskIdentifier)
    }

    // MARK: - Handling

    private static func handle(_ task: BGAppRefreshTask) {
        // Re-arm first: if the fetch crashes or expires we still get another turn.
        schedule()

        let work = Task { @MainActor in
            let newData = await KademliaService.shared.performBackgroundFetch()
            task.setTaskCompleted(success: newData)
        }

        task.expirationHandler = {
            Log.app.debug("Background refresh expired, cancelling")
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
