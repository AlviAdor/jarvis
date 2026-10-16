import Foundation
import CryptoKit
import Speech

/// Helping the recogniser hear what people actually say to Jarvis: the names and words that matter to this
/// user, a small language model of typical requests, and fixes for words it reliably mishears.
public enum Hearing {
    // MARK: Words to lean towards

    /// Names and words from what the user told Jarvis about themselves ("AIUB", "Dhaka", "Figma").
    public static func profileWords(_ s: JarvisSettings) -> [String] {
        let text = ([s.aboutWork, s.aboutPlace, s.aboutNotes] + s.aboutFocus).joined(separator: " ")
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }).map(String.init)
        let common: Set<String> = ["I", "I'm", "My", "The", "A", "An", "And", "At", "In", "On", "Of", "For", "To", "With", "From", "Based", "Student", "Working"]
        return unique(tokens.filter { t in
            guard t.count >= 3, !common.contains(t), let f = t.first else { return false }
            return f.isUppercase || t.contains(where: \.isNumber)
        })
    }

    /// The places the user mentioned ("Dhaka, Bangladesh" → Dhaka, Bangladesh).
    public static func places(_ s: JarvisSettings) -> [String] {
        unique(s.aboutPlace.split(whereSeparator: { ",;/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static let assistants = ["ChatGPT", "Claude", "Gemini", "Grok", "Perplexity", "Copilot"]
    static let common = ["GitHub", "git commit", "git push", "git pull", "pull request", "Spotify", "AirPods", "lofi", "Wi-Fi", "Bluetooth"]

    /// Phrases recognition should favour; Apple suggests keeping it to about a hundred.
    public static func contextualStrings(wakeWord: String, settings s: JarvisSettings, apps: [String] = []) -> [String] {
        let first = s.userName.split(separator: " ").first.map(String.init) ?? ""
        var out: [String] = ["Jarvis", "Hey Jarvis", wakeWord.capitalized, "Hey " + wakeWord.capitalized, s.userName, first]
        out += places(s)
        out += profileWords(s)
        out += s.heardWords
        out += assistants
        out += common
        out += apps
        return Array(unique(out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).prefix(100))
    }

    // MARK: A language model of Jarvis requests

    /// The training data: typical requests, with this user's names, places, apps and learned words slotted in.
    static func modelData(locale: Locale, names: [String], places: [String], apps: [String], words: [String]) -> SFCustomLanguageModelData {
        let data = SFCustomLanguageModelData(locale: locale, identifier: "app.jarvis.requests", version: "1")
        let gen = SFCustomLanguageModelData.TemplatePhraseCountGenerator()
        let cities = ["Dhaka", "Chittagong", "Sylhet", "London", "New York", "Delhi", "Kolkata", "Dubai", "Singapore", "Tokyo", "Paris", "Toronto"]
        gen.define(className: "app", values: unique(apps + ["Spotify", "Safari", "Chrome", "Mail", "Messages", "Notes", "Calendar", "Finder", "Xcode", "Terminal", "Music", "Photos", "System Settings"]))
        gen.define(className: "ai", values: assistants)
        gen.define(className: "place", values: unique(places + cities))
        gen.define(className: "name", values: names.isEmpty ? ["Mum"] : names)
        gen.define(className: "device", values: ["AirPods", "AirPods Pro", "speakers", "headphones", "MacBook speakers"])
        gen.define(className: "genre", values: ["lofi", "jazz", "classical", "focus", "rock", "pop", "white noise", "rain sounds"])
        gen.define(className: "dev", values: ["git status", "git commit", "git push", "git pull", "pull request", "GitHub", "the tests", "the linter", "the build", "the main branch", "a new branch"])
        gen.define(className: "num", values: ["five", "ten", "fifteen", "twenty", "twenty five", "thirty", "forty five", "sixty"])
        gen.define(className: "day", values: ["today", "tomorrow", "tonight", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "next week"])
        let templates: [(String, Int)] = [
            ("hey Jarvis", 300), ("Jarvis", 300), ("hey <name>", 20),
            ("open <app>", 60), ("quit <app>", 20), ("switch to <app>", 20), ("open <app> and play some <genre> music", 20),
            ("play some <genre> music", 30), ("play <genre> on <app>", 15),
            ("ask <ai> to", 40), ("tell <ai> to", 20), ("use <ai> to", 20), ("open <ai>", 20), ("and read me the answer", 10),
            ("what's the weather in <place>", 40), ("what's the weather in <place> <day>", 30), ("what's the time in <place>", 15),
            ("how long does it take to get from <place> to <place>", 10),
            ("<dev>", 40), ("create a git commit", 30), ("commit and push", 20), ("push it to GitHub", 30), ("open a pull request on GitHub", 15),
            ("run <dev>", 20), ("show me <dev>", 10),
            ("how much free disk space does my Mac have", 20), ("free up disk space", 20), ("how's my Mac", 20), ("clean up my downloads", 10),
            ("switch to my <device>", 20), ("turn the volume up", 15), ("turn the volume down", 15),
            ("set a timer for <num> minutes", 30), ("remind me to", 30), ("remind me <day> to", 20),
            ("send a message to <name>", 20), ("call <name>", 15), ("email <name>", 10),
            ("search my documents for", 15), ("search the web for", 15), ("what's on my calendar <day>", 20),
        ]
        for (t, c) in templates { gen.insert(template: t, count: c) }
        data.insert(phraseCountGenerator: gen)
        for w in words { data.insert(phraseCount: .init(phrase: w, count: 20)) }
        for (g, p) in [("Jarvis", "dZ \"A v I s"), ("GitHub", "g \"I t h V b"), ("ChatGPT", "tS \"{ t dZ %i p %i t \"i"), ("lofi", "l \"@U f aI")] {
            data.insert(term: .init(grapheme: g, phonemes: [p]))
        }
        return data
    }

    /// Compiles the language model on this Mac (about a second) and reuses it until the words change.
    /// Nil when the recogniser can't use one.
    public static func languageModel(locale: Locale, names: [String], places: [String], apps: [String], words: [String],
                                     in folder: URL) async -> SFSpeechLanguageModel.Configuration? {
        let recipe = ([locale.identifier, "1"] + names + ["|"] + places + ["|"] + apps + ["|"] + words).joined(separator: "\u{1F}")
        let key = SHA256.hash(data: Data(recipe.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = folder.appendingPathComponent(key, isDirectory: true)
        let fm = FileManager.default
        let cfg = SFSpeechLanguageModel.Configuration(languageModel: dir.appendingPathComponent("model"), vocabulary: dir.appendingPathComponent("vocabulary"))
        if fm.fileExists(atPath: cfg.languageModel.path) { return cfg }
        do {
            // Older models are of no further use.
            for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: old) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let asset = dir.appendingPathComponent("requests.bin")
            try await modelData(locale: locale, names: names, places: places, apps: apps, words: words).export(to: asset)
            if #available(macOS 26.0, *) {
                try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: asset, configuration: cfg)
            } else {
                try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: asset, clientIdentifier: "app.jarvis", configuration: cfg)
            }
            return cfg
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    // MARK: Fixing what it mishears

    /// Mishearings fixed only where the intended word is clear from the words around it.
    static let rules: [(pattern: String, template: String)] = [
        // "git" heard as an everyday word, right before a git verb.
        (#"\b(?:gift|gate|date|kit|guilt|good|get|geet)\s+(commit|commits|rebase|stash|diff|clone|checkout)\b"#, "git $1"),
        (#"\b(?:gift|kit|geet)\s+(push|pull|status|log|branch)\b"#, "git $1"),
        (#"\b(?:git|get)\s?hub\b"#, "GitHub"),
        // ChatGPT, heard in pieces or as "chatting".
        (#"\b(?:chat\s?g\.?\s?p\.?\s?t\.?|chat\s?gbt|chad\s?gpt|chat\s?gpd)(?=\W|$)"#, "ChatGPT"),
        (#"\b(ask|tell|use|open|have)\s+chatting\b"#, "$1 ChatGPT"),
        // "free disk space" heard as "feet is space".
        (#"\b(?:feet|feed|fee|free)\s+(?:is|of|do|to|this)\s+space\b"#, "free disk space"),
        (#"\bfeet\s+space\b"#, "free space"),
    ]

    /// "GitHub" misheard after push/open, fixed only when the request is clearly about code.
    static let gitHubAfterPush = #"\b((?:push|pushed|pushing|upload|publish|open|opened)\b[^.?!]{0,24}?\b(?:to|on|in))\s+(?:get\s+up|get\s+hard|give\s+up|the\s+top|the\s+job|jeb|gib|get\s+her|get\s+out|get\s+hope|get\s+hum|good\s+hub)\b"#

    /// Fixes words the recogniser reliably mishears, then applies the user's own corrections.
    public static func correct(_ text: String, learned: [String: String] = [:]) -> String {
        var t = text
        for (p, tmpl) in rules { t = replace(t, p, tmpl) }
        if t.range(of: #"\b(?:git|commit|commits|branch|repo|repository|code|changes|pull request)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            t = replace(t, gitHubAfterPush, "$1 GitHub")
        }
        // The user's corrections, longest first, each anchored by the words around it.
        for (heard, meant) in learned.sorted(by: { $0.key.count > $1.key.count }) {
            let words = heard.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let pattern = "(?<![\\w'])" + words.joined(separator: "[\\s,]+") + "(?![\\w'])"
            t = replace(t, pattern, NSRegularExpression.escapedTemplate(for: meant))
        }
        return t
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    // MARK: Learning from corrections

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-"))) }
            .filter { !$0.isEmpty }
    }

    /// What the user fixed when they edited a spoken request: small word swaps, each kept with one word either
    /// side so the fix only applies in the same setting ("a gift commit" → "a git commit", "in Parker" → "in Dhaka").
    /// Rewrites and added or removed words aren't mishearings, so they're left out.
    public static func corrections(heard: String, meant: String) -> [String: String] {
        let h = words(heard), m = words(meant)
        guard !h.isEmpty, !m.isEmpty, h.count <= 40, m.count <= 40 else { return [:] }
        let hl = h.map { $0.lowercased() }, ml = m.map { $0.lowercased() }
        // Longest common subsequence, then walk it to find the stretches that differ.
        var lcs = Array(repeating: Array(repeating: 0, count: m.count + 1), count: h.count + 1)
        for i in stride(from: h.count - 1, through: 0, by: -1) {
            for j in stride(from: m.count - 1, through: 0, by: -1) {
                lcs[i][j] = hl[i] == ml[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        guard Double(lcs[0][0]) >= 0.6 * Double(max(h.count, m.count)) else { return [:] }
        var pairs: [(hs: Range<Int>, ms: Range<Int>)] = []
        var i = 0, j = 0
        while i < h.count || j < m.count {
            if i < h.count, j < m.count, hl[i] == ml[j] { i += 1; j += 1; continue }
            let (i0, j0) = (i, j)
            while i < h.count || j < m.count {
                if i < h.count, j < m.count, hl[i] == ml[j] { break }
                if j >= m.count || (i < h.count && lcs[i + 1][j] >= lcs[i][j + 1]) { i += 1 } else { j += 1 }
            }
            pairs.append((i0..<i, j0..<j))
        }
        // Swapped words that sound alike were misheard; anything else is the user changing their mind.
        let swaps = pairs.filter {
            !$0.hs.isEmpty && !$0.ms.isEmpty && $0.hs.count <= 3 && $0.ms.count <= 3
                && soundsAlike(h[$0.hs].joined(), m[$0.ms].joined())
        }
        guard !swaps.isEmpty, pairs.count <= 4 else { return [:] }
        var out: [String: String] = [:]
        for s in swaps {
            let left = s.ms.lowerBound > 0 ? [m[s.ms.lowerBound - 1]] : []
            let right = s.ms.upperBound < m.count ? [m[s.ms.upperBound]] : []
            let key = (left + h[s.hs] + right).joined(separator: " ").lowercased()
            out[key] = (left + m[s.ms] + right).joined(separator: " ")
        }
        return out
    }

    /// A rough spoken form: vowels as one sound, silent letters dropped, an "r" before a consonant or at the end
    /// left out as British English does, so "Parker" and "Dhaka", or "get up" and "GitHub", come out close.
    static func soundKey(_ word: String) -> String {
        var s = word.lowercased().filter(\.isLetter)
        for (a, b) in [("ph", "f"), ("dh", "d"), ("th", "t"), ("gh", "g"), ("ck", "k"), ("sh", "s"), ("ch", "c"), ("wh", "w"), ("kh", "k"), ("bh", "b")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        let map: [Character: Character] = ["c": "k", "q": "k", "z": "s", "v": "f", "j": "g", "e": "a", "i": "a", "o": "a", "u": "a", "y": "a"]
        var chars: [Character] = []
        for c in s {
            let m: Character = map[c] ?? c
            if m == "h" { continue }
            if m == "x" { chars += ["k", "s"] } else { chars.append(m) }
        }
        var out: [Character] = []
        for (k, c) in chars.enumerated() {
            if c == "r", k + 1 >= chars.count || chars[k + 1] != "a" { continue }
            if out.last != c { out.append(c) }
        }
        return String(out)
    }

    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let x = Array(soundKey(a)), y = Array(soundKey(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var prev = row[0]; row[0] = i
            for j in 1...y.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return Double(row[y.count]) <= max(1, 0.5 * Double(max(x.count, y.count)))
    }

    /// Whether what the mic caught is only Jarvis's own recent speech, such as "Good afternoon" from its greeting.
    /// Two or more words in the same order as something it said (one slip allowed in longer runs).
    public static func isEcho(_ heard: String, of spoken: String) -> Bool {
        let h = words(heard).map { $0.lowercased() }, s = words(spoken).map { $0.lowercased() }
        guard h.count >= 2, h.count <= s.count else { return false }
        for i in 0...(s.count - h.count) {
            let misses = zip(h, s[i..<(i + h.count)]).filter { $0 != $1 }.count
            if misses == 0 || (h.count >= 4 && misses == 1) { return true }
        }
        return false
    }

    /// Words from a correction worth leaning towards next time.
    public static func newWords(heard: String, meant: String) -> [String] {
        let heardSet = Set(words(heard).map { $0.lowercased() })
        return unique(words(meant).filter { !heardSet.contains($0.lowercased()) && $0.count >= 3 })
    }

    public static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.lowercased()).inserted }
    }
}
