//
//  SafetyNumberView.swift
//  HopChat-1
//
//  Safety-number comparison: 60 digits in 12 groups of 5, a QR code carrying our
//  own identity, and a scanner for theirs. Design Contract §7.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import os

struct SafetyNumberView: View {

    let contact: Contact
    /// Verify a specific key instead of the pinned one (used while resolving a
    /// key change, where the *new* key is the one under review).
    var theirSigningKey: String? = nil

    @StateObject private var kad   = KademliaService.shared
    @StateObject private var trust = TrustStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var digits: String?
    @State private var isComputing = false
    @State private var showScanner = false
    @State private var scanOutcome: ScanOutcome?
    @State private var confirmManual = false

    private enum ScanOutcome: Equatable {
        case match
        case mismatch
        case unreadable
    }

    private var resolvedKey: String? {
        theirSigningKey ?? trust.pinnedSigningKey(for: contact.phone)
    }

    private var isVerified: Bool { trust.isVerified(contact.phone) }

    var body: some View {
        List {
            Section {
                Text("A safety number is a code shared only by the two of you. If it matches on both phones, nobody is reading your messages in the middle. It changes when one of you reinstalls hoppin or switches phone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let digits {
                Section {
                    Text(TrustStore.formattedSafetyNumber(digits))
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                        .accessibilityLabel(Text(spokenSafetyNumber(digits)))
                    qrCode
                } header: {
                    Text("Safety number with \(contact.displayName)")
                } footer: {
                    Text("Compare these digits with the ones on their phone, or scan their code.")
                }
            } else if isComputing {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Calculating safety number…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No key for this contact yet")
                            .font(.headline)
                        Text("hoppin needs their encryption key before a safety number exists. Send them a message, or refresh below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Refresh Key") {
                            Task {
                                await kad.refreshCertificate(for: contact.phone)
                                await compute()
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let scanOutcome {
                Section { outcomeView(scanOutcome) }
            }

            Section {
                Button {
                    scanOutcome = nil
                    showScanner = true
                } label: {
                    Label("Scan Their Code", systemImage: "qrcode.viewfinder")
                        .frame(minHeight: 44)
                }
                .disabled(resolvedKey == nil)

                Button {
                    confirmManual = true
                } label: {
                    Label("Mark as Verified Manually", systemImage: "checkmark.shield")
                        .frame(minHeight: 44)
                }
                .disabled(digits == nil || isVerified)

                if isVerified {
                    Button(role: .destructive) {
                        trust.setVerified(contact.phone, false)
                        scanOutcome = nil
                        Log.ui.notice("verification cleared")
                    } label: {
                        Label("Clear Verification", systemImage: "xmark.shield")
                            .frame(minHeight: 44)
                    }
                }
            } header: {
                Text("Verification")
            } footer: {
                Text(isVerified
                     ? "Marked as verified. Clearing this does not delete any messages."
                     : "Only mark this as verified once you have compared every digit, or scanned their code.")
            }
        }
        .appBackground()
        .navigationTitle("Safety Number")
        .navigationBarTitleDisplayMode(.inline)
        .task { await compute() }
        .sheet(isPresented: $showScanner) {
            QRScannerView { value in
                handleScan(value)
            }
        }
        .confirmationDialog("Mark \(contact.displayName) as verified?",
                            isPresented: $confirmManual,
                            titleVisibility: .visible) {
            Button("Mark as Verified") {
                trust.setVerified(contact.phone, true)
                scanOutcome = nil
                Log.ui.notice("verified manually")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do this only if you read all 60 digits aloud together and every one matched.")
        }
    }

    // MARK: - QR

    private var qrCode: some View {
        VStack(spacing: 8) {
            if let image = qrImage {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .padding(12)
                    // Always light behind the code so scanners cope in dark mode.
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(Text("Your verification QR code. Ask your contact to scan it."))
            }
            Text("Let them scan your code")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var qrImage: Image? {
        let myKey = CryptoManager.shared.signingPublicKeyBase64
        guard !kad.myPhone.isEmpty, !myKey.isEmpty else { return nil }
        let payload = TrustStore.qrString(phone: kad.myPhone, signingKey: myKey)
        guard let cg = Self.makeQR(payload) else { return nil }
        return Image(decorative: cg, scale: 1, orientation: .up)
    }

    /// High-correction QR, scaled up before rasterizing so it stays crisp.
    nonisolated static func makeQR(_ string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    // MARK: - Outcome

    @ViewBuilder
    private func outcomeView(_ outcome: ScanOutcome) -> some View {
        switch outcome {
        case .match:
            VStack(alignment: .leading, spacing: 6) {
                Label("Verified", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                Text("The codes match. Your conversation with \(contact.displayName) is end-to-end encrypted and nobody is in the middle.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

        case .mismatch:
            VStack(alignment: .leading, spacing: 6) {
                Label("Codes do not match", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("This can mean your conversation is being intercepted, or simply that one of you is looking at a different contact or an out-of-date screen. Don't send anything sensitive. Close and reopen this screen on both phones and scan again; if it still doesn't match, contact them another way before continuing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

        case .unreadable:
            VStack(alignment: .leading, spacing: 6) {
                Label("That isn't a hoppin code", systemImage: "questionmark.circle")
                    .font(.headline)
                Text("Ask them to open this same screen in hoppin and show their code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func handleScan(_ value: String) {
        guard let parsed = TrustStore.parseQR(value) else {
            scanOutcome = .unreadable
            return
        }
        guard let expected = resolvedKey else {
            scanOutcome = .unreadable
            return
        }
        if parsed.phone == contact.phone && parsed.signingKey == expected {
            trust.setVerified(contact.phone, true)
            scanOutcome = .match
            Log.ui.notice("safety number verified by scan")
        } else {
            scanOutcome = .mismatch
            Log.ui.error("safety number scan mismatch")
        }
    }

    // MARK: - Digits

    private func compute() async {
        guard digits == nil, !isComputing else { return }
        let myPhone = kad.myPhone
        let myKey = CryptoManager.shared.signingPublicKeyBase64
        guard !myPhone.isEmpty, !myKey.isEmpty, let theirKey = resolvedKey else { return }
        let theirPhone = contact.phone

        isComputing = true
        // ~10 400 SHA-512 rounds — never on the main thread.
        let value = await Task.detached(priority: .userInitiated) {
            TrustStore.safetyNumber(myPhone: myPhone, myKey: myKey,
                                    theirPhone: theirPhone, theirKey: theirKey)
        }.value
        digits = value
        isComputing = false
    }

    /// "12345 67890" → "1 2 3 4 5, 6 7 8 9 0, …" so VoiceOver reads group by group.
    private func spokenSafetyNumber(_ digits: String) -> String {
        TrustStore.formattedSafetyNumber(digits)
            .split(separator: " ")
            .map { spacedDigits(String($0)) }
            .joined(separator: ", ")
    }
}
