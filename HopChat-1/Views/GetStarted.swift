import SwiftUI
import iPhoneNumberField

struct GetStarted: View {
    @StateObject private var kad = KademliaService.shared
    @State private var phoneText = ""
    @State private var isLoading = false
    @State private var navigateToChats = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Spacer()

                ZStack {
                    Image(systemName: "wifi")
                        .font(.system(size: 80))
                        .foregroundStyle(.blue)
                        .shadow(color: .blue.opacity(0.4), radius: 20, x: 0, y: 10)
                }

                Text("HopChat")
                    .font(.largeTitle.weight(.bold))

                Text("Peer-to-peer WiFi chat,\nno servers needed")
                    .font(.title2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Spacer()

                iPhoneNumberField("Insert your phone number", text: $phoneText)
                    .countryCodePlaceholderColor(Color.gray)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(kad.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

            
                Button {
                    isLoading = true
                    
                    Task {
                        // 1. Generate or retrieve persistent node UUID
                        clearPhone()
                        let nodeUUID: UUID
                        if let existing = KeychainHelper.shared.getUUID() {
                            nodeUUID = existing
                            print("🔑 Existing node UUID: \(nodeUUID)")
                        } else {
                            nodeUUID = UUID()
                            let saved = KeychainHelper.shared.saveUUID(nodeUUID)
                            print("🔑 New node UUID saved: \(saved)")
                        }
                        
                        await kad.register(phone: phoneText)
                        
                        savePhone(phoneText)
                        
                        await MainActor.run {
                            isLoading = false
                            navigateToChats = true
                        }
                    }
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Register")
                        }
                    }
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.blue, in: Capsule())
                    .shadow(color: .blue.opacity(0.3), radius: 10)
                }


                Spacer().frame(height: 60)
            }
            .padding(.horizontal, 32)
            .frame(maxHeight: .infinity)
            .background(Color(.systemBackground))
            .ignoresSafeArea(.container, edges: .all)
            .navigationDestination(isPresented: $navigateToChats) {
                ChatListView()
                    .navigationBarBackButtonHidden(true)
            }
            .onAppear {
                // Already registered? Skip straight to chats
                if let saved = loadPhone() {
                    phoneText = saved
                    Task {
                        await kad.register(phone: saved)
                        navigateToChats = true
                    }
                }
            }
        }
    }

    // MARK: - Local persistence (just the phone number)
    private func savePhone(_ phone: String) {
        UserDefaults.standard.set(phone, forKey: "hopchat.phone")
    }

    private func loadPhone() -> String? {
        return UserDefaults.standard.string(forKey: "hopchat.phone")
    }
    
    private func clearPhone() {
        UserDefaults.standard.removeObject(forKey: "hopchat.phone")
    }
}

#Preview {
    GetStarted()
}
