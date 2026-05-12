//
//  TranslationBridgeView.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 26/02/2026.
//
//  Invisible 0×0 view that owns the TranslationSession lifecycle.
//  Embed once at the root of the view hierarchy.
//

import SwiftUI
import Translation

struct TranslationBridgeView: View {
    @ObservedObject private var service = TranslationService.shared

    // Current session + the config it was created for.
    @State private var config: TranslationSession.Configuration?
    @State private var readySession: TranslationSession?
    @State private var readyConfig:  TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: service.pendingRequest?.id) { _, _ in
                processNext()
            }
            .translationTask(config) { session in
                readySession = session
                readyConfig  = config
                await processWithSession(session)
            }
    }

    // MARK: - Private

    private func processNext() {
        guard let req = service.pendingRequest else { return }
        let needed = TranslationSession.Configuration(
            source: nil,
            target: Locale.Language(identifier: req.targetLang)
        )
        if let session = readySession, readyConfig == needed {
            // Reuse existing session for the same language pair.
            Task { await processWithSession(session) }
        } else {
            // Trigger .translationTask to obtain a new session.
            config = needed
        }
    }

    private func processWithSession(_ session: TranslationSession) async {
        guard let req = service.pendingRequest else { return }
        do {
            let response = try await session.translate(req.text)
            service.complete(request: req, result: response.targetText)
        } catch {
            print("🌐 Translation error: \(error)")
            service.complete(request: req, result: nil)
        }
    }
}
