#!/usr/bin/env bash
# ── CBA daemon: long-polls Telegram and answers questions in real time ───────
# Owns the bot's getUpdates loop. Run via cbactl.sh (start/stop/status).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"

OFFSET_FILE="${CBA_HOME}/state/offset"
OFFSET="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"

log "CBA daemon starting. model=${CBA_MODEL} repos=[${CBA_REPOS}] offset=${OFFSET}"

# Greet the main channel so the founder knows CBA is live (skip if none set).
if [ -n "${CBA_MAIN_CHAT:-}" ]; then
  tg_send "$CBA_MAIN_CHAT" "🤖 CBA (Code Base Assistant) is online.
Ask me anything about the OpenWallet codebase — features, flows, endpoints, where code lives — and I'll answer from the actual source.
Commands: /help  /status  /ping"
fi

# handle_command <chat> <text> -> returns 0 if it was a command (already replied)
handle_command() {
  local chat="$1" text="$2"
  case "$text" in
    /ping*)   tg_send "$chat" "pong ✅ CBA is alive."; return 0;;
    /status*) tg_send "$chat" "🤖 CBA status
model: ${CBA_MODEL}
repos: ${CBA_REPOS}
mode: read-only (Read/Grep/Glob)
offset: $(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"; return 0;;
    /help*|/start*) tg_send "$chat" "🤖 CBA — Code Base Assistant
Ask in plain language, e.g.:
• How does the incentive discount flow work?
• Where is the refund reversal handled?
• What are the request fields for POST /incentive/campaign/evaluate?
• What breaks if I change SenderValidator.getUserDetails?

I read the real code (backend + frontend) and reply with the flow and file:line
references. I'm read-only — I explain, I don't change code.
Commands: /help  /status  /ping"; return 0;;
  esac
  return 1
}

while true; do
  RESP="$(tg_api getUpdates -d offset="$OFFSET" -d timeout=45 --max-time 60)"
  # Telegram returns {"ok":false,...} on error (e.g. 409 if another poller runs).
  if [ "$(echo "$RESP" | jq -r '.ok' 2>/dev/null)" != "true" ]; then
    log "getUpdates not ok: $(echo "$RESP" | jq -c '{ok,error_code,description}' 2>/dev/null || echo "$RESP" | head -c 200)"
    sleep 5; continue
  fi

  N="$(echo "$RESP" | jq '.result | length')"
  [ "${N:-0}" -eq 0 ] && continue

  # Iterate updates one by one.
  echo "$RESP" | jq -c '.result[]' | while read -r upd; do
    UPD_ID="$(echo "$upd" | jq -r '.update_id')"
    OFFSET=$((UPD_ID + 1)); echo "$OFFSET" > "$OFFSET_FILE"

    # Support both group/channel messages and private chats. Text only.
    CHAT="$(echo "$upd" | jq -r '.message.chat.id // .channel_post.chat.id // empty')"
    TEXT="$(echo "$upd" | jq -r '.message.text // .channel_post.text // empty')"
    FROM="$(echo "$upd" | jq -r '.message.from.username // .message.from.first_name // "channel"')"
    ISBOT="$(echo "$upd" | jq -r '.message.from.is_bot // false')"
    MSG_ID="$(echo "$upd" | jq -r '.message.message_id // .channel_post.message_id // empty')"

    [ -z "$CHAT" ] && { log "skip update ${UPD_ID}: no chat (service event)"; continue; }
    [ -z "$TEXT" ] && { log "skip update ${UPD_ID}: non-text (chat=${CHAT}, from=${FROM})"; continue; }
    [ "$ISBOT" = "true" ] && continue
    # In a channel there is no .from; skip posts CBA itself made (self-loop guard).
    is_own_message "$MSG_ID" && { log "skip own message $MSG_ID"; continue; }
    chat_allowed "$CHAT" || { log "ignored chat $CHAT (not allowed)"; continue; }

    log "Q from ${FROM} (chat ${CHAT}): ${TEXT:0:120}"

    # ── Pending-email step: if CBA just delivered an artifact to this chat and is
    #    waiting for an email address, this message answers that prompt. ────────
    PEND="${CBA_HOME}/state/pending_email/${CHAT}"
    if [ -f "$PEND" ]; then
      PEND_EMAIL="$(extract_email "$TEXT")"
      if [ -n "$PEND_EMAIL" ]; then
        EMAIL="$PEND_EMAIL"
        mapfile -t AFILES < "$PEND"
        tg_typing "$CHAT"
        if python3 "${DIR}/send_mail.py" "$EMAIL" "CBA: your requested files" \
             "Attached are the files you asked CBA to generate." "${AFILES[@]}" >/dev/null 2>&1; then
          tg_send "$CHAT" "📧 Sent to ${EMAIL} ✅"
          log "emailed artifacts to ${EMAIL}"
        else
          tg_send "$CHAT" "⚠️ Couldn't send the email (SMTP not configured or send failed). The files are still available above in Telegram."
          log "email send failed to ${EMAIL}"
        fi
        rm -f "$PEND"; continue
      elif printf '%s' "$TEXT" | grep -qiE '^(no|nope|skip|nah|cancel)\b'; then
        tg_send "$CHAT" "👍 No email — the files are above in Telegram."
        rm -f "$PEND"; continue
      else
        # Not an email and not a decline → treat as a fresh request.
        rm -f "$PEND"
      fi
    fi

    # ── Pending-action confirm step: a prior action is awaiting "CONFIRM". ─────
    PACT="${CBA_HOME}/state/pending_action/${CHAT}"
    if [ -f "$PACT" ]; then
      if printf '%s' "$TEXT" | grep -qiE '^[[:space:]]*(confirm|yes proceed|proceed|execute)\b'; then
        read -r ACT U M A D C < "$PACT"; rm -f "$PACT"
        if [ "$ACT" = "rerun-p2m" ] && [[ "$U" =~ ^[0-9a-fA-F-]{16,}$ ]] && [[ "$M" =~ ^[0-9]{6,15}$ ]] \
           && [[ "$A" =~ ^[0-9.]+$ ]] && [[ "$D" =~ ^[0-9.]+$ ]] && [[ "$C" =~ ^[0-9]+$ ]]; then
          tg_send "$CHAT" "▶️ Executing (audit-logged)…"; tg_typing "$CHAT"
          RES="$(CBA_CONFIG="$CBA_CONFIG" "${DIR}/actq" rerun-p2m "$U" "$M" "$A" "$D" "$C" 2>&1 | tail -c 1400)"
          tg_send "$CHAT" "Result:
${RES}"
          log "ACTION executed for ${FROM}: rerun-p2m $U $M $A $D $C"
        else
          tg_send "$CHAT" "⚠️ Stored action was invalid; cancelled."
        fi
      else
        tg_send "$CHAT" "❌ Action cancelled."
      fi
      rm -f "$PACT"; continue
    fi

    handle_command "$CHAT" "$TEXT" && continue

    # Audience hint: main channel treated as founder-facing, DMs as developer.
    AUD="developer"; [ "$CHAT" = "$CBA_MAIN_CHAT" ] && AUD="founder"

    # ── Action request (WRITE-enabled instances only): plan → confirm → execute.
    if [ "${CBA_WRITE_ENABLED:-}" = "true" ] && is_action_request "$TEXT"; then
      tg_typing "$CHAT"
      PLAN="$("${DIR}/ask.sh" "ACTION-PLANNING MODE — do NOT perform anything, only inspect live data and propose. The user asked: '${TEXT}'. Identify the exact target transaction from live data. Then output EXACTLY two lines:
PLAN: <one line: txnId, product, amount, sender, receiver, what a re-run would do>
CMD: ${DIR}/actq rerun-p2m <userId> <merchantMobile> <amount> <discount> <campaignId>
Output the CMD line ONLY if it is a P2M/SEND_MONEY transaction AND you know the merchant's PLAINTEXT mobile number (receiver mobiles are encrypted in the DB). Otherwise output exactly 'CMD: NONE'." founder)"
      PLINE="$(printf '%s' "$PLAN" | grep -iE '^PLAN:' | head -1)"
      ARGS="$(printf '%s' "$PLAN" | grep -E '^CMD: .*actq rerun-p2m ' | head -1 | sed -E 's/.*rerun-p2m[[:space:]]+//')"
      read -r U M A D C _ <<< "$ARGS"
      if [[ "$U" =~ ^[0-9a-fA-F-]{16,}$ ]] && [[ "$M" =~ ^[0-9]{6,15}$ ]] && [[ "$A" =~ ^[0-9.]+$ ]] && [[ "$D" =~ ^[0-9.]+$ ]] && [[ "$C" =~ ^[0-9]+$ ]]; then
        mkdir -p "${CBA_HOME}/state/pending_action"
        printf 'rerun-p2m %s %s %s %s %s\n' "$U" "$M" "$A" "$D" "$C" > "${CBA_HOME}/state/pending_action/${CHAT}"
        tg_send "$CHAT" "⚠️ This is a WRITE action (moves money in dev).
${PLINE}
Plan: rerun P2M — merchant ${M}, amount ${A}, discount ${D}, campaign ${C}.
Reply CONFIRM to execute, or anything else to cancel."
        log "action proposed for ${FROM}: rerun-p2m $U $M $A $D $C"
      else
        tg_send "$CHAT" "${PLINE:-I checked the request.}
I won't auto-execute this: split/cross-border replays aren't automated, and receiver mobiles are encrypted so I can't safely reconstruct a P2M re-run from history. Give me explicit P2M params (merchant mobile, amount, discount, campaign) and I'll run it with a confirm step."
        log "action not auto-executable for ${FROM}"
      fi
      continue
    fi

    # ── Artifact request → generate file(s), upload to Telegram, offer email. ──
    if is_artifact_request "$TEXT"; then
      tg_typing "$CHAT"
      tg_send "$CHAT" "🛠️ Generating your file(s)… this can take a minute or two."
      mapfile -t FILES < <("${DIR}/artifact.sh" "$TEXT" "$AUD")
      if [ "${#FILES[@]}" -eq 0 ] || printf '%s' "${FILES[0]}" | grep -q "__CBA_ERROR__"; then
        tg_send "$CHAT" "⚠️ I couldn't generate the file(s). ${FILES[0]:-} Try narrowing the request."
        log "artifact failed for ${FROM}"
        continue
      fi
      mkdir -p "${CBA_HOME}/state/pending_email"
      : > "${CBA_HOME}/state/pending_email/${CHAT}"
      REAL_FILES=()
      for f in "${FILES[@]}"; do
        [ -f "$f" ] || continue
        tg_send_document "$CHAT" "$f" "$(basename "$f")"
        echo "$f" >> "${CBA_HOME}/state/pending_email/${CHAT}"
        REAL_FILES+=("$f")
      done

      # If the request asked to be emailed, send now — to an address in the
      # message if present, otherwise the configured default. Only fall back to
      # "reply with an address" when there is no default.
      if wants_email "$TEXT"; then
        DEST="$(extract_email "$TEXT")"; [ -z "$DEST" ] && DEST="${CBA_DEFAULT_EMAIL:-}"
        if [ -n "$DEST" ]; then
          tg_typing "$CHAT"
          if python3 "${DIR}/send_mail.py" "$DEST" "CBA: your requested files" \
               "Attached are the files you asked CBA to generate." "${REAL_FILES[@]}" >/dev/null 2>&1; then
            tg_send "$CHAT" "✅ ${#REAL_FILES[@]} file(s) above, and emailed to ${DEST} 📧"
            rm -f "${CBA_HOME}/state/pending_email/${CHAT}"
            log "delivered+emailed ${#REAL_FILES[@]} artifact(s) to ${DEST}"; continue
          else
            tg_send "$CHAT" "✅ ${#REAL_FILES[@]} file(s) above. ⚠️ Email to ${DEST} failed — reply with another address to retry."
            log "email failed to ${DEST}"; continue
          fi
        fi
      fi

      tg_send "$CHAT" "✅ Done — ${#REAL_FILES[@]} file(s) above.
📧 Reply with an email address and I'll send them to your inbox too (or reply 'no')."
      log "delivered ${#REAL_FILES[@]} artifact(s) to ${FROM}"
      continue
    fi

    tg_typing "$CHAT"
    ANSWER="$("${DIR}/ask.sh" "$TEXT" "$AUD")"
    [ -z "$ANSWER" ] && ANSWER="🤔 I couldn't produce an answer for that. Try rephrasing or narrowing the question."
    tg_send "$CHAT" "$ANSWER"
    log "answered ${FROM} (chat ${CHAT}), ${#ANSWER} chars"
  done
  # The `while read` above runs in a subshell (pipe), so reload the offset it
  # persisted to disk before the next long-poll — otherwise we'd refetch.
  OFFSET="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
done
