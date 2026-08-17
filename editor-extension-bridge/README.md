# TimeTracker Context Bridge (VS Code / Kiro extension)

The local half of the **TimeTracker Context** pair — see
**[`editor-extension`](../editor-extension)** first, this one only matters if you use
Remote-SSH, Codespaces, WSL, or dev containers.

## Why this exists

`timetracker-context` (the collector) needs to run wherever your **workspace** lives, because
that's the only place the real repo/branch/working-tree-changes state exists (via the built-in Git
extension). For a remote workspace, VS Code correctly runs it on the remote host — but a heartbeat
file written there is invisible to the TimeTracker app on your Mac.

This extension exists purely to be the other end of that gap. It declares
`"extensionKind": ["ui"]` in its `package.json`, which forces VS Code to always keep it on your
**local** machine, regardless of which workspace is open. The collector hands it the finished
heartbeat over `vscode.commands.executeCommand('timetracker.receiveHeartbeat', ...)` — VS Code's
own command-routing bridge, guaranteed to reach the right host — and this extension just writes it
to the same local file TimeTracker already reads.

**No network calls, no file access outside the heartbeat directory, no channel other than VS
Code's own already-authenticated connection to the remote host.** It validates every incoming id
against the collector's known filename format and caps payload size before writing anything.

## Build & Install

Identical to `editor-extension` — see that README. The only thing that matters here: make sure
this one installs to your **local** machine, not the remote workspace (run *Install from VSIX*
from a local window, or `code --install-extension` from a local terminal — not the remote-connected
integrated terminal).

```bash
cd editor-extension-bridge
npm install
npm run compile
npm run package           # → timetracker-context-bridge.vsix
code --install-extension timetracker-context-bridge.vsix
```

## Verify

There's no user-facing command — it's silent by design. Confirm it's working by checking a
heartbeat actually lands while you're connected over Remote-SSH:

```bash
cat ~/Library/Application\ Support/TimeTracker/editor-context/*.json | python3 -m json.tool
```

If nothing appears, check the collector extension's status (Command Palette → **TimeTracker: Show
context status** in the remote window) — it shows a one-time warning notification if it can't find
this extension's command, which usually means this one isn't installed locally.
