#!/usr/bin/env python3
"""Apply schema v4 (Phases 7-8) to an existing SUNNATI DB copy.

Idempotent: every statement uses IF NOT EXISTS / guarded ALTERs (a
column is added only when PRAGMA table_info shows it missing), so
running it twice — or on a DB that already has v3+v4 — is a no-op.
Also applies SCHEMA_V3 first when the v3 tables are absent, so a v2
database can be migrated in one step. (The shipped assets/sunnati.db
already carries v3 since the verified core landed 2026-11-26, so the
v3 step is a no-op there.)

Usage (work copy ONLY — never run on assets/sunnati.db directly):
    python3 tools/migrate_schema_v4.py --db ~/workspace/phase7-work/work.db
"""
from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_db import SCHEMA_V3, SCHEMA_V4  # noqa: E402


def _apply_script(con: sqlite3.Connection, script: str) -> dict:
    report: dict = {"columns_added": [], "columns_already_present": [],
                    "statements_run": 0}
    alter_re = re.compile(
        r"ALTER TABLE (\w+) ADD COLUMN (\w+) (.*?);", re.DOTALL)
    for m in alter_re.finditer(script):
        table, column, definition = m.group(1), m.group(2), m.group(3)
        existing = {r[1] for r in
                    con.execute(f"PRAGMA table_info({table})").fetchall()}
        if column in existing:
            report["columns_already_present"].append(f"{table}.{column}")
        else:
            con.execute(
                f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
            report["columns_added"].append(f"{table}.{column}")
    remaining = alter_re.sub("", script)
    con.executescript(remaining)
    report["statements_run"] = remaining.count(";")
    return report


def apply_v4(con: sqlite3.Connection) -> dict:
    tables = {r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
    report: dict = {"v3_applied": False, "v3": None, "v4": None}
    if "narrator_aliases" not in tables:
        report["v3"] = _apply_script(con, SCHEMA_V3)
        report["v3_applied"] = True
    report["v4"] = _apply_script(con, SCHEMA_V4)
    con.execute("INSERT OR REPLACE INTO meta (key, value) VALUES"
                " ('schema_version', '4')")
    con.commit()
    return report


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", required=True, help="DB path to migrate")
    args = ap.parse_args()
    con = sqlite3.connect(args.db)
    try:
        before = {r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
        report = apply_v4(con)
        after = {r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
        print(f"migrated {args.db} to schema v4")
        print(f"v3 applied here: {report['v3_applied']}")
        print(f"v4 columns added: {report['v4']['columns_added']}")
        print(f"v4 columns already present: "
              f"{report['v4']['columns_already_present']}")
        print(f"new tables: {sorted(after - before)}")
        row = con.execute(
            "SELECT value FROM meta WHERE key='schema_version'").fetchone()
        print(f"meta schema_version: {row[0]}")
        row = con.execute("PRAGMA quick_check").fetchone()
        print(f"quick_check: {row[0]}")
        return 0 if row[0] == "ok" else 1
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
