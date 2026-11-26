#!/usr/bin/env python3
"""Apply the Phase 5 schema v3 additions to an existing SUNNATI DB.

Idempotent: ALTER TABLE ... ADD COLUMN statements are only executed for
columns that do not exist yet (checked via PRAGMA table_info); the
CREATE TABLE / CREATE INDEX statements in SCHEMA_V3 all use
IF NOT EXISTS. The v3 SQL is imported from tools/build_db.py so there
is exactly one definition of the schema.

Usage (work copy ONLY — never run on assets/sunnati.db directly):
    python3 tools/migrate_schema_v3.py --db ~/workspace/phase5-work/work.db
"""
from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_db import SCHEMA_V3  # noqa: E402


def apply_v3(con: sqlite3.Connection) -> dict:
    report = {"columns_added": [], "columns_already_present": [],
              "statements_run": 0}
    # 1. ALTER TABLE ... ADD COLUMN (only for missing columns).
    alter_re = re.compile(
        r"ALTER TABLE (\w+) ADD COLUMN (\w+) (.*?);", re.DOTALL)
    remaining = SCHEMA_V3
    for m in alter_re.finditer(SCHEMA_V3):
        table, column, definition = m.group(1), m.group(2), m.group(3)
        existing = {r[1] for r in
                    con.execute(f"PRAGMA table_info({table})").fetchall()}
        if column in existing:
            report["columns_already_present"].append(f"{table}.{column}")
        else:
            con.execute(
                f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
            report["columns_added"].append(f"{table}.{column}")
    remaining = alter_re.sub("", SCHEMA_V3)
    # 2. Everything else (CREATE TABLE / INDEX, all IF NOT EXISTS).
    con.executescript(remaining)
    report["statements_run"] = remaining.count(";")
    # 3. Meta: record the schema version on the migrated copy.
    con.execute("INSERT OR REPLACE INTO meta (key, value) VALUES"
                " ('schema_version', '3')")
    con.execute("INSERT OR REPLACE INTO meta (key, value) VALUES"
                " ('phase', '2-3-imported + 5-schema-v3 (empty narrator"
                " tables)')")
    con.execute("INSERT OR REPLACE INTO meta (key, value) VALUES"
                " ('no_data_yet', 'narrators, chains, narrator_aliases,"
                " narrator_grades, narrator_scholars, narrator_teachers,"
                " narrator_students, narrator_sources,"
                " narrator_identity_matches, takhrij, hadith_variants,"
                " topics, hadith_relations, glossary: لا توجد بيانات"
                " موثقة بعد — المرحلة 5. Tables exist empty with full"
                " structure; no dummy rows. hadith_narrators /"
                " isnad_chains / isnad_nodes may hold ONLY"
                " machine-extracted parser candidates (narrator_id NULL,"
                " match_status unlinked/needs_review, parser_version"
                " stamped) — never a linked narrator identity or a"
                " status verdict.')")
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
        report = apply_v3(con)
        after = {r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
        print(f"migrated {args.db} to schema v3")
        print(f"columns added: {report['columns_added']}")
        print(f"columns already present: "
              f"{report['columns_already_present']}")
        print(f"new tables: {sorted(after - before)}")
        row = con.execute(
            "SELECT value FROM meta WHERE key='schema_version'"
        ).fetchone()
        print(f"meta schema_version: {row[0]}")
        row = con.execute("PRAGMA quick_check").fetchone()
        print(f"quick_check: {row[0]}")
        return 0 if row[0] == "ok" else 1
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
