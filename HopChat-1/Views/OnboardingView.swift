//
//  OnboardingView.swift
//  HopChat-1
//
//  First-launch story + the Terms/Privacy gate.
//
//  The v1 copy claimed "messages never leave the local network" and "no
//  sign-ups". Neither is true in v2: there is an SMS verification step and an
//  encrypted store-and-forward relay. This screen says so plainly — App Review
//  and users both deserve the accurate version.
//

import SwiftUI
import os

// MARK: - Slides

private struct OnboardingSlide: Identifiable {
    let id: Int
    let icon: String
    let color: Color
    let title: String
    let body: String
}

private let onboardingSlides: [OnboardingSlide] = [
    OnboardingSlide(
        id: 0,
        icon: "hand.wave.fill",
        color: .blue,
        title: String(localized: "Welcome to hoppin"),
        body: String(localized: "Private messaging for the people you actually know. Set-up takes one SMS and about a minute.")
    ),
    OnboardingSlide(
        id: 1,
        icon: "checkmark.message.fill",
        color: .indigo,
        title: String(localized: "Verify Your Number Once"),
        body: String(localized: "We text a 6-digit code to your phone number so people can find you and nobody can pretend to be you. Your number is sent to the hoppin server only for that check.")
    ),
    OnboardingSlide(
        id: 2,
        icon: "lock.shield.fill",
        color: .green,
        title: String(localized: "Encrypted End to End"),
        body: String(localized: "Every message is encrypted and signed on your device before it leaves. Only the people in the conversation hold the keys that open it.")
    ),
    OnboardingSlide(
        id: 3,
        icon: "arrow.triangle.branch",
        color: .orange,
        title: String(localized: "Two Ways to Arrive"),
        body: String(localized: "On the same Wi-Fi, messages hop straight from device to device. Otherwise a relay holds them sealed until you pick them up, and the people running it cannot read them.")
    ),
    OnboardingSlide(
        id: 4,
        icon: "number.square.fill",
        color: .purple,
        title: String(localized: "Check Your Contacts"),
        body: String(localized: "Each chat has a safety number you can compare in person or by QR code. If a contact's keys ever change, hoppin warns you before you send anything.")
    ),
    OnboardingSlide(
        id: 5,
        icon: "iphone.and.arrow.forward",
        color: .teal,
        title: String(localized: "Stays on Your Device"),
        body: String(localized: "Messages, photos and contacts live on your iPhone. Nothing readable is kept off it, and deleting your account wipes all of it.")
    ),
]

// MARK: - Onboarding

struct OnboardingView: View {

    @AppStorage(AppConfig.Keys.hasSeenOnboarding) private var hasSeenOnboarding = false
    @AppStorage(AppConfig.Keys.hasAcceptedTerms) private var hasAcceptedTerms = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page = 0

    /// Index of the terms page, which always comes last.
    private var termsPage: Int { onboardingSlides.count }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(onboardingSlides) { slide in
                    OnboardingSlideView(slide: slide, reduceMotion: reduceMotion)
                        .tag(slide.id)
                }
                TermsPage(onAccept: finish)
                    .tag(termsPage)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))

            if page < termsPage {
                VStack(spacing: 12) {
                    Button {
                        advance()
                    } label: {
                        Text("Next")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding.next")

                    Button {
                        withAnimation { page = termsPage }
                    } label: {
                        Text("Skip")
                            .font(.subheadline)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.skip")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: 700)
            }
        }
        .background(Color(.systemBackground))
        .frame(maxWidth: .infinity)
    }

    private func advance() {
        let next = min(page + 1, termsPage)
        if reduceMotion {
            page = next
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { page = next }
        }
    }

    private func finish() {
        hasAcceptedTerms = true
        hasSeenOnboarding = true
        Log.ui.info("Onboarding completed and terms accepted")
    }
}

// MARK: - Slide

private struct OnboardingSlideView: View {
    let slide: OnboardingSlide
    let reduceMotion: Bool

    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)

                ZStack {
                    Circle()
                        .fill(slide.color.opacity(0.14))
                        .frame(width: 148, height: 148)
                    Image(systemName: slide.icon)
                        .font(.system(size: 54, weight: .medium))
                        .foregroundStyle(slide.color)
                        .accessibilityHidden(true)
                }
                .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.7))
                .opacity(appeared || reduceMotion ? 1 : 0)
                .accessibilityHidden(true)

                VStack(spacing: 14) {
                    Text(slide.title)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)

                    Text(slide.body)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)
                .accessibilityElement(children: .combine)

                Spacer(minLength: 48)
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
        }
        .onDisappear { appeared = reduceMotion }
    }
}

// MARK: - Terms page

private struct TermsPage: View {

    let onAccept: () -> Void

    @State private var agreed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "doc.text.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)

                    Text("Before You Start")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                }

                Text("hoppin has a zero-tolerance policy for abusive content and abusive users. Anything you send is your responsibility.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 14) {
                    TermsPoint(icon: "flag.fill",
                               text: Text("You can report a message or a contact from any chat. Reports are reviewed and accounts can be removed."))
                    TermsPoint(icon: "hand.raised.fill",
                               text: Text("You can block anyone. A blocked contact cannot reach you again."))
                    TermsPoint(icon: "person.badge.shield.checkmark.fill",
                               text: Text("Harassment, threats, and illegal or abusive content are not allowed and there is no appeal for the worst of them."))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Link(destination: AppConfig.termsURL) {
                        Label("Terms of Service (EULA)", systemImage: "arrow.up.right.square")
                            .font(.body)
                            .frame(minHeight: 44)
                    }
                    Link(destination: AppConfig.privacyURL) {
                        Label("Privacy Policy", systemImage: "arrow.up.right.square")
                            .font(.body)
                            .frame(minHeight: 44)
                    }
                }

                Toggle(isOn: $agreed) {
                    Text("I have read and agree to the Terms of Service and the Privacy Policy, and I accept the zero-tolerance policy for abusive content.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .padding(.vertical, 4)
                .accessibilityIdentifier("onboarding.termsToggle")

                Button {
                    onAccept()
                } label: {
                    Text("Agree and Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!agreed)
                .accessibilityIdentifier("onboarding.agree")

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct TermsPoint: View {
    let icon: String
    let text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            text
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview { OnboardingView() }
#Preview("Dark") { OnboardingView().preferredColorScheme(.dark) }
