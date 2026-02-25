import SwiftUI

struct ContentView: View {
    @State private var pulse: CGFloat = 1.0
    
    var body: some View {
        NavigationStack{
            VStack(spacing: 40) {
                Spacer()
                
                // Central WiFi icon with glow
                ZStack {
                    Image(systemName: "wifi")
                        .font(.system(size: 80))
                        .foregroundStyle(.blue)
                        .scaleEffect(pulse)
                        .shadow(color: .blue.opacity(0.4), radius: 20, x: 0, y: 10)
                }
                
                Text("HopChat")
                    .font(.largeTitle.weight(.bold))
                    .fontDesign(.default)
                
                Text("Peer-to-peer WiFi chat,\nno servers needed")
                    .font(.title2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                NavigationLink("Get Started") {
                    GetStarted()
                }
                .font(.title2.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(.blue, in: Capsule())
                .shadow(color: .blue.opacity(0.3), radius: 10)
                
                Spacer()
                    .frame(height: 60)
            }
            .padding(.horizontal, 32)
            .frame(maxHeight: .infinity)
            .background(Color(.systemBackground))  // White/light mode
            .ignoresSafeArea(.container, edges: .all)

            .clipped()  // Keeps rotation subtle around icon
            }
        }

}

#Preview {
    ContentView()
}
