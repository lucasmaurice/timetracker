import Foundation

/// Minimal Tempo Cloud REST client (https://api.tempo.io/4) for posting worklogs.
/// Tempo auth is SEPARATE from Jira — a Tempo API token (Settings → API integration in Tempo),
/// stored in the Keychain. Read off-main via preload() to avoid blocking the UI on the prompt.
/// Tempo's worklog author is a Jira accountId, so this client is handed the connected `Atlassian`
/// instance to resolve it — `resolveAuthor()` is the only WorklogProvider method that needs it.
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class TempoClient: WorklogProvider, Preloadable, @unchecked Sendable {
    var displayName: String { "Tempo" }
    private static let account = "tempo_token"
    private static let base = "https://api.tempo.io/4"
    private let config: Config
    private let atlassian: Atlassian

    /// Guards every mutable field. `preload()` deliberately runs on a background queue (the
    /// Keychain can block on a permission prompt), while main reads `configured` when rebuilding
    /// the menu — so these were genuinely racing. Never held across an `await`.
    private let lock = NSLock()
    private func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private var loaded = false
    private var cachedToken: String?

    /// (day|block) → tempoWorklogId, so re-submitting replaces instead of duplicating.
    /// Tiny metadata file, NOT pruned with segments (resubmission needs it).
    private var worklogMap: [String: Int] = [:]
    private var mapFile: URL { AppPaths.dataDir.appendingPathComponent("tempo-worklogs.json") }

    init(config: Config, atlassian: Atlassian) {
        self.config = config
        self.atlassian = atlassian
        if let data = try? Data(contentsOf: mapFile),
           let m = try? JSONDecoder().decode([String: Int].self, from: data) { worklogMap = m }   // init: no contention yet
    }

    private func mapKey(day: String, block: String) -> String { "\(day)|\(block)" }
    func worklogId(day: String, block: String) -> String? {
        sync { worklogMap[mapKey(day: day, block: block)] }.map(String.init)
    }

    /// The Tempo worklog author is your Jira account — Tempo has no separate identity of its own.
    func resolveAuthor() async -> String? { await atlassian.accountId() }

    private func saveMap() {
        try? FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
        let snapshot = sync { worklogMap }
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: mapFile, options: [.atomic]) }
    }

    func legacyFixedBlockWorklogIds(day: String) -> [(block: String, id: String)] {
        WorklogKey.legacyIds(in: sync { worklogMap }, day: day)
    }

    func setWorklogId(day: String, block: String, id: String?) {
        sync {
            if let id, let intId = Int(id) { worklogMap[mapKey(day: day, block: block)] = intId }
            else { worklogMap.removeValue(forKey: mapKey(day: day, block: block)) }
        }
        saveMap()
    }

    /// Drop map entries for days older than `days` (resubmission no longer realistic).
    func pruneWorklogMap(olderThanDays days: Double) {
        guard days > 0 else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = .current
        let cutoff = Date().addingTimeInterval(-days * 86400)
        sync {
            worklogMap = worklogMap.filter { kv in
                guard let dayStr = kv.key.split(separator: "|").first, let d = f.date(from: String(dayStr)) else { return true }
                return d >= cutoff
            }
        }
        saveMap()
    }

    /// Read the token once, off the main thread (Keychain can block on a permission prompt).
    func preload() {
        guard sync({ !loaded }) else { return }
        let t = Keychain.getCodable(String.self, account: Self.account)   // outside the lock
        sync { cachedToken = t; loaded = true }
    }

    var configured: Bool { sync { cachedToken != nil } }

    func connect(token: String) {
        Keychain.setCodable(token, account: Self.account)
        sync { cachedToken = token; loaded = true }
    }

    func disconnect() {
        Keychain.delete(account: Self.account)
        sync { cachedToken = nil; loaded = true }
    }

    /// Create one Tempo worklog. Throws with the server message on failure (e.g. a missing
    /// mandatory work attribute), which the caller surfaces so you see exactly what Tempo wants.
    /// Create a worklog; returns the tempoWorklogId (for later update/delete) when present.
    @discardableResult
    func createWorklog(issueId: String, author: String?, date: String, startTime: String,
                       seconds: Int, description: String) async throws -> String? {
        guard let token = sync({ cachedToken }) else { throw TempoError.notConfigured }
        guard let author else { throw TempoError.notConfigured }
        guard let issueIdInt = Int(issueId) else { throw TempoError.badURL }
        guard let url = URL(string: "\(Self.base)/worklogs") else { throw TempoError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "issueId": issueIdInt,
            "timeSpentSeconds": seconds,
            "startDate": date,
            "startTime": startTime,
            "description": description,
            "authorAccountId": author,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TempoError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            throw TempoError.http(http.statusCode, String(String(data: data, encoding: .utf8)?.prefix(400) ?? ""))
        }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["tempoWorklogId"] as? Int).map(String.init)
    }

    /// Delete a previously-created worklog. 404 (already gone) is tolerated.
    func deleteWorklog(id: String) async {
        guard let token = sync({ cachedToken }), let url = URL(string: "\(Self.base)/worklogs/\(id)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }
}

enum TempoError: LocalizedError {
    case notConfigured, badURL, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Tempo token. Use “Connect Tempo…” first."
        case .badURL: return "Invalid Tempo request."
        case .http(let c, let m):
            let hint = c == 401 ? " (check the Tempo API token)" : ""
            return "Tempo HTTP \(c)\(hint): \(m)"
        }
    }
}
