import Foundation

/// Reads your *own* AI coding-session history (Claude Code, VSCode/Copilot, Kiro) from the
/// local files those tools write — the single highest-signal source, since your prompts
/// describe the task in your own words. This is NOT keylogging or screen capture: it reads
/// session transcripts the apps persist, same as reading `git log`. Stays local.
///
/// Output is capped (a title + a few recent prompts, truncated) so the context stays compact.
final class SessionReader {
    private var cache: [String: (value: String?, at: Date)] = [:]
    private let ttl: TimeInterval = 60
    private let fm = FileManager.default

    /// Best recent AI-session text for the active repo (falls back to the globally newest
    /// Claude Code session touched in the last 15 min).
    func recentWork(repoPath: String?, now: Date) -> String? {
        let key = repoPath ?? "__global__"
        if let c = cache[key], now.timeIntervalSince(c.at) < ttl { return c.value }

        var out: [String] = []
        if let repoPath {
            if let c = claudeCodeForRepo(repoPath) { out.append("Claude Code: \(c)") }
            if let v = vscodeForRepo(repoPath) { out.append("Copilot: \(v)") }
            if let k = kiroForRepo(repoPath) { out.append("Kiro: \(k)") }
        }
        if out.isEmpty, let g = claudeCodeNewest(within: 900, now: now) { out.append("Claude Code: \(g)") }

        let value = out.isEmpty ? nil : out.joined(separator: " ⏐ ")
        cache[key] = (value, now)
        return value
    }

    // MARK: - Claude Code (~/.claude/projects/<encoded-cwd>/<uuid>.jsonl)

    private var claudeProjects: URL { fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects") }

    /// Claude Code encodes the cwd by replacing every non-alphanumeric character with "-" — NOT
    /// just "/" and "." as originally assumed here. Confirmed against a real path containing "@"
    /// (a domain-joined remote account, "lmaurice@progi.local"): the real encoded directory name
    /// had no "@" in it, which a "/"-and-"."-only replacement would have left in place, silently
    /// missing every session for that path. Doesn't change behavior for typical Mac paths (no
    /// special characters beyond "/" and "."), which is why this went unnoticed until a path with
    /// an unusual character actually hit it.
    private func encodeCwd(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    private func claudeCodeForRepo(_ repoPath: String) -> String? {
        let dir = claudeProjects.appendingPathComponent(encodeCwd(repoPath))
        guard let newest = newestFile(in: dir, ext: "jsonl") else { return nil }
        return summarizeClaudeJSONL(newest)
    }

    private func claudeCodeNewest(within seconds: TimeInterval, now: Date) -> String? {
        guard let dirs = try? fm.contentsOfDirectory(at: claudeProjects, includingPropertiesForKeys: nil) else { return nil }
        var best: (url: URL, at: Date)?
        for d in dirs {
            guard let f = newestFile(in: d, ext: "jsonl"),
                  let m = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(m) < seconds else { continue }
            if best == nil || m > best!.at { best = (f, m) }
        }
        return best.flatMap { summarizeClaudeJSONL($0.url) }
    }

    /// Pull the AI session title + the last few user prompts from a Claude Code transcript.
    private func summarizeClaudeJSONL(_ url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var title: String?
        var userMsgs: [String] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "ai-title":
                if let t = obj["aiTitle"] as? String { title = t }
            case "user":
                if let t = Self.userText(obj["message"]) { userMsgs.append(t) }
            default: break
            }
        }
        var parts: [String] = []
        if let title { parts.append(title) }
        // Last 3 prompts, skipping our own one-word controls.
        let recent = userMsgs.filter { $0.count > 4 }.suffix(3).map { String($0.prefix(200)) }
        parts.append(contentsOf: recent)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func userText(_ message: Any?) -> String? {
        guard let m = message as? [String: Any] else { return nil }
        if let s = m["content"] as? String { return s }
        if let arr = m["content"] as? [[String: Any]] {
            let texts = arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            return texts.isEmpty ? nil : texts.joined(separator: " ")
        }
        return nil
    }

    // MARK: - VSCode / Copilot (workspaceStorage/<hash>/chatSessions/*.json)

    private func vscodeForRepo(_ repoPath: String) -> String? {
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage")
        guard let hashDir = workspaceDir(in: base, matching: repoPath) else { return nil }
        // Modern Copilot Chat writes single-object .jsonl; older builds used .json.
        guard let newest = newestFile(in: hashDir.appendingPathComponent("chatSessions"), exts: ["jsonl", "json"]) else { return nil }
        return vscodeChatSummary(newest) ?? harvestText(from: newest)
    }

    /// Targeted parse of a Copilot Chat session: pull the user's recent prompt text from
    /// `v.requests[].message.text` (avoids the generic harvester scooping up model/UI noise).
    private func vscodeChatSummary(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let v = (obj["v"] as? [String: Any]) ?? obj
        guard let requests = v["requests"] as? [[String: Any]] else { return nil }
        let texts = requests.compactMap { ($0["message"] as? [String: Any])?["text"] as? String }.filter { $0.count > 4 }
        let recent = texts.suffix(3).map { String($0.prefix(200)) }
        return recent.isEmpty ? nil : recent.joined(separator: " · ")
    }

    // MARK: - Kiro (globalStorage/kiro.kiroagent/workspace-sessions/<base64(path)>/sessions.json)

    private func kiroForRepo(_ repoPath: String) -> String? {
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent/workspace-sessions")
        // Kiro encodes the workspace path as base64 but replaces '=' padding with '_', which broke
        // a naive match for any path whose length isn't a multiple of 3. Match by decoding each
        // dir name back to a path instead — robust to that and to base64url variants.
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil),
              let dir = dirs.first(where: { Self.decodeBase64Path($0.lastPathComponent) == repoPath })
        else { return nil }
        return kiroSummary(dir)
    }

    /// Decode a Kiro/base64(url) directory name back to the workspace path it encodes.
    private static func decodeBase64Path(_ name: String) -> String? {
        var s = name.replacingOccurrences(of: "_", with: "=").replacingOccurrences(of: "-", with: "+")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Newest Kiro session for a workspace: its title + the last few of your prompts, pulled from
    /// `<sessionId>.json` history (sessions.json is just the index). Falls back to recent titles.
    private func kiroSummary(_ dir: URL) -> String? {
        let indexURL = dir.appendingPathComponent("sessions.json")
        guard let data = try? Data(contentsOf: indexURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let createdMs: ([String: Any]) -> Double = { Double($0["dateCreated"] as? String ?? "0") ?? 0 }
        let newest = arr.max { createdMs($0) < createdMs($1) }
        var parts: [String] = []
        if let title = newest?["title"] as? String { parts.append(title) }
        if let sid = newest?["sessionId"] as? String,
           let sdata = try? Data(contentsOf: dir.appendingPathComponent("\(sid).json")),
           let sobj = try? JSONSerialization.jsonObject(with: sdata) as? [String: Any],
           let history = sobj["history"] as? [[String: Any]] {
            let userTexts = history.compactMap { entry -> String? in
                guard let m = entry["message"] as? [String: Any], (m["role"] as? String) == "user" else { return nil }
                if let c = m["content"] as? [[String: Any]] {
                    let t = c.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                    return t.isEmpty ? nil : t
                }
                return m["content"] as? String
            }
            parts.append(contentsOf: userTexts.suffix(3).map { String($0.prefix(200)) })
        }
        if parts.count <= 1 {
            parts.append(contentsOf: arr.compactMap { $0["title"] as? String }.suffix(3).map { String($0.prefix(120)) })
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    /// Find the VSCode/Kiro workspaceStorage hash dir whose workspace.json folder == repoPath.
    private func workspaceDir(in base: URL, matching repoPath: String) -> URL? {
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        let want = "file://" + repoPath
        for d in dirs {
            let wj = d.appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: wj),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = obj["folder"] as? String else { continue }
            if folder == want || folder.hasSuffix(repoPath) { return d }
        }
        return nil
    }

    private func newestFile(in dir: URL, ext: String) -> URL? { newestFile(in: dir, exts: [ext]) }

    private func newestFile(in dir: URL, exts: [String]) -> URL? {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { exts.contains($0.pathExtension) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .max { $0.1 < $1.1 }?.0
    }

    /// Tolerant extractor for unknown chat JSON: pull recent string values under text-ish keys.
    private func harvestText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: [String] = []
        Self.harvest(obj, into: &found)
        let recent = found.filter { $0.count > 4 }.suffix(4).map { String($0.prefix(200)) }
        return recent.isEmpty ? nil : recent.joined(separator: " · ")
    }

    private static let textKeys: Set<String> = ["text", "message", "prompt", "request", "title", "aiTitle", "name"]

    private static func harvest(_ any: Any, into out: inout [String]) {
        if let dict = any as? [String: Any] {
            for (k, v) in dict {
                if textKeys.contains(k), let s = v as? String { out.append(s) }
                else { harvest(v, into: &out) }
            }
        } else if let arr = any as? [Any] {
            for v in arr { harvest(v, into: &out) }
        }
    }
}
