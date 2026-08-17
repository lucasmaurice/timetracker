// TimeTracker Context Bridge — the local half of the TimeTracker Context pair.
//
// `extensionKind: ["ui"]` (see package.json) forces VS Code to keep this extension on your LOCAL
// machine even when the active workspace is remote (Remote-SSH, Codespaces, WSL, dev containers).
// The collector (`timetracker-context`) runs wherever the workspace lives — local or remote — and
// gathers the real repo/branch/changes/symbol/terminal data there, using the git extension's
// exported API and other workspace-only APIs that don't cross the local/remote boundary. It hands
// the finished payload to THIS extension over `vscode.commands.executeCommand`, VS Code's own
// command-routing bridge, which is guaranteed to reach the right host regardless of where either
// extension is running. No network call, no file access outside the heartbeat directory, and no
// channel other than VS Code's own (already-authenticated) extension-to-extension command bus.

import * as vscode from 'vscode';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const CONTEXT_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'TimeTracker', 'editor-context');
// The collector's heartbeat ids are lowercase hex (an FNV-1a hash of the workspace root). Reject
// anything else outright rather than trust an argument that reaches us via inter-extension IPC —
// cheap defense against a path-traversal id from a buggy or unexpected caller.
const SAFE_ID = /^[0-9a-f]+$/i;
const MAX_PAYLOAD_BYTES = 64 * 1024;   // heartbeats are a few hundred bytes; this is generous headroom

export function activate(ctx: vscode.ExtensionContext) {
  try { fs.mkdirSync(CONTEXT_DIR, { recursive: true }); } catch { /* TimeTracker not installed yet */ }

  ctx.subscriptions.push(
    vscode.commands.registerCommand('timetracker.receiveHeartbeat', (fileId: unknown, payload: unknown) => {
      if (typeof fileId !== 'string' || !SAFE_ID.test(fileId)) { return; }
      if (typeof payload !== 'object' || payload === null) { return; }
      let json: string;
      try { json = JSON.stringify(payload); } catch { return; }
      if (json.length > MAX_PAYLOAD_BYTES) { return; }
      try { fs.writeFileSync(path.join(CONTEXT_DIR, `${fileId}.json`), json); } catch { /* ignore */ }
    }),
    vscode.commands.registerCommand('timetracker.removeHeartbeat', (fileId: unknown) => {
      if (typeof fileId !== 'string' || !SAFE_ID.test(fileId)) { return; }
      try {
        const p = path.join(CONTEXT_DIR, `${fileId}.json`);
        if (fs.existsSync(p)) { fs.unlinkSync(p); }
      } catch { /* ignore */ }
    }),
  );
}

export function deactivate() {}
