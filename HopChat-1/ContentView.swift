import SwiftUI

struct ContentView: View {
    @StateObject private var kad = KademliaService.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var phoneText       = ""
    @State private var isLoading       = false
    @State private var errorMessage:   String?
    @State private var navigateToChats = false
    @State private var pulse: CGFloat  = 1.0
    @State private var appear          = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Apple-style adaptive background
                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    // ── Hero ─────────────────────────────────────────
                    VStack(spacing: 16) {

                        // Icon — SF Symbols WiFi with Apple blue
                        ZStack {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(width: 100, height: 100)
                                .scaleEffect(pulse)
                                .animation(
                                    .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                                    value: pulse
                                )

                            Image(systemName: "wifi")
                                .font(.system(size: 44, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .opacity(appear ? 1 : 0)
                        .scaleEffect(appear ? 1 : 0.7)
                        .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.05), value: appear)

                        // App name — SF Pro Rounded, like Apple apps
                        Text("HopChat")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .opacity(appear ? 1 : 0)
                            .offset(y: appear ? 0 : 10)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appear)

                        // Tagline
                        VStack(spacing: 5) {
                            Text("No servers. No strangers.")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.accentColor)

                            Text("No sign-ups.\nJust hop and go!")
                                .font(.system(size: 15))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .opacity(appear ? 1 : 0)
                        .offset(y: appear ? 0 : 8)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25), value: appear)
                    }

                    Spacer()

                    // ── Phone Input & CTA ─────────────────────────────
                    VStack(spacing: 16) {

                        // Phone field — Apple grouped list style
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
                                        phoneText.isEmpty
                                            ? Color.clear
                                            : Color.accentColor.opacity(0.5),
                                        lineWidth: 1.5
                                    )
                            )
                        }.padding(.horizontal, 16)

                        // Error
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 4)
                        }

                        // CTA — Apple-style filled button
                        Button(action: startRegistration) {
                            Group {
                                if isLoading {
                                    HStack(spacing: 8) {
                                        ProgressView().tint(Color.white)
                                        Text(kad.status)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.leading, 4)

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
                        .padding(.horizontal,16)

                        Spacer().frame(height: 32)
                        // Privacy note — typical Apple onboarding footer
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
            .navigationDestination(isPresented: $navigateToChats) {
                ChatListView().navigationBarBackButtonHidden(true)
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

// MARK: - Feature Pill

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
        .background(
            Capsule()
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
    }
}

#Preview {
    ContentView()
}

#Preview("Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}
