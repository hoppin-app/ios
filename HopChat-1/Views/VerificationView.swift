//
//  VerificationView.swift
//  HopChat-1
//
//  SMS verification — the v2 replacement for "type any phone number and you're
//  registered". Nothing works until the server has issued a certificate for a
//  number the user proved they control.
//

import SwiftUI

struct VerificationView: View {

    @EnvironmentObject private var service: KademliaService

    private enum Step: Equatable {
        case phone
        case code(phone: String, retryAfter: Int)
    }

    @State private var step: Step = .phone
    @State private var prefill = ""
    #if DEBUG
    @State private var showDeveloper = false
    #endif

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .phone:
                    PhoneNumberStep(
                        title: String(localized: "Verify Your Number"),
                        explanation: String(localized: "hoppin texts you a 6-digit code. This is the only time you need it — it proves the number is yours so nobody else can claim it."),
                        prefill: prefill,
                        submitTitle: String(localized: "Send Code"),
                        onSubmit: { raw in
                            let result = try await service.requestVerificationCode(phone: raw)
                            step = .code(phone: result.normalizedPhone,
                                         retryAfter: result.retryAfter)
                        }
                    )

                case .code(let phone, let retryAfter):
                    VerificationCodeStep(
                        phone: phone,
                        retryAfter: retryAfter,
                        onConfirm: { code in
                            try await service.confirmVerification(phone: phone, code: code)
                            await NotificationService.shared.requestPermission()
                        },
                        onResend: {
                            let result = try await service.requestVerificationCode(phone: phone)
                            return result.retryAfter
                        },
                        onBack: {
                            prefill = phone
                            step = .phone
                        }
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDeveloper = true
                    } label: {
                        Image(systemName: "hammer")
                    }
                    .accessibilityLabel(Text(verbatim: "Developer settings"))
                }
            }
            .sheet(isPresented: $showDeveloper, onDismiss: {
                Task { await service.reconnect() }
            }) {
                NavigationStack {
                    SettingsDeveloperView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button { showDeveloper = false } label: { Text(verbatim: "Done") }
                            }
                        }
                }
            }
            #endif
        }
        .onAppear {
            if prefill.isEmpty, let hint = service.legacyPhoneHint {
                prefill = hint
            }
        }
        .safeAreaInset(edge: .bottom) {
            if service.legacyPhoneHint != nil, step == .phone {
                Text("hoppin now verifies numbers by SMS. Your old number is filled in — verify it once to keep using it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .frame(maxWidth: 700)
            }
        }
    }
}

#Preview {
    VerificationView().environmentObject(KademliaService.shared)
}
