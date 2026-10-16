import Foundation

/// Deep research: plan the angles, search them side by side, read the best sources in full, and write a
/// cited brief that says where sources disagree. Depth follows the effort setting and the usage saver.
public enum Research {
    public struct Source: Sendable, Hashable {
        public let title: String
        public let url: String
    }

    public struct Finding: Sendable {
        public let query: String
        public let text: String
        public let sources: [Source]
    }

    public struct Depth: Sendable, Equatable {
        public let queries: Int
        public let reads: Int
        public let words: Int
    }

    public struct Report: Sendable {
        public let title: String
        public let text: String
        public let sources: [Source]
        public let model: String
    }

    public static func depth(effort: String, usageSaver: Bool) -> Depth {
        if usageSaver { return Depth(queries: 2, reads: 2, words: 450) }
        switch effort {
        case "low": return Depth(queries: 3, reads: 2, words: 500)
        case "high": return Depth(queries: 6, reads: 6, words: 1100)
        case "max": return Depth(queries: 8, reads: 8, words: 1600)
        default: return Depth(queries: 4, reads: 4, words: 800)
        }
    }

    /// Requests that ask for research rather than a quick answer.
    public static func isRequest(_ text: String) -> Bool {
        let t = text.lowercased()
        let phrases = ["deep dive", "deep research", "do research", "do some research", "research report", "literature review",
                       "market research", "find out everything", "write a report", "write me a report", "prepare a report",
                       "make a report", "compile a report", "thorough research", "in-depth comparison", "detailed comparison"]
        if phrases.contains(where: t.contains) { return true }
        let start = #"^(?:hey |ok )?(?:jarvis[,.]? )?(?:can you |could you |please |i need you to |help me |i want you to )*(?:research|investigate|look into|dig into)\b"#
        return t.range(of: start, options: .regularExpression) != nil
    }

    // MARK: Prompts

    static func planPrompt(_ d: Depth) -> String {
        """
        You plan web research. Break the user's question into the \(d.queries) most useful Google searches that together answer it well: \
        different angles (facts and figures, recent news, official or primary sources, comparisons, prices, expert opinion, criticism), \
        specific enough to find real sources, in the language most likely to have good sources. Fit them to the user's context when it matters.
        Reply with JSON only: {"title": "a short title for the report", "queries": ["...", "..."]}
        """
    }

    static func searchPrompt(_ angles: Int) -> String {
        """
        Use Google Search to research each numbered angle below, with a separate search for each one. For every angle write a short \
        section starting with its number: the specific facts, figures, dates, names and prices found, what each source says, and any \
        disagreement between sources. Say when something is old or unconfirmed. Plain text, under \(140 * angles) words in all.
        """
    }

    /// The angles split into a few grounded requests: Gemini runs the individual searches inside each one, so a deep
    /// search costs one or two requests instead of one per angle, and stays well under the free per-minute limits.
    public static func batches(_ queries: [String]) -> [[String]] {
        let n = queries.count <= 3 ? 1 : 2
        var out = Array(repeating: [String](), count: n)
        for (i, q) in queries.enumerated() { out[i % n].append(q) }
        return out.filter { !$0.isEmpty }
    }

    static func writePrompt(_ d: Depth, today: String) -> String {
        """
        You are an expert researcher writing a brief for the user from the research notes and page extracts below. Today is \(today).
        - Start with "**Bottom line:**" and the direct answer in one or two sentences.
        - Then "## Key findings": the most important points as bullets, each ending with the numbered source(s) it rests on, like [2] or [1][4].
        - Add sections only where they help this question: a comparison table, options with pros and cons, costs, a timeline, steps, \
        or a recommendation fitted to the user.
        - Add "## Where sources disagree" when they do, and say what is uncertain or couldn't be found.
        Use only the material given; never invent facts, numbers or sources. Prefer recent, primary and official sources, and date figures that change.
        Don't write a list of sources at the end; it is added for you. About \(d.words) words. Write in the language of the user's question.
        """
    }

    // MARK: Pieces

    /// The title and searches from the planner's reply: JSON, or one search per line if the JSON is broken.
    public static func parsePlan(_ text: String, question: String, max: Int) -> (title: String, queries: [String]) {
        var title = "", queries: [String] = []
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
           let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] {
            title = (obj["title"] as? String) ?? ""
            queries = (obj["queries"] as? [String]) ?? []
        } else {
            queries = text.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-*•0123456789.)\"")))
            }.filter { $0.count > 3 }
        }
        queries = Array(Hearing.unique(queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).prefix(max))
        if queries.isEmpty { queries = [question] }
        if title.isEmpty { title = String(question.prefix(60)) }
        return (title.trimmingCharacters(in: .whitespacesAndNewlines), queries)
    }

    /// The pages worth reading in full: one per site, in the order the searches found them.
    public static func pickSources(_ findings: [Finding], max: Int) -> [Source] {
        var seen = Set<String>(), out: [Source] = []
        var iterators = findings.map { $0.sources.makeIterator() }
        // Take the first source of every search, then the second, so each angle gets read.
        var progressed = true
        while out.count < max, progressed {
            progressed = false
            for i in iterators.indices {
                guard out.count < max, let s = iterators[i].next() else { continue }
                progressed = true
                if seen.insert(site(s)).inserted { out.append(s) }
            }
        }
        return out
    }

    /// The site a source is on. Google's search results link through a redirect, but their titles are the site names.
    static func site(_ s: Source) -> String {
        guard let host = URL(string: s.url)?.host?.lowercased(), !host.contains("vertexaisearch"), !host.hasSuffix("google.com") else {
            return s.title.lowercased()
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Numbers every source once, in the order first seen.
    static func numbered(_ findings: [Finding], read: [(Source, String, String)]) -> [Source] {
        var list: [Source] = []
        var urls = Set<String>()
        for (s, final, _) in read where urls.insert(final).inserted { list.append(Source(title: s.title, url: final)) }
        for f in findings {
            for s in f.sources where !read.contains(where: { $0.0 == s }) && urls.insert(s.url).inserted { list.append(s) }
        }
        return list
    }

    /// The material the writer works from, with every source numbered.
    static func material(question: String, context: String, findings: [Finding], read: [(Source, String, String)], sources: [Source]) -> String {
        func number(_ s: Source) -> Int? {
            let url = read.first(where: { $0.0 == s })?.1 ?? s.url
            return sources.firstIndex { $0.url == url }.map { $0 + 1 }
        }
        var out = "The user's question: \(question)\n"
        if !context.isEmpty { out += "About the user: \(context)\n" }
        out += "\nSources:\n" + sources.enumerated().map { "[\($0.offset + 1)] \($0.element.title) — \($0.element.url)" }.joined(separator: "\n")
        out += "\n\nResearch notes:\n"
        for f in findings {
            let refs = f.sources.compactMap(number).map { "[\($0)]" }.joined()
            out += "\n### \(f.query)\n\(f.text)\n" + (refs.isEmpty ? "" : "Found in: \(refs)\n")
        }
        if !read.isEmpty {
            out += "\nPage extracts:\n"
            for (s, _, text) in read {
                out += "\n[\(number(s) ?? 0)] \(s.title)\n\(text)\n"
            }
        }
        return out
    }

    /// The sources the brief actually cites, as a closing list.
    static func sourceList(_ text: String, sources: [Source]) -> String {
        let cited = Set(text.matches(of: #/\[(\d{1,2})\]/#).compactMap { Int($0.1) })
        let used = sources.enumerated().filter { cited.isEmpty || cited.contains($0.offset + 1) }
        guard !used.isEmpty else { return "" }
        return "\n\n## Sources\n" + used.map { "\($0.offset + 1). [\($0.element.title)](\($0.element.url))" }.joined(separator: "\n")
    }

    // MARK: Running

    /// Every model that could do the step is resting after hitting a limit.
    struct Resting: LocalizedError {
        let models: [String]
        var errorDescription: String? { Friendly.allResting(models) }
    }

    /// Tries each model in turn until one answers.
    private static func first<T>(_ models: [String], _ body: (String) async throws -> T) async throws -> (T, String) {
        var last: Error = Resting(models: models)
        for m in models where QuotaBook.shared.usable(m) {
            if Task.isCancelled || KillSwitch.shared.tripped { throw CancellationError() }
            do { return (try await body(m), m) } catch is CancellationError { throw CancellationError() } catch { last = error }
        }
        throw last
    }

    public static func run(question: String, context: String, depth d: Depth, effort: String, client: GeminiClient,
                           planModels: [String], searchModels: [String], writeModels: [String],
                           progress: @escaping @Sendable (ActionEvent) async -> Void,
                           usage: @escaping @Sendable (Usage) -> Void,
                           onText: (@Sendable (String) -> Void)? = nil) async throws -> Report {
        // 1. Plan the searches.
        let planId = UUID()
        await progress(ActionEvent(id: planId, title: "Planning the research", state: .running, icon: "list.bullet.rectangle"))
        let user = context.isEmpty ? question : "\(question)\n\n(About me: \(context))"
        let (planned, _) = try await first(planModels) { m in
            try await client.generate(model: m, system: planPrompt(d), contents: [["role": "user", "parts": [["text": user]]]],
                                      maxTokens: 600, thinking: GeminiAgent.thinking(for: m, mode: .chat, effort: "low"))
        }
        usage(planned.usage)
        let plan = parsePlan(planned.text, question: question, max: d.queries)
        await progress(ActionEvent(id: planId, title: "Planned \(plan.queries.count) searches", detail: plan.queries.joined(separator: "\n"), state: .done, icon: "list.bullet.rectangle"))

        // 2. Search the angles in one or two grounded requests, each starting on a different model.
        let searchId = UUID()
        await progress(ActionEvent(id: searchId, title: "Searching \(plan.queries.count) angles", state: .running, icon: "globe"))
        let groups = batches(plan.queries)
        let searchers = searchModels.filter(GeminiClient.canSearch)
        let results: [Result<Finding, Error>] = searchers.isEmpty ? [] : await withTaskGroup(of: (Int, Result<Finding, Error>).self) { g in
            for (i, angles) in groups.enumerated() {
                let order = Array(searchers[(i % searchers.count)...] + searchers[..<(i % searchers.count)])
                let ask = "Question: \(question)\n\nAngles:\n" + angles.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                g.addTask {
                    do {
                        let (r, _) = try await first(order) { m in
                            try await client.generate(model: m, system: searchPrompt(angles.count), contents: [["role": "user", "parts": [["text": ask]]]],
                                                      tools: [["google_search": [String: Any]()]], maxTokens: 400 * angles.count + 600,
                                                      thinking: GeminiAgent.thinking(for: m, mode: .web, effort: "low"))
                        }
                        usage(r.usage)
                        return (i, .success(Finding(query: angles.joined(separator: "; "), text: r.text, sources: r.sources.map { Source(title: $0.title, url: $0.url) })))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            var out = [Result<Finding, Error>?](repeating: nil, count: groups.count)
            for await (i, r) in g { out[i] = r }
            return out.compactMap { $0 }
        }
        if KillSwitch.shared.tripped || Task.isCancelled { throw CancellationError() }
        var findings = results.compactMap { try? $0.get() }
        if findings.isEmpty {
            // Google Search isn't available on this key right now: use open web results, then read the pages as usual.
            findings = await withTaskGroup(of: (Int, Finding?).self) { g in
                for (i, q) in plan.queries.enumerated() {
                    g.addTask {
                        let hits = await WebSearch.duckDuckGo(q, limit: 6)
                        guard !hits.isEmpty else { return (i, nil) }
                        let text = hits.map { "- \($0.title): \($0.snippet)" }.joined(separator: "\n")
                        return (i, Finding(query: q, text: text, sources: hits.map { Source(title: $0.title, url: $0.url) }))
                    }
                }
                var out = [Finding?](repeating: nil, count: plan.queries.count)
                for await (i, f) in g { out[i] = f }
                return out.compactMap { $0 }
            }
        }
        guard !findings.isEmpty else {
            let reason: Error = results.compactMap { if case .failure(let e) = $0 { return e } else { return nil } }.first ?? LLMError.badResponse
            await progress(ActionEvent(id: searchId, title: "The searches didn't come back", detail: Friendly.message(reason), state: .failed, icon: "globe"))
            throw reason
        }
        let found = Set(findings.flatMap(\.sources).map(\.title)).count
        await progress(ActionEvent(id: searchId, title: "Searched \(plan.queries.count) angles", detail: "\(found) sources found", state: .done, icon: "globe"))

        // 3. Read the best pages in full, side by side.
        let picks = pickSources(findings, max: d.reads)
        var read: [(Source, String, String)] = []
        if !picks.isEmpty {
            let readId = UUID()
            await progress(ActionEvent(id: readId, title: "Reading \(picks.count) sources", detail: picks.map(\.title).joined(separator: ", "), state: .running, icon: "doc.richtext"))
            read = await withTaskGroup(of: (Int, (Source, String, String)?).self) { g in
                for (i, s) in picks.enumerated() {
                    g.addTask {
                        let page = await Web.page(s.url)
                        guard page.ok, page.text.count > 300 else { return (i, nil) }
                        return (i, (s, page.url, String(page.text.prefix(d.reads > 4 ? 4500 : 6000))))
                    }
                }
                var out = [(Source, String, String)?](repeating: nil, count: picks.count)
                for await (i, r) in g { out[i] = r }
                return out.compactMap { $0 }
            }
            await progress(ActionEvent(id: readId, title: "Read \(read.count) of \(picks.count) sources", detail: read.map { URL(string: $0.1)?.host ?? $0.0.title }.joined(separator: ", "), state: .done, icon: "doc.richtext"))
        }
        if KillSwitch.shared.tripped || Task.isCancelled { throw CancellationError() }

        // 4. Write the brief.
        let writeId = UUID()
        await progress(ActionEvent(id: writeId, title: "Writing the report", state: .running, icon: "doc.text"))
        let sources = numbered(findings, read: read)
        let notes = material(question: question, context: context, findings: findings, read: read, sources: sources)
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy"
        let system = writePrompt(d, today: f.string(from: Date()))
        let contents: [[String: Any]] = [["role": "user", "parts": [["text": notes]]]]
        let (written, model) = try await first(writeModels) { m in
            let thinking = GeminiAgent.thinking(for: m, mode: .hard, effort: effort)
            if let onText {
                return try await client.stream(model: m, system: system, contents: contents, maxTokens: 8192, thinking: thinking, onText: onText)
            }
            return try await client.generate(model: m, system: system, contents: contents, maxTokens: 8192, thinking: thinking)
        }
        usage(written.usage)
        let body = written.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw LLMError.badResponse }
        await progress(ActionEvent(id: writeId, title: "Wrote the report", detail: "\(sources.count) sources", state: .done, icon: "doc.text"))
        return Report(title: plan.title, text: body + sourceList(body, sources: sources), sources: sources, model: model)
    }

    /// Saves the report as Markdown in Documents/Jarvis/Research, never over an existing file.
    public static func save(_ r: Report, question: String) -> URL? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis/Research", isDirectory: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let safe = r.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n")).joined(separator: " ").prefix(70)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = FileOps.free(dir.appendingPathComponent("\(f.string(from: Date())) \(safe).md"))
            try "# \(r.title)\n\n_\(question)_\n\n\(r.text)\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
