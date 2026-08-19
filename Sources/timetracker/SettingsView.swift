import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var config: Config
    init(_ config: Config) { self.config = config }
}

/// Full settings form for every config.json field, with a short description under each.
/// Saving writes the file; a restart applies it (Config is copied into components at launch).
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Provider") {
                    Picker("Issue tracker", selection: $model.config.issueProvider) {
                        Text("Jira").tag(IssueProviderKind.jira)
                        Text("Azure DevOps").tag(IssueProviderKind.azureDevOps)
                    }
                    Picker("Time tracking", selection: $model.config.worklogProvider) {
                        Text("Tempo").tag(WorklogProviderKind.tempo)
                        Text("7pace").tag(WorklogProviderKind.sevenPace)
                    }
                    Text("Changes here need a restart to take effect — Config is copied into every component at launch.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("Tracking") {
                    num("Idle after (seconds)", \.idleSeconds, "No activity for this long counts as idle (excluded from billable time).")
                    num("Sample cadence (seconds)", \.sampleSeconds, "How often the focused window is sampled. App switches are caught instantly regardless.")
                    num("Workday starts at hour (0–24)", \.dayStartHour, "When your first timesheet block begins, e.g. 9 = 9am.")
                    num("Block length (hours)", \.blockHours, "Length of each timesheet block, e.g. 4 or 1.")
                    num("Workday length (hours)", \.workdayHours, "Total tracked hours/day. Blocks = workday ÷ block length (e.g. 8 ÷ 1 = 8 blocks).")
                }

                Section("Periods (floating blocks)") {
                    Text("Regular work still buckets into blockHours-sized chunks (above), but floats to skip over the carve-outs below instead of sitting on a fixed clock grid.")
                        .font(.caption2).foregroundStyle(.secondary)
                    text("Daily standup title match", $model.config.dailyStandupTitleMatch, "Substring (case-insensitive) that identifies your daily standup among detected meetings.")
                    text("Daily standup ticket", $model.config.dailyStandupTicket, "Where standup time is logged. Empty = abstain (no ticket).")
                    num("Break starts at hour", \.breakStartHour, "Local hour the fixed daily break begins, e.g. 12 = noon. Injected unconditionally, not detected from an idle gap.")
                    num("Break length (minutes)", \.breakDurationMinutes, "Fixed duration injected once/day regardless of actual activity then.")
                    text("Break ticket", $model.config.breakTicket, "Where break time is logged. Empty = abstain (no ticket).")
                    num("Merge gap (minutes)", \.periodMergeGapMinutes, "A brief interruption shorter than this doesn't split one continuous meeting/code-review session into two periods.")
                    num("Round non-regular periods to (minutes)", \.periodRoundMinutes, "Daily/break/code-review/meeting reported duration rounds to the nearest this-many minutes. Not applied to floating regular blocks.")
                    num("Minimum period length (minutes)", \.periodMinMinutes, "Floor for daily/break/code-review/meeting reported duration.")
                    num("Mention weight (seconds per mention)", \.periodMentionWeightSeconds, "How many seconds one explicit ticket-key mention (beyond time spent) is worth when scoring a regular block's ticket.")
                    toggle("Summer Friday enabled", $model.config.summerFridayEnabled, "Shortened Friday target during a yearly-recurring date range, instead of the normal workday length above.")
                    text("Summer Friday start (MM-dd)", $model.config.summerFridayStartMonthDay, "Inclusive range start, reapplied every year, e.g. 06-01.")
                    text("Summer Friday end (MM-dd)", $model.config.summerFridayEndMonthDay, "Inclusive range end, e.g. 08-31. Must not wrap across Dec→Jan.")
                    num("Summer Friday target (hours)", \.summerFridayHours, "Daily target on a qualifying Friday, e.g. 6.")
                }

                Section("Privacy — never watch") {
                    text("Excluded apps", csv(\.excludedApps), "Private apps to never record (matched on bundle id / name), e.g. perplexity, TrainingPeaks, Spotify.")
                    text("Excluded window/URL patterns", csv(\.excludedWindowPatterns), "Don't record windows whose app/title/URL contains these, e.g. facebook.com, reddit.com.")
                    Text("Chrome profiles can't be detected directly — exclude personal domains here, or use a separate browser for personal and exclude that app above.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("Reminders & prompts") {
                    toggle("Fill reminders enabled", $model.config.remindersEnabled, "Morning/evening popups to fill your timesheet.")
                    num("Morning reminder hour", \.morningReminderHour, "After this hour, nudge once if the last active day isn't filled.")
                    num("Evening reminder hour", \.eveningReminderHour, "After this hour, nudge once to fill today.")
                    num("Prompt after unknown (minutes)", \.promptAfterUnknownMinutes, "If this much of the current block has no ticket, prompt you.")
                    num("Abstain nudge (minutes)", \.abstainNudgeMinutes, "Nudge after this many minutes of continuous un-guessable work (no candidate at all). 0 = off.")
                    num("Prompt cooldown (minutes)", \.promptCooldownMinutes, "Minimum gap between prompts/nudges.")
                }

                if model.config.issueProvider == .jira {
                    Section("Jira") {
                        text("Board ids", intCSV(\.jiraBoardIds), "Comma-separated board numbers (from each board URL) for active-sprint detection.")
                        text("Service-desk queues", csv(\.jiraQueues), "Comma-separated PROJECT/queueId, e.g. PES/246. Treated like an active sprint (boost + include).")
                        num("Auto-refresh every (minutes)", \.jiraRefreshMinutes, "Re-pull tickets this often (and once on launch). 0 = manual only.")
                        num("Ignore tickets older than (days)", \.jiraMaxAgeDays, "Don't fetch tickets untouched beyond this; next refresh skips them. 0 = no limit.")
                        text("Ticket prefixes", csv(\.ticketPrefixes), "Comma-separated keys to recognize, e.g. CLOUDINFRA, PES, GEN.")
                    }
                } else {
                    Section("Azure DevOps") {
                        text("Organization", $model.config.azureOrg, "Your Azure DevOps org — the <org> in https://dev.azure.com/<org>.")
                        text("Project", $model.config.azureProject, "Restrict work-item queries to one project. Empty = org-wide (assignee = @Me across every project you have access to) — most people work across more than one AzDO project.")
                        text("Team", $model.config.azureTeam, "Team name (not project name) used for active-iteration detection. Empty disables it — inSprint stays false rather than guessing.")
                        text("WIQL override", $model.config.azureWiql, "Replace the built-in \"assigned to me, not done\" query entirely. Empty = use the default.")
                        text("Excluded areas", csv(\.azureExcludedAreas), "Area-path prefixes to drop from the corpus, e.g. a noisy service-desk area with no project prefix to filter by the way Jira's excluded tickets can.")
                        text("Branch key pattern", $model.config.azureBranchKeyPattern, "Regex (1st capture group = the work-item id) recognizing an id in a branch name. Default matches feature/48210-fix-thing.")
                        toggle("Mine PR→work-item links", $model.config.azurePRBridgeEnabled, "Resolve Azure Repos pull requests to work items to seed the repo→ticket bridge — the grounded signal Jira gets for free from branch/commit ticket keys. Needs the PAT's Code (read) scope.")
                    }
                }

                Section("Tickets — shared") {
                    text("Workspace folders", csv(\.workspaceGlobs), "Where your git repos live (for branch/commit/cwd detection).")
                    text("Excluded tickets", csv(\.excludedTickets), "Never track/suggest these. Exact keys or globs, e.g. EXCL-*, CLOUDINFRA-9999. Jira only — Azure DevOps has no project prefix to glob against; use Excluded areas above instead.")
                    text("Common / catch-all tickets", csv(\.commonTickets), "Always shown in the pickers even if unassigned/old, e.g. the quarterly CLOUDINFRA-6081. Manual-pick only.")
                    text("Common tickets JQL", $model.config.commonTicketsJQL, "Auto-pull common tickets via JQL, e.g. parent = PES-204 (epics under it). Updates as epics rotate. Jira only.")
                    text("'No ticket' label", $model.config.noTicketLabel, "Shown in pickers for work with no ticket. Fills the block (no nagging) and reads in the timesheet.")
                    text("Always-no-ticket signatures", csv(\.noTicketRules), "Contexts that always resolve to no-ticket (still logged, non-billable), e.g. app:com.spotify.client, host:news.ycombinator.com. Built up via 'Mark as no-ticket'.")
                    text("'No ticket' → billing ticket", $model.config.noTicketTempoTicket, "Where to log no-ticket time in Tempo/7pace. Empty = skip those blocks (don't submit).")
                    toggle("Guess only from current sprint", $model.config.guessFromSprintOnly, "Restrict guesses to assigned tickets in the active sprint/iteration. Off by default (sprint detection is unreliable and this starves the pool). It still boosts ranking; this only limits eligibility.")
                    text("Preferred states", csv(\.preferredTicketStates), "Exact state names (case-insensitive) that rank above tickets in any other state, even ones sharing the same broad category — e.g. Azure Boards' \"Dev\" state, which usually categorizes as In Progress the same as \"Active\"/\"Resolved\" but means something more specific. Empty = off. See Preferred-state boost below.")
                }

                if model.config.worklogProvider == .sevenPace {
                    Section("7pace") {
                        text("Organization", $model.config.sevenPaceOrg, "Your 7pace/Azure DevOps org for the Timetracker API host, https://<org>.timehub.7pace.com.")
                        text("Activity type id", $model.config.sevenPaceActivityTypeId, "UUID attached to every submitted worklog. Empty = omit the field (many orgs make it mandatory — check 7pace → Settings → Activity Types if submits fail).")
                    }
                }

                Section("Guessing — fusion ranker") {
                    Text("All signals (lexical, content memory, repo→ticket history, embeddings, LLM) are fused into one calibrated confidence per ticket. Exact keys (branch/URL/commit) always win outright.")
                        .font(.caption2).foregroundStyle(.secondary)
                    toggle("Lexical guessing enabled", $model.config.semanticEnabled, "Token-overlap matching against ticket text. Leave on.")
                    num("Auto-tag confidence", \.fusionWeights.autoTagThreshold, "Fused confidence (0–1) needed to auto-apply a guess. Higher = stricter/more precise. 0.80 default.")
                    num("Suggest confidence", \.fusionWeights.suggestThreshold, "Below this, abstain (no menu noise). Between this and auto-tag, it's a suggestion. 0.40 default.")
                    num("Auto-tag margin", \.fusionWeights.margin, "Top guess must beat #2 by this much confidence to auto-tag (avoids coin-flips). 0.12 default.")
                    int("Max candidates", \.semanticMaxCandidates, "How many ranked guesses to keep for menus/prompt.")
                }

                Section("Fusion — signal reliabilities (0–1, advanced)") {
                    Text("How much each signal contributes when it fires. Memory (your confirmed labels) and corrections are trusted most; embedding/LLM corroborate.")
                        .font(.caption2).foregroundStyle(.secondary)
                    num("Content memory", \.fusionWeights.memory, "Similar work you've labeled before.")
                    num("Repo → ticket history", \.fusionWeights.repo, "Tickets recently worked in the active repo (mined from git).")
                    num("Lexical match", \.fusionWeights.lexical, "Token overlap with ticket text.")
                    num("Embedding match", \.fusionWeights.embedding, "Synonym corroborator.")
                    num("LLM vote", \.fusionWeights.llm, "Local-model agreement (only counts when it agrees).")
                    num("Signature corrections", \.fusionWeights.correction, "Tickets you've confirmed for this app/repo/site before.")
                    num("Noisy-context strictness (browser/Slack)", \.fusionWeights.tierBrowserMessaging, "Multiplier (≥1) on the auto-tag bar in browser/chat/email with no repo — keeps them suggest-only.")
                }

                Section("LLM (Ollama)") {
                    toggle("LLM enabled", $model.config.ollamaEnabled, "Use a local model to pick/justify a ticket. Requires Ollama running.")
                    text("Ollama URL", $model.config.ollamaURL, "Local Ollama server. Default http://localhost:11434.")
                    text("Model", $model.config.ollamaModel, "e.g. qwen3:4b (better) or qwen3:1.7b (lighter). Must be pulled.")
                    num("Safety re-check every (minutes)", \.llmRefreshMinutes, "Fallback cadence for long single-context sessions. The LLM is otherwise event-driven (fires only when fusion is undecided). 0 = prompt-time only.")
                    num("Arc window (minutes)", \.llmArcWindowMinutes, "How much recent history the LLM sees as the 'arc of work'.")
                    num("Previous-guess TTL (minutes)", \.llmPreviousGuessTTLMinutes, "How long a prior guess is fed back before it must re-earn it (anti-pin).")
                    int("Few-shot examples", \.llmFewShot, "How many of your labeled examples to show the LLM as guidance.")
                }

                Section("Embeddings (Ollama)") {
                    toggle("Embeddings enabled", $model.config.embeddingsEnabled, "Continuous semantic matching to catch synonyms. Now a weighted feature in the fusion ranker (see reliabilities above).")
                    text("Embedding model", $model.config.embeddingModel, "e.g. nomic-embed-text. Must be pulled.")
                }

                Section("Ranking weights (multipliers, 1.0 = neutral)") {
                    Text("Each match score is multiplied by these based on the ticket's state. See the live effect in Inspector → Ranking weights applied.")
                        .font(.caption2).foregroundStyle(.secondary)
                    num("Done penalty (×)", \.rankWeights.donePenalty, "Completed tickets — <1 pushes them down (kept for matching, rarely surfaced).")
                    num("In-Progress boost (×)", \.rankWeights.inProgressBoost, "Status In Progress.")
                    num("In-Review boost (×)", \.rankWeights.inReviewBoost, "Status In Review.")
                    num("Active-sprint boost (×)", \.rankWeights.sprintBoost, "Ticket is in the board's active sprint.")
                    num("Queue boost (×)", \.rankWeights.queueBoost, "Ticket is in a watched service-desk queue.")
                    num("Recent <3d boost (×)", \.rankWeights.recent3dBoost, "Updated (comment/edit) in the last 3 days.")
                    num("Recent <14d boost (×)", \.rankWeights.recent14dBoost, "Updated in the last 14 days.")
                    num("Stale >60d penalty (×)", \.rankWeights.stale60dPenalty, "Untouched for over 60 days.")
                    num("Preferred-state boost (×)", \.rankWeights.preferredStateBoost, "Applied when the ticket's raw state name is in Preferred states above (Tickets — shared section).")
                }

                Section("Housekeeping (pruning)") {
                    num("Keep segments for (days)", \.segmentRetentionDays, "Delete raw focus segments older than this. 0 = keep forever. (Labels/learning are kept.)")
                    num("Boxed-day segments for (days)", \.submittedRetentionDays, "Days already submitted to Tempo get their segments dropped sooner than the above.")
                    int("Max labeled examples", \.labelMaxCount, "Cap on training examples kept (most recent). Duplicates are merged. 0 = unlimited.")
                }

                Section("Workflow context (LLM system prompt)") {
                    Text("Describe your work (role, projects, what repos/tools/meetings mean) so the LLM reasons with your world in mind.")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: $model.config.workflowContext).frame(minHeight: 90).font(.callout)
                }

                Section("Category rules (`category: kw1, kw2` per line)") {
                    Text("Maps apps/keywords to a coarse category (meeting, infra, coding…) used when no ticket is found.")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: categoryRulesText).frame(minHeight: 100).font(.system(.callout, design: .monospaced))
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Changes apply after restart.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save", action: onSave).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 580, height: 700)
    }

    // MARK: - Row helpers

    private func num(_ label: String, _ kp: WritableKeyPath<Config, Double>, _ help: String = "") -> some View {
        let b = Binding<Double>(get: { model.config[keyPath: kp] }, set: { model.config[keyPath: kp] = $0 })
        return VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); TextField("", value: b, format: .number).frame(width: 90).multilineTextAlignment(.trailing) }
            if !help.isEmpty { cap(help) }
        }
    }

    private func int(_ label: String, _ kp: WritableKeyPath<Config, Int>, _ help: String = "") -> some View {
        let b = Binding<Int>(get: { model.config[keyPath: kp] }, set: { model.config[keyPath: kp] = $0 })
        return VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); TextField("", value: b, format: .number).frame(width: 90).multilineTextAlignment(.trailing) }
            if !help.isEmpty { cap(help) }
        }
    }

    private func toggle(_ label: String, _ isOn: Binding<Bool>, _ help: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) { Toggle(label, isOn: isOn); if !help.isEmpty { cap(help) } }
    }

    private func text(_ label: String, _ binding: Binding<String>, _ help: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) { TextField(label, text: binding); if !help.isEmpty { cap(help) } }
    }

    private func cap(_ s: String) -> some View { Text(s).font(.caption2).foregroundStyle(.secondary) }

    // MARK: - Array bindings

    private func csv(_ kp: WritableKeyPath<Config, [String]>) -> Binding<String> {
        Binding(
            get: { model.config[keyPath: kp].joined(separator: ", ") },
            set: { model.config[keyPath: kp] = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        )
    }

    private func intCSV(_ kp: WritableKeyPath<Config, [Int]>) -> Binding<String> {
        Binding(
            get: { model.config[keyPath: kp].map(String.init).joined(separator: ", ") },
            set: { model.config[keyPath: kp] = $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        )
    }

    private var categoryRulesText: Binding<String> {
        Binding(
            get: { model.config.categoryRules.map { "\($0.category): \($0.anyOf.joined(separator: ", "))" }.joined(separator: "\n") },
            set: { text in
                model.config.categoryRules = text.split(separator: "\n").compactMap { line in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    let cat = parts[0].trimmingCharacters(in: .whitespaces)
                    let kws = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    return cat.isEmpty || kws.isEmpty ? nil : CategoryRule(category: cat, anyOf: kws)
                }
            }
        )
    }
}
