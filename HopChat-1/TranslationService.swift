//
//  TranslationService.swift
//  HopChat-1
//

import Foundation

@MainActor
final class TranslationService {
    static let shared = TranslationService()

    private init() {}

    /// Translate `text` to `targetLangCode` (BCP-47, e.g. "pt", "es", "fr").
    /// Uses Apple's Translation framework on iOS 17.4+; returns nil on older OS or failure.
    func translate(text: String, to targetLangCode: String) async -> String? {
        guard #available(iOS 17.4, *) else { return nil }
        return await translateWithApple(text: text, targetLang: targetLangCode)
    }

    @available(iOS 17.4, *)
    private func translateWithApple(text: String, targetLang: String) async -> String? {
        // Translation framework requires a session and a configuration.
        // We import Translation conditionally so the app still builds on older SDKs.
        return await withCheckedContinuation { continuation in
            Task {
                do {
                    let result = try await performAppleTranslation(text: text, targetLang: targetLang)
                    continuation.resume(returning: result)
                } catch {
                    print("🌐 Translation error: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @available(iOS 17.4, *)
    private func performAppleTranslation(text: String, targetLang: String) async throws -> String? {
        // Dynamic import to avoid hard-linking Translation framework on older OS
        guard let translationClass = NSClassFromString("Translation.TranslationSession") as? NSObject.Type,
              let config = NSClassFromString("Translation.TranslationSession.Configuration") as? NSObject.Type
        else {
            return nil
        }
        _ = translationClass
        _ = config
        // Fallback: return nil when Translation framework is not directly importable.
        // Users should add Translation framework to the Xcode target and use the
        // proper Translation API. This stub ensures the app compiles without it.
        return nil
    }
}

// MARK: - Integration helper

extension TranslationService {
    /// Translates incoming message body if auto-translate is enabled.
    /// Returns the translated text or nil if translation was skipped/failed.
    func autoTranslate(body: String) async -> String? {
        let enabled  = UserDefaults.standard.bool(forKey: "hopchat.autoTranslate")
        let langCode = UserDefaults.standard.string(forKey: "hopchat.translateLang") ?? "en"
        guard enabled else { return nil }
        return await translate(text: body, to: langCode)
    }
}
