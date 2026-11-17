#!/usr/bin/env bash
# ── CBA answer engine ───────────────────────────────────────────────────────
# Usage: ./ask.sh "<question>" ["<audience: founder|developer>"]
# Runs a read-only Claude agent grounded in the configured repos and prints the
# final answer to stdout. This is the single brain used by the daemon and can
# also be called standalone (or by any other Claude agent / script).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"

QUESTION="${1:-}"
AUDIENCE="${2:-developer}"
[ -z "$QUESTION" ] && { echo "usage: ask.sh <question> [founder|developer]"; exit 1; }

# Build --add-dir flags for every repo; first repo is the working directory.
read -r -a REPOS <<< "$CBA_REPOS"
WORKDIR="${REPOS[0]}"
ADD_DIRS=()
for r in "${REPOS[@]}"; do ADD_DIRS+=(--add-dir "$r"); done

# Compose the system prompt: persona + durable memory + skills.
SYS="$(cat "${DIR}/system_prompt.md")

=== AUDIENCE ===
The current question is from a ${AUDIENCE}. Tailor depth accordingly (see agents.md conventions).

=== DURABLE MEMORY (memory.md) ===
$(cat "${DIR}/memory.md" 2>/dev/null)

=== SKILLS / PLAYBOOK (skills.md) ===
$(cat "${DIR}/skills.md" 2>/dev/null)

=== TOOLS ===
DBQ = ${DIR}/dbq   (live-data tool; enabled=${CBA_DB_ENABLED:-false})
$([ "${CBA_DB_ENABLED:-}" = "true" ] && echo "Run it as: ${DIR}/dbq mongo <collection> '<filter>' [limit] [FIELD:desc]  |  ${DIR}/dbq mysql \"SELECT …\"" || echo "Live-data tool is DISABLED for this instance — answer from code only.")"

cd "$WORKDIR" || exit 1

# Build the tool allow-list. Base is read-only code tools. When live-data is on,
# grant ONLY the scoped db wrapper (Bash(dbq:*)) — not general Bash — so the agent
# can run read-only queries but nothing else. Edit/Write/NotebookEdit stay off.
TOOLS="$CBA_ALLOWED_TOOLS"
[ "${CBA_DB_ENABLED:-}" = "true" ] && TOOLS="$TOOLS Bash(${DIR}/dbq:*)"

timeout "${CBA_TIMEOUT}" claude -p "$QUESTION" \
  --model "$CBA_MODEL" \
  --allowedTools $TOOLS \
  --disallowedTools "Edit" "Write" "NotebookEdit" \
  "${ADD_DIRS[@]}" \
  --append-system-prompt "$SYS" 2>>"${CBA_HOME}/logs/claude.err"

rc=$?
if [ $rc -ne 0 ]; then
  if [ $rc -eq 124 ]; then
    echo "⏳ CBA timed out after ${CBA_TIMEOUT}s on this question. Try narrowing it or ask again."
  else
    echo "⚠️ CBA hit an internal error (exit $rc). Check ${CBA_HOME}/logs/claude.err."
  fi
fi
exit 0
