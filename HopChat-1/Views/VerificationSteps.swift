//
//  VerificationSteps.swift
//  HopChat-1
//
//  The two reusable halves of every SMS flow (first registration and number
//  change): "enter a phone number" and "enter the 6-digit code".
//
//  Both steps are dumb: they collect input, show progress and render errors.
//  The caller supplies the async work, so `VerificationView` and
//  `ChangeNumberView` share the exact same screens.
//

import SwiftUI
import os

// MARK: - Error copy

nonisolated enum VerificationErrorText {

    /// Turns a thrown `ServiceError` / `ServerError` into something a person
    /// can act on. Unknown server codes fall through to the server's own text.
    static func text(for error: Error) -> String {
        if let service = error as? ServiceError {
            switch service {
            case .invalidPhone:
                return String(localized: "That doesn't look like a valid phone number. Include the country code, like +351 912 345 678.")
            case .unavailable:
                return String(localized: "No connection to hoppin. Check your internet and try again.")
            case .offline, .serverDown, .untrustedServer, .notConfigured:
                return service.errorDescription ?? String(localized: "Something went wrong.")
            case .notRegistered, .notOnhoppin:
                return String(localized: "That number isn't verified yet. Request a new code and try again.")
            case .blocked:
                return String(localized: "This number can't be verified right now.")
            case .suspended:
                return service.errorDescription ?? String(localized: "Something went wrong.")
            case .server(let message):
                return serverText(message)
            case .keyChangeUnacknowledged, .tooManyMembers:
                return service.errorDescription ?? String(localized: "Something went wrong.")
            }
        }
        if let server = error as? ServerError {
            switch server {
            case .server("suspended", _):
                return ServiceError.suspended.errorDescription ?? ""
            case .server(let code, let message):
                return serverText(message.isEmpty ? code : message)
            case .timeout, .transport:
                return String(localized: "No connection to hoppin. Check your internet and try again.")
            case .offline:
                return ServiceError.offline.errorDescription ?? ""
            case .refused:
                return ServiceError.serverDown.errorDescription ?? ""
            case .untrustedServer:
                return ServiceError.untrustedServer.errorDescription ?? ""
            case .notConfigured:
                return ServiceError.notConfigured.errorDescription ?? ""
            case .badServerSignature:
                return String(localized: "The server's reply couldn't be verified. Try again later.")
            case .badResponse:
                return String(localized: "Unexpected reply from the server. Try again.")
            }
        }
        return error.localizedDescription
    }

    private static func serverText(_ raw: String) -> String {
        let lower = raw.lowercased()

        if lower.contains("server key not configured") {
            return "This build has no pinned server key, so it can't verify anything. (Developer: set hoppin.dev.serverKey or ship AppConfig.serverSigningKeyBase64.)"
        }
        if lower.contains("rate_limited") || lower.contains("rate limited") || lower.contains("too many requests") {
            if let seconds = firstInteger(in: raw) {
                return String(localized: "Too many attempts. Try again in \(wait(seconds)).")
            }
            return String(localized: "Too many attempts. Wait a few minutes and try again.")
        }
        if lower.contains("too_many_attempts") || lower.contains("too many attempts") {
            return String(localized: "Too many wrong codes. Request a new code to start over.")
        }
        if lower.contains("code_expired") || lower.contains("expired") {
            return String(localized: "That code has expired. Request a new one.")
        }
        if lower.contains("invalid_code") || lower.contains("invalid code") {
            return String(localized: "That code isn't right. Check the SMS and try again.")
        }
        if lower.contains("invalid_phone") {
            return String(localized: "That doesn't look like a valid phone number. Include the country code.")
        }
        if lower.contains("not_registered") {
            return String(localized: "That number isn't verified yet. Request a new code and try again.")
        }
        if lower.contains("internal") || raw.isEmpty {
            return String(localized: "The server had a problem. Try again in a moment.")
        }
        return raw
    }

    private static func wait(_ seconds: Int) -> String {
        if seconds < 60 { return String(localized: "\(seconds) seconds") }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        return String(localized: "\(minutes) minutes")
    }

    private static func firstInteger(in s: String) -> Int? {
        var digits = ""
        for ch in s where ch.isASCII {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return Int(digits)
    }
}

// MARK: - Phone step

/// Collects a phone number, previews the normalized E.164 form, and hands the
/// raw text to `onSubmit`.
struct PhoneNumberStep: View {

    let title: String
    let explanation: String
    var prefill: String = ""
    var submitTitle: String = String(localized: "Send Code")
    /// Returns the normalized phone and the seconds until a resend is allowed.
    let onSubmit: (String) async throws -> Void
    var onCancel: (() -> Void)? = nil

    @State private var raw = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var normalized: String? { PhoneNumber.normalize(raw) }
    private var canSubmit: Bool { normalized != nil && !isWorking }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "phone.badge.checkmark")
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)

                    Text(title)
                        .hopTitle()

                    Text(explanation)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Phone number")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("+351 912 345 678", text: $raw)
                        .font(.title3)
                        // The phone pad hides "+" behind a long-press on 0 (and
                        // hardware keyboards type it as "*"), which made
                        // international numbers impossible to enter.
                        .keyboardType(.numbersAndPunctuation)
                        .textContentType(.telephoneNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: raw) { _, new in
                            let clean = PhoneNumber.sanitizeInput(new)
                            if clean != new { raw = clean }
                        }
                        .focused($focused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Palette.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Palette.hairlineStrong, lineWidth: 1)
                        )
                        .accessibilityLabel(Text("Phone number, including country code"))
                        .accessibilityIdentifier("verification.phoneField")
                        .onSubmit { submit() }

                    if let normalized {
                        Label {
                            Text("We'll verify \(normalized)")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else if !raw.isEmpty {
                        Label {
                            Text("Add your country code, like +351 or +1.")
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill")
                        }
                        .font(.footnote)
                        .foregroundStyle(Palette.warn)
                    }
                }

                if let errorText {
                    ErrorNotice(text: errorText)
                }

                Button {
                    submit()
                } label: {
                    Group {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text(submitTitle).font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.ink)
                .disabled(!canSubmit)
                .accessibilityIdentifier("verification.submit")

                if let onCancel {
                    Button(role: .cancel) {
                        onCancel()
                    } label: {
                        Text("Cancel").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Text("Your number is sent to the hoppin server so it can text you a code and issue your certificate. It is never shared with other services.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if raw.isEmpty, !prefill.isEmpty { raw = prefill }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focused = false
        errorText = nil
        isWorking = true
        Task {
            do {
                try await onSubmit(raw)
            } catch {
                errorText = VerificationErrorText.text(for: error)
                Log.ui.error("Verification request failed: \(String(describing: error), privacy: .public)")
            }
            isWorking = false
        }
    }
}

// MARK: - Code step

/// Six-digit OTP entry with auto-submit, a resend countdown and a way back.
struct VerificationCodeStep: View {

    let phone: String
    var retryAfter: Int
    let onConfirm: (String) async throws -> Void
    /// Returns a fresh `retryAfter`.
    let onResend: () async throws -> Int
    let onBack: () -> Void

    @State private var code = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var remaining = 0
    @State private var countdownToken = 0
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)

                    Text("Enter Your Code")
                        .hopTitle()

                    Text("We sent a 6-digit code by SMS to \(phone). It expires in 10 minutes.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("000000", text: $code)
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .tracking(8)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Palette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Palette.hairlineStrong, lineWidth: 1)
                    )
                    .accessibilityLabel(Text("Six digit verification code"))
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                        if digits.count == 6, !isWorking { confirm() }
                    }

                if let errorText {
                    ErrorNotice(text: errorText)
                }

                Button {
                    confirm()
                } label: {
                    Group {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text("Verify").font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.ink)
                .disabled(code.count != 6 || isWorking)

                HStack {
                    if remaining > 0 {
                        Text("Resend in \(remaining)s")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .accessibilityLabel(Text("You can request a new code in \(remaining) seconds"))
                    } else {
                        Button {
                            resend()
                        } label: {
                            Text("Send a new code")
                                .font(.subheadline)
                                .frame(minHeight: 44)
                        }
                        .disabled(isWorking)
                    }

                    Spacer()

                    Button {
                        onBack()
                    } label: {
                        Text("Wrong number?")
                            .font(.subheadline)
                            .frame(minHeight: 44)
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            focused = true
            if remaining == 0 { startCountdown(retryAfter) }
        }
        .task(id: countdownToken) {
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
            }
        }
    }

    private func startCountdown(_ seconds: Int) {
        remaining = max(0, seconds)
        countdownToken += 1
    }

    private func confirm() {
        guard code.count == 6, !isWorking else { return }
        focused = false
        errorText = nil
        isWorking = true
        let entered = code
        Task {
            do {
                try await onConfirm(entered)
            } catch {
                errorText = VerificationErrorText.text(for: error)
                code = ""
                Log.ui.error("Code confirmation failed: \(String(describing: error), privacy: .public)")
            }
            isWorking = false
        }
    }

    private func resend() {
        guard !isWorking else { return }
        errorText = nil
        isWorking = true
        Task {
            do {
                let next = try await onResend()
                startCountdown(next)
                code = ""
                focused = true
            } catch {
                errorText = VerificationErrorText.text(for: error)
            }
            isWorking = false
        }
    }
}

// MARK: - Shared error notice

struct ErrorNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
