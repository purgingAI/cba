#!/usr/bin/env bash
# ── Jira Resolver Agent daemon ──────────────────────────────────────────────
# Long-polls its OWN bot (JIRA_TOKEN) for Jira tickets posted in JIRA_CHAT; for each
# ticket asks Claude (read-only over both repos) WHERE the change goes and posts a
# solution-architecture card + Mermaid diagram. Own token required (poller = 409 rule).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/config.env"

TOKEN="${JIRA_TOKEN:-}"
API="https://api.telegram.org/bot${TOKEN}"
REPLY="${JIRA_REPLY_CHAT:-$JIRA_CHAT}"
STATE="${JIRA_STATE}"; mkdir -p "$STATE"
OFFSET_FILE="${STATE}/offset"; SEEN="${STATE}/seen_ids"
LOG="${HOME}/cba/logs/jira.log"
PROMPT="$(cat "${DIR}/jira_prompt.md")"
read -r -a REPOS <<< "$JIRA_REPOS"; ADD_DIRS=(); for r in "${REPOS[@]}"; do ADD_DIRS+=(--add-dir "$r"); done

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

_send_html(){ local chat="$1" body="$2" resp ok
  [ -z "$body" ] && return
  resp="$(curl -s --max-time 60 "${API}/sendMessage" --data-urlencode "chat_id=${chat}" \
    --data-urlencode "text=${body}" -d parse_mode=HTML -d disable_web_page_preview=true)"
  ok="$(echo "$resp" | jq -r '.ok' 2>/dev/null)"
  [ "$ok" = "true" ] || curl -s --max-time 60 "${API}/sendMessage" --data-urlencode "chat_id=${chat}" \
    --data-urlencode "text=$(printf '%s' "$body" | sed -E 's/<[^>]+>//g')" -d disable_web_page_preview=true >/dev/null; }
tg_html(){ local text="$1" acc="" line   # split on NEWLINE boundaries (keeps inline tags whole)
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$acc" ] && [ $(( ${#acc} + ${#line} + 1 )) -gt 3500 ]; then _send_html "$REPLY" "$acc"; acc=""; fi
    acc="${acc}${line}"$'\n'
  done <<< "$text"
  _send_html "$REPLY" "$acc"; }
tg_photo(){ curl -s --max-time 120 "${API}/sendPhoto" -F "chat_id=${REPLY}" -F "photo=@${1}" -F "caption=${2:0:1000}" -F parse_mode=HTML >/dev/null 2>&1; }
render_mermaid(){ local mmd="$1" out="$2"
  [ "$JIRA_MERMAID" = kroki ] && curl -s --max-time 60 -X POST https://kroki.io/mermaid/png -H "Content-Type: text/plain" --data-binary @"$mmd" -o "$out"
  [ -s "$out" ] && [ "$(head -c4 "$out" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]; }

resolve_ticket(){ # <ticket text>
  local ticket="$1" out card mmd
  log "resolving ticket: $(printf '%s' "$ticket" | head -c 80)…"
  out="$(timeout "${JIRA_TIMEOUT}" claude -p "Jira ticket:\n\n${ticket}" \
      --model "${JIRA_MODEL}" --allowedTools "Read Grep Glob" "${ADD_DIRS[@]}" \
      --append-system-prompt "$PROMPT" 2>>"${HOME}/cba/logs/jira.err")"
  [ -z "$out" ] && { tg_html "🎫 Could not analyse the ticket (internal error). Check jira.err."; return; }
  card="$(printf '%s' "$out" | awk '/```mermaid/{exit} {print}')"
  mmd="$(printf '%s' "$out" | awk '/```mermaid/{f=1;next} /```/{f=0} f{print}')"
  if [ -n "$mmd" ]; then printf '%s\n' "$mmd" > /tmp/jira.mmd
    render_mermaid /tmp/jira.mmd /tmp/jira.png && tg_photo /tmp/jira.png "🎫 Solution architecture"; fi
  tg_html "$card"
}

poll(){
  local offset; offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
  local resp; resp="$(curl -s --max-time 60 "${API}/getUpdates" -d offset="$offset" -d timeout=45)"
  [ -z "$resp" ] && return
  local n; n="$(echo "$resp" | jq '.result | length' 2>/dev/null || echo 0)"
  [ "$n" -gt 0 ] 2>/dev/null || return
  local i
  for ((i=0;i<n;i++)); do
    local upd uid text mid cid
    upd="$(echo "$resp" | jq ".result[$i]")"
    uid="$(echo "$upd" | jq -r '.update_id')"
    echo $((uid+1)) > "$OFFSET_FILE"
    cid="$(echo "$upd" | jq -r '(.channel_post.chat.id // .message.chat.id // empty)')"
    # Only act on the configured Jira channel (this bot may also post changelog cards elsewhere).
    [ -n "$JIRA_CHAT" ] && [ "$cid" != "$JIRA_CHAT" ] && continue
    text="$(echo "$upd" | jq -r '(.channel_post.text // .message.text // .channel_post.caption // .message.caption // empty)')"
    mid="$(echo "$upd" | jq -r '(.channel_post.message_id // .message.message_id // empty)')"
    [ -z "$text" ] && continue
    grep -qxF "$mid" "$SEEN" 2>/dev/null && continue
    if [ "${JIRA_REQUIRE_KEY}" = "true" ] && ! printf '%s' "$text" | grep -qE "$JIRA_KEY_REGEX"; then continue; fi
    echo "$mid" >> "$SEEN"; tail -n 500 "$SEEN" > "${SEEN}.tmp" 2>/dev/null && mv "${SEEN}.tmp" "$SEEN"
    resolve_ticket "$text"
  done
}

# One-off resolve for testing: jira.sh test "<ticket text>"
if [ "${1:-}" = "test" ]; then resolve_ticket "${2:-PS-000 sample ticket}"; exit 0; fi

if [ -z "$TOKEN" ] || [ -z "$JIRA_CHAT" ]; then
  log "JIRA_TOKEN / JIRA_CHAT not configured — idle. Fill agents/jira/config.env then restart."
  echo "Jira agent not configured (set JIRA_TOKEN + JIRA_CHAT in agents/jira/config.env)."; exit 0
fi
log "jira resolver daemon up (chat ${JIRA_CHAT})"
while true; do poll || true; sleep 2; done
