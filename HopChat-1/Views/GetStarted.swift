import SwiftUI
import iPhoneNumberField

struct GetStarted: View {
    @StateObject private var kad = KademliaService.shared
    @State private var phoneText = ""
    @State private var isLoading = false

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

                // Status indicator
                if isLoading {
                    if kad.status == ""{
                        // Connected successfully
                        // Go to the screen of the chats
                    }
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(kad.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(action: {
                    guard !phoneText.isEmpty else { return }
                    isLoading = true
                    Task {
                        await kad.register(phone: phoneText)
                        isLoading = false
                    }
                }) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Register")
                            Image(systemName: "arrow.right")
                        }
                    }
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(phoneText.isEmpty ? .gray : .blue, in: Capsule())
                    .shadow(color: .blue.opacity(0.3), radius: 10)
                }
                .disabled(phoneText.isEmpty || isLoading)

                Spacer()
                    .frame(height: 60)
            }
            .padding(.horizontal, 32)
            .frame(maxHeight: .infinity)
            .background(Color(.systemBackground))
            .ignoresSafeArea(.container, edges: .all)
        }
    }
}

#Preview {
    GetStarted()
}
