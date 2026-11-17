#!/usr/bin/env python3
"""CBA action executor — performs allow-listed WRITE actions (money movement).

Only reachable when the calling instance has CBA_WRITE_ENABLED=true (the trusted
"31st Deadline" channel). Every invocation is appended to state/actions.log.
The daemon requires a human "CONFIRM" before it ever calls this.

Actions:
  action_tool.py preview <txnId>
      → read-only summary of a transaction (safe; used to build the plan).
  action_tool.py rerun-p2m <userId> <merchantMobile> <amount> <discount> <campaignId>
      → replays a P2M / SEND_MONEY transaction via the proven RunTxn driver.

Split-payment / cross-border replay is intentionally NOT automated (multi-leg,
unsafe to reconstruct) — those must be done manually.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

DIR = Path(__file__).resolve().parent
ACTIONS = DIR / "actions"
LOG = DIR / "state" / "actions.log"


def cfg() -> dict:
    path = os.environ.get("CBA_CONFIG") or str(DIR / "config.env")
    d = {}
    p = Path(path)
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip().strip('"').strip("'")
    return d


def audit(msg: str) -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")


def guard() -> None:
    if cfg().get("CBA_WRITE_ENABLED", "false") != "true":
        print("ACTIONS DISABLED for this instance (CBA_WRITE_ENABLED != true)")
        audit("BLOCKED: actions disabled")
        sys.exit(7)


def preview(txn_id: str) -> int:
    # Read-only lookup via the existing db tool.
    out = subprocess.run(
        [str(DIR / "dbq"), "mongo", "transaction", json.dumps({"TXN_ID": txn_id}), "2"],
        capture_output=True, text=True, timeout=30,
    )
    print(out.stdout or out.stderr)
    return 0


def rerun_p2m(user_id, mobile, amount, discount, campaign) -> int:
    guard()
    audit(f"RERUN-P2M start user={user_id} merchant={mobile} amount={amount} discount={discount} campaign={campaign}")
    cp = f"{ACTIONS}/txlib/*:{ACTIONS}"
    # RunTxn reads /tmp/.mongouri & /tmp/.jwtsec; we keep copies in actions/ and
    # point HOME-style lookups by running from the actions dir with those files.
    env = dict(os.environ)
    proc = subprocess.run(
        ["java", "-cp", cp, "RunTxn", user_id, mobile, str(amount), str(discount), str(campaign)],
        capture_output=True, text=True, cwd=str(ACTIONS), env=env, timeout=120,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    ok = "HTTP 200" in out and '"status":200' in out
    audit(f"RERUN-P2M result ok={ok} :: {out.strip()[-400:]}")
    print(out.strip()[-1500:])
    return 0 if ok else 1


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    try:
        if cmd == "preview" and len(sys.argv) == 3:
            return preview(sys.argv[2])
        if cmd == "rerun-p2m" and len(sys.argv) == 7:
            return rerun_p2m(*sys.argv[2:7])
    except Exception as e:  # noqa: BLE001
        audit(f"ERROR {cmd}: {e}")
        print(f"action error: {e}")
        return 1
    print("usage: action_tool.py preview <txnId> | rerun-p2m <userId> <merchantMobile> <amount> <discount> <campaignId>")
    return 2


if __name__ == "__main__":
    sys.exit(main())
