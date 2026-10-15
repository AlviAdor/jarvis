import Foundation
import NaturalLanguage
import AVFoundation

/// Working out which language text is in, and which voice can speak it.
public enum Language {
    /// The language of a piece of text as a BCP-47 code ("en", "bn", "hi", "ar"...), or nil if it's too short to tell.
    public static func detect(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(t)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.5 else { return nil }
        return lang.rawValue
    }

    public static func isEnglish(_ text: String) -> Bool { (detect(text) ?? "en").hasPrefix("en") }

    /// The display name of a language in English ("Bengali", "Hindi").
    public static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// The best installed Mac voice for a language: Personal and Premium first, then Enhanced, then any.
    public static func voice(for code: String, preferred: String = "") -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix(code.lowercased()) }
        if let p = all.first(where: { $0.identifier == preferred }) { return p }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            if v.voiceTraits.contains(.isPersonalVoice) { return 0 }
            switch v.quality {
            case .premium: return 1
            case .enhanced: return 2
            default: return 3
            }
        }
        return all.min { rank($0) < rank($1) }
    }

    /// Splits "Heard: …" off the start of an answer to a spoken request.
    public static func splitHeard(_ answer: String) -> (heard: String?, rest: String) {
        let t = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              first.lowercased().hasPrefix("heard:") else { return (nil, t) }
        let heard = first.dropFirst("heard:".count).trimmingCharacters(in: .whitespaces)
        let rest = t.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (heard.isEmpty ? nil : heard, rest)
    }
}
