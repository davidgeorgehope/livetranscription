import Foundation

/// Minimal `.env` reader. Looks in cwd and the livetranscription repo root.
enum DotEnv {
    static func value(for key: String) -> String? {
        for url in candidateFiles() {
            guard let values = parse(url), let raw = values[key] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func candidateFiles() -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return }
            seen.insert(path)
            urls.append(url)
        }

        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            add(dir.appendingPathComponent(".env"))
            add(dir.appendingPathComponent("macos/.env"))
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        let home = fm.homeDirectoryForCurrentUser
        add(home.appendingPathComponent("Projects/livetranscription/.env"))
        add(home.appendingPathComponent("Projects/livetranscription/macos/.env"))
        return urls
    }

    private static func parse(_ url: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count))
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 {
                let first = value.first!
                let last = value.last!
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            out[key] = value
        }
        return out
    }
}
