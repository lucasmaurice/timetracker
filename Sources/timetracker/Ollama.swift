import Foundation

/// Minimal client for a LOCAL Ollama instance (http://localhost:11434), used only at
/// prompt-time to phrase a ticket suggestion and break ties among the top embedding
/// candidates. Never used in the continuous hot path. Fully local; if Ollama isn't
/// running, every call returns nil and the caller falls back to the embedding guess.
final class Ollama {
    private let config: Config
    init(config: Config) { self.config = config }

    var enabled: Bool { config.ollamaEnabled }

    struct Suggestion: Decodable { var key: String; var reason: String; var confidence: Double? }

    /// Iteratively identify the ticket: the model sees the last hour of work (`arc`), the
    /// current moment, and its own `previous` guess, and refines. Returns nil on any failure.
    /// Build the exact (system, user) messages — shared by suggest() and the Inspector preview.
    func buildPrompt(arc: String, current: String, candidates: [Ticket],
                     previous: (key: String, reason: String)?, hints: String,
                     examples: [(context: String, ticket: String)]) -> (system: String, user: String) {
        let list = candidates.map { "\($0.key): \($0.llmText)" }.joined(separator: "\n")
        var system = """
        You identify which ONE Jira ticket a developer is currently working on, from the candidate
        keys below. The developer's OWN WORDS — the "AI session" text, and recent branch/commit
        names — are the strongest evidence; weigh the most recent activity most. Candidates often
        share an epic, so choose by which SERVICE / repo / files the current work touches, NOT the
        shared epic. KEEP your previous guess unless recent activity clearly points elsewhere.
        If NONE of the candidates genuinely matches the current work (e.g. the work is on a
        different tool, or simply has no ticket), answer "NONE" — do NOT force a wrong pick.
        Respond ONLY as compact JSON, reason first:
        {"reason":"<short why>","key":"<TICKET-KEY or NONE>","confidence":<0.0-1.0>}.
        """
        let workflow = config.workflowContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workflow.isEmpty { system += "\n\nWork context:\n\(workflow)" }

        var user = ""
        if !examples.isEmpty {
            user += "How the user has labeled similar work before (strong guidance):\n"
            user += examples.map { "- \($0.context) → \($0.ticket)" }.joined(separator: "\n") + "\n\n"
        }
        user += "CURRENT WORK (most important — what they're doing right now):\n\(current)\n\n"
        let trimmedArc = arc.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedArc.isEmpty && trimmedArc != "(no recorded activity yet)" {
            user += "Time per activity over the last hour:\n\(trimmedArc)\n\n"
        }
        if !hints.isEmpty { user += "Retrieval signals (candidate scores; higher = closer match):\n\(hints)\n\n" }
        if let p = previous { user += "Your previous guess was \(p.key) — \(p.reason). Keep it unless the current work clearly changed.\n\n" }
        user += "Candidate tickets (pick the ONE whose service/repo matches the current work, or NONE):\n\(list)"
        return (system, user)
    }

    /// The full prompt the LLM would receive right now (for the Inspector).
    func previewPrompt(arc: String, current: String, candidates: [Ticket],
                       previous: (key: String, reason: String)?, hints: String,
                       examples: [(context: String, ticket: String)]) -> String {
        let p = buildPrompt(arc: arc, current: current, candidates: candidates,
                            previous: previous, hints: hints, examples: examples)
        return "MODEL: \(config.ollamaModel)\n\n=== SYSTEM ===\n\(p.system)\n\n=== USER ===\n\(p.user)"
    }

    /// Memoize identical prompts (bounded) so the event-driven trigger + safety timer don't
    /// re-spend a local-model inference on a context we just judged.
    private var cache: [Int: Suggestion] = [:]
    private var cacheOrder: [Int] = []

    func suggest(arc: String, current: String, candidates: [Ticket],
                 previous: (key: String, reason: String)?, hints: String = "",
                 examples: [(context: String, ticket: String)] = []) async -> Suggestion? {
        guard config.ollamaEnabled, !candidates.isEmpty,
              let url = URL(string: "\(config.ollamaURL)/api/chat") else { return nil }

        let (system, user) = buildPrompt(arc: arc, current: current, candidates: candidates,
                                         previous: previous, hints: hints, examples: examples)
        var hasher = Hasher(); hasher.combine(system); hasher.combine(user)
        let key = hasher.finalize()
        if let hit = cache[key] { return hit }
        let body: [String: Any] = [
            "model": config.ollamaModel,
            "stream": false,
            "format": "json",
            "options": ["temperature": 0],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        struct ChatResponse: Decodable { struct Msg: Decodable { var content: String }; var message: Msg }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let inner = chat.message.content.data(using: .utf8) else { return nil }
            let sugg = try JSONDecoder().decode(Suggestion.self, from: inner)
            // The model is allowed to abstain ("NONE") when nothing fits — surface that as the
            // no-ticket label rather than forcing a wrong pick.
            if sugg.key.uppercased() == "NONE" || sugg.key.caseInsensitiveCompare(config.noTicketLabel) == .orderedSame {
                return Suggestion(key: config.noTicketLabel, reason: sugg.reason, confidence: sugg.confidence)
            }
            // Otherwise only trust a key that's actually in the candidate set.
            guard candidates.contains(where: { $0.key.caseInsensitiveCompare(sugg.key) == .orderedSame }) else { return nil }
            // Pass the model's self-reported confidence through — dropping it here was a bug
            // that left the LLM auto-tag gate (confidence >= threshold) permanently unreachable.
            let out = Suggestion(key: sugg.key.uppercased(), reason: sugg.reason, confidence: sugg.confidence)
            cache[key] = out
            cacheOrder.append(key)
            if cacheOrder.count > 64 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
            return out
        } catch {
            return nil
        }
    }
}
