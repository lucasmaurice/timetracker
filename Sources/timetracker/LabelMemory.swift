import Foundation

/// Content-based memory of the examples you label (context → ticket), kept in SQLite.
/// At inference it finds the most similar past contexts (IDF-weighted token overlap) and
/// returns their tickets — so the system learns *your* mapping as you teach it. Also
/// supplies few-shot examples for the LLM. This is the "training data"; it is NOT neural
/// fine-tuning — it improves purely by accumulating labeled examples.
final class LabelMemory {
    private let store: Store
    private var idf: [String: Double] = [:]
    private var rows: [(ticket: String, doc: String, vec: [String: Double], trust: Double)] = []

    init(store: Store) { self.store = store; reload() }

    var count: Int { rows.count }

    /// How much to trust a similarity match by label provenance. User-confirmed examples are
    /// ground truth; git-mined seeds are weaker priors (they map repo/commit text → ticket but
    /// were never confirmed as *your* time attribution), so their similarity is discounted.
    private static func trust(forKind kind: String) -> Double {
        switch kind {
        case "backfill": return 0.6
        default: return 1.0          // correction / training
        }
    }

    func reload() {
        let labels = store.allLabels()
        let docs = labels.map { (ticket: $0.ticket, doc: $0.doc, toks: TicketMatcher.tokens($0.doc),
                                 trust: Self.trust(forKind: $0.kind)) }
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d.toks) { df[t, default: 0] += 1 } }
        let n = Double(max(docs.count, 1))
        idf = df.mapValues { log((n + 1) / (Double($0) + 1)) + 1 }
        rows = docs.map { ($0.ticket, $0.doc, vec($0.toks), $0.trust) }
    }

    private func vec(_ toks: [String]) -> [String: Double] {
        var v: [String: Double] = [:]
        for t in Set(toks) { if let w = idf[t] { v[t] = w } }
        return v
    }

    /// Nearest labeled examples to the current context, best first. Similarity is scaled by the
    /// example's provenance trust (backfill seeds count less than confirmed labels). `excludingDoc`
    /// drops an exact-match document — used for leave-one-out evaluation so a held-out example
    /// can't trivially retrieve itself.
    func nearest(context: String, k: Int, excludingDoc: String? = nil) -> [(ticket: String, score: Double, doc: String)] {
        guard !rows.isEmpty else { return [] }
        let cv = vec(TicketMatcher.tokens(context))
        guard !cv.isEmpty else { return [] }
        return rows
            .filter { excludingDoc == nil || $0.doc != excludingDoc }
            .map { (ticket: $0.ticket, score: TicketMatcher.cosine(cv, $0.vec) * $0.trust, doc: $0.doc) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(k).map { $0 }
    }

    /// One best example per distinct ticket, for LLM few-shot prompting.
    func fewShot(context: String, k: Int) -> [(context: String, ticket: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for r in nearest(context: context, k: k * 3) where seen.insert(r.ticket).inserted {
            out.append((String(r.doc.replacingOccurrences(of: "\n", with: " · ").prefix(160)), r.ticket))
            if out.count >= k { break }
        }
        return out
    }
}
