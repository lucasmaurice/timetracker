// TimeTracker Context — a tiny VS Code / Kiro extension that gathers a per-workspace "heartbeat"
// of the live editor state and gets it to the local TimeTracker app: reliable repo/branch/file
// (from the built-in Git extension), the symbol you're editing, commands run in the integrated
// terminal, and the active task. No network calls, ever.
//
// This extension runs wherever the WORKSPACE lives — local, or the remote host when you're on
// Remote-SSH/Codespaces/WSL — because it needs the git extension's exported API and other
// workspace-scoped data that only exists there. When the workspace is local, that's also where
// TimeTracker reads its heartbeat file from, so it writes directly. When the workspace is REMOTE,
// direct writes would land on the remote machine's disk where TimeTracker can never see them — so
// instead it hands the payload to the paired `timetracker-context-bridge` extension (which VS Code
// always keeps on your local machine, via its own `extensionKind: ["ui"]`) over
// `vscode.commands.executeCommand`, VS Code's own command-routing bridge. No network call, no file
// access outside the heartbeat directory — everything travels inside VS Code's own already-
// authenticated connection to the remote host.

import * as vscode from 'vscode';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const CONTEXT_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'TimeTracker', 'editor-context');
const MAX_RECENT = 8;
const MAX_CMDS = 8;
const HEARTBEAT_MS = 15000;

let gitApi: any;
let fileId = '';
let outFile = '';
let warnedMissingBridge = false;
const recentFiles: string[] = [];
const terminalCmds: string[] = [];
let activeTask: string | undefined;
let lastPayload: Record<string, unknown> = {};

/// `vscode.env.remoteName` is undefined for a fully local session, and a string ("ssh-remote",
/// "wsl", "codespaces", ...) whenever the workspace is remote — exactly what decides whether a
/// direct local write would land on the wrong machine.
function isRemote(): boolean {
  return vscode.env.remoteName !== undefined;
}

export async function activate(ctx: vscode.ExtensionContext) {
  // Local-write path only matters for non-remote sessions; harmless (and ignored) otherwise.
  try { fs.mkdirSync(CONTEXT_DIR, { recursive: true }); } catch { /* TimeTracker not installed yet, or remote */ }

  const root = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  fileId = hash(root ?? `no-folder-${process.pid}`);
  outFile = path.join(CONTEXT_DIR, fileId + '.json');

  // The built-in Git extension is the authoritative source for repo + branch.
  try {
    const gitExt = vscode.extensions.getExtension('vscode.git');
    if (gitExt) { if (!gitExt.isActive) { await gitExt.activate(); } gitApi = gitExt.exports.getAPI(1); }
  } catch { /* ignore */ }

  const sched = debounce(write, 400);

  ctx.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor((e) => { if (e) { pushRecent(e.document.uri.fsPath); } void sched(); }),
    vscode.window.onDidChangeTextEditorSelection(() => void sched()),
    vscode.window.onDidChangeWindowState(() => void write()),
    vscode.tasks.onDidStartTask((e) => { activeTask = e.execution.task.name; void sched(); }),
    vscode.tasks.onDidEndTask(() => { activeTask = undefined; }),
    vscode.debug.onDidChangeActiveDebugSession(() => void sched()),
    vscode.commands.registerCommand('timetracker.status', showStatus),
  );

  // Integrated-terminal command capture (shell integration; VS Code 1.93+, present in recent
  // forks). Gated at runtime so the extension still loads on older bases.
  const anyWin = vscode.window as any;
  if (typeof anyWin.onDidStartTerminalShellExecution === 'function') {
    ctx.subscriptions.push(anyWin.onDidStartTerminalShellExecution((e: any) => {
      const cmd: string | undefined = e?.execution?.commandLine?.value;
      if (cmd && cmd.trim()) {
        terminalCmds.push(cmd.trim().slice(0, 160));
        while (terminalCmds.length > MAX_CMDS) { terminalCmds.shift(); }
        void sched();
      }
    }));
  }

  if (vscode.window.activeTextEditor) { pushRecent(vscode.window.activeTextEditor.document.uri.fsPath); }

  const timer = setInterval(() => { if (vscode.window.state.focused) { void write(); } }, HEARTBEAT_MS);
  ctx.subscriptions.push({ dispose: () => clearInterval(timer) });
  void write();
}

export function deactivate() {
  // Remove our heartbeat so a closed window isn't read as the focused one.
  if (isRemote()) {
    // Fire-and-forget: deactivate() isn't reliably awaited, and there's nothing useful to do if
    // the bridge (or the command bus itself, mid-teardown) doesn't respond in time.
    void Promise.resolve(vscode.commands.executeCommand('timetracker.removeHeartbeat', fileId)).catch(() => {});
    return;
  }
  try { if (outFile && fs.existsSync(outFile)) { fs.unlinkSync(outFile); } } catch { /* ignore */ }
}

async function write() {
  const ed = vscode.window.activeTextEditor;
  const root = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  const rel = (p?: string): string | undefined => (p ? vscode.workspace.asRelativePath(p, false) : undefined);

  let repo: string | undefined;
  let branch: string | undefined;
  let scmMessage: string | undefined;
  let changes: string[] = [];
  try {
    const repos: any[] = gitApi?.repositories ?? [];
    const r = (ed && repos.find((x) => ed.document.uri.fsPath.startsWith(x.rootUri.fsPath))) ?? repos[0];
    if (r) {
      repo = path.basename(r.rootUri.fsPath);
      branch = r.state?.HEAD?.name;
      const msg = (r.inputBox?.value ?? '').trim();          // the commit message you're typing
      if (msg) { scmMessage = msg.slice(0, 200); }
      const ch = [...(r.state?.workingTreeChanges ?? []), ...(r.state?.indexChanges ?? [])];
      changes = ch.map((c: any) => rel(c.uri?.fsPath)).filter(Boolean).slice(0, 12) as string[];
    }
  } catch { /* ignore */ }

  const payload = {
    schema: 1,
    ts: Date.now() / 1000,
    focused: vscode.window.state.focused,
    app: vscode.env.appName,                 // "Visual Studio Code" or "Kiro"
    workspaceRoot: root,
    repo,
    branch,
    file: ed?.document.uri.fsPath,
    language: ed?.document.languageId,
    symbol: await symbolAtCursor(ed),
    recentFiles: recentFiles.slice(-MAX_RECENT).map((p) => rel(p)).filter(Boolean),  // repo-relative (dir context)
    changes,                                  // files you're actually modifying (relative paths)
    scmMessage,                               // commit-in-progress — often names the ticket
    terminalCmds: terminalCmds.slice(-MAX_CMDS),
    task: activeTask,
    debugSession: vscode.debug.activeDebugSession?.name,
  };
  lastPayload = payload;

  if (isRemote()) {
    try {
      await vscode.commands.executeCommand('timetracker.receiveHeartbeat', fileId, payload);
    } catch {
      // Most likely cause: the timetracker-context-bridge companion isn't installed locally, so
      // the command doesn't exist. Warn once (not every 15s heartbeat) rather than fail silently
      // forever — a remote session with no bridge installed produces no attribution signal at all,
      // and that's easy to mistake for TimeTracker itself not running.
      if (!warnedMissingBridge) {
        warnedMissingBridge = true;
        void vscode.window.showWarningMessage(
          'TimeTracker Context: install the "TimeTracker Context Bridge" extension locally to send editor context over this remote connection.');
      }
    }
    return;
  }
  try { if (outFile) { fs.writeFileSync(outFile, JSON.stringify(payload)); } } catch { /* ignore */ }
}

async function symbolAtCursor(ed?: vscode.TextEditor): Promise<string | undefined> {
  if (!ed) { return undefined; }
  try {
    const syms = await vscode.commands.executeCommand<vscode.DocumentSymbol[]>(
      'vscode.executeDocumentSymbolProvider', ed.document.uri);
    const pos = ed.selection.active;
    const find = (list?: vscode.DocumentSymbol[]): string | undefined => {
      for (const s of list ?? []) {
        if (s.range.contains(pos)) { return find(s.children) ?? s.name; }
      }
      return undefined;
    };
    return find(syms);
  } catch { return undefined; }
}

function pushRecent(p: string) {
  if (!p) { return; }
  const i = recentFiles.indexOf(p);
  if (i >= 0) { recentFiles.splice(i, 1); }
  recentFiles.push(p);
  while (recentFiles.length > MAX_RECENT) { recentFiles.shift(); }
}

function showStatus() {
  const dest = isRemote()
    ? `sent via timetracker.receiveHeartbeat to the local TimeTracker Context Bridge (remote session: ${vscode.env.remoteName})`
    : outFile;
  vscode.window.showInformationMessage(
    `TimeTracker context → ${dest}\n` + JSON.stringify(lastPayload, null, 0).slice(0, 300));
}

function debounce(fn: () => void | Promise<void>, ms: number): () => void {
  let t: NodeJS.Timeout | undefined;
  return () => { if (t) { clearTimeout(t); } t = setTimeout(() => void fn(), ms); };
}

// Small stable hash for the heartbeat filename (FNV-1a, hex). The TimeTracker side reads every
// file and picks by focus/freshness, so the exact name doesn't matter — only that it's stable.
function hash(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return (h >>> 0).toString(16);
}
