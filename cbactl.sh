#!/usr/bin/env bash
# ── CBA control script: start | stop | restart | status | logs ──────────────
# Multi-instance aware. Select a bot instance with CBA_CONFIG=<file>, e.g.:
#   CBA_CONFIG=config.bot2.env ./cbactl.sh start
# Defaults to config.env (bot 1).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CBA_CONFIG="${CBA_CONFIG:-${DIR}/config.env}"
# make relative config paths resolve against the script dir
case "$CBA_CONFIG" in /*) : ;; *) CBA_CONFIG="${DIR}/${CBA_CONFIG}";; esac
export CBA_CONFIG

# Read CBA_HOME from the chosen config so state/logs are per-instance.
CBA_HOME="$(bash -c "source '$CBA_CONFIG'; echo \"\${CBA_HOME:-$DIR}\"")"
mkdir -p "${CBA_HOME}/state" "${CBA_HOME}/logs"
PIDFILE="${CBA_HOME}/state/cba.pid"
LOG="${CBA_HOME}/logs/cba.log"

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

start() {
  if is_running; then echo "CBA already running (pid $(cat "$PIDFILE")) [config: $CBA_CONFIG]."; return 0; fi
  echo "Starting CBA [config: $CBA_CONFIG, home: $CBA_HOME]…"
  CBA_CONFIG="$CBA_CONFIG" nohup bash "${DIR}/cba.sh" >>"$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 1
  is_running && echo "CBA started (pid $(cat "$PIDFILE")). Logs: $LOG" || { echo "Failed to start — see $LOG"; tail -n 20 "$LOG"; }
}

stop() {
  if is_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    pkill -P "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "CBA stopped [config: $CBA_CONFIG]."
  else
    echo "CBA not running [config: $CBA_CONFIG]."; rm -f "$PIDFILE"
  fi
}

status() {
  if is_running; then echo "CBA is RUNNING (pid $(cat "$PIDFILE")) [config: $CBA_CONFIG, home: $CBA_HOME]."; else echo "CBA is STOPPED [config: $CBA_CONFIG]."; fi
}

case "${1:-}" in
  start)   start;;
  stop)    stop;;
  restart) stop; sleep 1; start;;
  status)  status;;
  logs)    tail -n "${2:-40}" -f "$LOG";;
  *) echo "usage: [CBA_CONFIG=<file>] $0 {start|stop|restart|status|logs [N]}";;
esac
