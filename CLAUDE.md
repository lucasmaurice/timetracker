# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A local-only macOS menu-bar app (SwiftPM executable, no Xcode project) that samples the focused
app/window, enriches it with local signals (git, browser URL, AI-session transcripts, kube, editor
heartbeat), infers the Jira ticket (or Azure DevOps work item) being worked on, and builds a
block-based daily timesheet that can be exported to `~/timesheet-log.md` or posted to Tempo (or
7pace).

`README.md` documents the user-facing behaviour and the signal inventory in detail — read it for
*what* the app does. This file covers *how the code is put together*.

## Commands

```bash
swift build                      # debug build (fast iteration; type-checks everything)
swift build -c release
./build.sh                       # release + assemble TimeTracker.app + ad-hoc sign + install to ~/Applications
./scripts/reset-accessibility.sh # run AFTER build.sh — see below
.build/debug/timetracker --eval  # headless evaluation harness (see "Testing")
./scripts/install-launchagent.sh # start at login + relaunch on crash
./scripts/sync-sprint.sh         # offline sprint.json sync (needs a CLASSIC token; app stays offline)

./scripts/build-editor-extensions.sh      # builds + installs/updates both editor extensions locally
```

**Ad-hoc signing gotcha:** every rebuild changes the code hash, which invalidates the macOS
Accessibility grant. Without Accessibility the app gets empty window titles and attribution
silently degrades. After `./build.sh`, run `./scripts/reset-accessibility.sh` and re-grant — and
do *not* rebuild after granting, or the grant resets again.

Running the app needs Accessibility (window titles) and Automation (browser tab URLs). It is an
`LSUIElement` agent — no Dock icon, no main window; all UI hangs off the status item.

## Testing

There is **no unit-test target**. The equivalent is `timetracker --eval` (`EvalHarness.swift`),
a read-only headless harness that never starts the menu-bar app. It reports:

- timesheet coverage over the last 30 days, broken down by `ticket_source`
- the mined repo→ticket bridge
- a leakage-free temporal backtest of the repo signal (train on history >21d old)
- segment replay over user-confirmed contexts, and leave-one-out ranking accuracy over labels
  (including auto-tag fire rate and precision)

When you change anything in the attribution pipeline, run `--eval` before and after and compare
top-1/top-3 and **auto-tag precision**. Precision matters more than coverage here — the design
prefers abstaining to guessing wrong. Note `--eval` scores only the deterministic signals
(lexical + memory + repo); embedding/LLM are live-only and not reproducible offline.

## Architecture

### The attribution pipeline

```
FocusMonitor.sample()            every config.sampleSeconds + NSWorkspace activate/wake events
  ├─ main thread: frontmost app, idle (CGEventSource), screen-lock, AX window title
  └─ enrichQueue (utility): ContextEnricher.enrich() → WorkContext
       └─ main thread: FocusMonitor.commit()
            → Attribution.attribute() → decideAttribution()
            → segment boundary detection (sameSignature) → flush() → Store.insert(Segment)
```

`decideAttribution` in [Attribution.swift](Sources/timetracker/Attribution.swift) is the heart.
It short-circuits in strict order — exact ticket key (url → branch → title → commit → scmMessage →
aiSession), then `noTicketRules`, then a correction confirmed ≥2× — and only then builds
per-candidate feature vectors (`buildFeatures`) and hands them to `FusionRanker`.

Signal producers, each independently indexable and all local:

| File | Signal |
|------|--------|
| [Semantic.swift](Sources/timetracker/Semantic.swift) (`TicketMatcher`) | lexical TF-IDF cosine over the ticket corpus |
| [LabelMemory.swift](Sources/timetracker/LabelMemory.swift) | k-NN over your labeled examples, trust-weighted by provenance |
| [RepoTicketBridge.swift](Sources/timetracker/RepoTicketBridge.swift) | git-mined repo→ticket history, recency-decayed (42d half-life) |
| [AzurePRBridge.swift](Sources/timetracker/AzurePRBridge.swift) | Azure Repos PR→work-item resolution, feeds `RepoTicketBridge` |
| [EmbeddingMatcher.swift](Sources/timetracker/EmbeddingMatcher.swift) | Ollama `nomic-embed-text` cosine (async) |
| [Ollama.swift](Sources/timetracker/Ollama.swift) | local LLM vote (async, event-driven) |
| [CorrectionStore.swift](Sources/timetracker/CorrectionStore.swift) | signature (repo:/host:/app:) → ticket confirmation counts |
| [Providers.swift](Sources/timetracker/Providers.swift) | `TicketKeyFormat` (key-shape seam) + `IssueProvider`/`WorklogProvider` protocols |

[FusionRanker.swift](Sources/timetracker/FusionRanker.swift) squashes each raw signal to `[0,1]`
at its own calibrated centre, then combines by noisy-OR, then applies a precision-first policy
(`autoTag` / `suggest` / `abstain`) with a tier multiplier that stiffens the bar in noisy contexts.

### Two-phase attribution (sync then async)

The synchronous pass uses deterministic signals only. Embedding and LLM arrive later and trigger
a re-fusion, orchestrated in `main.swift`:

```
monitor.onUpdate → maybeEmbed()      embed the new context doc (async)
                 → refineCurrent()   re-run decideAttribution with embedding + LLM vote
                 → llmRefine()       ONLY if fusion is still undecided → refineCurrent() again
```

`llmTimer` (`llmRefreshMinutes`) is a low-frequency safety net for long single-context sessions
where no focus change ever re-triggers embedding — not the primary trigger.

**Invariant:** `Attribution.isExact(source)` gates every async path. Sources in
`Attribution.exactSources` (`url`, `branch`, `title`, `commit`, `session`, `learned`, `manual`,
`pinned`) are never overridden by a refinement, and a pin beats everything except idle. If you add
a new attribution source that must not be second-guessed, add it to that set.

### Abstention is load-bearing

Several mechanisms exist specifically so the app says "I don't know" instead of guessing wrong.
Do not "fix" these into always producing a ranked answer:

- `TicketMatcher` restricts its vocabulary to the ticket corpus and applies the prior
  *multiplicatively*, so cosine 0 stays 0 — unrelated activity scores zero against every ticket.
- `FusionRanker.fuse` caps any candidate with no *grounded* signal (lexical/memory/repo/correction)
  below `suggestThreshold`, so corroborator-only support (embedding/LLM/status prior) can surface a
  suggestion but can never auto-tag.
- `ungroundedRepoDamp` scales down every candidate when the active repo is outside the ticket
  universe entirely (no mined history, no ticket text mentions it).
- `tierFactor` makes browser/Slack/email contexts effectively suggest-only.

### Corpus vs. guess pool

`Attribution.sprint` is the full data lake — every assigned ticket including done ones, kept for
matching and memory. `guessTickets` / `guessKeys` is the narrower pool the *guesser* may pick from:
prefix-filtered to `ticketPrefixes`, not-done, plus configured `commonTickets`, widened by keys
mined from local git history. Exact-key signals and the manual pickers are deliberately **not**
restricted to the pool; `buildFeatures`'s local `allow()` closure enforces the restriction for
every fused signal. `reloadSprint()` rebuilds both and re-indexes the lexical matcher.

### Provider abstraction (Jira/Tempo vs Azure DevOps/7pace)

`config.issueProvider` (`jira` | `azureDevOps`) and `config.worklogProvider` (`tempo` | `sevenPace`)
select which concrete client backs `IssueProvider`/`WorklogProvider` ([Providers.swift](Sources/timetracker/Providers.swift)).
`main.swift` never hardcodes a concrete type on a provider-generic path (menu build, refresh,
connect/disconnect, submit) — it dispatches through the `issueProvider`/`worklogProvider` computed
properties, which resolve to `atlassian`/`azureDevOps` and `tempo`/`sevenPace` based on config. Like
every other setting, switching providers needs a restart — `Attribution` builds its `keyFormat` once
in `init` from `config.issueProvider`.

The `PREFIX-1234` vs `AB#1234` key-shape difference is isolated behind `TicketKeyFormat`: `extract`
is parameterized by `KeySource` (url/branch/title/commit/session/freeText) because a bare number is
safe to trust from a work-item URL but not from a window title — `AzureBoardsKeyFormat` only allows
it through `Attribution`'s corpus-gated fallback (`exactTicket`), never as a blind regex match.
`isGuessable` replaces the old hardcoded `prefix + "-"` check; **never** re-hardcode a key shape
assumption outside this file, or a new provider silently breaks pool membership (an early version of
this did — an empty guess pool kills every fusion signal with no visible error, just a permanent
abstain nudge).

`SprintFile.provider` stamps which provider wrote `sprint.json`; `reloadSprint()` treats a
foreign-provider file as empty rather than silently reusing stale cross-provider tickets after a
switch. `CorrectionStore` lookups are gated by `guessKeys` for the same reason — a correction learned
under one provider must never resolve as an exact, never-overridden match under another.

`AzureDevOps.swift` resolves `done`/prior-boost from each work item **type's live state category**
(`wit/workitemtypes/{type}/states`), never a hardcoded state-name list — state vocabularies are
customized per process template and per type (verified: a real org's Task/User Story states include
a non-standard `"Dev"` state, and `"Resolved"` categorizes as `InProgress`, not a distinct category).
WIQL project scoping is optional (empty `azureProject` = org-wide `@Me` query) since real usage
spans multiple AzDO projects, the same way `ticketPrefixes` already spans multiple Jira projects.

Azure Repos orgs that complete PRs via merge commits (not squash) carry no ticket-key text in
commit subjects at all — [AzurePRBridge.swift](Sources/timetracker/AzurePRBridge.swift) restores
the git-mined repo→ticket signal for those orgs by resolving PRs to their linked work items
(one list-PRs call per repo, falling back to a per-PR `/workitems` lookup for the unresolved
remainder) and merging the result into `RepoTicketBridge` via `ingestResolvedKeys`. This runs
**after** `rebuildRepoBridge` in the same background pass — that call replaces the bridge's map
wholesale, so merging first would be silently wiped. Toggle with `azurePRBridgeEnabled`.

### The learning loop

Labels are training data, and only *explicit* user action creates them:

- `recordCorrection` — from `overrideCurrentTicket` but **only when `source == "manual"`**, so the
  app never trains on its own auto-tags.
- `recordTraining` — from the Teach UI.
- Review window confirm/change — an unchanged, unconfirmed block teaches nothing.

Each label is a `(context_doc, ticket, kind)` row; `kind` drives `LabelMemory.trust` (git
`backfill` seeds count 0.6 vs 1.0 for `correction`/`training`). On first run
`backfillFromHistory()` warm-starts from git (guarded by the `ttBackfilledV1` UserDefaults flag).

`normalizeTicketEntry` is the **single chokepoint** that keeps poison out of the store — it turns a
pasted Jira URL into `PROJ-1234` and rejects garbage. Any new path that accepts a ticket string
from a human or a model must go through it. A one-time repair migration (`ttMigratedV1`, see
`runDataMigration`) exists because it once didn't.

### Timesheet output

Two coexisting models, split by how retrospective vs. live the consumer is:

**Fixed blocks (`TimeBlocks`/`BlockReport`/`Summary`) — real-time only.** `Summary` buckets
segments into `TimeBlocks.blocks` (a `workdayHours` day of `blockHours` blocks starting at
`dayStartHour`; the first block absorbs early activity and the last absorbs late, so nothing is
lost). Each block becomes a `BlockReport`. This model is now used ONLY by the live paths that need
a cheap, synchronous "which block is `now` in": `checkAbstainNudge`/`checkUnknownBacklog`'s
real-time prompts, `AssignView`'s `.thisBlock` scope, `llmHints`'s "already logged today" line, and
`exportToday()`'s quick menu export. `block_assignments` (keyed `(day, block-id)`) still backs
manual overrides for exactly these paths.

**Floating periods (`PeriodCompiler`/`Period`) — Review and Submit.** `PeriodCompiler.compile(day:
config: store: attribution: ollama:)` (async) is the retrospective/batch day-builder used by
**Review today…** and worklog submission. It carves a day into `Period`s (`kind`:
`.regular`/`.daily`/`.breakPeriod`/`.codeReview`/`.meeting`) instead of fixed clock-aligned blocks:

- Code-review periods group segments already tagged live by the PR-review feature
  (`ticketSource == "prReview"`) — no new detection, just grouping.
- Meeting periods group segments carrying `Segment.meeting` (set by `FocusMonitor.flush()` from
  `WorkContext.meeting`); one matching `config.dailyStandupTitleMatch` becomes a `.daily` period on
  the fixed `dailyStandupTicket` instead of going through the Ollama guess.
- A `.breakPeriod` is injected unconditionally at `config.breakStartHour` for
  `breakDurationMinutes` — not detected from an idle gap — and clips overlapping time out of every
  other period (break wins outright over whatever else was scheduled then).
- Everything left over floats into `blockHours`-sized `.regular` buckets: accumulated *active*
  time, skipping over the carve-outs above (so a block can span more wall-clock time than
  `blockHours` if a meeting interrupted it). Each bucket's ticket is chosen by a duration + explicit
  ticket-key-mention score (`Config.periodMentionWeightSeconds`), gated to candidates where
  `Ticket.assignedToMe && Ticket.isInProgressLike(preferredStates:)` — `isInProgressLike` exists
  because `statusCategory` is Azure-DevOps-only (always nil for Jira), so it falls back through
  `preferredTicketStates` membership, then a plain "contains progress" name heuristic, before
  giving up. A block with no qualifying candidate abstains rather than guessing wrong.
- Non-regular periods round their *reported* (submitted) duration to `periodRoundMinutes`, clamped
  to `periodMinMinutes`; floating regular blocks are exempt. If the day's total falls short of the
  target (`workdayHours`, or `summerFridayHours` on a qualifying Friday —
  `TimeBlocks.isSummerFriday`/`dailyTargetSeconds`), the shortfall pads the single most-dominant
  regular period's reported duration; overtime is never trimmed. `Period.trueSeconds` always holds
  the real, unrounded, unpadded total, independent of `reportedSeconds` — load-bearing for a
  possible future time-bank/weekly-rebalance feature, so don't collapse the two.
- `seq` is a `Period`'s stable per-day identity — NOT positional, because a day's period shape is
  data-dependent (a segment gets re-tagged, more activity accrues between two compiles). Saving
  Review greedily matches each fresh period to a saved `period_assignments` row of the same `kind`
  within ~10 minutes of the same `start`, reusing its `seq`; a genuinely new period gets a
  brand-new, append-only `seq`. This is what keeps `Submit to Tempo`'s replace-not-duplicate
  behavior working across edits — `worklogId(day:block:)` is called with `String(period.seq)` in
  place of the old block-id string, so the worklog-id map format didn't need to change at all.

Both `BlockReport` and `Period` conform to `PeriodicReport` (`byTicket`/`byCategory`) so
`Summary.describe(_:)` works against either. `Summary.appendTimesheet(day:)` (fixed blocks) and
`appendTimesheet(periods:day:)` (floating periods) both write to `~/timesheet-log.md`; submission
goes via whichever `WorklogProvider` is active, to Tempo or 7pace — each keeps its **own**
`(day|block) → worklogId` map file (`tempo-worklogs.json` is `[String: Int]`, 7pace's ids are UUID
strings) so re-submitting replaces rather than duplicates. Don't merge them into one shared file —
`TempoClient`'s decode is `try?`-and-silently-empty on a shape mismatch, which would turn a format
change into duplicate worklogs on the next submit.

## Conventions and constraints

**Threading.** This is the most common source of real bugs here, and the comments in the code
record which ones already happened:

- Enrichment (AppleScript, `git`, `lsof`, `pgrep`, `kubectl`, `ps`) runs on `FocusMonitor`'s serial
  `enrichQueue`, never on main — it froze the menu bar. The enricher's caches assume that serial queue.
- Keychain reads go through `preload()` on a background queue. `SecItemCopyMatching` can block on a
  permission prompt and froze launch; after the first read everything is in-memory
  (`Atlassian.credentials` is deliberately pure in-memory and never hits the Keychain).
- `commit()`, attribution, and all UI run on main. Startup migrations run synchronously on main
  before the monitor starts, so there is no concurrent DB access.
- Heavy git mining (`rebuildRepoBridge`, `backfillFromHistory`) is background; the in-memory index
  reload that follows happens back on main.

**Subprocesses** always go through `Shell` — absolute tool paths (launchd gives the app a minimal
PATH), concurrent pipe read so `git log` can't deadlock the buffer, and a watchdog timeout.

**Config** is loaded once at launch and copied by value into every component, so settings changes
need a restart (the Settings window says so). `addNoTicketRule` re-reads from disk before saving
specifically to avoid clobbering unrelated in-flight edits. Every field in `Config` should have a
comment explaining what it does — `SettingsView` surfaces essentially all of them with that help text.

**Network boundary.** Only the active issue provider's connect/refresh, the active worklog
provider's submit, localhost Ollama, and — the one deliberate exception — live PR-review
resolution touch the network. Focus logging is entirely offline. Keep it that way — it is the
app's central promise, restated in the README, the Info.plist usage strings, and the `Store`
header comment.

**PR-review resolution (the network-boundary exception).** When the focused window title matches
Azure Repos' PR-review format ("Pull request NNNN: … - Repos" — both the web UI and VS Code use
it), `main.swift`'s `maybeResolvePRReview` calls `AzureDevOps.resolveWorkItem(forPullRequestId:)`
live, regardless of who the linked work item is assigned to, and caches the result in
`Attribution.prReviewTickets` (source `"prReview"`, added to `Attribution.exactSources` — a
resolved PR review is never second-guessed by embedding/LLM refinement). This is intentionally
*not* a widening of `guessTickets`/`sprint.json`'s "assigned to me" corpus — reviewing a
teammate's PR is real work on their ticket, but the general guess pool should still stay scoped to
your own assigned work. `AzureDevOps` caches the resolution 10 minutes per PR id so repeated
attribution samples during one review don't re-hit the API, and `maybeResolvePRReview` skips
entirely once `Attribution.isExact` is already true for the segment — no polling.

**Privacy layers are distinct.** `excludedApps`/`excludedWindowPatterns` record *nothing* (the
window title isn't even read); `noTicketRules` still log the time but resolve it to no-ticket. Idle
and excluded segments persist no `context_doc`.

**Code style.** Compact Swift — single-line structs, `a; b` on one line, unwrapped `guard let`
chains — with dense comments that explain *why*, often naming the bug a line prevents. Match it.
`.vscode/settings.json` disables Swift format-on-save on purpose: `swift-format` is an AST
pretty-printer with no style-preserving mode, so it reformats whole files and destroys this layout.
Don't re-enable it, and don't run it over existing files.

## Data locations

All under `~/Library/Application Support/TimeTracker/` (`AppPaths.dataDir`):

| File | Contents |
|------|----------|
| `timetracker.sqlite` | `segments`, `labels`, `block_assignments`, `period_assignments` (WAL mode; schema + `ALTER TABLE` migrations in `Store.createSchema`, which intentionally ignores "column exists" errors) |
| `config.json` | the `Config` struct |
| `sprint.json` | ticket/work-item corpus written by the active `IssueProvider`'s refresh or `sync-sprint.sh` (gitignored); stamped with `provider` so a stale cross-provider file is ignored, not reused |
| `corrections.json` | signature → ticket counts |
| `repo-tickets.json` | mined repo→ticket bridge |
| `tempo-worklogs.json` | Tempo's `(day\|block) → worklogId` (`Int`), deliberately *not* pruned with segments |
| `sevenpace-worklogs.json` | 7pace's own `(day\|block) → worklogId` (UUID string) — kept separate from Tempo's, see Timesheet output above |
| `editor-context/*.json` | heartbeats written by the editor extension, read when an editor is frontmost |

Plus `~/timesheet-log.md` for exported rows. Migration and run-once state lives in UserDefaults:
`ttMigratedV1`, `ttBackfilledV1`, `submittedDays`, `lastMorningDay`, `lastEveningDay`.

Retention is enforced by `housekeeping()` on a background queue at launch
(`segmentRetentionDays`, shorter `submittedRetentionDays` for days already posted to Tempo,
`labelMaxCount` label cap, 90-day Tempo worklog-map prune).
