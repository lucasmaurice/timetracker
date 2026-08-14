import Foundation

/// Continuous semantic matcher backed by a local Ollama embedding model
/// (nomic-embed-text). Complements the lexical matcher by catching synonym cases
/// (e.g. "IAM Roles" ↔ an IRSA/OIDC ticket) that share no literal tokens.
///
/// All calls are async and run off the focus-sampling hot path. If Ollama is down or the
/// model is missing, every call no-ops and the app falls back to lexical + the periodic LLM.
final class EmbeddingMatcher {
    private let config: Config
    private var vectors: [(key: String, vec: [Double])] = []
    private var contextCache: [String: [TicketGuess]] = [:]

    init(config: Config) { self.config = config }

    var enabled: Bool { config.embeddingsEnabled }
    var isIndexed: Bool { !vectors.isEmpty }

    /// Embed all ticket texts once (batched). Call on launch and after each sprint refresh.
    func index(_ tickets: [Ticket]) async {
        guard config.embeddingsEnabled, !tickets.isEmpty else { return }
        contextCache.removeAll()
        guard let embs = await embed(tickets.map { $0.matchText }), embs.count == tickets.count else { return }
        vectors = zip(tickets, embs).map { ($0.0.key, $0.1) }
    }

    func rank(context: String, max: Int) async -> [TicketGuess] {
        guard config.embeddingsEnabled, !vectors.isEmpty else { return [] }
        if let c = contextCache[context] { return Array(c.prefix(max)) }
        guard let cv = await embed([context])?.first else { return [] }
        let scored = vectors
            .map { TicketGuess(key: $0.key, score: Self.cosine(cv, $0.vec)) }
            .sorted { $0.score > $1.score }
        contextCache[context] = scored
        return Array(scored.prefix(max))
    }

    // MARK: - Ollama /api/embed

    private struct EmbedResponse: Decodable { var embeddings: [[Double]] }

    private func embed(_ inputs: [String]) async -> [[Double]]? {
        guard let url = URL(string: "\(config.ollamaURL)/api/embed") else { return nil }
        let body: [String: Any] = ["model": config.embeddingModel, "input": inputs]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(EmbedResponse.self, from: data).embeddings
        } catch {
            return nil
        }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = na.squareRoot() * nb.squareRoot()
        return d == 0 ? 0 : dot / d
    }
}
