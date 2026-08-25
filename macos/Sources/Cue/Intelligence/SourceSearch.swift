import Foundation

struct SourceHit {
    let file: String
    let snippet: String
}

/// Ranked ripgrep search over local knowledge roots (docs repo + past call
/// transcripts). Conversational questions are mostly filler, so keywords are
/// weighted by rarity (1/df). Product-path boosts and demoting live
/// `call-*.md` files keep grounding on docs instead of the current transcript.
struct SourceSearch {
    let roots: [String]
    /// Basename of the active session file to exclude (avoids self-hits).
    var excludeBasenames: Set<String> = []

    private static let rgPath = "/opt/homebrew/bin/rg"
    private static let maxDocumentFrequency = 800

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
    ]

    func search(question: String, context: String = "") -> [SourceHit] {
        var candidates = Self.candidateKeywords(from: question, limit: 8)
        if candidates.count < 3, !context.isEmpty {
            let extra = Self.candidateKeywords(from: context, limit: 8)
                .filter { !candidates.contains($0) }
            candidates.append(contentsOf: extra.suffix(5))
        }
        guard !candidates.isEmpty else { return [] }

        var keywordFiles: [(keyword: String, files: [String])] = []
        for keyword in candidates {
            let files = filesMatching(keyword)
            guard !files.isEmpty else { continue }
            if files.count > Self.maxDocumentFrequency, candidates.count > 1 { continue }
            if files.count > 2500 { continue }
            keywordFiles.append((keyword, files))
        }

        // Sole content word (e.g. "Origin") often exceeds max DF. Keep the
        // rarest match rather than returning nothing.
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
        for (_, files) in keywordFiles {
            let weight = 1.0 / Double(files.count)
            for file in files {
                fileScores[file, default: 0] += weight + Self.pathBoost(file)
            }
        }
        let topFiles = fileScores
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(4)
            .map(\.key)

        let snippetKeywords = keywordFiles
            .sorted { $0.files.count < $1.files.count }
            .prefix(3)
            .map { NSRegularExpression.escapedPattern(for: $0.keyword) }
        let pattern = "(" + snippetKeywords.joined(separator: "|") + ")"

        var hits: [SourceHit] = []
        for file in topFiles {
            let out = runRG(["-in", "-C", "2", "-m", "5", pattern, file], timeout: 3)
            guard !out.isEmpty else { continue }
            hits.append(SourceHit(file: relativePath(file), snippet: String(out.prefix(1500))))
        }
        return hits
    }

    private func filesMatching(_ keyword: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: keyword)
        let out = runRG(
            ["-il", "--type", "md", "--max-filesize", "300K", "\\b\(escaped)"] + roots,
            timeout: 4
        )
        return out.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .filter { !excludeBasenames.contains(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    private func relativePath(_ file: String) -> String {
        for root in roots where file.hasPrefix(root) {
            return String(file.dropFirst(root.count).drop(while: { $0 == "/" }))
        }
        return file
    }

    /// Prefer product docs; demote past-call transcripts so they don't drown
    /// out the knowledge repo when the question text also appears in a session file.
    static func pathBoost(_ path: String) -> Double {
        let lower = path.lowercased()
        var boost = 0.0
        if lower.contains("/docs/") { boost += 0.05 }
        if lower.contains("origin") { boost += 0.08 }
        if lower.contains("scm-integrations") { boost += 0.06 }
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name.hasSuffix(".wrap.md") {
            // Distilled call wraps should outrank raw transcript echo.
            boost += 0.15
        } else if name.hasPrefix("call-") {
            boost -= 0.2
        }
        return boost
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
