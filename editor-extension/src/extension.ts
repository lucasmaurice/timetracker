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

// Off by default: a command line can carry secrets typed inline (tokens in `export FOO=...`,
// passwords in connection strings, `curl -H "Authorization: Bearer ..."`). Read live (not cached)
// so toggling the setting takes effect immediately, no reload needed.
function terminalCaptureEnabled(): boolean {
  return vscode.workspace.getConfiguration('timetracker').get<boolean>('captureTerminalCommands', false);
}

let warnedTerminalCapture = false;
function maybeWarnTerminalCapture() {
  if (!terminalCaptureEnabled() || warnedTerminalCapture) { return; }
  warnedTerminalCapture = true;
  void vscode.window.showWarningMessage(
    'TimeTracker Context: terminal command capture is ON. Command lines can contain secrets ' +
    '(tokens, passwords) typed inline — this text goes into TimeTracker\'s local heartbeat file. ' +
    'Turn off "timetracker.captureTerminalCommands" in Settings if you don\'t want that.');
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

  maybeWarnTerminalCapture();   // reminder if it was already left on from a previous session

  ctx.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor((e) => { if (e) { pushRecent(e.document.uri.fsPath); } void sched(); }),
    vscode.window.onDidChangeTextEditorSelection(() => void sched()),
    vscode.window.onDidChangeWindowState(() => void write()),
    vscode.tasks.onDidStartTask((e) => { activeTask = e.execution.task.name; void sched(); }),
    vscode.tasks.onDidEndTask(() => { activeTask = undefined; }),
    vscode.debug.onDidChangeActiveDebugSession(() => void sched()),
    vscode.commands.registerCommand('timetracker.status', showStatus),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (!e.affectsConfiguration('timetracker.captureTerminalCommands')) { return; }
      if (terminalCaptureEnabled()) { maybeWarnTerminalCapture(); }
      else { terminalCmds.length = 0; }   // purge whatever was captured while it was on
    }),
  );

  // Integrated-terminal command capture (shell integration; VS Code 1.93+, present in recent
  // forks). Always registered so a live setting toggle takes effect without a reload — gated
  // inside the handler (terminalCaptureEnabled(), checked fresh on every command) rather than at
  // registration time.
  const anyWin = vscode.window as any;
  if (typeof anyWin.onDidStartTerminalShellExecution === 'function') {
    ctx.subscriptions.push(anyWin.onDidStartTerminalShellExecution((e: any) => {
      if (!terminalCaptureEnabled()) { return; }
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
    // Re-checked here too (not just at capture time): if the setting was disabled mid-session,
    // this stops SENDING whatever was already captured while it was on, immediately — not just
    // stopping new capture. See maybeWarnTerminalCapture's config-change handler for the memory-
    // clearing counterpart.
    terminalCmds: terminalCaptureEnabled() ? terminalCmds.slice(-MAX_CMDS) : [],
    task: activeTask,
    debugSession: vscode.debug.activeDebugSession?.name,
    // Only gathered when remote — the Mac process (SessionReader.swift) already reads Claude
    // Code / Copilot state directly for a local session; it has no local path to state that
    // lives on a remote host, which is exactly where THIS process is running in that case.
    aiSession: isRemote() ? aiSessionRemote(root) : undefined,
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

// AI-session detection for a REMOTE host — a TypeScript port of the same reads
// SessionReader.swift already does for a local Mac session (Claude Code JSONL transcripts,
// Copilot Chat's workspaceStorage), pointed at the remote host's own equivalent paths instead:
// `~/.claude/projects` (same encoding either way — Claude Code's cwd-encoding is platform-
// independent) and `~/.vscode-server/data/User/workspaceStorage` (VS Code Server's documented
// remote data directory, vs. desktop VS Code's `Library/Application Support/Code/User/...`).
// Reads only — never modifies anything, same 100%-local-reads posture as the Swift side.
let aiSessionCache: { repoPath: string | undefined; value: string | undefined; at: number } | undefined;
const AI_SESSION_TTL_MS = 60000;

function aiSessionRemote(repoPath: string | undefined): string | undefined {
  const now = Date.now();
  if (aiSessionCache && aiSessionCache.repoPath === repoPath && now - aiSessionCache.at < AI_SESSION_TTL_MS) {
    return aiSessionCache.value;
  }
  const parts: string[] = [];
  if (repoPath) {
    const claude = claudeCodeForRepo(repoPath);
    if (claude) { parts.push(`Claude Code: ${claude}`); }
    const copilot = copilotForRepo(repoPath);
    if (copilot) { parts.push(`Copilot: ${copilot}`); }
  }
  const value = parts.length ? parts.join(' ⏐ ') : undefined;
  aiSessionCache = { repoPath, value, at: now };
  return value;
}

function newestFile(dir: string, exts: string[]): string | undefined {
  let names: string[];
  try { names = fs.readdirSync(dir); } catch { return undefined; }
  let best: { full: string; mtime: number } | undefined;
  for (const name of names) {
    if (!exts.includes(path.extname(name).slice(1))) { continue; }
    const full = path.join(dir, name);
    let mtime: number;
    try { mtime = fs.statSync(full).mtimeMs; } catch { continue; }
    if (!best || mtime > best.mtime) { best = { full, mtime }; }
  }
  return best?.full;
}

// Claude Code encodes the cwd by replacing every non-alphanumeric character with "-" — same rule
// SessionReader.swift uses (see its comment for how this was confirmed: a real path containing
// "@" showed no "@" in the actual encoded directory name, which a "/"-and-"."-only replacement
// would have left in place).
function encodeCwd(p: string): string {
  return p.replace(/[^a-zA-Z0-9]/g, '-');
}

function claudeCodeForRepo(repoPath: string): string | undefined {
  const dir = path.join(os.homedir(), '.claude', 'projects', encodeCwd(repoPath));
  const f = newestFile(dir, ['jsonl']);
  return f ? summarizeClaudeJSONL(f) : undefined;
}

function summarizeClaudeJSONL(file: string): string | undefined {
  let content: string;
  try { content = fs.readFileSync(file, 'utf8'); } catch { return undefined; }
  let title: string | undefined;
  const userMsgs: string[] = [];
  for (const line of content.split('\n')) {
    if (!line.trim()) { continue; }
    let obj: any;
    try { obj = JSON.parse(line); } catch { continue; }
    if (obj?.type === 'ai-title' && typeof obj.aiTitle === 'string') {
      title = obj.aiTitle;
    } else if (obj?.type === 'user') {
      const t = claudeUserText(obj.message);
      if (t) { userMsgs.push(t); }
    }
  }
  const parts: string[] = [];
  if (title) { parts.push(title); }
  // Last 3 REAL prompts: skip one-word controls and Claude Code's own command/skill scaffolding,
  // injected as synthetic "user" turns (slash-command wrappers, whole skill files loaded as "Base
  // directory for this skill: ..."). Without this, those synthetic turns crowd the actual prompt
  // out of the last-3 window — confirmed on a real transcript (see SessionReader.swift, the
  // canonical version of this logic, for the exact case that surfaced it).
  parts.push(...userMsgs.filter((m) => m.length > 4 && !looksSynthetic(m)).slice(-3).map((m) => m.slice(0, 200)));
  return parts.length ? parts.join(' · ') : undefined;
}

// True for Claude Code's own injected scaffolding (slash-command wrappers, skill-file content,
// hook/system output) rather than something you actually typed.
const SYNTHETIC_MARKERS = [
  '<command-message>', '<command-name>', '<command-args>',
  '<local-command-stdout>', '<local-command-stderr>', '<local-command-caveat>',
  '<system-reminder>', 'Base directory for this skill:',
];
function looksSynthetic(text: string): boolean {
  return SYNTHETIC_MARKERS.some((m) => text.includes(m));
}

function claudeUserText(message: any): string | undefined {
  if (!message || typeof message !== 'object') { return undefined; }
  if (typeof message.content === 'string') { return message.content; }
  if (Array.isArray(message.content)) {
    const texts = message.content
      .filter((c: any) => c?.type === 'text' && typeof c.text === 'string')
      .map((c: any) => c.text as string);
    return texts.length ? texts.join(' ') : undefined;
  }
  return undefined;
}

function vscodeServerDataDir(): string {
  const override = process.env.VSCODE_SERVER_DIR;
  return override ? path.join(override, 'data') : path.join(os.homedir(), '.vscode-server', 'data');
}

function copilotForRepo(repoPath: string): string | undefined {
  const base = path.join(vscodeServerDataDir(), 'User', 'workspaceStorage');
  const hashDir = workspaceDirMatching(base, repoPath);
  if (!hashDir) { return undefined; }
  // Modern Copilot Chat writes single-object .jsonl; older builds used .json.
  const f = newestFile(path.join(hashDir, 'chatSessions'), ['jsonl', 'json']);
  return f ? copilotChatSummary(f) : undefined;
}

// Find the workspaceStorage hash dir whose workspace.json folder == repoPath.
function workspaceDirMatching(base: string, repoPath: string): string | undefined {
  let names: string[];
  try { names = fs.readdirSync(base); } catch { return undefined; }
  const want = 'file://' + repoPath;
  for (const name of names) {
    const wj = path.join(base, name, 'workspace.json');
    let obj: any;
    try { obj = JSON.parse(fs.readFileSync(wj, 'utf8')); } catch { continue; }
    const folder = obj?.folder;
    if (typeof folder === 'string' && (folder === want || folder.endsWith(repoPath))) {
      return path.join(base, name);
    }
  }
  return undefined;
}

// Targeted parse of a Copilot Chat session: pull the user's recent prompt text from
// `v.requests[].message.text` (avoids scooping up model/UI noise a generic harvester would catch).
function copilotChatSummary(file: string): string | undefined {
  let obj: any;
  try { obj = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return undefined; }
  const v = obj?.v ?? obj;
  const requests = v?.requests;
  if (!Array.isArray(requests)) { return undefined; }
  const texts = requests
    .map((r: any) => r?.message?.text)
    .filter((t: any) => typeof t === 'string' && t.length > 4) as string[];
  const recent = texts.slice(-3).map((t) => t.slice(0, 200));
  return recent.length ? recent.join(' · ') : undefined;
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
  // AI-session path diagnostics — only meaningful (and only computed) when remote, since that's
  // the only case where aiSessionRemote's path-matching can silently miss due to an environment
  // mismatch (e.g. os.homedir() resolving differently across process contexts on domain-joined
  // accounts) that's otherwise invisible from the outside.
  let diag = '';
  if (isRemote()) {
    const root = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    const home = os.homedir();
    const claudeDir = root ? path.join(home, '.claude', 'projects', encodeCwd(root)) : undefined;
    const copilotBase = path.join(vscodeServerDataDir(), 'User', 'workspaceStorage');
    diag = '\n--- ai-session diagnostics ---'
      + `\nos.homedir() = ${home}`
      + `\nworkspaceRoot = ${root}`
      + `\nclaudeDir = ${claudeDir}`
      + `\nclaudeDir exists = ${claudeDir ? fs.existsSync(claudeDir) : 'n/a (no workspace root)'}`
      + `\nvscodeServerDataDir = ${vscodeServerDataDir()}`
      + `\ncopilot workspaceStorage exists = ${fs.existsSync(copilotBase)}`;
  }
  vscode.window.showInformationMessage(
    `TimeTracker context → ${dest}${diag}\n` + JSON.stringify(lastPayload, null, 0).slice(0, 300));
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
