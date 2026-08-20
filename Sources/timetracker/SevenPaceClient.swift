import Foundation

/// 7pace Timetracker REST client (https://{org}.timehub.7pace.com/api/rest), Bearer-token auth.
/// Worklog ids are string UUIDs (not Tempo's Int), so this keeps its own `(day|block) → uuid`
/// map file rather than sharing `TempoClient`'s — widening that file's value type to a UUID would
/// hit its `try?`-and-silently-empty decode path on the first old-format read, turning every
/// future resubmit into a duplicate instead of a replace.
///
/// Two things about this client are UNVERIFIED against a real 7pace tenant (no test tenant was
/// available while building this): whether `userId` is required in the create-worklog body or the
/// API infers it from the bearer token, and the exact response envelope shape. `createWorklog`
/// logs the raw response body via `lastRawResponse` for the first real submit to be checked
/// against; adjust `WorklogResponse`'s decoding if the tenant's shape differs.
final class SevenPaceClient: WorklogProvider {
    var displayName: String { "7pace" }
    private static let account = "sevenpace_token"
    private let config: Config

    private var loaded = false
    private var cachedToken: String?
    var configured: Bool { cachedToken != nil }

    /// (day|block) → 7pace worklog id (a UUID string). Its own file — see the type note above.
    private var worklogMap: [String: String] = [:]
    private var mapFile: URL { AppPaths.dataDir.appendingPathComponent("sevenpace-worklogs.json") }

    /// The raw JSON of the most recent createWorklog response, for verifying the envelope shape
    /// against a real tenant (see the type-level doc comment).
    private(set) var lastRawResponse: String?

    init(config: Config) {
        self.config = config
        if let data = try? Data(contentsOf: mapFile),
           let m = try? JSONDecoder().decode([String: String].self, from: data) { worklogMap = m }
    }

    private func mapKey(day: String, block: String) -> String { "\(day)|\(block)" }
    func worklogId(day: String, block: String) -> String? { worklogMap[mapKey(day: day, block: block)] }

    func legacyFixedBlockWorklogIds(day: String) -> [(block: String, id: String)] {
        WorklogKey.legacyIds(in: worklogMap, day: day)
    }

    func setWorklogId(day: String, block: String, id: String?) {
        if let id { worklogMap[mapKey(day: day, block: block)] = id }
        else { worklogMap.removeValue(forKey: mapKey(day: day, block: block)) }
        saveMap()
    }

    private func saveMap() {
        try? FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(worklogMap) { try? data.write(to: mapFile, options: [.atomic]) }
    }

    /// Drop map entries for days older than `days` (resubmission no longer realistic).
    func pruneWorklogMap(olderThanDays days: Double) {
        guard days > 0 else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = .current
        let cutoff = Date().addingTimeInterval(-days * 86400)
        worklogMap = worklogMap.filter { kv in
            guard let dayStr = kv.key.split(separator: "|").first, let d = f.date(from: String(dayStr)) else { return true }
            return d >= cutoff
        }
        saveMap()
    }

    func preload() {
        guard !loaded else { return }
        cachedToken = Keychain.getCodable(String.self, account: Self.account)
        loaded = true
    }

    func connect(token: String) {
        Keychain.setCodable(token, account: Self.account)
        cachedToken = token; loaded = true
    }

    func disconnect() {
        Keychain.delete(account: Self.account)
        cachedToken = nil; loaded = true
    }

    private func base() -> String? {
        let org = config.sevenPaceOrg.trimmingCharacters(in: .whitespaces)
        guard !org.isEmpty else { return nil }
        return "https://\(org).timehub.7pace.com/api/rest"
    }

    /// 7pace has no separate "who am I" identity call documented for the CRUD API; unlike Tempo
    /// (which needs a Jira accountId it can't derive itself), the worklog's author may simply be
    /// inferred by the API from the bearer token — see the type-level doc comment. Returns nil,
    /// which `createWorklog` treats as "omit userId from the body" rather than failing outright.
    func resolveAuthor() async -> String? { nil }

    private struct WorklogResponse: Decodable {
        struct Envelope: Decodable { var data: Inner? }
        struct Inner: Decodable { var id: String }
        var data: Inner?
        var id: String?
        var resolvedId: String? { data?.id ?? id }
    }

    @discardableResult
    func createWorklog(issueId: String, author: String?, date: String, startTime: String,
                       seconds: Int, description: String) async throws -> String? {
        guard let token = cachedToken else { throw SevenPaceError.notConfigured }
        guard let base = base(), let url = URL(string: "\(base)/workLogs?api-version=3.2") else {
            throw SevenPaceError.notConfigured
        }
        guard let workItemId = Int(issueId) else { throw SevenPaceError.badRequest("issueId isn't numeric: \(issueId)") }

        // ISO 8601 local-time timestamp combining the block's day + start time (7pace's `timeStamp`
        // has no separate date/time split like Tempo's startDate/startTime).
        let timeStamp = "\(date)T\(startTime)"

        var body: [String: Any] = [
            "timeStamp": timeStamp,
            "length": seconds,
            "billableLength": seconds,
            "workItemId": workItemId,
            "comment": description,
        ]
        let activityTypeId = config.sevenPaceActivityTypeId.trimmingCharacters(in: .whitespaces)
        if !activityTypeId.isEmpty { body["activityTypeId"] = activityTypeId }
        if let author { body["userId"] = author }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        lastRawResponse = String(data: data, encoding: .utf8)
        guard let http = resp as? HTTPURLResponse else { throw SevenPaceError.badRequest("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw SevenPaceError.http(http.statusCode, String(String(data: data, encoding: .utf8)?.prefix(400) ?? ""))
        }
        // Tolerant of either an enveloped {"data": {"id": ...}} or a bare {"id": ...} response —
        // the exact shape wasn't verifiable against a real tenant while building this.
        return (try? JSONDecoder().decode(WorklogResponse.self, from: data))?.resolvedId
    }

    func deleteWorklog(id: String) async {
        guard let token = cachedToken, let base = base(),
              let url = URL(string: "\(base)/workLogs/\(id)?api-version=3.2") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Activity types available for `sevenPaceActivityTypeId`, for Settings to show a real picker
    /// instead of asking for a bare UUID.
    struct ActivityType: Decodable { var id: String; var name: String }
    func fetchActivityTypes() async -> [ActivityType] {
        guard let token = cachedToken, let base = base(),
              let url = URL(string: "\(base)/activityTypes?api-version=3.2") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
        else { return [] }
        if let list = try? JSONDecoder().decode([ActivityType].self, from: data) { return list }
        struct Wrapped: Decodable { var data: [ActivityType]? }
        return (try? JSONDecoder().decode(Wrapped.self, from: data))?.data ?? []
    }
}

enum SevenPaceError: LocalizedError {
    case notConfigured, badRequest(String), http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No 7pace token or organization. Use “Connect 7pace…” first."
        case .badRequest(let m): return "Invalid 7pace request: \(m)"
        case .http(let c, let m):
            let hint = c == 401 || c == 403 ? " (check the 7pace token)" : ""
            return "7pace HTTP \(c)\(hint): \(m)"
        }
    }
}
