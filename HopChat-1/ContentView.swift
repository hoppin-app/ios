//
//  ContentView.swift
//  HopChat-1
//
//  Root routing: onboarding (with the terms gate) → SMS verification → tabs.
//  Also owns the three things that must sit above every screen: the app-lock
//  gate, the privacy cover for the app switcher, and the connection banner.
//

import SwiftUI

// MARK: - Floating Tab Bar

struct FloatingTabBar: View {
    @Binding var selectedTab: Int
    var unreadCount: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let items: [(icon: String, filled: String, label: String)] = [
        ("bubble.left",  "bubble.left.fill",  String(localized: "Chats")),
        ("person",       "person.fill",       String(localized: "People")),
        ("gearshape",    "gearshape.fill",    String(localized: "Settings")),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                tabButton(index: i)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule().strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.13), radius: 26, x: 0, y: 8)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
        .frame(maxWidth: 560)
    }

    @ViewBuilder
    private func tabButton(index: Int) -> some View {
        Button {
            if reduceMotion {
                selectedTab = index
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                    selectedTab = index
                }
            }
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: selectedTab == index ? items[index].filled : items[index].icon)
                        .font(.body.weight(selectedTab == index ? .semibold : .regular))
                        .frame(minHeight: 24)
                        .accessibilityHidden(true)

                    if index == 0, unreadCount > 0 {
                        Text(unreadCount > 9 ? "9+" : "\(unreadCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(.red, in: Capsule())
                            .offset(x: 11, y: -5)
                            .accessibilityHidden(true)
                    }
                }

                Text(items[index].label)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selectedTab == index ? Color.accentColor : Color(.tertiaryLabel))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(items[index].label))
        .accessibilityValue(index == 0 && unreadCount > 0
                            ? Text("\(unreadCount) unread") : Text(""))
        .accessibilityAddTraits(selectedTab == index ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(["tab.chats", "tab.people", "tab.settings"][index])
    }
}

// MARK: - Content View

struct ContentView: View {

    @StateObject private var service = KademliaService.shared
    @StateObject private var store   = ConversationStore.shared
    @StateObject private var appLock = AppLock.shared

    @AppStorage(AppConfig.Keys.hasSeenOnboarding) private var hasSeenOnboarding = false
    @AppStorage(AppConfig.Keys.hasAcceptedTerms)  private var hasAcceptedTerms  = false

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab = 0
    @State private var didStartService = false
    @State private var splashFinished = false
    @State private var splashDismissed = false

    private var needsOnboarding: Bool { !hasSeenOnboarding || !hasAcceptedTerms }
    /// The animated launch continues until the service is up and the logo has
    /// finished drawing. First launch goes straight to onboarding instead.
    private var showsSplash: Bool { !splashDismissed && !needsOnboarding }
    private var coverForPrivacy: Bool { appLock.isEnabled && scenePhase != .active }

    var body: some View {
        ZStack {
            root
                .environmentObject(service)

            if showsSplash {
                HopSplashView { splashFinished = true }
                    .transition(.opacity)
                    .zIndex(0.5)
            }

            if appLock.isLocked {
                LockScreen(appLock: appLock)
                    .transition(.opacity)
                    .zIndex(1)
            }

            if coverForPrivacy {
                PrivacyCover()
                    .zIndex(2)
            }
        }
        .onChange(of: didStartService && splashFinished) { _, ready in
            guard ready else { return }
            withAnimation(.easeInOut(duration: 0.45)) { splashDismissed = true }
        }
        .task {
            guard !didStartService else { return }
            await service.start()
            didStartService = true
        }
    }

    @ViewBuilder
    private var root: some View {
        if needsOnboarding {
            OnboardingView()
        } else if !didStartService && !service.isRegistered {
            // Covered by the splash; matches the launch screen underneath it.
            Color("LaunchBackground").ignoresSafeArea()
        } else if !service.isRegistered {
            VerificationView()
        } else {
            mainTabView
        }
    }

    // MARK: - Main tabs

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            ChatListView()
                .toolbar(.hidden, for: .tabBar)
                .tag(0)
            PeopleView()
                .toolbar(.hidden, for: .tabBar)
                .tag(1)
            SettingsView()
                .toolbar(.hidden, for: .tabBar)
                .tag(2)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.showTabBar {
                FloatingTabBar(selectedTab: $selectedTab,
                               unreadCount: store.totalUnreadCount)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ConnectionBanner(state: service.connectionState)
        }
        .overlay(alignment: .center) {
            // Drives the Translation session; owned by the chat agent.
            TranslationBridgeView()
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
                .clipped()
                .accessibilityHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { _ in
            selectedTab = 0
        }
    }
}

// MARK: - Connection banner

private struct ConnectionBanner: View {
    let state: ConnectionState

    var body: some View {
        switch state {
        case .error(let message):
            banner(text: message, systemImage: "exclamationmark.triangle.fill",
                   tint: .orange, showsProgress: false)
        case .connecting:
            banner(text: String(localized: "Connecting…"), systemImage: nil,
                   tint: .secondary, showsProgress: true)
        case .offline, .online:
            EmptyView()
        }
    }

    private func banner(text: String, systemImage: String?, tint: Color, showsProgress: Bool) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}


// MARK: - App lock

private struct LockScreen: View {

    @ObservedObject var appLock: AppLock

    @State private var isAuthenticating = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Text("hoppin is locked")
                    .font(.system(.title2, design: .rounded).weight(.bold))

                Text("Unlock to read your messages.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if failed {
                    Text("Unlock failed. Try again.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    authenticate()
                } label: {
                    Group {
                        if isAuthenticating {
                            ProgressView()
                        } else {
                            Label("Unlock", systemImage: "faceid").font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAuthenticating)
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }
            .frame(maxWidth: 420)
            .padding(24)
        }
        .onAppear { authenticate() }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let ok = await appLock.authenticate()
            failed = !ok
            isAuthenticating = false
        }
    }
}

// MARK: - Privacy cover

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
        .accessibilityHidden(true)
    }
}

#Preview { ContentView() }
#Preview("Dark") { ContentView().preferredColorScheme(.dark) }
