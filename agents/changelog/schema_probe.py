#!/usr/bin/env python3
"""Snapshot the SHAPE of the dev databases — never the data.

MySQL  : tables, columns (type/nullability/default/position), indexes.
MongoDB: collections and their indexes. Mongo has no declared column set, so a
         collection's field shape is taken from the @Document classes in code
         (entity_diff.py), not from sampling documents — sampling would read
         customer data, which this tool must never do.

Writes one JSON snapshot. schema_diff.py compares two of them.

Usage: schema_probe.py <out.json>
"""
import json
import os
import sys
from datetime import datetime, timezone

MYSQL_SCHEMAS = [s.strip() for s in os.environ.get(
    "CHLOG_MYSQL_SCHEMAS", "APP_DB_dev").split(",") if s.strip()]
MONGO_DBS = [s.strip() for s in os.environ.get(
    "CHLOG_MONGO_DBS", "APP_DB").split(",") if s.strip()]


def mysql_snapshot():
    import pymysql
    host = os.environ["CHLOG_MYSQL_HOST"]
    user = os.environ["CHLOG_MYSQL_USER"]
    pwd = os.environ["CHLOG_MYSQL_PASS"]
    port = int(os.environ.get("CHLOG_MYSQL_PORT", "3306"))

    conn = pymysql.connect(host=host, user=user, password=pwd, port=port,
                           connect_timeout=20, read_timeout=60,
                           cursorclass=pymysql.cursors.DictCursor)
    out = {}
    try:
        with conn.cursor() as cur:
            placeholders = ",".join(["%s"] * len(MYSQL_SCHEMAS))
            # Columns. information_schema only — no row is ever read from a business table.
            cur.execute(f"""
                SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION,
                       COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA
                FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA IN ({placeholders})
                ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
            """, MYSQL_SCHEMAS)
            for r in cur.fetchall():
                t = out.setdefault(f"{r['TABLE_SCHEMA']}.{r['TABLE_NAME']}",
                                   {"columns": {}, "indexes": {}})
                t["columns"][r["COLUMN_NAME"]] = {
                    "pos": r["ORDINAL_POSITION"],
                    "type": r["COLUMN_TYPE"],
                    "nullable": r["IS_NULLABLE"],
                    "default": r["COLUMN_DEFAULT"],
                    "key": r["COLUMN_KEY"],
                    "extra": r["EXTRA"],
                }
            cur.execute(f"""
                SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, NON_UNIQUE,
                       GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS COLS
                FROM information_schema.STATISTICS
                WHERE TABLE_SCHEMA IN ({placeholders})
                GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, NON_UNIQUE
            """, MYSQL_SCHEMAS)
            for r in cur.fetchall():
                t = out.setdefault(f"{r['TABLE_SCHEMA']}.{r['TABLE_NAME']}",
                                   {"columns": {}, "indexes": {}})
                t["indexes"][r["INDEX_NAME"]] = {
                    "unique": r["NON_UNIQUE"] == 0,
                    "columns": r["COLS"],
                }
    finally:
        conn.close()
    return out


def mongo_snapshot():
    import pymongo
    uri = os.environ["CHLOG_MONGO_URI"]
    cli = pymongo.MongoClient(uri, serverSelectionTimeoutMS=20000)
    out = {}
    try:
        for dbname in MONGO_DBS:
            db = cli[dbname]
            for coll in db.list_collection_names():
                key = f"{dbname}.{coll}"
                try:
                    idx = {n: {"keys": str(spec.get("key")),
                               "unique": bool(spec.get("unique", False))}
                           for n, spec in db[coll].index_information().items()}
                except Exception as e:
                    idx = {"_error": {"keys": str(e)[:120], "unique": False}}
                out[key] = {"indexes": idx}
    finally:
        cli.close()
    return out


def main():
    if len(sys.argv) < 2:
        print("usage: schema_probe.py <out.json>", file=sys.stderr)
        return 2
    snap = {"taken_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "mysql": {}, "mongo": {}, "errors": {}}
    try:
        snap["mysql"] = mysql_snapshot()
    except Exception as e:
        snap["errors"]["mysql"] = str(e)[:300]
    try:
        snap["mongo"] = mongo_snapshot()
    except Exception as e:
        snap["errors"]["mongo"] = str(e)[:300]

    with open(sys.argv[1], "w") as f:
        json.dump(snap, f, indent=1, sort_keys=True, default=str)
    print(f"mysql tables: {len(snap['mysql'])}  mongo collections: {len(snap['mongo'])}"
          + (f"  errors: {snap['errors']}" if snap["errors"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
