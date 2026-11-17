#!/usr/bin/env python3
"""Extract DECLARED entity changes from a git range, with author and feature.

Reads the JPA (@Entity/@Table/@Column/@JoinColumn) and Mongo (@Document) declarations
out of the commits themselves, so every change carries who made it and which module it
belongs to. The live-database probe says what actually landed; this says who asked for
it and why. Correlating the two is what makes an out-of-band ALTER visible.

Usage: entity_diff.py <repo> <old_sha> <new_sha> [out.json]
"""
import json
import re
import subprocess
import sys

ENTITY_FILE = re.compile(r"\.java$")
# A declaration line we care about, as it appears in a unified diff (+/- prefixed).
TABLE_RE = re.compile(r'@Table\s*\(\s*name\s*=\s*"([^"]+)"')
DOC_RE = re.compile(r'@Document\s*\(\s*(?:collection\s*=\s*)?"([^"]+)"')
DOC_BARE_RE = re.compile(r'@Document\b')
COLUMN_RE = re.compile(r'@Column\s*\(([^)]*)\)')
COLNAME_RE = re.compile(r'name\s*=\s*"([^"]+)"')
FIELD_RE = re.compile(r'private\s+[\w<>,.\[\] ]+\s+(\w+)\s*;')


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def module_of(path):
    """First path segment is the Gradle module — the closest thing to 'which feature'."""
    return path.split("/")[0] if "/" in path else "(root)"


def main():
    if len(sys.argv) < 4:
        print("usage: entity_diff.py <repo> <old_sha> <new_sha> [out.json]", file=sys.stderr)
        return 2
    repo, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
    rng = f"{old}..{new}"

    # Only files that could carry an entity declaration.
    files = [f for f in sh("git", "-C", repo, "diff", "--name-only", rng).splitlines()
             if ENTITY_FILE.search(f)]

    changes = []
    for path in files:
        patch = sh("git", "-C", repo, "diff", rng, "--", path)
        if not patch:
            continue
        added = [l[1:] for l in patch.splitlines() if l.startswith("+") and not l.startswith("+++")]
        removed = [l[1:] for l in patch.splitlines() if l.startswith("-") and not l.startswith("---")]
        blob = "\n".join(added)
        if not (TABLE_RE.search(blob) or DOC_RE.search(blob) or DOC_BARE_RE.search(blob)
                or COLUMN_RE.search(blob) or TABLE_RE.search("\n".join(removed))):
            continue

        # Who touched this file in the range, and the subjects — the "by whom / why".
        authors = sorted(set(sh("git", "-C", repo, "log", "--format=%an", rng, "--", path).split("\n")) - {""})
        subjects = [s for s in sh("git", "-C", repo, "log", "--format=%s", rng, "--", path).splitlines() if s]

        # The declared table/collection this class maps to. Usually the @Table line is NOT
        # in the diff — only the new fields are — so fall back to the whole file at the new
        # SHA (then the old one, for a deleted entity). Without this the mapping is null for
        # the common "added a column" case and correlation against the live DB fails.
        whole = sh("git", "-C", repo, "show", f"{new}:{path}") \
            or sh("git", "-C", repo, "show", f"{old}:{path}")
        haystacks = [blob, "\n".join(removed), whole]

        def first(rx):
            for h in haystacks:
                m = rx.search(h)
                if m:
                    return m.group(1)
            return None

        table = first(TABLE_RE)
        collection = first(DOC_RE)
        if not collection and any(DOC_BARE_RE.search(h) for h in haystacks):
            # @Document with no explicit name -> collection is the decapitalised class name
            cls = path.rsplit("/", 1)[-1][:-5]
            collection = cls[0].lower() + cls[1:]

        # Added / removed persistent fields.
        def fields(lines):
            out = []
            for i, line in enumerate(lines):
                fm = FIELD_RE.search(line)
                if not fm:
                    continue
                name = fm.group(1)
                col = None
                for back in range(max(0, i - 4), i):
                    cm = COLUMN_RE.search(lines[back])
                    if cm:
                        nm = COLNAME_RE.search(cm.group(1))
                        col = nm.group(1) if nm else None
                out.append(col or name)
            return out

        added_fields = [f for f in fields(added) if f not in fields(removed)]
        removed_fields = [f for f in fields(removed) if f not in fields(added)]

        changes.append({
            "file": path,
            "module": module_of(path),
            "class": path.rsplit("/", 1)[-1][:-5],
            "table": table,
            "collection": collection,
            "fields_added": added_fields,
            "fields_removed": removed_fields,
            "authors": authors,
            "commits": subjects[:5],
        })

    result = {"repo": repo, "range": rng, "count": len(changes), "changes": changes}
    if len(sys.argv) > 4:
        with open(sys.argv[4], "w") as f:
            json.dump(result, f, indent=1)
    else:
        print(json.dumps(result, indent=1))
    print(f"{len(changes)} declared entity change(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
