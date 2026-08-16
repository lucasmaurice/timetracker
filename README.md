# TimeTracker

A private, local-only macOS menu-bar app that logs which app/window you're focused on,
infers the JIRA ticket you're working on, and builds a two-block (2×4h) daily timesheet.

**Privacy posture**
- 100% local. The daemon makes **no network calls** (except Connect/Refresh to Jira) and does
  **no screen recording**, no keystroke logging, no clipboard/screen-pixel capture.
- Storage is a single SQLite file under `~/Library/Application Support/TimeTracker/`.
- Each segment stores the **enriched work context locally** — window title, active-tab URL,
  git branch/changed files/commit subjects, and your own AI-session prompts — because that's
  the signal the guesser (and the Teach/learning loop) needs. It never leaves your machine.
  Excluded apps/windows store nothing; idle segments store no context.
- Idle (no input ≥ 5 min, configurable) is recorded but excluded from billable time.

## What it captures

For each focus interval (segment): start/end, app bundle id + name, window title, idle flag,
the inferred `ticket` / `ticket_source` / `category` / confidence, and the enriched
`context_doc` (the same local signals the guesser saw — repo, branch, files, commits,
AI-session prompts, kube context). All local.

### Ticket inference

**Exact keys win outright** (highest precision, in order): a `CLOUDINFRA-/PES-/GEN-####`
found in the active tab **URL**, the git **branch**, the window **title**, a recent **commit**
subject, or your **AI-session** text. A context you've **confirmed ≥2×** before
(`learned`) also short-circuits.

**Otherwise, a calibrated late-fusion ranker** scores each candidate ticket. Every signal is
squashed onto a common 0–1 scale and combined by noisy-OR, so independent signals that agree
reinforce while a lone signal is bounded — and the system still **abstains** when nothing is
grounded (no wrong guesses on noise). The signals:

- **Lexical** — IDF-weighted token overlap of the activity context vs. ticket text
  (summary + epic + components + labels + description). Concrete shared jargon
  (`vmselect`, `oidc`, `slo`, repo/file names) drives it.
- **Repo → ticket history** — the tickets recently worked *in the active repo*, mined from
  local git (branch names + commit subjects), recency-decayed. The strongest signal for
  continuation work, even when the current branch names no key.
- **Content memory** — your past labeled examples (k-NN over their context docs); learns
  *your* mapping as you confirm/correct. Git history seeds it on first run (warm start).
- **Embeddings** (local `nomic-embed-text`) — catches synonyms the lexical layer misses
  (e.g. "IAM Roles" ↔ an IRSA/OIDC ticket).
- **Ollama LLM** (local `qwen3:4b`) — an **event-driven** tie-breaker: it runs only when the
  deterministic fusion is still undecided, and its pick is one weighted, agreement-trusted
  vote in the fusion (never a standalone auto-tagger). Requires a local Ollama
  (`brew install ollama` → `ollama pull qwen3:4b nomic-embed-text`); if it's down, the rest
  still works. Set `ollamaEnabled: false` to disable.
- **Status/recency prior** — In-Progress / active-sprint / recently-updated tickets rank higher.

A guess is **auto-applied only when its fused confidence clears `fusionWeights.autoTagThreshold`
and beats the runner-up by `fusionWeights.margin`** — and the bar is stiffer in noisy contexts
(browser/Slack/email only ever *suggest*). Otherwise it's a ranked suggestion in the menu/review.

**You** — manual override from the menu, the real-time prompt, or the review window — always wins,
and each confirmation is recorded as a labeled example the ranker learns from.

Measure it anytime with `timetracker --eval` (headless): timesheet coverage, the mined
repo→ticket bridge, and a leakage-free temporal backtest of the repo signal.

### Local signals gathered (no keylogger, no screen capture)

Each focus change builds a `WorkContext` from local sources only, fed to both the lexical
matcher and the LLM. The ticket-key regex scans the URL, branch, title, commit subjects, and
AI-session text (so an explicit key in any of them wins immediately):

| Signal | Source | Permission |
|--------|--------|------------|
| Frontmost app + window title | NSWorkspace + Accessibility | Accessibility |
| **Browser active-tab URL** | AppleScript to Chrome/Safari/Arc (skips Chrome incognito) | Automation |
| **AI-session prompts** | Claude Code (`~/.claude/projects`, incl. `aiTitle`), Copilot (`workspaceStorage/*/chatSessions/*.jsonl` → `v.requests[].message.text`), Kiro (`workspace-sessions/<base64 path>` → newest session's history) | none (reads your own local files) |
| **Editor extension** (optional) | VS Code / Kiro heartbeat: repo, branch, file, **symbol at cursor**, **commit-message draft**, **modified/recent files** (relative paths), **integrated-terminal commands**, active task / debug session. See [`editor-extension/`](editor-extension/) | none (extension writes a local file) |
| Git depth | branch + `git log -8` subjects + `git status` changed files + open file | none |
| Kubernetes context | `kubectl config current-context` (+ namespace) | none |
| Dev processes | `pgrep` for terraform/kubectl/helm/k9s/vault/… | none |
| Recently-active repos | mtime of `~/Workspace/*/.git/index` (last 30 min) | none |
| Current meeting | EventKit event in progress (title + attendees) | Calendar (read-only) |

These are deliberately **not** collected: keystrokes, screen/window pixels, clipboard.

The optional **[editor extension](editor-extension/)** (VS Code / Kiro) sharpens the editor
signals: it writes a local heartbeat with the exact repo/branch/file (no title parsing), the
symbol you're editing, and the `terraform`/`kubectl` commands you run in the integrated terminal.
TimeTracker reads it when an editor is frontmost; without it, everything still works from titles +
git. Build/install: `cd editor-extension && npm install && npm run package`, then install the VSIX.

The LLM (`qwen3:4b` via local Ollama) is **event-driven**: it fires when the deterministic
fusion (lexical + memory + repo + embeddings) is still undecided for the current context, and
again at the unknown-time prompt. Identical prompts are memoized; a low-frequency safety pass
(`llmRefreshMinutes`, default 5) covers long single-context sessions. Its vote is folded into
the fusion — trusted most when it agrees with a grounded signal — never a standalone auto-tag.

> Design note: the ranker is a **calibrated late-fusion** of all signals, not a single model.
> Each signal is squashed to a common 0–1 scale before combination, which removes the original
> bug where scores on incompatible scales were compared against one shared floor. Apple
> `NLEmbedding` was still rejected (it mis-ranked obvious cases and scored noise ~0.45); the
> embedding feature uses local Ollama `nomic-embed-text` and only contributes alongside a
> grounded signal, so abstention is preserved.

## Timesheet model

Each day is split into two 4h blocks at `blockSplitHour` (default 13:00 → AM/PM). Each block
that has activity gets one row, attributed to the ticket with the most active time (or your
manual assignment), emitted to `~/timesheet-log.md` in the format your CLAUDE.md expects:

```
| 2026-06-01 | CLOUDINFRA-1234 | 4h | CLOUDINFRA-1234: fix ... (2h10), infra (1h05) |
```

### Feedback when there's no guess

The menu-bar icon reflects the state — a ticket (tagged), `?KEY` (a guess awaiting your
**✓ Accept**), or `?` (nothing to go on). Two prompts, both `promptCooldownMinutes`-debounced:
the block-backlog prompt (`promptAfterUnknownMinutes`, default 2h) and a gentler **abstain nudge**
after `abstainNudgeMinutes` (default 15) of *continuous un-guessable* work. Either offers
**Assign / No ticket / Snooze**.

**"Mark as no-ticket"** (menu or nudge) records the time as non-billable, teaches the model a
negative example, and offers to make it a standing rule (`noTicketRules`, e.g.
`app:com.spotify.client`) so similar work resolves to no-ticket automatically — different from
`excludedApps`, which records nothing.

### The review *is* the training loop

The **Review today…** window shows, per block: a recap of what you did (repo · files ·
AI-session), the system's **best guess with its description and *why*** (source · confidence),
ranked **alternatives with scores**, a searchable picker, and **✓ Confirm** / **No ticket**.
Crucially, when you **change** a guess or **explicitly confirm** one, the block's real work
context (its persisted `context_doc`) becomes a training example — so every review session makes
the next day's guesses better. Unchanged-and-unconfirmed blocks teach nothing (no learning from
silence).

## Build & install

```bash
./build.sh                      # compiles, assembles ~/Applications/TimeTracker.app, ad-hoc signs
open ~/Applications/TimeTracker.app
# System Settings → Privacy & Security → Accessibility → enable TimeTracker
./scripts/install-launchagent.sh   # optional: start at login + keep alive
```

A clock icon appears in the menu bar showing the current ticket (or category / `?`).

## Sprint picklist

The app reads `~/Library/Application Support/TimeTracker/sprint.json` for its ticket
picklist and validation. Which issue tracker fills it is set by **Settings → Provider → Issue
tracker** (`config.issueProvider`: `jira` or `azureDevOps`) — switching needs a restart, like every
other setting. Jira has two ways to populate it; Azure DevOps has one.

### In-app API token (Jira, recommended)

The app authenticates to Jira with **Basic auth** (your email + a personal API token) routed
through the `api.atlassian.com/ex/jira/{cloudId}` gateway, fetches your open tickets, and writes
`sprint.json`. **The app makes network calls only on Connect and Refresh**; all focus logging
stays offline.

**Scoped or classic tokens both work in-app** — because it uses the gateway (it resolves your
cloud id from the site automatically). A scoped token needs scopes `read:jira-work` and
`read:jira-user` (or `read:me`). (The offline `sync-sprint.sh` script below hits the
`<site>.atlassian.net` base URL directly, so it still requires an **unscoped/classic** token.)

Setup:

1. Create a token at <https://id.atlassian.com/manage-profile/security/api-tokens>.
2. In the menu bar: **Connect Atlassian (API token)…** (has an "Open token page" button) → enter:
   - **Site**: your `<site>` (e.g. `acme`, or `acme.atlassian.net` — both accepted)
   - **Email**: your Atlassian account email
   - **API token**: the token you created
3. It validates against `/myself`, then loads your tickets. Use **Refresh sprint list** anytime.
   **Disconnect Atlassian** removes the stored credentials.

Notes:
- Credentials live in the login Keychain, never in `config.json`. Bad credentials are not saved.
- Tickets come from JQL `assignee = currentUser() AND statusCategory != Done AND project in
  (CLOUDINFRA, PES, GEN)` — adjust via `ticketPrefixes` in `config.json`.

### Or: offline script (same API token, app stays fully offline)

If you'd rather the app never touch the network, use the script instead:

```bash
export ATLASSIAN_SITE=yourcompany ATLASSIAN_EMAIL=you@company.com ATLASSIAN_API_TOKEN=xxxx
./scripts/sync-sprint.sh
```

Either way, the file format is:

```json
{ "provider": "jira", "updated": "2026-06-01T12:00:00Z",
  "tickets": [ { "key": "CLOUDINFRA-1234", "summary": "Fix node draining" } ] }
```

### Azure DevOps work items

With **Settings → Provider → Issue tracker = Azure DevOps**, the app authenticates with a
**Personal Access Token** (HTTP Basic) instead of Jira's gateway, fetches work items assigned to
you (`[System.AssignedTo] = @Me`), and writes the same `sprint.json` (stamped
`"provider": "azureDevOps"` so a stale Jira file is never reused after switching).

Setup:

1. Create a token at `https://dev.azure.com/<org>/_usersSettings/tokens` with scopes **Work Items
   (Read)** and **Code (Read)** (the second is for the Azure Repos PR→work-item bridge).
2. In the menu bar: **Connect Azure DevOps (PAT)…** (has an "Open token page" button) → enter your
   organization and the token.
3. It validates against a cheap org-level call, then loads your work items. Use **Refresh sprint
   list** anytime. **Disconnect Azure DevOps** removes the stored credentials.

Notes:
- The credential lives in the login Keychain, never in `config.json`. Bad credentials aren't saved.
- Work items are queried **org-wide by default** (`azureProject` empty) — most people work across
  more than one Azure DevOps project, the same way `ticketPrefixes` already spans multiple Jira
  projects. Set `azureProject` in Settings to restrict to one.
- Keys are shown/stored as `AB#12345` (Azure Boards' own commit-linking syntax). A bare number
  (as Azure DevOps shows everywhere in its own UI) is still recognized when it matches an open
  work item's id — see `azureBranchKeyPattern` in Settings if your team's branch naming needs a
  different capture pattern than the default `feature/12345-fix-thing`.
- `done`/ranking-boost state is resolved from each work item type's *live* state category, not a
  fixed list — process templates vary per project and per type.

## Configuration

`~/Library/Application Support/TimeTracker/config.json` (created on first run). Notable keys:
`idleSeconds`, `blockSplitHour`, `promptAfterUnknownMinutes`, `abstainNudgeMinutes`, `noTicketRules`, `promptCooldownMinutes`,
`sampleSeconds`, `ticketPrefixes`, `workspaceGlobs`, `categoryRules`, `issueProvider`, `worklogProvider`,
`azureOrg`, `azureProject`, `azureTeam`, `sevenPaceOrg`, `sevenPaceActivityTypeId`.

## Files

| Path | Purpose |
|------|---------|
| `Sources/timetracker/Store.swift` | SQLite schema + reads/writes + data-hygiene migration |
| `Sources/timetracker/FocusMonitor.swift` | NSWorkspace events + AX title + idle, segmentation |
| `Sources/timetracker/Attribution.swift` | exact-key + fusion attribution, normalization, repo bridge wiring |
| `Sources/timetracker/Providers.swift` | `TicketKeyFormat` key-shape seam + `IssueProvider`/`WorklogProvider` protocols |
| `Sources/timetracker/Atlassian.swift` / `AzureDevOps.swift` | Jira / Azure DevOps issue providers |
| `Sources/timetracker/TempoClient.swift` / `SevenPaceClient.swift` | Tempo / 7pace worklog providers |
| `Sources/timetracker/FusionRanker.swift` | calibrated late-fusion (per-signal squash + noisy-OR + policy) |
| `Sources/timetracker/RepoTicketBridge.swift` | git-history repo→ticket mining (recency-decayed) |
| `Sources/timetracker/LabelMemory.swift` | k-NN over your labeled examples (kind-weighted) |
| `Sources/timetracker/EvalHarness.swift` | `--eval` headless coverage / accuracy report |
| `Sources/timetracker/Shell.swift` | shared process runner (timeout + watchdog) |
| `Sources/timetracker/Summary.swift` | 4h-block bucketing + timesheet-log.md export |
| `Sources/timetracker/main.swift` | menu-bar UI, override, prompt, async refinement orchestration |

## Known limitations / TODO

- Meeting time while truly idle (watching, not typing) is dropped by the idle filter.
  `# TODO:` count idle time as active when the foreground app is in the `meeting` category.
- Browser attribution is title-only; deep tab/URL detail would need Automation permission (declined by design).
- Sprint sync uses `assignee = currentUser()`, not literal `openSprints()` — adjust the JQL if you want true sprint scope.
- Ad-hoc signature: a clean rebuild keeps the same identity, but if macOS ever drops the
  Accessibility grant after an update, re-toggle it in System Settings.
- Azure DevOps has no Azure Repos PR→work-item bridge yet, so the git-mined repo→ticket signal
  stays empty unless work items are named directly in branches/commits (`AB#1234`) — Jira gets this
  signal for free from branch/commit ticket keys.
- 7pace's exact worklog-create response shape and whether it requires an explicit `userId` weren't
  verifiable against a real tenant while this was built — the first real submit may need a small
  fix in `SevenPaceClient.swift` if your tenant's response differs.
