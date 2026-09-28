//
//  KeyChangeBanner.swift
//  HopChat-1
//
//  Shown whenever `TrustStore.shared.pendingKeyChanges` contains a participant
//  of the conversation on screen. The service refuses to send in that state
//  (`ServiceError.keyChangeUnacknowledged`), so the banner is the *only* way
//  out: verify the new safety number, or accept it deliberately.
//
//  Deliberately not dismissible and deliberately loud: a silent key change is
//  exactly what an interception attempt looks like.
//

import SwiftUI

struct KeyChangeBanner: View {

    private let phone: String
    private let onVerify: () -> Void
    private let onAccept: () -> Void

    init(phone: String,
         onVerify: @escaping () -> Void,
         onAccept: @escaping () -> Void) {
        self.phone = phone
        self.onVerify = onVerify
        self.onAccept = onAccept
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Security code changed")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(Palette.warn)
            }

            Text("\(phone) may have reinstalled hoppin or switched device. Messages are blocked until you check.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    verifyButton
                    acceptButton
                }
                VStack(spacing: 10) {
                    verifyButton
                    acceptButton
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warnSoft)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Security code changed for \(phone). Sending is blocked until you verify or accept."))
    }

    private var verifyButton: some View {
        Button(action: onVerify) {
            Text("Verify")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.ink)
        .accessibilityHint(Text("Compare safety numbers with \(phone)"))
    }

    private var acceptButton: some View {
        Button(action: onAccept) {
            Text("Accept anyway")
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(Palette.ink)
        .accessibilityHint(Text("Trust the new security code without verifying"))
    }
}
