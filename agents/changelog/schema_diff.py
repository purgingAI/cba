#!/usr/bin/env python3
"""Diff two schema snapshots into a flat list of change records.

Emits only SHAPE changes — a table/collection appearing or disappearing, a column
added/dropped/redefined, an index added/dropped. Row data is never looked at, so a
busy production table and an empty one produce identical output.

Usage: schema_diff.py <old.json> <new.json> [out.json]
"""
import json
import sys


def _col_delta(old, new):
    """Human-readable description of what changed about one column, or None."""
    bits = []
    if old.get("type") != new.get("type"):
        bits.append(f"type {old.get('type')} → {new.get('type')}")
    if old.get("nullable") != new.get("nullable"):
        o = "NULL" if old.get("nullable") == "YES" else "NOT NULL"
        n = "NULL" if new.get("nullable") == "YES" else "NOT NULL"
        bits.append(f"{o} → {n}")
    if old.get("default") != new.get("default"):
        bits.append(f"default {old.get('default')!r} → {new.get('default')!r}")
    if old.get("key") != new.get("key"):
        bits.append(f"key {old.get('key') or '-'} → {new.get('key') or '-'}")
    if old.get("extra") != new.get("extra"):
        bits.append(f"extra {old.get('extra') or '-'} → {new.get('extra') or '-'}")
    return ", ".join(bits) or None


def diff_mysql(old, new):
    changes = []
    for table in sorted(set(old) | set(new)):
        o, n = old.get(table), new.get(table)
        if o is None:
            cols = list(n.get("columns", {}))
            changes.append({"store": "MySQL", "object": table, "change": "TABLE ADDED",
                            "detail": f"{len(cols)} columns: " + ", ".join(cols[:12])
                                      + ("…" if len(cols) > 12 else "")})
            continue
        if n is None:
            changes.append({"store": "MySQL", "object": table, "change": "TABLE DROPPED",
                            "detail": f"had {len(o.get('columns', {}))} columns"})
            continue

        oc, nc = o.get("columns", {}), n.get("columns", {})
        for c in sorted(set(nc) - set(oc)):
            d = nc[c]
            null = "NULL" if d.get("nullable") == "YES" else "NOT NULL"
            changes.append({"store": "MySQL", "object": table, "change": "COLUMN ADDED",
                            "detail": f"{c} {d.get('type')} {null}"})
        for c in sorted(set(oc) - set(nc)):
            changes.append({"store": "MySQL", "object": table, "change": "COLUMN DROPPED",
                            "detail": f"{c} (was {oc[c].get('type')})"})
        for c in sorted(set(oc) & set(nc)):
            delta = _col_delta(oc[c], nc[c])
            if delta:
                changes.append({"store": "MySQL", "object": table,
                                "change": "COLUMN CHANGED", "detail": f"{c}: {delta}"})

        oi, ni = o.get("indexes", {}), n.get("indexes", {})
        for i in sorted(set(ni) - set(oi)):
            u = "UNIQUE " if ni[i].get("unique") else ""
            changes.append({"store": "MySQL", "object": table, "change": "INDEX ADDED",
                            "detail": f"{u}{i} ({ni[i].get('columns')})"})
        for i in sorted(set(oi) - set(ni)):
            changes.append({"store": "MySQL", "object": table, "change": "INDEX DROPPED",
                            "detail": f"{i} (was {oi[i].get('columns')})"})
    return changes


def diff_mongo(old, new):
    changes = []
    for coll in sorted(set(old) | set(new)):
        o, n = old.get(coll), new.get(coll)
        if o is None:
            changes.append({"store": "MongoDB", "object": coll, "change": "COLLECTION ADDED",
                            "detail": f"{len(n.get('indexes', {}))} index(es)"})
            continue
        if n is None:
            changes.append({"store": "MongoDB", "object": coll, "change": "COLLECTION DROPPED",
                            "detail": ""})
            continue
        oi, ni = o.get("indexes", {}), n.get("indexes", {})
        for i in sorted(set(ni) - set(oi)):
            u = "UNIQUE " if ni[i].get("unique") else ""
            changes.append({"store": "MongoDB", "object": coll, "change": "INDEX ADDED",
                            "detail": f"{u}{i} {ni[i].get('keys')}"})
        for i in sorted(set(oi) - set(ni)):
            changes.append({"store": "MongoDB", "object": coll, "change": "INDEX DROPPED",
                            "detail": f"{i} {oi[i].get('keys')}"})
    return changes


def main():
    if len(sys.argv) < 3:
        print("usage: schema_diff.py <old.json> <new.json> [out.json]", file=sys.stderr)
        return 2
    old = json.load(open(sys.argv[1]))
    new = json.load(open(sys.argv[2]))
    changes = (diff_mysql(old.get("mysql", {}), new.get("mysql", {}))
               + diff_mongo(old.get("mongo", {}), new.get("mongo", {})))
    result = {"from": old.get("taken_at"), "to": new.get("taken_at"),
              "count": len(changes), "changes": changes}
    if len(sys.argv) > 3:
        with open(sys.argv[3], "w") as f:
            json.dump(result, f, indent=1)
    else:
        print(json.dumps(result, indent=1))
    print(f"{len(changes)} schema change(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
