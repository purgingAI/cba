#!/usr/bin/env bash
# ── CBA shared library: config loading + Telegram helpers ───────────────────
set -uo pipefail

# Resolve CBA_HOME to this script's directory if not set.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Config file is selectable per bot instance via CBA_CONFIG (defaults to config.env).
CBA_CONFIG="${CBA_CONFIG:-${_LIB_DIR}/config.env}"
# shellcheck disable=SC1091
source "${CBA_CONFIG}"
CBA_HOME="${CBA_HOME:-$_LIB_DIR}"
# Ensure per-instance state/log dirs exist (instances keep separate CBA_HOME).
mkdir -p "${CBA_HOME}/state/pending_email" "${CBA_HOME}/state/artifacts" "${CBA_HOME}/logs" 2>/dev/null || true

API="https://api.telegram.org/bot${CBA_TOKEN}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${CBA_HOME}/logs/cba.log" >&2; }

# tg_api <method> [curl args...]
tg_api() { local m="$1"; shift; curl -s --max-time 60 "${API}/${m}" "$@"; }

# tg_send <chat_id> <text>  — splits on Telegram's 4096-char limit.
# Records the message_id of each sent message so the daemon can skip its own
# posts when they echo back as channel_post updates (avoids self-answer loops).
SENT_IDS_FILE="${CBA_HOME}/state/sent_ids"
tg_send() {
  local chat="$1" text="$2" chunk resp mid
  # Telegram hard limit is 4096; leave headroom.
  while [ -n "$text" ]; do
    chunk="${text:0:3900}"
    text="${text:3900}"
    resp="$(tg_api sendMessage \
      --data-urlencode "chat_id=${chat}" \
      --data-urlencode "text=${chunk}" \
      -d disable_web_page_preview=true)"
    mid="$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)"
    [ -n "$mid" ] && echo "$mid" >> "$SENT_IDS_FILE"
  done
  # Keep the dedup file bounded.
  [ -f "$SENT_IDS_FILE" ] && tail -n 500 "$SENT_IDS_FILE" > "${SENT_IDS_FILE}.tmp" 2>/dev/null && mv "${SENT_IDS_FILE}.tmp" "$SENT_IDS_FILE"
}

# is_own_message <message_id> — true if CBA sent it (skip to avoid self-loop).
is_own_message() {
  [ -f "$SENT_IDS_FILE" ] || return 1
  grep -qxF "$1" "$SENT_IDS_FILE"
}

# tg_typing <chat_id> — shows the "typing…" indicator while CBA thinks.
tg_typing() { tg_api sendChatAction -d chat_id="$1" -d action=typing >/dev/null 2>&1; }

# tg_send_document <chat_id> <filepath> [caption] — uploads a file as a Telegram
# document. Records the returned message_id for the self-loop guard.
tg_send_document() {
  local chat="$1" file="$2" caption="${3:-}" resp mid
  resp="$(curl -s --max-time 120 "${API}/sendDocument" \
    -F chat_id="${chat}" \
    -F document=@"${file}" \
    -F caption="${caption}")"
  mid="$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)"
  [ -n "$mid" ] && echo "$mid" >> "${CBA_HOME}/state/sent_ids"
  [ -n "$mid" ] && return 0 || { log "sendDocument failed: $(echo "$resp" | jq -c '{ok,description}' 2>/dev/null)"; return 1; }
}

# looks_like_email <text> — 0 if the text is (just) an email address.
looks_like_email() {
  printf '%s' "$1" | grep -qiE '^[[:space:]]*[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}[[:space:]]*$'
}

# wants_email <text> — 0 if the message asks for delivery by email/mail.
wants_email() {
  printf '%s' "$1" | grep -qiE '\b(e-?mail|mail) (me|it|this|us|them|the|over|across)\b' && return 0
  printf '%s' "$1" | grep -qiE '(on|to|via|over|through) (the )?(e-?mail|mail|inbox)\b' && return 0
  printf '%s' "$1" | grep -qiE '\b(send|share|deliver) .*(e-?mail|inbox)\b' && return 0
  return 1
}

# extract_email <text> — prints the first email address found, if any.
extract_email() { printf '%s' "$1" | grep -oiE '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' | head -1; }

# is_artifact_request <text> — 0 if the message asks CBA to generate/deliver a file/doc.
is_artifact_request() {
  local t="$1"
  # (a) generation verbs + a document noun
  printf '%s' "$t" | grep -qiE '(generate|create|make|produce|write|build|draft|prepare|export|give me).*(document|documentation|doc |docx|report|postman|collection|spec|specification|guide|readme|excel|csv|pdf|sheet|\.json|json file|api doc)' && return 0
  # (b) deliver/send/email/share + a document noun (e.g. "send the FE documentation on email")
  printf '%s' "$t" | grep -qiE '(send|email|mail|share|export).*(document|documentation|report|postman|collection|spec|guide|readme|excel|csv|pdf|api doc|json|flow|diagram)' && return 0
  # (c) explicit Postman mention
  printf '%s' "$t" | grep -qiE '\bpostman\b' && return 0
  # (d) any explicit "mail/email me …" delivery intent → produce a file & email it
  wants_email "$t" && return 0
  return 1
}

# is_action_request <text> — 0 if the message asks CBA to PERFORM an action
# (money movement / mutation), e.g. "reinitiate the last split payment",
# "re-do the transaction flow", "rerun/retry/resend the payment".
is_action_request() {
  printf '%s' "$1" | grep -qiE '\b(re[ -]?initiate|re[ -]?do|re[ -]?run|re[ -]?execute|re[ -]?trigger|re[ -]?send|retry|trigger|initiate|execute|replay)\b' \
    && printf '%s' "$1" | grep -qiE '\b(payment|transaction|txn|split|transfer|p2m|send[ -]?money|flow|remittance)\b'
}

# chat_allowed <chat_id> — honors CBA_ALLOWED_CHATS (empty = allow all).
chat_allowed() {
  [ -z "${CBA_ALLOWED_CHATS:-}" ] && return 0
  case ",${CBA_ALLOWED_CHATS}," in *",$1,"*) return 0;; *) return 1;; esac
}
