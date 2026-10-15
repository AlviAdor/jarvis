import Foundation

/// Gemini's studio voices, used through the Interactions API. Online and counted against your quota.
public enum GeminiVoice {
    public static let voices: [(name: String, style: String)] = [
        ("Charon", "Informative"), ("Orus", "Firm"), ("Iapetus", "Clear"), ("Algieba", "Smooth"),
        ("Rasalgethi", "Informative"), ("Alnilam", "Firm"), ("Schedar", "Even"), ("Gacrux", "Mature"),
        ("Sadaltager", "Knowledgeable"), ("Kore", "Firm"), ("Puck", "Upbeat"), ("Zephyr", "Bright"),
        ("Fenrir", "Excitable"), ("Leda", "Youthful"), ("Aoede", "Breezy"), ("Callirrhoe", "Easy-going"),
        ("Autonoe", "Bright"), ("Enceladus", "Breathy"), ("Umbriel", "Easy-going"), ("Despina", "Smooth"),
        ("Erinome", "Clear"), ("Algenib", "Gravelly"), ("Laomedeia", "Upbeat"), ("Achernar", "Soft"),
        ("Pulcherrima", "Forward"), ("Achird", "Friendly"), ("Zubenelgenubi", "Casual"),
        ("Vindemiatrix", "Gentle"), ("Sadachbia", "Lively"), ("Sulafat", "Warm"),
    ]

    public static let models = ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"]

    /// Returns WAV audio (24 kHz mono 16-bit).
    public static func synthesize(_ text: String, voice: String, style: String, model: String, key: String) async throws -> Data {
        guard !key.isEmpty else { throw LLMError.missingKey }
        var content: [String: Any] = ["type": "text", "text": text]
        if !style.isEmpty { content["annotations"] = [["type": "speech_metadata", "style": style]] }
        var body: [String: Any] = [
            "model": model,
            "input": [["type": "user_input", "content": [content]]],
            "response_format": ["type": "audio"],
            "generation_config": ["speech_config": [["voice": voice]]],
            "store": false,   // don't keep the interaction on Google's side
        ]

        for _ in 0..<2 {
            var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.timeoutInterval = 60
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let raw = String(data: data, encoding: .utf8) ?? ""
            if code == 400, body["store"] != nil, raw.contains("store") {
                body.removeValue(forKey: "store")
                continue
            }
            guard code == 200 else { throw LLMError.http(code, raw) }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.badResponse }
            let steps = obj["steps"] as? [[String: Any]] ?? []
            let audio = steps
                .filter { $0["type"] as? String == "model_output" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .last { $0["type"] as? String == "audio" }
            guard let b64 = audio?["data"] as? String, let wav = Data(base64Encoded: b64) else { throw LLMError.badResponse }
            return wav
        }
        throw LLMError.badResponse
    }
}
