#!/usr/bin/env python3
"""Control panel for the changelog agent — stdlib only, no dependencies.

The agent's expensive part is the Claude call that narrates code changes; the schema
watch costs nothing but a couple of metadata queries. So the switches are separate:
you can leave schema tracking on permanently and turn narration off when you want to
stop spending tokens, rather than losing the whole agent.

The daemon reads control.json at the top of every tick, so a toggle takes effect on the
next run with no restart.

Binds to 127.0.0.1 by default: the panel has no authentication and it controls token
spend, so it must not be reachable from the rest of the VPC. Reach it with a tunnel:

    ssh -L 8787:127.0.0.1:8787 riley@127.0.0.1    # then open localhost:8787

Pass an explicit host only if you are putting real auth in front of it.

Usage: control_ui.py [port] [host]
"""
import json
import os
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

HOME = os.path.expanduser("~/chlog")
STATE = os.path.join(HOME, "state")
CONTROL = os.path.join(STATE, "control.json")
LOG = os.path.join(HOME, "logs", "changelog.log")
AGENT = os.path.join(HOME, "agent", "changelog.sh")

DEFAULTS = {
    "enabled": True,          # master switch — nothing runs when false
    "code_narrative": True,   # Claude call per repo per tick  ← the token spend
    "schema_watch": True,     # information_schema + Mongo metadata — no tokens
    "teams": False,           # post to the Teams webhook as well
}


def load():
    try:
        with open(CONTROL) as f:
            return {**DEFAULTS, **json.load(f)}
    except Exception:
        return dict(DEFAULTS)


def save(cfg):
    os.makedirs(STATE, exist_ok=True)
    tmp = CONTROL + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=1)
    os.replace(tmp, CONTROL)


def tail(path, n=40):
    try:
        with open(path, errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except Exception:
        return "(no log yet)"


def last_run():
    try:
        return datetime.fromtimestamp(os.path.getmtime(LOG), timezone.utc)\
            .strftime("%d %b %Y %H:%M UTC")
    except Exception:
        return "never"


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Changelog Agent</title><style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#0d1117;color:#e6edf3;font:14px/1.55 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:760px;margin:0 auto;padding:28px 18px 60px}
h1{font-size:20px;margin:0 0 4px;letter-spacing:-.01em}
.sub{color:#8b949e;font-size:13px;margin-bottom:22px}
.card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:6px 18px;margin-bottom:16px}
.row{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:14px 0;border-bottom:1px solid #21262d}
.row:last-child{border-bottom:0}
.name{font-weight:600}
.desc{color:#8b949e;font-size:12.5px;margin-top:2px}
.cost{display:inline-block;font-size:11px;padding:1px 7px;border-radius:999px;margin-left:8px;vertical-align:1px}
.cost.t{background:#3d2a12;color:#e3a008;border:1px solid #6b4708}
.cost.f{background:#12291c;color:#3fb950;border:1px solid #14532d}
.sw{position:relative;width:46px;height:26px;flex:0 0 46px;border:0;border-radius:999px;background:#30363d;cursor:pointer;transition:background .15s}
.sw[data-on="1"]{background:#238636}
.sw i{position:absolute;top:3px;left:3px;width:20px;height:20px;border-radius:50%;background:#e6edf3;transition:transform .15s}
.sw[data-on="1"] i{transform:translateX(20px)}
.sw:disabled{opacity:.35;cursor:not-allowed}
.bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:18px 0 8px}
button.act{background:#21262d;border:1px solid #30363d;color:#e6edf3;border-radius:8px;padding:8px 14px;cursor:pointer;font:inherit}
button.act:hover{border-color:#8b949e}
button.act.pri{background:#238636;border-color:#2ea043}
pre{background:#010409;border:1px solid #30363d;border-radius:10px;padding:14px;overflow:auto;max-height:340px;font-size:12px;color:#c9d1d9;margin:0}
.meta{color:#8b949e;font-size:12.5px}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:7px;vertical-align:1px}
</style></head><body><div class="wrap">
<h1><span class="dot" style="background:__DOT__"></span>Changelog Agent</h1>
<div class="sub">dev/changelog · hourly · last run __LAST__</div>

<div class="card">__ROWS__</div>

<div class="bar">
  <button class="act pri" onclick="run('once')">Run now</button>
  <button class="act" onclick="run('schema')">Schema only</button>
  <button class="act" onclick="location.reload()">Refresh</button>
  <span class="meta" id="msg"></span>
</div>

<div class="card" style="padding:16px 18px">
  <div class="meta" style="margin-bottom:8px">Recent activity</div>
  <pre>__LOG__</pre>
</div>
</div><script>
function toggle(k,el){
  fetch('/set?key='+k+'&value='+(el.dataset.on==='1'?0:1),{method:'POST'})
    .then(r=>r.json()).then(()=>location.reload());
}
function run(what){
  document.getElementById('msg').textContent='running…';
  fetch('/run?what='+what,{method:'POST'}).then(r=>r.json())
    .then(d=>{document.getElementById('msg').textContent=d.msg;
              setTimeout(()=>location.reload(),2500);});
}
</script></body></html>"""

ROWS = [
    ("enabled", "Agent enabled", "Master switch. Off means nothing runs on the hourly tick.", None),
    ("code_narrative", "Code narrative", "Claude reads the diff and writes the “what shipped” card + diagram.", "tokens"),
    ("schema_watch", "Schema watch", "Database entity/column/index changes. Metadata queries only.", "free"),
    ("teams", "Post to Teams", "Also send the Adaptive Card to the Teams webhook.", "free"),
]


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urlparse(self.path)
        if u.path not in ("/", "/index.html"):
            return self._send(404, "not found", "text/plain")
        cfg = load()
        rows = []
        for key, name, desc, cost in ROWS:
            on = "1" if cfg.get(key) else "0"
            # Sub-switches are meaningless while the master is off — show them disabled.
            dis = " disabled" if (key != "enabled" and not cfg.get("enabled")) else ""
            badge = ""
            if cost == "tokens":
                badge = '<span class="cost t">uses tokens</span>'
            elif cost == "free":
                badge = '<span class="cost f">no tokens</span>'
            rows.append(
                f'<div class="row"><div><div class="name">{name}{badge}</div>'
                f'<div class="desc">{desc}</div></div>'
                f'<button class="sw" data-on="{on}"{dis} onclick="toggle(\'{key}\',this)">'
                f'<i></i></button></div>')
        page = (PAGE.replace("__ROWS__", "".join(rows))
                    .replace("__LOG__", tail(LOG).replace("&", "&amp;").replace("<", "&lt;"))
                    .replace("__LAST__", last_run())
                    .replace("__DOT__", "#3fb950" if cfg.get("enabled") else "#6e7681"))
        self._send(200, page)

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/set":
            key = q.get("key", [""])[0]
            if key not in DEFAULTS:
                return self._send(400, '{"error":"unknown key"}', "application/json")
            cfg = load()
            cfg[key] = q.get("value", ["0"])[0] == "1"
            save(cfg)
            return self._send(200, json.dumps(cfg), "application/json")
        if u.path == "/run":
            what = q.get("what", ["once"])[0]
            if what not in ("once", "schema", "code"):
                what = "once"
            threading.Thread(target=lambda: subprocess.run(
                [AGENT, what], capture_output=True, timeout=1800), daemon=True).start()
            return self._send(200, json.dumps({"msg": f"{what} started"}), "application/json")
        self._send(404, '{"error":"not found"}', "application/json")


if __name__ == "__main__":
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    if not os.path.exists(CONTROL):
        save(dict(DEFAULTS))
    print(f"changelog control panel on {host}:{port}", flush=True)
    HTTPServer((host, port), H).serve_forever()
