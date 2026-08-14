import Foundation

/// Calibrated late-fusion ranker. Each signal (lexical, embedding, content memory, repo→ticket
/// history, status/recency prior, learned corrections, LLM) is first squashed onto a common
/// [0,1] "this signal believes ticket K" scale — killing the scale-mismatch bug where a raw
/// TF-IDF cosine of 0.18 and an embedding cosine of 0.6 were compared against one shared 0.6
/// floor. The per-candidate squashed signals are then combined by **noisy-OR**, so independent
/// signals that agree on the same ticket reinforce (two agreeing ≫ one strong), while a lone
/// signal is bounded by its own reliability. Abstention is preserved: a candidate with no
/// *grounded* signal (lexical/memory/repo/correction) can be a suggestion but never auto-tags.
///
/// This generalizes the old hand-rolled consensus (`reconcileAutoTag`) into one principled score.
enum FusionRanker {
    /// All raw signals for one candidate ticket in the current context. Absent signals are 0.
    struct Features {
        var lexical: Double = 0        // TicketMatcher cosine × prior
        var embedding: Double = 0      // EmbeddingMatcher cosine (async; 0 when not yet computed)
        var memory: Double = 0         // LabelMemory kNN top similarity (trust-weighted)
        var repo: Double = 0           // RepoTicketBridge share ≈ P(ticket | repo)
        var statusRecency: Double = 0  // ticket prior weight, normalized to ~[0,1]
        var correctionCount: Double = 0 // times this (signature → ticket) was confirmed
        var llmAgrees: Bool = false    // the LLM picked this ticket
        var llmConfidence: Double = 0  // and how confident it said it was
    }

    /// Logistic squash centered at `x0` with width `s`: maps a raw signal to [0,1] where x0 is
    /// "meaningfully present" (≈0.5). Centers are the signals' calibrated thresholds.
    private static func squash(_ x: Double, _ x0: Double, _ s: Double) -> Double {
        1 / (1 + exp(-(x - x0) / s))
    }

    /// Fuse one candidate's features into a calibrated probability in [0,1].
    static func fuse(_ f: Features, _ w: FusionWeights) -> Double {
        // Squash each raw signal to a comparable scale at its own natural threshold.
        let sLex = f.lexical > 0 ? squash(f.lexical, 0.18, 0.06) : 0
        let sEmb = f.embedding > 0 ? squash(f.embedding, 0.60, 0.08) : 0
        let sMem = f.memory > 0 ? squash(f.memory, 0.45, 0.10) : 0
        let sRepo = f.repo > 0 ? squash(f.repo, 0.25, 0.12) : 0
        let sStat = f.statusRecency > 0 ? min(1, f.statusRecency) : 0
        let sCorr = f.correctionCount > 0 ? squash(f.correctionCount, 1.5, 0.8) : 0
        let sLLM = (f.llmAgrees ? max(0.5, f.llmConfidence) : 0)

        // Noisy-OR over (reliability × squashed-signal): P = 1 − Π(1 − r_i·s_i).
        let votes: [(Double, Double)] = [
            (w.lexical, sLex), (w.embedding, sEmb), (w.memory, sMem), (w.repo, sRepo),
            (w.statusRecency, sStat), (w.correction, sCorr), (w.llm, sLLM),
        ]
        var inv = 1.0
        for (r, s) in votes { inv *= (1 - min(0.999, r * s)) }
        var p = 1 - inv

        // Preserve abstention: a candidate supported only by corroborators (embedding/LLM/status)
        // — with no grounded match — may surface as a suggestion but must never auto-tag.
        let grounded = sLex > 0 || sMem > 0 || sRepo > 0 || sCorr > 0
        if !grounded { p = min(p, w.suggestThreshold * 0.99) }
        return p
    }

    enum Decision { case autoTag, suggest, abstain }

    /// Apply the precision-first policy to a ranked, fused candidate list. `tierFactor` (≥1)
    /// stiffens the auto-tag bar in noisy contexts (browser/Slack/web) so they only ever suggest.
    static func decide(top: Double, runnerUp: Double, tierFactor: Double, _ w: FusionWeights) -> Decision {
        let tau = min(0.99, w.autoTagThreshold * tierFactor)
        if top >= tau && (top - runnerUp) >= w.margin { return .autoTag }
        if top >= w.suggestThreshold { return .suggest }
        return .abstain
    }
}
