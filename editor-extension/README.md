# TimeTracker Context (VS Code / Kiro extension)

Feeds the local **TimeTracker** app richer editor context so it guesses your ticket more
accurately. It writes one small JSON "heartbeat" per workspace describing the live editor state:

- workspace root, **repo + branch** (from the built-in Git extension — reliable, no title parsing)
- active **file**, language, and the **symbol** (function/class) at your cursor
- the **commit message you're typing** (`scmMessage`) — your own words, often names the ticket
- **files you're modifying** (`changes`, working-tree + staged) and recent files, as repo-relative
  paths (the directories carry service/component names that match ticket summaries)
- recent integrated-**terminal commands** (`terraform`, `kubectl`, `helm`, …) via shell integration
- the active **task** / **debug session**, and whether this window is focused

**100% local, no network calls, ever.** If TimeTracker isn't installed, the heartbeat is simply
never read. TimeTracker reads the freshest *focused* heartbeat when a VS Code / Kiro window is
frontmost, and merges it into the work context.

## If you use Remote-SSH / Codespaces / WSL: install the Bridge too

This extension needs to run wherever your **workspace** actually lives, because that's the only
place the Git extension's real repo/branch/changes state exists. For a local workspace that's your
Mac — no extra step. For a **remote** workspace (Remote-SSH, Codespaces, WSL, dev containers), VS
Code correctly runs it on the remote host, which means a direct file write would land on the
*remote* machine's disk, invisible to the TimeTracker app on your Mac.

To fix that, also install the companion **[`editor-extension-bridge`](../editor-extension-bridge)**
("TimeTracker Context Bridge"). It declares `extensionKind: ["ui"]`, so VS Code always keeps *it*
on your local machine regardless of where the workspace is — this extension then hands it the
heartbeat over `vscode.commands.executeCommand`, VS Code's own command-routing bridge, instead of
writing a file directly. No SSH config, no new network surface: everything travels inside VS
Code's own already-authenticated connection to the remote host. See that extension's own README
for build/install — the steps below are identical, just in the other folder.

If you forget to install it, you'll get a one-time warning notification the first time a remote
heartbeat fails to send, rather than silent nothing.

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

Remote workflows: also build/install `editor-extension-bridge` the same way, but make sure it
lands **locally** — e.g. run VS Code's *Install from VSIX* command while a *local* window (File →
New Window, not the remote one) is focused, or use `code --install-extension` from a local
terminal rather than the remote-connected integrated terminal.

**Option B — dev run (no packaging):** open this folder in VS Code / Kiro and press **F5** to
launch an Extension Development Host.

## Verify

Command Palette → **TimeTracker: Show context status** shows where the heartbeat is going (a local
file path, or — over a remote connection — confirmation it was sent to the Bridge) and the last
payload. Or, for a local session:

```bash
cat ~/Library/Application\ Support/TimeTracker/editor-context/*.json | python3 -m json.tool
```

## Notes

- Terminal-command capture uses VS Code shell integration (`onDidStartTerminalShellExecution`,
  VS Code 1.93+ / recent Kiro). On older bases the extension still works; that one field is just
  omitted.
- Works in any VS Code fork that supports the extension API (VS Code, Kiro, VSCodium, Cursor).
