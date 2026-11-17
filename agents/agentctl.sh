#!/usr/bin/env bash
# Control the CBA sub-agents (changelog, jira, cbttester). Usage:
#   ./agentctl.sh {start|stop|restart|status|logs} [changelog|jira|cbttester|all]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="${DIR}/../state"; mkdir -p "$RUN"

declare -A SCRIPT=( [changelog]="${DIR}/changelog/changelog.sh daemon" [jira]="${DIR}/jira/jira.sh" [cbttester]="${DIR}/cbttester/cbttester.sh" )
declare -A LOGF=( [changelog]="${HOME}/cba/logs/changelog.log" [jira]="${HOME}/cba/logs/jira.log" [cbttester]="${HOME}/cba/logs/cbttester.log" )

pidfile(){ echo "${RUN}/${1}.pid"; }
is_running(){ local p; p="$(cat "$(pidfile "$1")" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

start_one(){ local a="$1"
  if is_running "$a"; then echo "$a already running (pid $(cat "$(pidfile "$a")"))."; return 0; fi
  echo "starting $a…"; nohup bash ${SCRIPT[$a]} >>"${LOGF[$a]}" 2>&1 & echo $! > "$(pidfile "$a")"; }
stop_one(){ local a="$1" p; p="$(cat "$(pidfile "$a")" 2>/dev/null)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; echo "$a stopped."; else echo "$a not running."; fi
  rm -f "$(pidfile "$a")"; }
status_one(){ if is_running "$1"; then echo "$1: RUNNING (pid $(cat "$(pidfile "$1")"))"; else echo "$1: stopped"; fi; }

targets(){ case "${1:-all}" in all) echo "changelog jira cbttester";; *) echo "$1";; esac; }
cmd="${1:-status}"; sel="$(targets "${2:-all}")"
case "$cmd" in
  start)   for a in $sel; do start_one "$a"; done;;
  stop)    for a in $sel; do stop_one "$a"; done;;
  restart) for a in $sel; do stop_one "$a"; sleep 1; start_one "$a"; done;;
  status)  for a in $sel; do status_one "$a"; done;;
  logs)    for a in $sel; do echo "== $a =="; tail -n "${3:-30}" "${LOGF[$a]}" 2>/dev/null; done;;
  *) echo "usage: $0 {start|stop|restart|status|logs} [changelog|jira|cbttester|all]";;
esac
