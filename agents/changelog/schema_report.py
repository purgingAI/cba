#!/usr/bin/env python3
"""Correlate live-DB schema changes with the entity changes declared in code, and
render one card per channel.

Two sources answer two different questions:
  schema_diff.json  — what actually changed in the dev databases (truth)
  entity_diff.json  — what the code declared, with author and module (attribution)

Matching them by table/collection name gives a change that carries both. A DB change
with no matching declaration is surfaced separately as OUT-OF-BAND: it reached the
database without a commit behind it in this window, which is exactly the thing a team
loses track of.

Usage:
  schema_report.py --schema <schema_diff.json> [--entities <entity_diff.json> ...]
                   [--render telegram|teams] [--out <file>] [--window "14:00–15:00"]
"""
import argparse
import html
import json
import re
from collections import OrderedDict

STORE_LABEL = {"MySQL": "MySQL", "MongoDB": "Mongo"}


def bare(obj):
    """'APP_DB_dev.segment' -> 'segment' — schema/db prefix carries no meaning here."""
    return obj.split(".", 1)[1] if "." in obj else obj


def snake(name):
    """isSpecificAmount -> is_specific_amount, so a declared field matches a real column."""
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def load_entities(paths):
    """table/collection (bare, lowercased) -> the declaration that owns it."""
    index = {}
    for p in paths:
        try:
            d = json.load(open(p))
        except Exception:
            continue
        repo = d.get("repo", "").rstrip("/").split("/")[-1]
        for c in d.get("changes", []):
            for key in (c.get("table"), c.get("collection")):
                if key:
                    rec = dict(c)
                    rec["repo"] = repo
                    index[key.lower()] = rec
    return index


def build(schema_path, entity_paths, window=None, snapshot_path=None):
    sd = json.load(open(schema_path))
    ents = load_entities(entity_paths)
    # Current shape, used to tell "declared but genuinely missing" from "already applied".
    live = {}
    if snapshot_path:
        try:
            snap = json.load(open(snapshot_path))
            for obj, t in snap.get("mysql", {}).items():
                live[bare(obj).lower()] = set(t.get("columns", {}))
            for obj in snap.get("mongo", {}):
                live[bare(obj).lower()] = set()
        except Exception:
            live = {}

    groups = OrderedDict()
    for ch in sd.get("changes", []):
        groups.setdefault((ch["store"], ch["object"]), []).append(ch)

    attributed, orphans = [], []
    for (store, obj), changes in groups.items():
        ent = ents.get(bare(obj).lower())
        item = {"store": store, "object": obj, "bare": bare(obj), "changes": changes,
                "entity": ent}
        (attributed if ent else orphans).append(item)

    # A declaration with no DB change of its own is only news when the database does not
    # already have it — otherwise it was applied in an earlier window and repeating it
    # every hour would be noise. A Mongo collection also legitimately does not exist until
    # its first document is written, so an absent collection is reported, not an error.
    seen = {bare(i["object"]).lower() for i in attributed}
    declared_only = []
    for k, e in ents.items():
        if k in seen:
            continue
        if not live:
            declared_only.append(e); continue
        if k not in live:
            e = dict(e); e["why"] = "not created yet"
            declared_only.append(e); continue
        cols = live[k]
        if cols:
            missing = [f for f in e.get("fields_added", []) if f not in cols and snake(f) not in cols]
            if missing:
                e = dict(e); e["why"] = "missing: " + ", ".join(missing[:4])
                declared_only.append(e)

    return {"window": window, "from": sd.get("from"), "to": sd.get("to"),
            "attributed": attributed, "orphans": orphans,
            "declared_only": declared_only,
            "total": sd.get("count", 0)}


# ── renderers ────────────────────────────────────────────────────────────────

def _summary_rows(rep):
    rows = []
    for item in rep["attributed"] + rep["orphans"]:
        kinds = {c["change"] for c in item["changes"]}
        if len(item["changes"]) == 1:
            what = item["changes"][0]["change"].lower()
        elif kinds == {"COLUMN ADDED"}:
            what = f"+{len(item['changes'])} columns"
        else:
            what = f"{len(item['changes'])} changes"
        who = ""
        if item["entity"]:
            who = ", ".join(item["entity"].get("authors", [])[:1])
        rows.append((STORE_LABEL.get(item["store"], item["store"]),
                     item["bare"][:28], what[:18], who[:16] or "—"))
    for e in rep["declared_only"]:
        rows.append(("code", (e.get("table") or e.get("collection") or e["class"])[:28],
                     "declared only", ", ".join(e.get("authors", [])[:1])[:16] or "—"))
    return rows


def render_telegram(rep):
    L = []
    n = len(rep["attributed"]) + len(rep["orphans"]) + len(rep["declared_only"])
    L.append("🗄️ <b>Schema changes · dev</b>")
    L.append(f"<i>{n} object(s) changed · {rep.get('window') or rep.get('to','')}</i>")
    L.append("━━━━━━━━━━━━━━━━━")

    rows = _summary_rows(rep)
    if rows:
        w1 = max(5, max(len(r[0]) for r in rows))
        w2 = max(6, max(len(r[1]) for r in rows))
        w3 = max(6, max(len(r[2]) for r in rows))
        head = f"{'STORE'.ljust(w1)}  {'OBJECT'.ljust(w2)}  {'CHANGE'.ljust(w3)}  BY"
        body = "\n".join(f"{a.ljust(w1)}  {b.ljust(w2)}  {c.ljust(w3)}  {d}"
                         for a, b, c, d in rows)
        L.append(f"<pre>{html.escape(head)}\n{html.escape(body)}</pre>")

    for item in rep["attributed"]:
        e = item["entity"]
        L.append("")
        L.append(f"🧩 <b>{html.escape(item['bare'])}</b> · {item['store']}")
        for c in item["changes"][:8]:
            L.append(f"• <b>{c['change'].title()}</b> <code>{html.escape(c['detail'][:90])}</code>")
        feature = f"{e.get('repo','')}/{e.get('module','')}".strip("/")
        L.append(f"👤 {html.escape(', '.join(e.get('authors', [])[:2]) or '—')}"
                 f" · 🧩 {html.escape(feature)} · <code>{html.escape(e.get('class',''))}</code>")
        if e.get("commits"):
            L.append(f"💬 <i>{html.escape(e['commits'][0][:110])}</i>")

    if rep["orphans"]:
        L.append("")
        L.append("⚠️ <b>Out-of-band</b> — changed in the database with no matching commit")
        for item in rep["orphans"][:10]:
            for c in item["changes"][:3]:
                L.append(f"• <code>{html.escape(item['bare'])}</code> {c['change'].lower()}"
                         f" — {html.escape(c['detail'][:70])}")

    if rep["declared_only"]:
        L.append("")
        L.append("📝 <b>Declared in code, not yet in the database</b>")
        for e in rep["declared_only"][:10]:
            tgt = e.get("table") or e.get("collection") or e.get("class")
            why = f" — {e['why']}" if e.get("why") else ""
            L.append(f"• <code>{html.escape(tgt)}</code> {html.escape(e.get('class',''))}"
                     f"{html.escape(why)} ({html.escape(', '.join(e.get('authors', [])[:1]) or '—')})")

    L.append("━━━━━━━━━━━━━━━━━")
    return "\n".join(L)


def render_teams(rep):
    """Adaptive Card 1.4 — what Teams incoming webhooks accept."""
    body = [
        {"type": "TextBlock", "text": "🗄️ Schema changes · dev", "weight": "Bolder",
         "size": "Large", "wrap": True},
        {"type": "TextBlock", "isSubtle": True, "spacing": "None", "wrap": True,
         "text": f"{len(rep['attributed']) + len(rep['orphans']) + len(rep['declared_only'])}"
                 f" object(s) changed · {rep.get('window') or rep.get('to','')}"},
    ]

    rows = _summary_rows(rep)
    if rows:
        header = {"type": "TableRow", "cells": [
            {"type": "TableCell", "items": [{"type": "TextBlock", "text": h, "weight": "Bolder"}]}
            for h in ("Store", "Object", "Change", "By")]}
        trows = [{"type": "TableRow", "cells": [
            {"type": "TableCell", "items": [{"type": "TextBlock", "text": v, "wrap": True}]}
            for v in r]} for r in rows]
        body.append({"type": "Table", "firstRowAsHeaders": True,
                     "columns": [{"width": 1}, {"width": 3}, {"width": 2}, {"width": 2}],
                     "rows": [header] + trows})

    for item in rep["attributed"]:
        e = item["entity"]
        body.append({"type": "TextBlock", "text": f"**{item['bare']}** · {item['store']}",
                     "wrap": True, "separator": True})
        body.append({"type": "TextBlock", "wrap": True,
                     "text": "\n\n".join(f"- {c['change'].title()}: `{c['detail'][:90]}`"
                                         for c in item["changes"][:8])})
        body.append({"type": "FactSet", "facts": [
            {"title": "By", "value": ", ".join(e.get("authors", [])[:2]) or "—"},
            {"title": "Feature", "value": f"{e.get('repo','')}/{e.get('module','')}".strip("/")},
            {"title": "Entity", "value": e.get("class", "")},
            {"title": "Commit", "value": (e.get("commits") or ["—"])[0][:110]},
        ]})

    if rep["orphans"]:
        body.append({"type": "TextBlock", "separator": True, "wrap": True, "color": "Warning",
                     "text": "**Out-of-band** — changed in the database with no matching commit"})
        body.append({"type": "TextBlock", "wrap": True, "text": "\n\n".join(
            f"- `{i['bare']}` {c['change'].lower()} — {c['detail'][:70]}"
            for i in rep["orphans"][:10] for c in i["changes"][:3])})

    if rep["declared_only"]:
        body.append({"type": "TextBlock", "separator": True, "wrap": True,
                     "text": "**Declared in code, not yet in the database**"})
        body.append({"type": "TextBlock", "wrap": True, "text": "\n\n".join(
            f"- `{e.get('table') or e.get('collection') or e.get('class')}` — {e.get('class','')}"
            for e in rep["declared_only"][:10])})

    return json.dumps({
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": {"$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                        "type": "AdaptiveCard", "version": "1.4", "body": body},
        }],
    }, indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--schema", required=True)
    ap.add_argument("--entities", nargs="*", default=[])
    ap.add_argument("--render", choices=["telegram", "teams", "json"], default="telegram")
    ap.add_argument("--window")
    ap.add_argument("--snapshot", help="current snapshot, to suppress already-applied declarations")
    ap.add_argument("--out")
    a = ap.parse_args()

    rep = build(a.schema, a.entities, a.window, a.snapshot)
    if not (rep["attributed"] or rep["orphans"] or rep["declared_only"]):
        return 3  # nothing to say — caller skips posting

    text = {"telegram": render_telegram, "teams": render_teams,
            "json": lambda r: json.dumps(r, indent=1)}[a.render](rep)
    if a.out:
        open(a.out, "w").write(text)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
