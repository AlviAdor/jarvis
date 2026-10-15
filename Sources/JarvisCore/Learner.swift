import Foundation

/// Picks up lasting facts about the user from what they say, the way a good assistant would:
/// "I study at AIUB", "my sister is Mim", "I prefer short answers". Runs quietly after a reply.
public enum Learner {
    static let selfWords = [" i ", " i'm ", " im ", " i've ", " i'd ", " my ", " me ", " mine ", " myself ", " we ", " our "]

    /// Only messages where the user talks about themselves are worth a look.
    public static func worthChecking(_ text: String) -> Bool {
        let s = " " + text.lowercased().replacingOccurrences(of: "[,.!?]", with: " ", options: .regularExpression) + " "
        return s.split(separator: " ").count >= 4 && selfWords.contains { s.contains($0) }
    }

    static let instructions = """
    You keep a small memory of lasting facts about the user of a voice assistant.
    From the user's message, write down only facts that will still be true and useful in a month: who they are, \
    where they live or study or work, people in their life, preferences, habits, projects, devices, goals.
    Skip one-off requests, questions, moods and anything already known. Never record passwords, card numbers or other secrets.
    Write each fact as a short third-person sentence starting with "User" or "User's", one per line.
    If there is nothing new, reply with exactly NONE.
    """

    /// Turns the model's reply into new facts, dropping repeats and anything that looks sensitive.
    public static func parse(_ answer: String, known: [String]) -> [String] {
        let t = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.uppercased() != "NONE" else { return [] }
        let knownLower = known.map { $0.lowercased() }
        var out: [String] = []
        for raw in t.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let f = line.first, "-•*0123456789.) ".contains(f) { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            let l = line.lowercased()
            guard line.count >= 8, line.count <= 160, l != "none",
                  !["password", "passcode", "pin ", "card number", "cvv", "api key", "social security"].contains(where: l.contains),
                  !knownLower.contains(where: { $0 == l || $0.contains(l) || l.contains($0) }),
                  !out.contains(where: { $0.lowercased() == l }) else { continue }
            if !line.hasSuffix(".") { line += "." }
            out.append(line)
        }
        return Array(out.prefix(3))
    }

    public static func learn(from text: String, known: [String], key: String, model: String) async -> [String] {
        guard !key.isEmpty, worthChecking(text) else { return [] }
        let prompt = "Already known:\n" + (known.isEmpty ? "(nothing)" : known.suffix(40).map { "- \($0)" }.joined(separator: "\n")) +
            "\n\nUser's message:\n\(text)"
        guard let r = try? await GeminiClient(apiKey: key).generate(
            model: model, system: instructions, contents: [["role": "user", "parts": [["text": prompt]]]],
            maxTokens: 160, thinking: model.hasPrefix("gemini-2") ? .budget(0) : .level("minimal")) else { return [] }
        return parse(r.text, known: known)
    }
}
