# TimeTracker Context (VS Code / Kiro extension)

Feeds the local **TimeTracker** app richer editor context so it guesses your JIRA ticket more
accurately. It writes one small JSON "heartbeat" per workspace to
`~/Library/Application Support/TimeTracker/editor-context/` describing the live editor state:

- workspace root, **repo + branch** (from the built-in Git extension — reliable, no title parsing)
- active **file**, language, and the **symbol** (function/class) at your cursor
- the **commit message you're typing** (`scmMessage`) — your own words, often names the ticket
- **files you're modifying** (`changes`, working-tree + staged) and recent files, as repo-relative
  paths (the directories carry service/component names that match ticket summaries)
- recent integrated-**terminal commands** (`terraform`, `kubectl`, `helm`, …) via shell integration
- the active **task** / **debug session**, and whether this window is focused

**100% local.** It makes no network calls and only writes that one file. If TimeTracker isn't
installed, the file is simply never read. TimeTracker reads the freshest *focused* heartbeat when
a VS Code / Kiro window is frontmost, and merges it into the work context.

## Build

```bash
cd editor-extension
npm install
npm run compile          # → out/extension.js
```

## Install

**Option A — packaged VSIX (recommended, installs in both editors):**

```bash
npm run package          # → timetracker-context.vsix
```

- VS Code: `code --install-extension timetracker-context.vsix`
- Kiro:    `kiro --install-extension timetracker-context.vsix`
  (or in either editor: Command Palette → *Extensions: Install from VSIX…*)

**Option B — dev run (no packaging):** open this folder in VS Code / Kiro and press **F5** to
launch an Extension Development Host.

## Verify

Command Palette → **TimeTracker: Show context status** shows the file path it's writing and the
last payload. Or:

```bash
cat ~/Library/Application\ Support/TimeTracker/editor-context/*.json | python3 -m json.tool
```

## Notes

- Terminal-command capture uses VS Code shell integration (`onDidStartTerminalShellExecution`,
  VS Code 1.93+ / recent Kiro). On older bases the extension still works; that one field is just
  omitted.
- Works in any VS Code fork that supports the extension API (VS Code, Kiro, VSCodium, Cursor).
