---
name: swift-macos-review
description: Review checklist for this repo's stack — SwiftPM menu-bar agent app, Swift concurrency, raw SQLite via C API, Keychain, Azure DevOps / Jira REST clients, the swift-testing suite, and build.sh bundle assembly. Use when reviewing a PR, diff, or branch here, or before opening one. Every item is a failure mode this codebase has actually shipped or nearly shipped.
---

# Reviewing changes in this repo

Read `CLAUDE.md` first — it is the architecture authority. This file is the *review* pass: what to
go looking for, and the spec that settles each argument. None of it is generic advice; each item is
a defect this repo shipped, or one caught in review here.

When a finding contradicts a doc comment, **the doc is a finding too**. This codebase's comments are
unusually confident, which makes a stale one actively dangerous — reviewers trust them.

## 0. Read the delivery mechanism before you "fix" it

The two worst findings in this repo's review history were both **confident, wrong conclusions from
reading code**, and both produced changes that made things worse:

- "Manual assignments never reach Review, because `AssignView` writes `block_assignments` and the
  compiler reads `period_assignments`." False. `applyAssignment` writes *through to the segments*
  via `Store.retag`, stamping `ticket_source = "manual"` — an exact source. The "fix" layered a
  coarse whole-block override on top and silently re-broadened every finer assignment ("Last 1
  hour" → the whole block). Caught only by a human using the app.
- "The launch mining pass mutates `Attribution` off-main." False. It only reaches `repoBridge`
  (serial-queue guarded) and `Store`. There was no race at the reported site.

Before writing a finding about data not arriving somewhere: **trace the write path to the field the
reader actually reads.** Grep for the setter, not the table. A second store existing is not proof
that it's the one being used.

Corollary: when a fix is easy to reason into, it is easy to reason back into. Pin it with a test
(§3) — that is the only thing that survives the next confident reader.

## 1. Persisted key formats are a public API

Anything that becomes a lookup key in a file, a table, or a remote system is a schema. Changing its
shape without a migration is a silent data bug, not a refactor.

- The worklog maps are keyed `"\(day)|\(block)"`. Fixed blocks used a bare integer; floating
  periods use `Period.id` (`"regular|CLOUD-1"`). When that changed, **every previously submitted day
  became unreachable and re-submitting created a second full set of worklogs on a real timesheet.**
  `WorklogKey` now detects the legacy shape and the submit path offers to delete those rows first —
  don't remove that, and don't add a third key shape without the same treatment.
- Same care for `block_assignments` / `period_assignments` and every UserDefaults run-once flag
  (`ttMigratedV1`, `ttBackfilledV1`, `submittedDays`).
- A "day needs attention" predicate that flips meaning will re-nag about all of history — and here
  that nagging is what walks a user into the duplicate-worklog path. Check what it returns for data
  written by the *previous* version. `TimesheetRecord.exists` counts all three forms for exactly
  this reason.

## 2. Concurrency

`Package.swift` builds with **`-strict-concurrency=targeted`, and the build is at zero warnings.**
A new warning means someone added a race — do not merge past it, and do not silence it.

Measured on this codebase when the flag was introduced: `targeted` = 1 warning site, `complete` =
323. Complete is dominated by main-actor isolation bookkeeping, not races, which is why the project
sits at targeted. Moving to complete is separate, larger work.

- **`@unchecked Sendable` must be earned, never asserted.** Every type carrying it here guards its
  own state — an `NSLock` (`Atlassian`, `AzureDevOps`, `TempoClient`, `SevenPaceClient`), a serial
  queue (`RepoTicketBridge`, `AzurePRBridge`), or SQLite's own serialized mode (`Store`). Adding it
  to a type that doesn't is how you re-hide the exact bug class the flag exists to expose.
  `Attribution` is deliberately **not** Sendable: `sprint`/`guessKeys` are main-owned and unguarded.
  Background work gets `Attribution.BackgroundMiner`, a narrow Sendable handle, instead.
- A `nonisolated async` function hops to the global cooperative pool. Being called from inside a
  `Task { @MainActor in … }` does **not** confer isolation on the awaited function — that mistake
  shipped here. If it touches `Store`, `Attribution`, or UI, mark it `@MainActor`.
- `AppDelegate` is `@MainActor`. Timer callbacks fire on the main run loop, so they use
  `MainActor.assumeIsolated` rather than a `Task` hop, which would defer them a turn for no reason.
- Never hold a lock across an `await`. Lock, read-or-write, unlock.
- CLAUDE.md's lanes still hold: `commit()`/attribution/UI on main; enrichment on `enrichQueue`;
  Keychain reads off-main via `preload()`. Say which lane new code lands in, in the review.
- **Thread Sanitizer works with Command Line Tools alone** — `swift build --sanitize=thread`. It's
  the only dynamic check for what the compiler can't prove.

## 3. Tests

`swift test` — swift-testing (`@Test`/`#expect`), offline and deterministic, well under a second.
Run it. A change to `PeriodCompiler`, `WorklogKey`, `Ticket` decoding, or `TimesheetRecord` that
doesn't touch tests is a finding in itself.

Traps that cost real debugging time here, all of them non-obvious:

- **Inside the `#expect` macro, an integer *expression* (`8 * 3600`) is type-checked in isolation,
  defaults to `Int`, and silently compares false against a `Double?`** — while printing
  `28800.0` vs `28800`, which look identical. Spell expected Doubles explicitly (`28800.0`). A bare
  literal takes its type from context and is fine.
- **`.serialized` only orders tests *within* one suite.** Separate top-level suites still run in
  parallel. `TestEnv` claims the process-global `AppPaths.overrideDataDir`, so every suite using it
  is nested inside `TTTests` to inherit the trait. A new suite that touches `TestEnv` and sits at
  top level will corrupt its neighbours intermittently.
- **`TestEnv.deinit` must not reset the global override.** deinit is not ordered against the next
  test's init, so resetting there can point a later test at the *real* data directory mid-run.
- A test that fails and then passes on re-run is a race, not a flake. Find it. Confirm fixes over
  several consecutive runs.

What is **not** reachable by tests, so must be exercised by hand: AppKit windows (Review, Assign,
Settings), AX/TCC permission behaviour, the launch path, and live provider calls. When closing an
issue on manual verification alone, say so.

## 4. Toolchain facts (checked, not assumed)

- This machine has **Command Line Tools only, no Xcode**, which ships neither `XCTest` nor the
  toolchain's bundled `Testing` module. swift-testing is a **package dependency** built from source;
  that is what makes `swift test` work at all here. It emits a "redundant on Swift 6" deprecation
  warning — **ignore it**. Removing the dependency breaks every machine without Xcode, including a
  lean CI runner.
- A `.testTarget` depending directly on the `timetracker` **executable** target works, top-level
  code and all. No library split is needed for testability; don't propose one on those grounds.
- Xcode buys SwiftUI previews (the one real gap, since the UI is what tests can't reach) and little
  else here. It is not required for tests, sanitizers, or the build.

## 5. Raw SQLite through the C API

`sqlite3_open` on macOS's system libsqlite3 gets **serialized** threading mode, so a shared
connection won't corrupt the file across threads. That is the *only* thing it protects — it is not
licence to read app-level caches off-main.

- Every new column needs its `ALTER TABLE` in `createSchema` **and** to be added to the `SELECT`
  list, the `INSERT` column list, the bind-index sequence, and the row decoder. Bind indices are
  1-based and positional — an inserted column silently shifts every later one.
- New tables get an explicit `PRIMARY KEY`. It's what lets callers use
  `Dictionary(uniqueKeysWithValues:)` without trapping — say so in the comment, because the trap is
  invisible at the call site.
- Check whether `housekeeping()` should prune the new table.

## 6. Swift correctness traps this codebase hits

- **`Dictionary(uniqueKeysWithValues:)` traps at runtime on a duplicate key.** Use it only where a
  DB primary key guarantees uniqueness. Where uniqueness comes from call *ordering* (e.g.
  `mergeByTicket` running before Save/Submit), use `Dictionary(_:uniquingKeysWith:)` — reordering a
  pipeline should not become a hard crash.
- **Adding a non-`Optional` stored property to a `Codable` persisted to disk breaks decoding of
  every existing file** — the synthesized `init(from:)` throws on the missing key and the corpus
  silently empties. Write `init(from:)` by hand with `decodeIfPresent` + a default, as `Config` and
  `Ticket` do.
- Fallback branches that conflate "absent because unavailable" with "absent because genuinely
  empty" produce a default that looks deliberate and is wrong. `Ticket.assignedToMe` needs three
  cases, not two: key absent → unknown; key null → unassigned; dict present → compare.
- O(n) lookups inside a per-item loop: `Attribution.tickets(for:)` is a linear scan of the corpus.
  Hoist a dictionary outside the loop.

## 7. Abstention and exactness are load-bearing

CLAUDE.md's §"Abstention is load-bearing" and the `Attribution.exactSources` invariant are
correctness properties, not style.

- Any new filter, gate, or candidate pool that can drop a ticket must exempt
  `Attribution.isExact(source)`. A gate keyed on "is this in my assigned corpus" silently discards
  tickets resolved from a branch, commit, or URL — git-mined keys live in `guessTickets`, not
  `sprint`. That shipped, and threw away correctly-attributed work.
- Prefer routing rejected time into a visible "untracked" bucket over dropping it.
- Changing anything in the attribution pipeline means running `--eval` before and after and
  comparing top-1/top-3 and **auto-tag precision**. Precision over coverage.
- `--eval` moves on its own as the user's labels accumulate. Before calling a change a regression,
  `git stash` and re-run against the previous commit on the same data. A drop from 69% to 53% here
  turned out to be the same 9 correct answers over a corpus that grew 13 → 17.

## 8. Reported time must be defensible

This app writes to someone's official timesheet. Rounding, clamping and padding all inflate.

- A minimum-duration clamp turns a 36-second glance into a full billed minimum. The predicate that
  decides *whether* a row exists must be the same one the export uses — a row that submits but never
  appears in `~/timesheet-log.md` is a reconciliation bug. Both use `hasActivity`, and rounding skips
  anything below that floor so the displayed figure matches what will be billed.
- Keep the real total and the reported total as separate fields; never let rounding overwrite the
  real one.
- Padding a shortfall is fine; trimming overtime is not. (Open question worth raising: padding the
  most-dominant regular period puts ~6h on a ticket with 26 minutes of real work when the day is
  mostly empty.)

## 9. macOS agent specifics (`LSUIElement`, ad-hoc signed)

- **`UNUserNotificationCenter.current()` raises `bundleProxyForCurrentProcess is nil` in a process
  without a bundle.** `swift build && .build/debug/timetracker` is a documented dev path, so every
  call site is gated on `Bundle.main.bundleIdentifier != nil`.
- Ad-hoc signing changes the code hash every rebuild, resetting Accessibility and any TCC-style
  grant. A feature depending on a persisted grant needs a degraded path, not an assumption.
- **`CFBundleVersion` must be one to three period-separated integers, digits only.** A git SHA is
  invalid there — `build.sh` puts the commit count in it and the SHA in the custom `TTBuildSHA`.

## 10. Network clients (Azure DevOps, Jira, Tempo, 7pace)

- **Pin the exact API version, including the preview revision** (`7.1-preview.1`, not
  `7.1-preview`). Microsoft deprecates a preview once GA ships and deactivates it ~12 weeks later,
  after which requests naming `-preview` are rejected. A bare `-preview` is a scheduled outage.
- **A field read out of a REST response must be in the request's `fields`/`$select` list.** A field
  never requested reads as absent and falls into the default branch — the feature then "works" and
  does nothing. `Ticket.assignedToMe` shipped this way and was a permanent no-op on Jira.
- **Validate credentials before persisting them.** Write to the Keychain after the connection test
  succeeds, not before. Relying on the caller to `disconnect()` on failure works until someone
  refactors the caller.
- Respect the network boundary: only the active issue provider's connect/refresh, the active
  worklog provider's submit, localhost Ollama, and live PR-review resolution. Anything else needs an
  explicit line in CLAUDE.md and the README.

## 11. Style

Compact Swift, `a; b` on one line, dense comments naming the bug each line prevents. Match the
surrounding file. `swift-format` is disabled on purpose — don't run it over existing files.

## Review output

Rank findings by blast radius: corrupts external state (timesheets, Keychain, the DB) > data race >
crash > silently-does-nothing > efficiency > style. For each, give `file:line`, the concrete input
that triggers it, and the observable wrong result. "Looks risky" is not a finding. And per §0, if
the finding is "X never reaches Y", trace the write path first.
