import Foundation

struct SourceHit {
    let file: String
    let snippet: String
}

/// Ranked ripgrep search over local knowledge roots (docs repo + past call
/// transcripts). Conversational questions are mostly filler, so keywords are
/// weighted by rarity (1/df). Path boosts prefer real docs; noise trees and
/// snapshot dumps are demoted or skipped.
struct SourceSearch {
    let roots: [String]
    /// Basename of the active session file to exclude from *repo* ranking
    /// (avoids self-hits drowning docs). Pass the same file explicitly to
    /// `transcriptSnippets` when the ask is about this call.
    var excludeBasenames: Set<String> = []

    private static let rgPath = "/opt/homebrew/bin/rg"
    private static let maxDocumentFrequency = 800

    /// Paths that keyword-match constantly but almost never answer call questions.
    private static let noiseGlobs = [
        "!**/__snapshots__/**",
        "!**/node_modules/**",
        "!**/.git/**",
        "!**/i18n/**",
        "!**/i18n-*/**",
        "!**/changelog/**",
        "!**/*.generated.md",
    ]

    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "you", "your", "our", "can", "could", "would",
        "will", "does", "did", "how", "what", "when", "where", "who", "why", "which",
        "that", "this", "these", "those", "with", "have", "has", "had", "was", "were",
        "there", "their", "they", "them", "then", "than", "but", "not", "all", "any",
        "get", "got", "just", "like", "yeah", "okay", "about", "into", "over", "some",
        "much", "many", "very", "really", "kind", "sort", "know", "think", "want",
        "need", "going", "gonna", "say", "said", "curious", "specific", "actually",
        "wanted", "also", "look", "looking", "looks", "options", "option", "flexible",
        "right", "sure", "little", "bit", "lot", "mean", "means", "guys", "folks",
        "basically", "come", "comes", "thing", "things", "stuff", "way", "ways",
        "make", "makes", "made", "use", "using", "used", "see", "seen", "still",
        "now", "well", "good", "great", "back", "out", "one", "two", "let", "lets",
        "here", "been", "being", "its", "his", "her", "him", "she", "from",
        "walk", "through", "click", "clicks", "show", "tell", "please", "help",
        "next", "step", "steps", "guide", "setup", "setting", "settings",
    ]

    func search(question: String, context: String = "") -> [SourceHit] {
        let candidates = Self.mergedKeywords(question: question, context: context)
        guard !candidates.isEmpty else { return [] }

        var keywordFiles: [(keyword: String, files: [String])] = []
        for keyword in candidates {
            let files = filesMatching(keyword)
            guard !files.isEmpty else { continue }
            if files.count > Self.maxDocumentFrequency, candidates.count > 1 { continue }
            if files.count > 2500 { continue }
            keywordFiles.append((keyword, files))
        }

        if keywordFiles.isEmpty {
            var best: (String, [String])?
            for keyword in candidates {
                let files = filesMatching(keyword)
                guard !files.isEmpty else { continue }
                if best == nil || files.count < best!.1.count {
                    best = (keyword, files)
                }
            }
            if let best { keywordFiles = [best] }
        }
        guard !keywordFiles.isEmpty else { return [] }

        var fileScores: [String: Double] = [:]
        var matchedKeywords: [String: Int] = [:]
        let keptKeywords = keywordFiles.map(\.keyword)
        for (_, files) in keywordFiles {
            let weight = 1.0 / Double(files.count)
            for file in files {
                matchedKeywords[file, default: 0] += 1
                fileScores[file, default: 0] += weight
                    + Self.pathBoost(file)
                    + Self.basenameKeywordBoost(path: file, keywords: keptKeywords)
            }
        }
        // A file that shares one word with the question is not evidence; in a
        // small corpus the path boost alone would carry it to the top.
        if keptKeywords.count >= 2 {
            fileScores = fileScores.filter { matchedKeywords[$0.key, default: 0] >= 2 }
        }
        let topFiles = fileScores
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(4)
            .map(\.key)

        return snippets(in: topFiles, keywords: keywordFiles.map(\.keyword))
    }

    /// Pull grounding from a specific transcript/session file (or in-memory
    /// dump written to a temp path). Used for interview / Ask-about-this-call
    /// so we don't rely on monorepo keyword noise.
    func transcriptSnippets(question: String, fileURL: URL, label: String? = nil) -> [SourceHit] {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let keywords = Self.candidateKeywords(from: question, limit: 8)
        guard !keywords.isEmpty else { return [] }
        let hits = snippets(in: [path], keywords: keywords)
        guard !hits.isEmpty else {
            // Fall back: last ~2k chars of the file as one hit.
            if let data = try? String(contentsOf: fileURL, encoding: .utf8) {
                let tail = String(data.suffix(2200))
                return [SourceHit(file: label ?? fileURL.lastPathComponent, snippet: tail)]
            }
            return []
        }
        return hits.map {
            SourceHit(file: label ?? $0.file, snippet: $0.snippet)
        }
    }

    /// Snippets from an in-memory dialogue string (recent window / ask context).
    func dialogueSnippets(question: String, dialogue: String, label: String = "live-dialogue") -> [SourceHit] {
        let trimmed = dialogue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { return [] }
        let keywords = Self.candidateKeywords(from: question, limit: 6)
        var scored: [(Int, String)] = []
        let lines = trimmed.components(separatedBy: .newlines)
        for line in lines {
            let l = line.lowercased()
            let score = keywords.reduce(0) { $0 + (l.contains($1) ? 1 : 0) }
            if score > 0 { scored.append((score, line)) }
        }
        scored.sort { $0.0 > $1.0 }
        let picked = scored.prefix(8).map(\.1)
        if !picked.isEmpty {
            let body = picked.joined(separator: "\n")
            return [SourceHit(file: label, snippet: String(body.prefix(2000)))]
        }
        // No keyword overlap: still return the tail so the model has call context.
        return [SourceHit(file: label, snippet: String(trimmed.suffix(2000)))]
    }

    private func snippets(in files: [String], keywords: [String]) -> [SourceHit] {
        let snippetKeywords = keywords
            .prefix(3)
            .map { NSRegularExpression.escapedPattern(for: $0) }
        guard !snippetKeywords.isEmpty else { return [] }
        let pattern = "(" + snippetKeywords.joined(separator: "|") + ")"
        var hits: [SourceHit] = []
        for file in files {
            let out = runRG(["-in", "-C", "2", "-m", "5", pattern, file], timeout: 3)
            guard !out.isEmpty else { continue }
            hits.append(SourceHit(file: relativePath(file), snippet: String(out.prefix(1500))))
        }
        return hits
    }

    private func filesMatching(_ keyword: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: keyword)
        var args = ["-il", "--type", "md", "--max-filesize", "400K"]
        args.append(contentsOf: Self.noiseGlobs.flatMap { ["--glob", $0] })
        args.append("\\b\(escaped)")
        args.append(contentsOf: roots)
        let out = runRG(args, timeout: 5)
        return out.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .filter { !excludeBasenames.contains(URL(fileURLWithPath: $0).lastPathComponent) }
            .filter { !Self.isNoisePath($0) }
    }

    private func relativePath(_ file: String) -> String {
        for root in roots where file.hasPrefix(root) {
            return String(file.dropFirst(root.count).drop(while: { $0 == "/" }))
        }
        return file
    }

    static func isNoisePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("/__snapshots__/")
            || lower.contains("/i18n/")
            || lower.contains("i18n-glossary")
            || lower.contains("/changelog/")
            || lower.hasSuffix(".generated.md")
    }

    static func pathBoost(_ path: String) -> Double {
        let lower = path.lowercased()
        var boost = 0.0
        if lower.contains("internal-docs") { boost += 0.2 }
        if lower.contains("/portal/") { boost += 0.15 }
        if lower.contains("/docs/") { boost += 0.08 }
        if lower.contains("cue/knowledge") { boost += 0.25 }
        // Playbook entries are how reps actually answer: a tie-breaker over
        // docs that match equally well, not a substitute for matching.
        if lower.contains("/playbook/") { boost += 0.15 }
        // Public product docs are what we say externally: the strongest signal
        // for product behaviour, above internal docs and code.
        if lower.contains("/product-docs/") { boost += 0.35 }
        // Internal FAQ / decks: accurate superset of the public docs, but internal-only.
        if lower.contains("/grok-bot-internal/") { boost += 0.3 }
        // Prep the user attached for this call beats everything else.
        if lower.contains("/prep/current/") { boost += 0.6 } else if lower.contains("/cue/prep/") { boost += 0.2 }
        if lower.contains("/sand/") && lower.contains("/docs/") { boost += 0.12 }
        if lower.contains("cloud.md") { boost += 0.1 }
        if lower.contains("grok") || lower.contains("grokbot") { boost += 0.15 }
        if lower.contains("signin") || lower.contains("sign-in") || lower.contains("sign_in") {
            boost += 0.2
        }
        if lower.contains("origin") && !lower.contains("origin-code-review") { boost += 0.06 }
        if lower.contains("scm-integrations") { boost += 0.06 }
        if lower.contains("origin-code-review") { boost -= 0.15 }
        if lower.contains("__snapshots__") { boost -= 0.5 }
        if lower.contains("/i18n") { boost -= 0.4 }
        if lower.hasSuffix(".generated.md") { boost -= 0.45 }
        // Generic portal landing pages match UI verbs constantly.
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if name == "index.md" || name == "components.md" || name == "dashboard.md" || name == "readme.md" {
            boost -= 0.18
        }
        if name.hasSuffix(".wrap.md") {
            boost += 0.08
        } else if name.hasPrefix("call-") {
            boost -= 0.2
        }
        return boost
    }

    /// Extra score when the file basename itself contains question keywords
    /// (e.g. grok-bot-signin.md for a Grok Bot ask).
    static func basenameKeywordBoost(path: String, keywords: [String]) -> Double {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        var boost = 0.0
        for kw in keywords where kw.count >= 3 && name.contains(kw) {
            boost += 0.35
        }
        if keywords.contains("grok"), keywords.contains("bot"), name.contains("grok"), name.contains("bot") {
            boost += 0.4
        }
        return boost
    }

    static func mergedKeywords(question: String, context: String) -> [String] {
        var candidates = candidateKeywords(from: question, limit: 8)
        if candidates.count < 3, !context.isEmpty {
            let extra = candidateKeywords(from: context, limit: 8)
                .filter { !candidates.contains($0) }
            candidates.append(contentsOf: extra.suffix(5))
        }
        return candidates
    }

    static func candidateKeywords(from text: String, limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        for word in words {
            guard word.count >= 3, !stopwords.contains(word), !seen.contains(word) else { continue }
            seen.insert(word)
            result.append(word)
            if result.count == limit { break }
        }
        return result
    }

    private func runRG(_ args: [String], timeout: TimeInterval) -> String {
        let process = Process()
        let rg = FileManager.default.isExecutableFile(atPath: Self.rgPath)
            ? Self.rgPath
            : "/usr/local/bin/rg"
        process.executableURL = URL(fileURLWithPath: rg)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
