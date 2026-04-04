import SwiftUI

struct GetStarted: View {
    @StateObject private var kad = KademliaService.shared
    @State private var phoneText       = ""
    @State private var isLoading       = false
    @State private var errorMessage:   String?
    @State private var navigateToChats = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Spacer()

                // Logo
                Image(systemName: "wifi")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue)
                    .shadow(color: .blue.opacity(0.4), radius: 20)

                VStack(spacing: 8) {
                    Text("HopChat")
                        .font(.largeTitle.weight(.bold))
                    Text("Peer-to-peer WiFi chat,\nno servers needed")
                        .font(.title2.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Phone field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your phone number")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("+351 912 345 678", text: $phoneText)
                        .keyboardType(.phonePad)
                        .padding()
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                }

                // Error
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                // Status while loading
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(kad.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                // Register button
                Button {
                    startRegistration()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Get Started")
                        }
                    }
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(phoneText.isEmpty ? Color.gray : Color.blue, in: Capsule())
                    .shadow(color: .blue.opacity(phoneText.isEmpty ? 0 : 0.3), radius: 10)
                }
                .disabled(phoneText.isEmpty || isLoading)

                Spacer().frame(height: 60)
            }
            .padding(.horizontal, 32)
            .background(Color(.systemBackground))
            .ignoresSafeArea(.container, edges: .all)
            .navigationDestination(isPresented: $navigateToChats) {
                ChatListView().navigationBarBackButtonHidden(true)
            }
            .onAppear {
                // Auto-login if phone was saved previously
                // Only pre-fill the field — don't auto-start (avoids blank screen on simulator)
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
            // Always navigate — KademliaService handles the no-WiFi/simulator case gracefully
            navigateToChats = true
        }
    }
}

#Preview {
    GetStarted()
}
