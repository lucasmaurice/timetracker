import AppKit
import Foundation

/// Atlassian Jira client using an **API token** (email + token, Basic auth) routed through
/// the `api.atlassian.com/ex/jira/{cloudId}` gateway. This gateway path works for both
/// scoped and classic tokens (a scoped token returns 401 against `<site>.atlassian.net`,
/// so we always go through the gateway and resolve the cloud id from the site).
///
/// Required token scopes: read:jira-work (search) and read:jira-user or read:me (/myself).
/// Create a token at https://id.atlassian.com/manage-profile/security/api-tokens
///
/// Credentials live in the login Keychain, never in config.json. Network calls happen only
/// on Connect (cloud-id resolve + validate) and Refresh; focus logging stays fully offline.
final class Atlassian: IssueProvider {
    var displayName: String { "Jira" }
    struct Credentials: Codable { var site: String; var email: String; var token: String; var cloudId: String }

    private static let account = "api_credentials"
    private let config: Config

    init(config: Config) { self.config = config }

    // Read the Keychain at most ONCE per launch and cache the result. The menu rebuilds
    // every focus change, and hitting the Keychain each time caused a prompt storm under
    // ad-hoc signing (every read re-prompts). After the first read (one prompt, click
    // "Always Allow"), all later checks are in-memory.
    private var loaded = false
    private var cached: Credentials?

    /// Pure in-memory — NEVER hits the Keychain on the calling thread. SecItemCopyMatching
    /// can block waiting on a permission prompt, which froze the menu-bar UI at launch.
    private var credentials: Credentials? { cached }
    var configured: Bool { cached != nil }
    var site: String? { cached?.site }

    /// Read the Keychain exactly once. MUST be called off the main thread (see above).
    func preload() {
        guard !loaded else { return }
        cached = Keychain.getCodable(Credentials.self, account: Self.account)
        loaded = true
    }

    func disconnect() {
        Keychain.delete(account: Self.account)
        cached = nil; loaded = true
    }

    /// Accepts "acme", "acme.atlassian.net", or "https://acme.atlassian.net/" → host only.
    static func normalizeSite(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if !s.contains(".") { s += ".atlassian.net" }
        return s
    }

    /// Resolve the site's cloud id (unauthenticated) so we can address the gateway.
    private func resolveCloudId(site: String) async throws -> String {
        struct TenantInfo: Codable { var cloudId: String }
        guard let url = URL(string: "https://\(site)/_edge/tenant_info") else { throw AtlassianError.badURL }
        let (data, resp) = try await URLSession.shared.data(from: url)
        try Self.check(resp, data)
        return try JSONDecoder().decode(TenantInfo.self, from: data).cloudId
    }

    /// Resolve cloud id, store credentials, and validate them. Returns the account name.
    @discardableResult
    func connect(site: String, email: String, token: String) async throws -> String {
        let normSite = Self.normalizeSite(site)
        let cloudId = try await resolveCloudId(site: normSite)
        let creds = Credentials(site: normSite, email: email, token: token, cloudId: cloudId)
        // Same ordering rule as AzureDevOps.connect: in memory so testConnection() can use them,
        // on disk only once they're known good. resolveCloudId above validates the SITE, not the
        // token — an unverified token was still being persisted whenever the test threw.
        cached = creds; loaded = true
        let who = try await testConnection()
        Keychain.setCodable(creds, account: Self.account)   // own the item under THIS binary
        return who
    }

    // MARK: - Requests

    private func authedRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let creds = credentials else { throw AtlassianError.notConfigured }
        var comps = URLComponents(string: "https://api.atlassian.com/ex/jira/\(creds.cloudId)\(path)")!
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw AtlassianError.badURL }
        var req = URLRequest(url: url)
        let basic = Data("\(creds.email):\(creds.token)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private struct Myself: Codable { var accountId: String?; var displayName: String?; var emailAddress: String? }
    private var cachedAccountId: String?

    /// Validate credentials; returns the account display name on success.
    @discardableResult
    func testConnection() async throws -> String {
        let req = try authedRequest(path: "/rest/api/3/myself")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        let me = try JSONDecoder().decode(Myself.self, from: data)
        cachedAccountId = me.accountId
        return me.displayName ?? me.emailAddress ?? "connected"
    }

    /// The current user's Atlassian accountId (needed as the Tempo worklog author).
    func accountId() async -> String? {
        if let id = cachedAccountId { return id }
        guard let req = try? authedRequest(path: "/rest/api/3/myself"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let me = try? JSONDecoder().decode(Myself.self, from: data) else { return nil }
        cachedAccountId = me.accountId
        return me.accountId
    }

    /// Resolve a ticket key to its numeric Jira issue id (fallback when not in the corpus).
    func fetchIssueId(forKey key: String) async -> String? {
        guard let req = try? authedRequest(path: "/rest/api/3/issue/\(key)", query: [.init(name: "fields", value: "id")]),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["id"] as? String
    }

    func browserURL(forKey key: String, project: String?) -> URL? {
        guard let site else { return nil }
        return URL(string: "https://\(site)/browse/\(key)")
    }

    /// Recursively flatten an ADF (Atlassian Document Format) node tree into plain text.
    private static func flattenADF(_ node: Any?) -> String {
        if let dict = node as? [String: Any] {
            var s = dict["text"] as? String ?? ""
            if let content = dict["content"] as? [Any] {
                s += " " + content.map { flattenADF($0) }.joined(separator: " ")
            }
            return s
        }
        if let arr = node as? [Any] { return arr.map { flattenADF($0) }.joined(separator: " ") }
        return ""
    }


    /// Issue keys in the board's ACTIVE sprint(s), via the Jira Agile API — more reliable
    /// than sniffing the Sprint custom field. Empty set if the board has no active sprint
    /// or the call fails (ranking then falls back to status + recency).
    private func activeSprintKeys(boardId: Int) async -> Set<String> {
        var keys = Set<String>()
        guard let req = try? authedRequest(path: "/rest/agile/1.0/board/\(boardId)/sprint",
                                           query: [.init(name: "state", value: "active")]),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sprints = root["values"] as? [[String: Any]] else { return keys }

        for sp in sprints {
            guard let sid = sp["id"] as? Int else { continue }
            var startAt = 0
            while true {
                guard let r = try? authedRequest(path: "/rest/agile/1.0/sprint/\(sid)/issue",
                          query: [.init(name: "fields", value: "key"),
                                  .init(name: "maxResults", value: "100"),
                                  .init(name: "startAt", value: "\(startAt)")]),
                      let (d, rp) = try? await URLSession.shared.data(for: r),
                      (rp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { break }
                let issues = obj["issues"] as? [[String: Any]] ?? []
                for i in issues { if let k = i["key"] as? String { keys.insert(k) } }
                let total = obj["total"] as? Int ?? 0
                startAt += issues.count
                if issues.isEmpty || startAt >= total { break }
            }
        }
        return keys
    }

    /// Internal rather than private so the assignee tri-state below can be tested against fixture
    /// payloads — the bug it encodes (field read but never requested) shipped once.
    func parseTicket(_ issue: [String: Any], sprintKeys: Set<String>, queueKeys: Set<String>,
                             commonKeys: Set<String>, sprintFieldId: String?) -> Ticket? {
        guard let key = issue["key"] as? String, let f = issue["fields"] as? [String: Any] else { return nil }
        let summary = f["summary"] as? String ?? ""
        let labels = f["labels"] as? [String] ?? []
        let components = (f["components"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let type = (f["issuetype"] as? [String: Any])?["name"] as? String
        let epic = ((f["parent"] as? [String: Any])?["fields"] as? [String: Any])?["summary"] as? String
        let statusObj = f["status"] as? [String: Any]
        let status = statusObj?["name"] as? String
        let done = ((statusObj?["statusCategory"] as? [String: Any])?["key"] as? String) == "done"
        let updated = f["updated"] as? String
        let desc = Self.flattenADF(f["description"])
        let text = Ticket.buildMatchText(summary: summary, type: type, epic: epic,
                                        components: components, labels: labels, description: desc)
        // inSprint = in a board's active sprint (Agile API) OR the issue's Sprint custom field has
        // an active sprint (fallback for boards where the Agile sprint endpoint returns nothing).
        let inSprint = sprintKeys.contains(key) || Self.hasActiveSprint(f[sprintFieldId ?? ""])
        // parseTicket is shared by the "assignee = currentUser()" fetch AND the queue/common-JQL
        // fetches (which explicitly pull in tickets that may not be assigned to you) — so check the
        // issue's own assignee against the connected account rather than trusting which query found
        // it. Three distinct cases, deliberately NOT collapsed into one `else` (an earlier version
        // did, which made an unassigned ticket read as yours):
        //   key absent   → the field wasn't requested; we genuinely can't tell → true (majority case)
        //   key null     → the issue really is unassigned → NOT yours
        //   dict present → compare identity; fall back to true only if we have no identity at all
        let assignedToMe: Bool
        if let assignee = f["assignee"] as? [String: Any] {
            if let acct = assignee["accountId"] as? String, let mine = cachedAccountId {
                assignedToMe = acct == mine
            } else if let email = assignee["emailAddress"] as? String, let mine = credentials?.email {
                assignedToMe = email.caseInsensitiveCompare(mine) == .orderedSame
            } else {
                assignedToMe = true   // assigned to someone, but we can't resolve our own identity
            }
        } else {
            assignedToMe = !f.keys.contains("assignee")   // null = unassigned; absent = unknown
        }
        return Ticket(key: key, summary: summary, text: text, status: status, updated: updated,
                      done: done, inSprint: inSprint, inQueue: queueKeys.contains(key),
                      common: commonKeys.contains(key.uppercased()), issueId: issue["id"] as? String,
                      assignedToMe: assignedToMe)
    }

    /// True if a Sprint custom-field value contains an active sprint. Jira Cloud returns an array
    /// of dicts ({state:"active",…}); older instances return strings containing "state=ACTIVE".
    private static func hasActiveSprint(_ value: Any?) -> Bool {
        if let arr = value as? [[String: Any]] {
            return arr.contains { ($0["state"] as? String)?.lowercased() == "active" }
        }
        if let arr = value as? [String] {
            return arr.contains { $0.lowercased().contains("state=active") }
        }
        return false
    }

    /// Resolve the Sprint custom-field id once (its schema.custom is the greenhopper sprint type).
    private var cachedSprintFieldId: String??
    private func sprintFieldId() async -> String? {
        if let cached = cachedSprintFieldId { return cached }
        guard let req = try? authedRequest(path: "/rest/api/3/field"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            cachedSprintFieldId = .some(nil); return nil
        }
        let id = fields.first { (($0["schema"] as? [String: Any])?["custom"] as? String) == "com.pyxis.greenhopper.jira:gh-sprint" }?["id"] as? String
        cachedSprintFieldId = .some(id)
        return id
    }

    /// Fetch ALL tickets assigned to the user, paginating to completion (the data lake),
    /// and (over)write sprint.json. Returns total and not-done counts.
    /// Fully-paginated `/search/jql` fetch for a JQL, returning raw issue dicts.
    private func fetchIssues(jql: String) async throws -> [[String: Any]] {
        // `assignee` is load-bearing, not cosmetic: parseTicket derives `Ticket.assignedToMe`
        // from it, and PeriodCompiler gates regular work on that. Omit it and every ticket silently
        // reads as "assigned to me" — the gate becomes a no-op with no visible error.
        var fields = "summary,labels,components,issuetype,parent,description,status,updated,assignee"
        if let sf = cachedSprintFieldId ?? nil { fields += ",\(sf)" }
        var out: [[String: Any]] = []
        var token: String?
        var pages = 0
        repeat {
            var q: [URLQueryItem] = [.init(name: "jql", value: jql),
                                     .init(name: "fields", value: fields),
                                     .init(name: "maxResults", value: "100")]
            if let t = token { q.append(.init(name: "nextPageToken", value: t)) }
            let req = try authedRequest(path: "/rest/api/3/search/jql", query: q)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.check(resp, data)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            out += root?["issues"] as? [[String: Any]] ?? []
            token = root?["nextPageToken"] as? String
            pages += 1
        } while token != nil && pages < 50
        return out
    }

    /// Resolve a service-desk's numeric id from its project key.
    private func serviceDeskId(projectKey: String) async -> Int? {
        var start = 0
        while true {
            guard let req = try? authedRequest(path: "/rest/servicedeskapi/servicedesk",
                                               query: [.init(name: "start", value: "\(start)"), .init(name: "limit", value: "100")]),
                  let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = root["values"] as? [[String: Any]] else { return nil }
            for v in values where (v["projectKey"] as? String) == projectKey {
                if let id = v["id"] as? Int { return id }
                if let s = v["id"] as? String { return Int(s) }
            }
            if (root["isLastPage"] as? Bool ?? true) || values.isEmpty { break }
            start += values.count
        }
        return nil
    }

    /// Issue keys in a service-desk queue, ref formatted "PROJECT/queueId" (e.g. "PES/246").
    private func queueIssueKeys(ref: String) async -> Set<String> {
        let parts = ref.split(separator: "/")
        guard parts.count == 2, let queueId = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return [] }
        let project = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
        guard let sdId = await serviceDeskId(projectKey: project) else { return [] }
        var keys = Set<String>()
        var start = 0
        while true {
            guard let req = try? authedRequest(path: "/rest/servicedeskapi/servicedesk/\(sdId)/queue/\(queueId)/issue",
                                               query: [.init(name: "start", value: "\(start)"), .init(name: "limit", value: "100")]),
                  let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            let values = root["values"] as? [[String: Any]] ?? []
            for v in values { if let k = v["key"] as? String { keys.insert(k) } }
            if (root["isLastPage"] as? Bool ?? true) || values.isEmpty { break }
            start += values.count
        }
        return keys
    }

    @discardableResult
    func refreshSprint() async throws -> RefreshResult {
        // Resolve the Sprint custom-field id first so every fetch includes it (fallback sprint
        // detection when the Agile board endpoint returns no active sprint).
        let sprintField = await sprintFieldId()
        // Board active-sprint keys and service-desk queue keys, tracked separately.
        var sprintKeys = Set<String>()
        for b in config.jiraBoardIds where b > 0 { sprintKeys.formUnion(await activeSprintKeys(boardId: b)) }
        var queueKeys = Set<String>()
        for q in config.jiraQueues { queueKeys.formUnion(await queueIssueKeys(ref: q)) }
        var commonKeys = Set(config.commonTickets.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty })

        var all: [Ticket] = []
        var seen = Set<String>()
        func add(_ issues: [[String: Any]]) {
            for issue in issues {
                if let t = parseTicket(issue, sprintKeys: sprintKeys, queueKeys: queueKeys,
                                       commonKeys: commonKeys, sprintFieldId: sprintField),
                   seen.insert(t.key).inserted { all.append(t) }
            }
        }

        // JQL-derived common tickets (e.g. "parent = PES-204") — fetched first so their keys
        // are flagged common and they enter the corpus even if unassigned.
        let commonJQL = config.commonTicketsJQL.trimmingCharacters(in: .whitespaces)
        if !commonJQL.isEmpty {
            let issues = (try? await fetchIssues(jql: commonJQL)) ?? []
            for i in issues { if let k = (i["key"] as? String)?.uppercased() { commonKeys.insert(k) } }
            add(issues)
        }

        var assignedJQL = "assignee = currentUser()"
        if config.jiraMaxAgeDays > 0 { assignedJQL += " AND updated >= -\(Int(config.jiraMaxAgeDays))d" }
        assignedJQL += " ORDER BY updated DESC"
        add(try await fetchIssues(jql: assignedJQL))

        // Pull queue + common tickets that aren't assigned to me into the corpus (chunked).
        let missing = Array(queueKeys.union(commonKeys).subtracting(seen))
        var i = 0
        while i < missing.count {
            let chunk = missing[i..<min(i + 50, missing.count)]
            add((try? await fetchIssues(jql: "key in (\(chunk.joined(separator: ",")))")) ?? [])
            i += 50
        }

        let f = ISO8601DateFormatter()
        let file = SprintFile(provider: IssueProviderKind.jira.rawValue, updated: f.string(from: Date()), tickets: all)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
        try enc.encode(file).write(to: AppPaths.sprintFile)
        return RefreshResult(total: all.count, open: all.filter { !$0.done }.count)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw AtlassianError.http(http.statusCode, String(body))
        }
    }
}

enum AtlassianError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Atlassian credentials. Use “Connect Atlassian…” first."
        case .badURL: return "Invalid Atlassian site."
        case .http(let c, let m):
            let hint = c == 401 ? " (check email + API token)" : c == 400 ? " (check project keys / JQL)" : ""
            return "Atlassian HTTP \(c)\(hint): \(m)"
        }
    }
}
