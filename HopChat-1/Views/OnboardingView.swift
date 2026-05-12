//
//  OnboardingView.swift
//  HopChat-1
//
//  First-launch tutorial explaining the P2P / DHT model.
//  Shown once; suppressed on subsequent launches via hopchat.hasSeenOnboarding.
//

import SwiftUI

// MARK: - Data

private struct Slide: Identifiable {
    let id:          Int
    let icon:        String
    let color:       Color
    let title:       String
    let body:        String
}

private let slides: [Slide] = [
    Slide(
        id: 0,
        icon: "wifi",
        color: .blue,
        title: "Welcome to HopChat",
        body: "Direct messaging that runs entirely on your local network, no cloud, no servers, no accounts required."
    ),
    Slide(
        id: 1,
        icon: "server.rack",
        color: .purple,
        title: "No Server in the Middle",
        body: "Most apps route your messages through a company's servers. HopChat connects you directly to the people on your WiFi. Your messages never leave the local network."
    ),
    Slide(
        id: 2,
        icon: "point.3.connected.trianglepath.dotted",
        color: .orange,
        title: "A Network That Finds Itself",
        body: "HopChat uses a Distributed Hash Table (DHT), the same idea behind BitTorrent. Every device holds a slice of a shared contact directory. Lookups hop across devices until the right person is found, with no central coordinator."
    ),
    Slide(
        id: 3,
        icon: "lock.shield.fill",
        color: .green,
        title: "Private by Design",
        body: "Every message is end-to-end encrypted with Curve25519. No sign-ups, no ads, nothing stored in the cloud. Your conversations exist only on the devices that exchanged them."
    ),
]

// MARK: - Main View

struct OnboardingView: View {
    @Binding var hasSeenOnboarding: Bool
    @State private var page = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground).ignoresSafeArea()

            // Slide carousel
            TabView(selection: $page) {
                ForEach(slides) { slide in
                    SlideView(slide: slide)
                        .tag(slide.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            // Tint the page dots to match the current slide colour
            .onAppear { UIPageControl.appearance().currentPageIndicatorTintColor = UIColor(slides[page].color) }
            .onChange(of: page) { _, new in
                UIPageControl.appearance().currentPageIndicatorTintColor = UIColor(slides[new].color)
            }

            // Bottom actions
            VStack(spacing: 14) {
                if page == slides.count - 1 {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            hasSeenOnboarding = true
                        }
                    } label: {
                        Text("Get Started")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(slides[page].color)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                } else {
                    Button {
                        withAnimation { page += 1 }
                    } label: {
                        Text("Next")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(slides[page].color)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Button("Skip") { hasSeenOnboarding = true }
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 52)
            .animation(.easeInOut(duration: 0.2), value: page)
        }
    }
}

// MARK: - Single Slide

private struct SlideView: View {
    let slide: Slide
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon bubble
            ZStack {
                Circle()
                    .fill(slide.color.opacity(0.12))
                    .frame(width: 140, height: 140)

                Circle()
                    .fill(slide.color.opacity(0.18))
                    .frame(width: 108, height: 108)

                Image(systemName: slide.icon)
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(slide.color)
            }
            .scaleEffect(appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.05), value: appeared)

            Spacer().frame(height: 40)

            // Text
            VStack(spacing: 14) {
                Text(slide.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                Text(slide.body)
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)

            Spacer()
        }
        .onAppear {
            appeared = false
            // Small delay so the animation plays even when swiping quickly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                appeared = true
            }
        }
        .onDisappear { appeared = false }
    }
}

#Preview {
    OnboardingView(hasSeenOnboarding: .constant(false))
}
