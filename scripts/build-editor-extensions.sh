#!/usr/bin/env bash
# Build + package both editor extensions (timetracker-context, timetracker-context-bridge) into
# VSIX files, and install/update the ones that belong on THIS (local) machine.
#
# The collector (editor-extension) needs to run wherever you actually edit — including, over
# Remote-SSH/Codespaces/WSL, the REMOTE host — which this script cannot reach automatically. It
# only auto-installs the collector locally (for a plain local workflow) and the Bridge locally
# (always correct — it must never run anywhere but here). See the printed instructions for the
# remote-side step.
set -euo pipefail
cd "$(dirname "$0")/.."

build_one() {
  local dir="$1" label="$2"
  echo "==> $label: npm install"
  (cd "$dir" && npm install --silent)
  echo "==> $label: compile + package"
  (cd "$dir" && npm run package)
}

install_local() {
  local vsix="$1" label="$2"
  for cli in code kiro; do
    if command -v "$cli" >/dev/null 2>&1; then
      echo "==> $label: installing/updating in $cli (local)"
      "$cli" --install-extension "$vsix" --force
    fi
  done
}

build_one editor-extension "TimeTracker Context (collector)"
build_one editor-extension-bridge "TimeTracker Context Bridge (local-only)"

echo
install_local "editor-extension-bridge/timetracker-context-bridge.vsix" "Bridge"
# The collector is only auto-installed locally for a plain (non-remote) workflow. If you use
# Remote-SSH, this local copy is harmless to have (it'll just sit unused for local workspaces)
# but is NOT what makes remote sessions work — see the remote step below.
install_local "editor-extension/timetracker-context.vsix" "Collector (local)"

cat <<'EOF'

Built:
  editor-extension/timetracker-context.vsix
  editor-extension-bridge/timetracker-context-bridge.vsix

Installed/updated locally above: the Bridge, and the collector for local (non-remote) editing.

Remote-SSH / Codespaces / WSL — install the COLLECTOR on the REMOTE side too (this script can't
reach it):
  1. Copy editor-extension/timetracker-context.vsix to the remote host, e.g.:
       scp editor-extension/timetracker-context.vsix your-remote:/tmp/
  2. From a REMOTE-connected VS Code window — integrated terminal or Extensions panel:
       code --install-extension /tmp/timetracker-context.vsix --force
     (or Extensions panel -> "..." menu -> Install from VSIX..., picking that file)

Do NOT install the Bridge extension on the remote side — it must stay local (that's the whole
point of its extensionKind: ["ui"] declaration). It was already installed locally above.

Re-run this script any time you pull a change to either extension; --force makes both installs
idempotent updates, not just first-time installs.
EOF
