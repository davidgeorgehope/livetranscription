import Foundation

/// Curated markdown pack under Application Support. Cue's grounded answers
/// search this before any repo root.
enum CueKnowledge {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cue/knowledge", isDirectory: true)
    }

    /// Q&A entries mined from real calls (`scripts/mine_playbook.py`): how
    /// strong reps actually answer, dated, with provenance and known pitfalls.
    static var playbookDirectory: URL {
        directory.appendingPathComponent("playbook", isDirectory: true)
    }

    /// Packs we used to copy in from the everysphere checkout. They were
    /// engineering docs about product internals (telemetry, specs, portal
    /// routes) and the eval showed they produce confident wrong answers on
    /// sales calls — e.g. "Grokbot runs locally" from an o11y README when
    /// the product is cloud VMs. Removed on launch so stale copies don't
    /// keep being searched.
    private static let retiredPacks = ["portal", "sand-docs", "grok-bot-refs"]

    /// Safe to call on launch; never throws.
    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: playbookDirectory, withIntermediateDirectories: true)
        for name in retiredPacks {
            try? fm.removeItem(at: directory.appendingPathComponent(name, isDirectory: true))
        }

        let readme = directory.appendingPathComponent("README.md")
        let body = """
        # Cue knowledge pack

        `product-docs/` — public cursor.com docs, refreshed by `macos/scripts/fetch_product_docs.py`.
        Ranked above internal docs and code for product behaviour.

        `grok-bot-internal/` — internal FAQ / decks (Notion and Figma exports). Accurate but
        internal-only; prompts state facts from here without quoting them as customer-facing.

        `playbook/` — Q&A mined from real calls by `macos/scripts/mine_playbook.py`.
        Each entry: canonical question, the answer as strong reps say it, as-of date,
        source calls, confidence, disagreements, and pitfalls Cue has gotten wrong.

        Drop any other customer-facing markdown alongside it. Do not add engineering
        docs about product internals here; they read as product truth to the model.
        """
        try? body.write(to: readme, atomically: true, encoding: .utf8)
    }
}
