import Foundation

/// Remembers tickets you explicitly assign, keyed by coarse context signatures
/// (repo / URL host / app), so future guesses in the same context lean your way.
/// Persisted locally. Counts let us require repeated confirmation before auto-tagging.
final class CorrectionStore {
    private var map: [String: [String: Int]] = [:]   // signature -> (ticket -> count)
    private let file = AppPaths.dataDir.appendingPathComponent("corrections.json")

    init() { load() }

    func record(signatures: [String], ticket: String) {
        guard !ticket.isEmpty else { return }
        for s in signatures { map[s, default: [:]][ticket, default: 0] += 1 }
        save()
    }

    /// One-time hygiene: normalize/repair or drop poisoned ticket keys. `normalize` returns a
    /// clean key (kept/merged) or nil (dropped). Counts merge when two keys normalize to one.
    /// Returns the number of entries changed.
    @discardableResult
    func sanitize(_ normalize: (String) -> String?) -> Int {
        var changed = 0
        var newMap: [String: [String: Int]] = [:]
        for (sig, tickets) in map {
            var merged: [String: Int] = [:]
            for (ticket, count) in tickets {
                guard let clean = normalize(ticket) else { changed += 1; continue }
                if clean != ticket { changed += 1 }
                merged[clean, default: 0] += count
            }
            if !merged.isEmpty { newMap[sig] = merged }
        }
        if changed > 0 { map = newMap; save() }
        return changed
    }

    /// The ticket most often confirmed across the given signatures, with its total count.
    func best(forSignatures sigs: [String]) -> (ticket: String, count: Int)? {
        var tally: [String: Int] = [:]
        for s in sigs { for (t, c) in map[s] ?? [:] { tally[t, default: 0] += c } }
        guard let top = tally.max(by: { $0.value < $1.value }) else { return nil }
        return (top.key, top.value)
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let m = try? JSONDecoder().decode([String: [String: Int]].self, from: data) else { return }
        map = m
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: file, options: [.atomic]) }
    }
}
