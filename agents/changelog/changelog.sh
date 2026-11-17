#!/usr/bin/env bash
# ── Changelog Agent daemon ──────────────────────────────────────────────────
# Every CHLOG_INTERVAL: fetch new commits on BE+FE, have Claude explain the FLOW
# change (extensive repo lookup), render a Mermaid diagram, post a rich card.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Base CBA config exists on the laptop install only; the EC2 install is self-contained.
[ -f "${HOME}/cba/config.env" ] && source "${HOME}/cba/config.env"
source "${DIR}/config.env"                       # CHLOG_* overrides (+ secrets.env)

TOKEN="${CHLOG_TOKEN:-${CBA_TOKEN:-}}"
API="https://api.telegram.org/bot${TOKEN}"
CHAT="${CHLOG_CHAT:-}"
STATE="${CHLOG_STATE}"; mkdir -p "$STATE"
LOG="${CHLOG_LOG:-${HOME}/cba/logs/changelog.log}"; mkdir -p "$(dirname "$LOG")"
PROMPT="$(cat "${DIR}/changelog_prompt.md")"

# Schema probe credentials: reuse the CBA MySQL creds unless overridden explicitly.
export CHLOG_MYSQL_HOST="${CHLOG_MYSQL_HOST:-${CBA_MYSQL_HOST:-}}"
export CHLOG_MYSQL_USER="${CHLOG_MYSQL_USER:-${CBA_MYSQL_USER:-}}"
export CHLOG_MYSQL_PASS="${CHLOG_MYSQL_PASS:-${CBA_MYSQL_PASS:-}}"
export CHLOG_MYSQL_PORT CHLOG_MYSQL_SCHEMAS CHLOG_MONGO_URI CHLOG_MONGO_DBS

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# ── Control switches (written by control_ui.py; read fresh every tick) ───────
# Missing file = everything on, so the agent still works before the panel is opened.
ctl(){ # <key> -> "1" | "0"
  local f="${STATE}/control.json"
  [ -f "$f" ] || { echo 1; return; }
  # NOT `.[$k] // true` — jq's // treats false as empty, so an off switch would read as on.
  local v; v="$(jq -r --arg k "$1" 'if has($k) then .[$k] else true end' "$f" 2>/dev/null)"
  [ "$v" = "true" ] && echo 1 || echo 0
}

_send_html(){ # <chat> <body> — one HTML message; falls back to plain on parse error
  local chat="$1" body="$2" resp ok
  [ -z "$body" ] && return
  resp="$(curl -s --max-time 60 "${API}/sendMessage" \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=${body}" \
    -d parse_mode=HTML -d disable_web_page_preview=true)"
  ok="$(echo "$resp" | jq -r '.ok' 2>/dev/null)"
  if [ "$ok" != "true" ]; then
    log "HTML send failed ($(echo "$resp" | jq -rc '.description' 2>/dev/null)); retry plain"
    curl -s --max-time 60 "${API}/sendMessage" \
      --data-urlencode "chat_id=${chat}" \
      --data-urlencode "text=$(printf '%s' "$body" | sed -E 's/<[^>]+>//g')" \
      -d disable_web_page_preview=true >/dev/null
  fi
}
tg_html(){ # <text> -> HTML card, split on NEWLINE boundaries (keeps inline tags whole)
  local text="$1" acc="" line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$acc" ] && [ $(( ${#acc} + ${#line} + 1 )) -gt 3500 ]; then _send_html "$CHAT" "$acc"; acc=""; fi
    acc="${acc}${line}"$'\n'
  done <<< "$text"
  _send_html "$CHAT" "$acc"
}

tg_photo(){ # <png> <caption>
  local png="$1" cap="${2:0:1000}"
  curl -s --max-time 120 "${API}/sendPhoto" \
    -F "chat_id=${CHAT}" -F "photo=@${png}" \
    -F "caption=${cap}" -F parse_mode=HTML >/dev/null 2>&1
}

teams_post(){ # <json-payload-file> — Adaptive Card to an incoming webhook
  [ -z "${CHLOG_TEAMS_WEBHOOK:-}" ] && return 0
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
    -H 'Content-Type: application/json' --data-binary @"$1" "$CHLOG_TEAMS_WEBHOOK")"
  # Power Automate Workflows answers 202 Accepted (the flow is queued, not run inline);
  # the retired O365 connector answered 200. Accept any 2xx.
  case "$code" in 2??) : ;; *) log "teams post failed http=$code" ;; esac
}

render_mermaid(){ # <mmd-file> <out-png> -> 0 on success
  local mmd="$1" out="$2"
  case "${CHLOG_MERMAID}" in
    kroki) curl -s --max-time 60 -X POST https://kroki.io/mermaid/png \
             -H "Content-Type: text/plain" --data-binary @"$mmd" -o "$out" ;;
    ink)   base64 -w0 "$mmd" | { read b64; curl -s --max-time 60 \
             "https://mermaid.ink/img/${b64}" -o "$out"; } ;;
    *)     return 1 ;;
  esac
  # valid PNG?  (magic bytes \x89PNG)
  [ -s "$out" ] && [ "$(head -c4 "$out" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]
}

process_repo(){ # <repo> <label> <branch> <state-file>
  local repo="$1" label="$2" branch="$3" sf="$4"
  [ -d "$repo/.git" ] || { log "skip $label: not a git repo"; return; }
  git -C "$repo" fetch --quiet origin "$branch" 2>>"$LOG" || { log "$label fetch failed"; return; }
  local head; head="$(git -C "$repo" rev-parse "origin/${branch}" 2>/dev/null)" || return
  if [ ! -f "$sf" ]; then echo "$head" > "$sf"; log "$label baselined at ${head:0:8}"; return; fi
  local last; last="$(cat "$sf")"
  [ "$last" = "$head" ] && { log "$label no new commits"; return; }

  local range="${last}..${head}"
  # Hand the window to schema_tick before the SHA advances.
  printf '%s' "$range" > "${STATE}/${label,,}_range"
  local commits; commits="$(git -C "$repo" log --no-merges --pretty=format:'%h %s — %an' "$range" | head -n "${CHLOG_MAX_COMMITS}")"
  [ -z "$commits" ] && { echo "$head" > "$sf"; log "$label only merges/empty"; return; }
  # If no channel configured yet, don't burn a Claude analysis — hold the commits
  # (don't advance the SHA) so they're processed once CHLOG_CHAT is set.
  if [ -z "$CHAT" ]; then log "$label: new commits in $range but CHLOG_CHAT unset — holding (configure to enable)"; return; fi
  log "$label new commits in $range"

  # Build the analysis input: commit list + capped diff.
  local input="/tmp/chlog_${label}.txt"
  {
    echo "REPO_LABEL=${label}"; echo "BRANCH=${branch}"; echo "DATE=$(date '+%d %b %Y')"
    echo; echo "Commits ($range):"; echo "$commits"
    echo; echo "Unified diff (capped):"
    git -C "$repo" diff "$range" --stat; echo
    git -C "$repo" diff "$range" | head -c 120000
  } > "$input"

  # Narration is the only part that spends tokens, so it has its own switch. When it is
  # off we still advance the SHA — otherwise re-enabling it would replay a huge backlog
  # into the channel in one tick.
  if [ "$(ctl code_narrative)" != "1" ]; then
    log "$label: ${range} — narration disabled, skipping Claude"
    echo "$head" > "$sf"
    return
  fi

  # Claude analysis (read-only, whole repo available for flow tracing).
  local out; out="$(timeout "${CHLOG_TIMEOUT}" claude -p "$(cat "$input")" \
      --model "${CHLOG_MODEL}" --allowedTools "Read Grep Glob" \
      --add-dir "$repo" --append-system-prompt "$PROMPT" 2>>"$(dirname "$LOG")/changelog.err")"
  [ -z "$out" ] && { log "$label claude returned empty"; return; }

  # Split card (before ```mermaid) and the mermaid block.
  local card mmd
  card="$(printf '%s' "$out" | awk '/```mermaid/{exit} {print}')"
  mmd="$(printf '%s' "$out" | awk '/```mermaid/{f=1;next} /```/{f=0} f{print}')"

  if [ -z "$CHAT" ]; then log "$label: CHLOG_CHAT not set — printing card to log only"; log "$card"; echo "$head" > "$sf"; return; fi

  # Diagram first (as a photo with a short caption), then the full card.
  if [ -n "$mmd" ]; then
    printf '%s\n' "$mmd" > "/tmp/chlog_${label}.mmd"
    if render_mermaid "/tmp/chlog_${label}.mmd" "/tmp/chlog_${label}.png"; then
      tg_photo "/tmp/chlog_${label}.png" "🚀 What shipped · ${label} — ${branch}"
    else log "$label mermaid render failed"; fi
  fi
  tg_html "$card"

  # Same card to Teams, converted rather than re-generated — no second Claude call.
  if [ -n "${CHLOG_TEAMS_WEBHOOK:-}" ] && [ "$(ctl teams)" = "1" ]; then
    printf '%s\n' "$card" > "/tmp/chlog_${label}_card.html"
    if "${CHLOG_HOME}/.venv/bin/python" "${CHLOG_HOME}/html_to_teams.py" \
         "/tmp/chlog_${label}_card.html" "/tmp/chlog_${label}_card.json" 2>>"$LOG"; then
      teams_post "/tmp/chlog_${label}_card.json"
    fi
  fi

  echo "$head" > "$sf"
  log "$label posted."
}

# ── Schema watch ────────────────────────────────────────────────────────────
# Two sources: the live databases (what actually changed) and the entity
# declarations in the commits (who changed it and for which feature). Entity
# ranges are captured by process_repo BEFORE it advances the SHA, so the code
# side always covers exactly the same window as the code card.
schema_tick(){
  [ "${CHLOG_SCHEMA_ENABLED:-1}" = "1" ] || return 0
  [ "$(ctl schema_watch)" = "1" ] || { log "schema watch disabled via control panel"; return 0; }
  local py="${CHLOG_HOME}/.venv/bin/python"
  [ -x "$py" ] || { log "schema: venv missing at $py"; return 0; }

  local cur="${STATE}/schema_now.json" prev="${STATE}/schema_prev.json"
  if ! "$py" "${CHLOG_HOME}/schema_probe.py" "$cur" >>"$LOG" 2>&1; then
    log "schema: probe failed"; return 0
  fi
  # A partial snapshot must never become the baseline: if MySQL was unreachable this
  # tick, baselining zero tables would make the next good tick report every table as
  # newly created. Skip instead, and keep the last known-good baseline.
  local perr; perr="$(jq -r '.errors | to_entries[]? | .key' "$cur" 2>/dev/null | paste -sd, -)"
  if [ -n "$perr" ]; then
    log "schema: probe incomplete (${perr}) — not baselining, will retry next tick"
    rm -f "$cur"; return 0
  fi
  if [ ! -f "$prev" ]; then
    cp "$cur" "$prev"; log "schema baselined ($(jq -r '.mysql|length' "$cur") tables)"; return 0
  fi

  "$py" "${CHLOG_HOME}/schema_diff.py" "$prev" "$cur" "${STATE}/schema_diff.json" 2>>"$LOG"

  # Entity declarations for the same window, one file per repo.
  local ents=()
  for pair in "BE:${CHLOG_BE_REPO}" "FE:${CHLOG_FE_REPO}"; do
    local lbl="${pair%%:*}"
    local repo="${pair#*:}"
    local rf="${STATE}/${lbl,,}_range"
    [ -f "$rf" ] || continue
    local range; range="$(cat "$rf")"
    local out="${STATE}/ent_${lbl,,}.json"
    if "$py" "${CHLOG_HOME}/entity_diff.py" "$repo" "${range%%..*}" "${range##*..}" "$out" 2>>"$LOG"; then
      ents+=("$out")
    fi
  done

  local window; window="$(date '+%d %b %Y %H:%M')"
  local card="${STATE}/schema_card.html"
  if "$py" "${CHLOG_HOME}/schema_report.py" --schema "${STATE}/schema_diff.json" \
        ${ents[@]+--entities "${ents[@]}"} --snapshot "$cur" \
        --window "$window" --render telegram --out "$card" 2>>"$LOG"; then
    [ -n "$CHAT" ] && tg_html "$(cat "$card")"
    if [ -n "${CHLOG_TEAMS_WEBHOOK:-}" ] && [ "$(ctl teams)" = "1" ]; then
      "$py" "${CHLOG_HOME}/schema_report.py" --schema "${STATE}/schema_diff.json" \
        ${ents[@]+--entities "${ents[@]}"} --snapshot "$cur" \
        --window "$window" --render teams --out "${STATE}/schema_card.json" 2>>"$LOG" \
        && teams_post "${STATE}/schema_card.json"
    fi
    log "schema card posted."
  else
    log "schema: no changes this window"
  fi
  mv "$cur" "$prev"
  rm -f "${STATE}"/*_range
}

run_once(){
  if [ "$(ctl enabled)" != "1" ]; then log "disabled via control panel — skipping tick"; return; fi
  process_repo "${CHLOG_BE_REPO}" "BE"  "${CHLOG_BE_BRANCH}" "${STATE}/be_last_sha"
  process_repo "${CHLOG_FE_REPO}" "FE"  "${CHLOG_FE_BRANCH}" "${STATE}/fe_last_sha"
  schema_tick
}

case "${1:-daemon}" in
  once)   run_once ;;                                   # single pass (for cron/testing)
  schema) schema_tick ;;                                # schema watch only (testing)
  code)   process_repo "${CHLOG_BE_REPO}" "BE" "${CHLOG_BE_BRANCH}" "${STATE}/be_last_sha"
          process_repo "${CHLOG_FE_REPO}" "FE" "${CHLOG_FE_BRANCH}" "${STATE}/fe_last_sha" ;;
  daemon) log "changelog daemon up (interval ${CHLOG_INTERVAL}s)"
          while true; do run_once; sleep "${CHLOG_INTERVAL}"; done ;;
  *) echo "usage: $0 {daemon|once|schema|code}";;
esac
