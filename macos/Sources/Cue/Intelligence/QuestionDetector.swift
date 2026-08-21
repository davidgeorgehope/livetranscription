import Foundation

struct QuestionDetector {
    private let verbs = [
        "can you", "could you", "would you", "will you", "do you", "does it",
        "did you", "how do", "how does", "how would", "how can", "what is",
        "what's", "what are", "what does", "what do", "why is", "why does",
        "when will", "when can", "where is", "is there", "are you", "are there",
        "should we", "should i", "pricing", "how much", "how long", "how many"
    ]

    func detect(in chunk: String, recent: String) -> String? {
        let cleaned = chunk
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 8 else { return nil }

        let sentences = splitSentences(cleaned)
        if let marked = sentences.last(where: { $0.contains("?") }) {
            return tidy(marked)
        }

        let lower = cleaned.lowercased()
        if verbs.contains(where: { lower.contains($0) }) {
            return tidy(sentences.last ?? cleaned)
        }

        // Catch a question that straddled the previous chunk.
        let recentSentences = splitSentences(recent)
        if let last = recentSentences.last, last.contains("?"), last.count >= 12 {
            return tidy(last)
        }
        return nil
    }

    private func splitSentences(_ text: String) -> [String] {
        text.split { ".!?\n".contains($0) }.map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func tidy(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.hasSuffix("?") { t += "?" }
        return t
    }
}
