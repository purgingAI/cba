#!/usr/bin/env bash
# ── CBA artifact generator ──────────────────────────────────────────────────
# Usage: ./artifact.sh "<question>" "<audience>"
# Runs a read-only Claude agent that PRINTS one or more deliverable files, each
# introduced by a marker line "===CBA_FILE: <name>===". This script splits the
# output into real files under state/artifacts/<ts>/ and prints their paths (one
# per line) to stdout for the daemon to upload/email. Claude stays read-only —
# it never uses Write; the daemon materializes the files.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"

QUESTION="${1:-}"
AUDIENCE="${2:-developer}"
[ -z "$QUESTION" ] && { echo "usage: artifact.sh <question> [audience]"; exit 1; }

read -r -a REPOS <<< "$CBA_REPOS"
WORKDIR="${REPOS[0]}"
ADD_DIRS=(); for r in "${REPOS[@]}"; do ADD_DIRS+=(--add-dir "$r"); done

OUTDIR="${CBA_HOME}/state/artifacts/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$OUTDIR"

SYS="$(cat "${DIR}/system_prompt.md")

=== OUTPUT MODE: ARTIFACT (FILE GENERATION) ===
You are producing downloadable deliverable file(s), not a chat reply.
STRICT OUTPUT RULES:
- Output ONLY file contents. No preamble, no closing chatter.
- Introduce EACH file with a line exactly of the form:
  ===CBA_FILE: <filename-with-extension>===
  followed immediately by that file's raw content.
- Do NOT wrap file content in Markdown code fences — emit raw content only.
- Choose clear filenames, e.g. incentive-engine-fe-api-changes.md and
  incentive-engine.postman_collection.json.
- For any Postman output, produce a VALID Postman Collection v2.1 JSON.
- Ground every endpoint/field in the actual code (Read/Grep/Glob first). Do not
  invent endpoints, fields, or payloads; if something can't be verified, omit it
  or mark it clearly as an assumption inside the document.
- Be complete and well-structured; length is fine (this is a file, not Telegram).

=== AUDIENCE ===
Requested by a ${AUDIENCE}.

=== DURABLE MEMORY (memory.md) ===
$(cat "${DIR}/memory.md" 2>/dev/null)

=== SKILLS / PLAYBOOK (skills.md) ===
$(cat "${DIR}/skills.md" 2>/dev/null)

=== TOOLS ===
DBQ = ${DIR}/dbq   (live-data tool; enabled=${CBA_DB_ENABLED:-false})
$([ "${CBA_DB_ENABLED:-}" = "true" ] && echo "Run it as: ${DIR}/dbq mongo <collection> '<filter>' [limit] [FIELD:desc]  |  ${DIR}/dbq mysql \"SELECT …\". Use it to ground documents in REAL data when asked." || echo "Live-data tool is DISABLED for this instance.")"

cd "$WORKDIR" || exit 1
TOOLS="$CBA_ALLOWED_TOOLS"
[ "${CBA_DB_ENABLED:-}" = "true" ] && TOOLS="$TOOLS Bash(${DIR}/dbq:*)"
RAW="$(timeout "${CBA_TIMEOUT}" claude -p "$QUESTION" \
  --model "$CBA_MODEL" \
  --allowedTools $TOOLS \
  --disallowedTools "Edit" "Write" "NotebookEdit" \
  "${ADD_DIRS[@]}" \
  --append-system-prompt "$SYS" 2>>"${CBA_HOME}/logs/claude.err")"
rc=$?
[ $rc -ne 0 ] && { echo "__CBA_ERROR__ claude exit $rc (timeout=${CBA_TIMEOUT}s)"; exit 0; }
[ -z "$RAW" ] && { echo "__CBA_ERROR__ empty output"; exit 0; }

# Split RAW into files on the ===CBA_FILE: name=== markers using awk.
printf '%s' "$RAW" | awk -v outdir="$OUTDIR" '
  /^===CBA_FILE:.*===[[:space:]]*$/ {
    if (fn != "") close(fn);
    name = $0; sub(/^===CBA_FILE:[[:space:]]*/, "", name); sub(/[[:space:]]*===[[:space:]]*$/, "", name);
    gsub(/[^A-Za-z0-9._-]/, "_", name);
    fn = outdir "/" name;
    print fn > "/dev/stderr";   # emit created path
    next;
  }
  { if (fn != "") print >> fn; else buf = buf $0 "\n"; }
  END {
    if (fn == "") {   # no markers — save whole thing as one .md
      fn = outdir "/cba-answer.md"; printf "%s", buf > fn; print fn > "/dev/stderr";
    }
  }
' 2>"${OUTDIR}/.paths"

# Print the created file paths for the daemon.
if [ -s "${OUTDIR}/.paths" ]; then
  sort -u "${OUTDIR}/.paths"
else
  # Fallback: save raw output as a single markdown file.
  echo "$RAW" > "${OUTDIR}/cba-answer.md"; echo "${OUTDIR}/cba-answer.md"
fi
exit 0
