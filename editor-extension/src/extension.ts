// TimeTracker Context — a tiny VS Code / Kiro extension that writes a per-workspace "heartbeat"
// of the live editor context to a file the local TimeTracker app reads. This gives TimeTracker
// reliable repo/branch/file plus signal it can't get from the outside: the symbol you're editing,
// commands run in the integrated terminal, and the active task. 100% local — one JSON file, no
// network. If TimeTracker isn't installed the file is simply never read.

import * as vscode from 'vscode';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const CONTEXT_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'TimeTracker', 'editor-context');
const MAX_RECENT = 8;
const MAX_CMDS = 8;
const HEARTBEAT_MS = 15000;

let gitApi: any;
let outFile = '';
const recentFiles: string[] = [];
const terminalCmds: string[] = [];
let activeTask: string | undefined;
let lastPayload: Record<string, unknown> = {};

export async function activate(ctx: vscode.ExtensionContext) {
  try { fs.mkdirSync(CONTEXT_DIR, { recursive: true }); } catch { /* TimeTracker not installed yet */ }

  const root = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  outFile = path.join(CONTEXT_DIR, hash(root ?? `no-folder-${process.pid}`) + '.json');

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
  vscode.window.showInformationMessage(
    `TimeTracker context → ${outFile}\n` + JSON.stringify(lastPayload, null, 0).slice(0, 300));
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
