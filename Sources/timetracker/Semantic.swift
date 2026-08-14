import Foundation

struct TicketGuess: Equatable {
    var key: String
    var score: Double
}

/// Ranks assigned tickets against the current activity context using IDF-weighted
/// token-overlap (TF-IDF cosine). Chosen over sentence embeddings because the signal
/// here is concrete shared jargon (vmselect, oidc, slo, repo/file names): rare-token
/// overlap discriminates well and—crucially—**abstains** (score 0) when there's no
/// lexical signal, which protects timesheet accuracy. Pure local, zero dependencies.
///
/// The vocabulary is the ticket corpus: context tokens absent from every ticket are
/// dropped, so unrelated activity (e.g. "lunch plans") scores 0 against all tickets.
final class TicketMatcher {
    private var idf: [String: Double] = [:]
    private var ticketVecs: [(key: String, vec: [String: Double], prior: Double)] = []
    private var cache: [String: [TicketGuess]] = [:]

    var isAvailable: Bool { !ticketVecs.isEmpty }

    func index(_ tickets: [Ticket], weights: RankWeights) {
        cache.removeAll()
        let now = Date()
        let docs = tickets.map { (key: $0.key, toks: Self.tokens($0.matchText), prior: $0.priorWeight(now: now, w: weights)) }
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d.toks) { df[t, default: 0] += 1 } }
        let n = Double(max(docs.count, 1))
        idf = df.mapValues { log((n + 1) / (Double($0) + 1)) + 1 }
        ticketVecs = docs.map { ($0.key, Self.vec($0.toks, idf: idf), $0.prior) }
    }

    func rank(context: String, max: Int) -> [TicketGuess] {
        guard !ticketVecs.isEmpty else { return [] }
        if let cached = cache[context] { return Array(cached.prefix(max)) }
        let cv = Self.vec(Self.tokens(context), idf: idf)
        guard !cv.isEmpty else { return [] }
        let scored = ticketVecs
            // Multiplicative prior preserves abstention: cosine 0 stays 0.
            .map { TicketGuess(key: $0.key, score: Self.cosine(cv, $0.vec) * $0.prior) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
        cache[context] = scored
        return Array(scored.prefix(max))
    }

    // MARK: - Internals

    private static let stop: Set<String> = [
        "the", "and", "for", "not", "all", "able", "new", "user", "story", "bug", "epic",
        "with", "this", "that", "from", "into", "via", "com", "www", "http", "https",
    ]

    static func tokens(_ s: String) -> [String] {
        s.lowercased().unicodeScalars
            .split { !CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }
            .filter { $0.count > 2 && !stop.contains($0) }
    }

    /// IDF-weighted term vector. Only keeps tokens present in the corpus vocabulary,
    /// so out-of-vocabulary context tokens don't inflate the norm (preserving abstention).
    private static func vec(_ toks: [String], idf: [String: Double]) -> [String: Double] {
        var v: [String: Double] = [:]
        for t in Set(toks) { if let w = idf[t] { v[t] = w } }
        return v
    }

    static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        var dot = 0.0
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        for (k, va) in small { if let vb = large[k] { dot += va * vb } }
        let na = a.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let nb = b.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return (na == 0 || nb == 0) ? 0 : dot / (na * nb)
    }
}
