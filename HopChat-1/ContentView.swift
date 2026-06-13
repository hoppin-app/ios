import SwiftUI

struct ContentView: View {
    @StateObject private var kad   = KademliaService.shared
    @StateObject private var store = ConversationStore.shared
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("hopchat.hasSeenOnboarding") private var hasSeenOnboarding = false

    @State private var phoneText        = ""
    @State private var isLoading        = false
    @State private var errorMessage:    String?
    @State private var navigateToChats: Bool = {
        let phone = UserDefaults.standard.string(forKey: "hopchat.phone") ?? ""
        return !phone.isEmpty
    }()
    @State private var selectedTab      = 0
    @State private var pulse: CGFloat   = 1.0
    @State private var appear           = false

    var body: some View {
        if !hasSeenOnboarding {
            OnboardingView(hasSeenOnboarding: $hasSeenOnboarding)
        } else if navigateToChats {
            mainTabView
        } else {
            registrationView
        }
    }

    // MARK: - Main Tab View

    private var mainTabView: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                ChatListView()
                    .tabItem { Label("Chats", systemImage: "bubble.left") }
                    .badge(store.totalUnreadCount)
                    .tag(0)

                PeopleView()
                    .tabItem { Label("People", systemImage: "person") }
                    .tag(1)

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(2)
            }

            // TranslationBridgeView must always be in the hierarchy so
            // the TranslationSession is alive during the full chat lifecycle.
            TranslationBridgeView()
                .allowsHitTesting(false)
        }
        // Switch to Chats tab when a notification deep-links into a conversation
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { _ in
            selectedTab = 0
        }
        .task {
            let phone = UserDefaults.standard.string(forKey: "hopchat.phone") ?? ""
            guard !phone.isEmpty else { return }
            if KeychainHelper.shared.getUUID() == nil {
                _ = KeychainHelper.shared.saveUUID(UUID())
            }
            await kad.register(phone: phone)
        }
    }

    // MARK: - Registration View

    private var registrationView: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 16) {
                        Image("HopChatIcon")
                            .resizable()
                            .frame(width: 100, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .scaleEffect(pulse)
                            .animation(
                                .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                                value: pulse
                            )
                            .opacity(appear ? 1 : 0)
                            .scaleEffect(appear ? 1 : 0.7)
                            .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.05), value: appear)

                        Text("HopChat")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .opacity(appear ? 1 : 0)
                            .offset(y: appear ? 0 : 10)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appear)

                        VStack(spacing: 5) {
                            Text("No servers. No strangers.")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("No sign-ups.\nJust hop on and go!")
                                .font(.system(size: 15))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .opacity(appear ? 1 : 0)
                        .offset(y: appear ? 0 : 8)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25), value: appear)
                    }

                    Spacer()

                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Phone Number")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)

                            HStack(spacing: 10) {
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.accentColor)

                                TextField("+351 912 345 678", text: $phoneText)
                                    .keyboardType(.phonePad)
                                    .font(.system(size: 17))
                                    .foregroundStyle(.primary)
                                    .tint(Color.accentColor)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        phoneText.isEmpty ? Color.clear : Color.accentColor.opacity(0.5),
                                        lineWidth: 1.5
                                    )
                            )
                        }.padding(.horizontal, 16)

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 4)
                        }

                        Button(action: startRegistration) {
                            Group {
                                if isLoading {
                                    HStack(spacing: 8) {
                                        ProgressView().tint(.white)
                                        Text(kad.status)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                } else {
                                    Text("Start Hopping! 👋")
                                        .font(.system(size: 17, weight: .semibold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(.white)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(phoneText.isEmpty ? Color(.tertiarySystemFill) : Color.accentColor)
                            )
                        }
                        .disabled(phoneText.isEmpty || isLoading)
                        .animation(.easeInOut(duration: 0.18), value: phoneText.isEmpty)
                        .padding(.horizontal, 16)

                        Spacer().frame(height: 32)
                        Text("Your number is only stored on this device and never shared.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(.tertiaryLabel))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, 14)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 16)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.42), value: appear)

                    Spacer().frame(height: 10)
                }
            }
            .onAppear {
                appear = true
                pulse  = 1.10
                if let saved = UserDefaults.standard.string(forKey: "hopchat.phone") {
                    phoneText = saved
                }
            }
        }
    }

    // MARK: - Registration

    private func startRegistration() {
        let phone = phoneText.replacingOccurrences(of: " ", with: "")
        guard !phone.isEmpty else { return }
        UserDefaults.standard.set(phone, forKey: "hopchat.phone")
        isLoading    = true
        errorMessage = nil
        if KeychainHelper.shared.getUUID() == nil {
            _ = KeychainHelper.shared.saveUUID(UUID())
        }
        Task {
            await kad.register(phone: phone)
            isLoading = false
            navigateToChats = true
        }
    }
}

// MARK: - Feature Pill (kept for potential reuse)

struct FeaturePill: View {
    let emoji: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(emoji).font(.system(size: 13))
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
    }
}

#Preview {
    ContentView()
}

#Preview("Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}
