#!/usr/bin/env bash
# Refresh the local sprint picklist (sprint.json) from Jira.
#
# The DAEMON never touches the network. This script is the only piece that does,
# and you run it on whatever cadence you like (cron, manually, or let Claude do it
# via the atlassian MCP). It writes ~/Library/Application Support/TimeTracker/sprint.json
# which the menu-bar app reads for its ticket picklist and key validation.
#
# Requires: jq, and an UNSCOPED (classic) Atlassian API token
# (https://id.atlassian.com/manage/api-tokens). Scoped tokens 401 against the
# <site>.atlassian.net base URL — they only work via the api.atlassian.com gateway.
#   export ATLASSIAN_SITE=yourcompany           # the <site> in <site>.atlassian.net
#   export ATLASSIAN_EMAIL=you@company.com
#   export ATLASSIAN_API_TOKEN=xxxx
set -euo pipefail

: "${ATLASSIAN_SITE:?set ATLASSIAN_SITE}"
: "${ATLASSIAN_EMAIL:?set ATLASSIAN_EMAIL}"
: "${ATLASSIAN_API_TOKEN:?set ATLASSIAN_API_TOKEN}"

OUT="$HOME/Library/Application Support/TimeTracker/sprint.json"
mkdir -p "$(dirname "$OUT")"

JQL='assignee = currentUser() AND statusCategory != Done AND project in (CLOUDINFRA, PES, GEN) ORDER BY updated DESC'

resp=$(curl -sf -G "https://${ATLASSIAN_SITE}.atlassian.net/rest/api/3/search/jql" \
    --data-urlencode "jql=${JQL}" \
    --data-urlencode "fields=summary" \
    --data-urlencode "maxResults=50" \
    -u "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" \
    -H "Accept: application/json")

echo "$resp" | jq '{updated: now | todate, tickets: [.issues[] | {key: .key, summary: .fields.summary}]}' > "$OUT"
echo "Wrote $(jq '.tickets | length' "$OUT") tickets to $OUT"
