//
//  SettingsNotificationsView.swift
//  HopChat-1
//
//  Notification preferences (contract §6) plus the system permission state,
//  which the in-app switches cannot override.
//

import SwiftUI
import UserNotifications
import UIKit
import os

struct SettingsNotificationsView: View {

    @AppStorage(AppConfig.Keys.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(AppConfig.Keys.notificationsPreview) private var showPreview = true
    @AppStorage(AppConfig.Keys.notificationsSound)   private var playSound = true

    @Environment(\.scenePhase) private var scenePhase
    @State private var systemStatus: UNAuthorizationStatus = .notDetermined
    @State private var isRequesting = false

    var body: some View {
        Form {
            Group {
                permissionSection

                Section {
                    Toggle(isOn: $notificationsEnabled) {
                        Text("Message notifications")
                    }
                    .accessibilityHint(Text("Shows a notification when a message arrives while hoppin is closed"))

                    Toggle(isOn: $showPreview) {
                        Text("Show preview")
                    }
                    .disabled(!notificationsEnabled)
                    .accessibilityHint(Text("Includes the sender's name and message text in the notification"))

                    Toggle(isOn: $playSound) {
                        Text("Play sound")
                    }
                    .disabled(!notificationsEnabled)
                } header: {
                    Text("In hoppin")
                } footer: {
                    Text("With previews off, notifications say only that a new message arrived.")
                }
            }
            .glassListRows()
        }
        .lavaBackground()
        .navigationTitle(Text("Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshStatus() } }
        }
    }

    // MARK: - System permission

    @ViewBuilder
    private var permissionSection: some View {
        Section {
            LabeledContent {
                Text(statusText)
                    .foregroundStyle(statusIsGood ? Color.secondary : Color.red)
            } label: {
                Text("System permission")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("System permission: \(statusText)"))

            switch systemStatus {
            case .notDetermined:
                Button {
                    Task { await request() }
                } label: {
                    Text("Allow notifications")
                        .frame(minHeight: 44)
                }
                .disabled(isRequesting)

            case .denied:
                Button {
                    openSystemSettings()
                } label: {
                    Text("Open iOS Settings")
                        .frame(minHeight: 44)
                }
                .accessibilityHint(Text("Opens the Settings app where you can turn hoppin notifications back on"))

            default:
                EmptyView()
            }
        } footer: {
            if systemStatus == .denied {
                Text("iOS is blocking hoppin notifications, so the switches below have no effect until you allow them in Settings.")
            }
        }
    }

    private var statusText: String {
        switch systemStatus {
        case .authorized:    return String(localized: "Allowed")
        case .provisional:   return String(localized: "Quiet delivery")
        case .ephemeral:     return String(localized: "Temporary")
        case .denied:        return String(localized: "Blocked in iOS Settings")
        case .notDetermined: return String(localized: "Not asked yet")
        @unknown default:    return String(localized: "Unknown")
        }
    }

    private var statusIsGood: Bool {
        systemStatus != .denied
    }

    private func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        systemStatus = settings.authorizationStatus
    }

    private func request() async {
        isRequesting = true
        _ = await NotificationService.shared.requestPermission()
        isRequesting = false
        await refreshStatus()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url) { opened in
            if !opened { Log.ui.error("Could not open iOS Settings") }
        }
    }
}

#Preview {
    NavigationStack { SettingsNotificationsView() }
}
