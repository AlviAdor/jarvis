import Foundation

/// Web results without Gemini's Google Search: DuckDuckGo's HTML results page, which its robots.txt allows
/// automated access to. Used when grounding isn't available on the user's key or is out of free requests.
public enum WebSearch {
    public struct Hit: Sendable, Equatable {
        public let title: String
        public let url: String
        public let snippet: String
    }

    public static func duckDuckGo(_ query: String, limit: Int = 8) async -> [Hit] {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(q)") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Array(parse(String(decoding: data, as: UTF8.self)).prefix(limit))
    }

    /// Titles, links and snippets from a results page, without ads.
    public static func parse(_ html: String) -> [Hit] {
        var hits: [Hit] = []
        var seen = Set<String>()
        let blocks = html.components(separatedBy: "class=\"result results_links")
        for block in blocks.dropFirst() where !block.prefix(160).contains("result--ad") {
            guard let link = first(#"class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#, in: block) else { continue }
            let url = resolve(Web.decodeEntities(link[0]))
            guard url.hasPrefix("http"), seen.insert(url).inserted else { continue }
            let snippet = first(#"class="result__snippet"[^>]*>([\s\S]*?)</a>"#, in: block)?[0] ?? ""
            hits.append(Hit(title: clean(link[1]), url: url, snippet: clean(snippet)))
        }
        return hits
    }

    /// DuckDuckGo sometimes links through its redirect; this gives the real address.
    static func resolve(_ href: String) -> String {
        var h = href
        if h.hasPrefix("//") { h = "https:" + h }
        if let c = URLComponents(string: h), c.host?.hasSuffix("duckduckgo.com") == true,
           let target = c.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        return h
    }

    private static func first(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

    private static func clean(_ s: String) -> String {
        Web.decodeEntities(s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Open web results with the best few pages read in full, as material for an answer.
    public static func material(_ query: String, results: Int = 6, read: Int = 3) async -> (text: String, hits: [Hit]) {
        let hits = await duckDuckGo(String(query.prefix(200)), limit: results)
        guard !hits.isEmpty else { return ("", []) }
        let pages: [(Int, String)] = await withTaskGroup(of: (Int, String)?.self) { g in
            for (i, h) in hits.prefix(read).enumerated() {
                g.addTask {
                    let p = await Web.page(h.url)
                    return p.ok && p.text.count > 300 ? (i, String(p.text.prefix(3500))) : nil
                }
            }
            var out: [(Int, String)] = []
            for await r in g { if let r { out.append(r) } }
            return out.sorted { $0.0 < $1.0 }
        }
        var text = hits.enumerated().map { "[\($0.offset + 1)] \($0.element.title) — \($0.element.snippet) (\($0.element.url))" }.joined(separator: "\n")
        if !pages.isEmpty { text += "\n\nPages:\n" + pages.map { "[\($0.0 + 1)] \(hits[$0.0].title)\n\($0.1)" }.joined(separator: "\n\n") }
        return (text, hits)
    }

    /// Results as text for the assistant, numbered, with the links to read.
    public static func describe(_ hits: [Hit], query: String) -> String {
        guard !hits.isEmpty else { return "No results for \u{201C}\(query)\u{201D}." }
        return "Web results for \u{201C}\(query)\u{201D} (read the most useful with fetch_url):\n" + hits.enumerated().map {
            "\($0.offset + 1). \($0.element.title) — \($0.element.snippet) (\($0.element.url))"
        }.joined(separator: "\n")
    }
}
