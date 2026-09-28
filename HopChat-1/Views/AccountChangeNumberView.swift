//
//  AccountChangeNumberView.swift
//  HopChat-1
//
//  Moves the account's certificate to a new phone number. Presented from
//  Settings; initialisable with no arguments.
//

import SwiftUI

struct ChangeNumberView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = KademliaService.shared

    private enum Step: Equatable {
        case explain
        case phone
        case code(phone: String, retryAfter: Int)
        case done(phone: String)
    }

    @State private var step: Step = .explain

    init() {}

    var body: some View {
        Group {
            switch step {
            case .explain:
                explanation

            case .phone:
                PhoneNumberStep(
                    title: String(localized: "New Number"),
                    explanation: String(localized: "We'll text a 6-digit code to the new number to check it's yours."),
                    submitTitle: String(localized: "Send Code"),
                    onSubmit: { raw in
                        let result = try await service.startNumberChange(newPhone: raw)
                        step = .code(phone: result.normalizedPhone, retryAfter: result.retryAfter)
                    },
                    onCancel: { step = .explain }
                )

            case .code(let phone, let retryAfter):
                VerificationCodeStep(
                    phone: phone,
                    retryAfter: retryAfter,
                    onConfirm: { code in
                        try await service.confirmNumberChange(newPhone: phone, code: code)
                        step = .done(phone: phone)
                    },
                    onResend: {
                        let result = try await service.startNumberChange(newPhone: phone)
                        return result.retryAfter
                    },
                    onBack: { step = .phone }
                )

            case .done(let phone):
                success(phone)
            }
        }
        .appBackground()
        .navigationTitle(Text("Change Number"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Explanation

    private var explanation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)

                    Text("Change Your Number")
                        .hopTitle()
                }

                if !service.myPhone.isEmpty {
                    Label {
                        Text("Currently \(service.myPhone)")
                    } icon: {
                        Image(systemName: "phone.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    ChangeNumberPoint(
                        icon: "checkmark.seal.fill",
                        title: Text("Your chats and keys move with you"),
                        detail: Text("Your messages, contacts and encryption keys stay exactly as they are. Only the number on your certificate changes."))
                    ChangeNumberPoint(
                        icon: "paperplane.fill",
                        title: Text("Your contacts are told automatically"),
                        detail: Text("hoppin sends each of your contacts a signed notice so their app follows you to the new number without a security warning."))
                    ChangeNumberPoint(
                        icon: "xmark.circle.fill",
                        title: Text("The old number stops working"),
                        detail: Text("Messages sent to your old number after the change will not reach you, and someone else can verify that number later."))
                }

                Button {
                    step = .phone
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.ink)
                .disabled(!service.isRegistered)

                if !service.isRegistered {
                    Text("Verify a number first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Success

    private func success(_ phone: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("You're on \(phone)")
                .hopTitle(.title2)
                .multilineTextAlignment(.center)
            Text("Your contacts have been notified. Your old number no longer reaches this device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.ink)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        // The tab bar would sit on top of "Done", and there is nowhere else
        // to go from here anyway.
        .toolbar(.hidden, for: .tabBar)
    }
}

private struct ChangeNumberPoint: View {
    let icon: String
    let title: Text
    let detail: Text

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                title.font(.headline)
                detail.font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { ChangeNumberView() }
}
