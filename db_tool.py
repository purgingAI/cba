#!/usr/bin/env python3
"""CBA read-only DB query tool.

This is the ONLY way CBA touches live data. It is strictly read-only:
  - Mongo: find() on an allow-listed set of collections; never write/aggregate-$out.
  - MySQL: single SELECT statement only; anything else is rejected.
Both cap the number of rows returned.

Usage:
  db_tool.py mongo <collection> '<json-filter>' [limit] [sortField:asc|desc]
  db_tool.py mysql "SELECT ... "        # single SELECT only

Config (CBA_CONFIG env or ./config.env): CBA_MONGO_URI, CBA_MONGO_DB,
CBA_MYSQL_HOST, CBA_MYSQL_PORT, CBA_MYSQL_USER, CBA_MYSQL_PASS, CBA_MYSQL_DB.
"""
import json
import os
import re
import sys
from pathlib import Path

MAX_ROWS = 50            # default cap
HARD_MAX = 200           # absolute ceiling

MONGO_COLLECTIONS = {
    "transaction", "settlementTransaction", "walletLedger", "feeTransaction",
    "globalWalletKeyMapper", "serviceProvider",
}

FORBIDDEN_SQL = re.compile(
    r"\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|replace|"
    r"merge|call|load_file|into\s+outfile|into\s+dumpfile|set\s|use\s)\b",
    re.IGNORECASE,
)


def load_config() -> dict:
    path = os.environ.get("CBA_CONFIG") or str(Path(__file__).resolve().parent / "config.env")
    cfg = {}
    p = Path(path)
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


def clamp(n) -> int:
    try:
        n = int(n)
    except Exception:
        n = MAX_ROWS
    return max(1, min(n, HARD_MAX))


def run_mongo(cfg, argv) -> int:
    from pymongo import MongoClient
    if len(argv) < 2:
        print("usage: db_tool.py mongo <collection> '<json-filter>' [limit] [field:asc|desc]")
        return 2
    coll = argv[0]
    if coll not in MONGO_COLLECTIONS:
        print(f"collection '{coll}' not allowed. Allowed: {sorted(MONGO_COLLECTIONS)}")
        return 3
    try:
        filt = json.loads(argv[1]) if argv[1] else {}
    except json.JSONDecodeError as e:
        print(f"bad JSON filter: {e}")
        return 4
    if not isinstance(filt, dict):
        print("filter must be a JSON object")
        return 4
    # Block any operator that could write/execute.
    blob = json.dumps(filt).lower()
    if "$where" in blob or "$function" in blob or "$out" in blob or "$merge" in blob:
        print("filter contains a disallowed operator")
        return 5
    limit = clamp(argv[2]) if len(argv) > 2 and argv[2] else MAX_ROWS
    sort = None
    if len(argv) > 3 and argv[3] and ":" in argv[3]:
        f, d = argv[3].split(":", 1)
        sort = [(f, -1 if d.lower().startswith("desc") else 1)]

    uri = cfg.get("CBA_MONGO_URI", "")
    dbname = cfg.get("CBA_MONGO_DB", "APP_DB")
    if not uri:
        print("CBA_MONGO_URI not set in config")
        return 6
    cli = MongoClient(uri, serverSelectionTimeoutMS=8000)
    cur = cli[dbname][coll].find(filt)
    if sort:
        cur = cur.sort(sort)
    cur = cur.limit(limit)
    rows = []
    for d in cur:
        d.pop("_id", None)
        rows.append({k: str(v) for k, v in d.items()})
    print(json.dumps({"collection": coll, "count": len(rows), "rows": rows}, indent=1, default=str))
    return 0


def run_mysql(cfg, argv) -> int:
    import pymysql
    if not argv:
        print("usage: db_tool.py mysql \"SELECT ...\"")
        return 2
    sql = argv[0].strip().rstrip(";").strip()
    if not re.match(r"(?is)^\s*select\b", sql):
        print("only SELECT statements are allowed")
        return 3
    if ";" in sql:
        print("multiple statements are not allowed")
        return 3
    if FORBIDDEN_SQL.search(sql):
        print("query contains a forbidden keyword (read-only SELECT only)")
        return 3
    if not re.search(r"(?is)\blimit\s+\d+", sql):
        sql = f"{sql} LIMIT {MAX_ROWS}"
    conn = pymysql.connect(
        host=cfg.get("CBA_MYSQL_HOST", ""),
        port=int(cfg.get("CBA_MYSQL_PORT", "3306") or "3306"),
        user=cfg.get("CBA_MYSQL_USER", ""),
        password=cfg.get("CBA_MYSQL_PASS", ""),
        database=cfg.get("CBA_MYSQL_DB", ""),
        connect_timeout=8,
        read_timeout=20,
        cursorclass=pymysql.cursors.DictCursor,
    )
    with conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
    print(json.dumps({"count": len(rows), "rows": rows}, indent=1, default=str))
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cfg = load_config()
    engine = sys.argv[1].lower()
    try:
        if engine == "mongo":
            return run_mongo(cfg, sys.argv[2:])
        if engine == "mysql":
            return run_mysql(cfg, sys.argv[2:])
    except Exception as e:  # noqa: BLE001
        print(f"query error: {e}")
        return 1
    print("first arg must be 'mongo' or 'mysql'")
    return 2


if __name__ == "__main__":
    sys.exit(main())
