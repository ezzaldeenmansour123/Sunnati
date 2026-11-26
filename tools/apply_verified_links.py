#!/usr/bin/env python3
"""Apply the verified isnad-link decisions to a freshly built SUNNATI DB.

Why this step exists (merge 2026-11-26): `tools/build_db.py` builds the
library from the Nine Books and creates the narrator tables EMPTY — it does
not run the isnad parser and does not know the human-reviewed linking
decisions. Without this step a CI-built database would ship with 0 parser
candidates and 0 verified links, silently disabling the tap-a-narrator
feature. This script seeds exactly the reviewed scope (the 1,500-hadith
sample: 7,808 candidates + 1,464 verified links + 1,588 chains + 6,231
relations + 7,808 review-log rows) from the committed
`tools/verified_links.json`, then verifies every count and fails the build
on any mismatch.

Rules:
  * The target tables must be EMPTY (a fresh build). Non-empty -> refuse,
    unless --force is given (clears the five tables first).
  * No row is invented here: every inserted row comes from the committed
    file, which was exported from the reviewed work database.
  * No narrator identity is linked beyond the file's `linked_verified`
    decisions; ambiguous/unlinked/pending rows keep narrator_id NULL.
  * Sets the meta keys that document the core (narrators_verified,
    linked_verified_rows, narrators_db, core_build_date).

Usage (CI — after `python3 tools/build_db.py --out assets/sunnati.db ...`):
    python3 tools/apply_verified_links.py --db assets/sunnati.db
    python3 tools/apply_verified_links.py --db assets/sunnati.db --links tools/verified_links.json

Exit code is non-zero on any failure; CI fails the build instead of
shipping a library without its verified links.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

TABLES = ("hadith_narrators", "isnad_nodes", "isnad_chains",
          "isnad_relations", "narrator_identity_matches")

EXPECTED = {
    "hadith_narrators": 7808,
    "isnad_nodes": 7808,
    "isnad_chains": 1588,
    "isnad_relations": 6231,
    "narrator_identity_matches": 7808,
    "linked_verified": 1464,
    "decisions": {
        "ambiguous": 3539,
        "linked_verified": 1464,
        "pending": 355,
        "unlinked": 2450,
    },
}

META_KEYS = ("narrators_verified", "linked_verified_rows", "narrators_db",
             "core_build_date")


def fail(msg: str) -> "SystemExit":
    print(f"ERROR: {msg}", file=sys.stderr)
    return SystemExit(1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", required=True, help="Target sunnati.db (fresh build)")
    ap.add_argument("--links", default=None,
                    help="verified_links.json (default: tools/verified_links.json)")
    ap.add_argument("--force", action="store_true",
                    help="Clear the four tables first if non-empty")
    ap.add_argument("--log-json", default=None,
                    help="Write a verification log (JSON) here")
    args = ap.parse_args()

    links_path = Path(args.links) if args.links else (
        Path(__file__).resolve().parent / "verified_links.json")
    if not links_path.is_file():
        raise fail(f"links file not found: {links_path}")
    data = json.loads(links_path.read_text(encoding="utf-8"))
    if data.get("format") != "sunnati-verified-links-v1":
        raise fail(f"unsupported links format: {data.get('format')!r}")
    for table in TABLES:
        if len(data[table]["rows"]) != EXPECTED[table]:
            raise fail(
                f"{table}: file has {len(data[table]['rows'])} rows, "
                f"expected {EXPECTED[table]} — file is not the reviewed export")

    db_path = Path(args.db)
    con = sqlite3.connect(db_path)
    try:
        total = con.execute("SELECT COUNT(*) FROM hadiths").fetchone()[0]
        if total != 65712:
            raise fail(f"hadiths count {total} != 65712 — wrong database")
        for table in TABLES:
            n = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            if n != 0:
                if not args.force:
                    raise fail(
                        f"{table} is not empty ({n} rows) — refusing to "
                        "overwrite reviewed data; use --force to clear first")
                con.execute(f"DELETE FROM {table}")
                print(f"  --force: cleared {table} ({n} rows)")
        for table in TABLES:
            cols = data[table]["columns"]
            rows = data[table]["rows"]
            placeholders = ", ".join("?" for _ in cols)
            con.executemany(
                f"INSERT INTO {table} ({', '.join(cols)}) "
                f"VALUES ({placeholders})",
                [[r[c] for c in cols] for r in rows],
            )
            print(f"  inserted {table}: {len(rows)} rows")
        for key in META_KEYS:
            if key in data.get("meta", {}):
                con.execute(
                    "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                    (key, data["meta"][key]),
                )
        con.commit()

        # -- verification ---------------------------------------------------
        errors = []
        report: dict = {"counts": {}, "decisions": {}}
        for table in TABLES:
            n = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            report["counts"][table] = n
            if n != EXPECTED[table]:
                errors.append(f"{table}: {n} != {EXPECTED[table]}")
        linked = con.execute(
            "SELECT COUNT(*) FROM narrator_identity_matches "
            "WHERE decision = 'linked_verified'").fetchone()[0]
        report["counts"]["linked_verified"] = linked
        if linked != EXPECTED["linked_verified"]:
            errors.append(f"linked_verified: {linked} != "
                          f"{EXPECTED['linked_verified']}")
        for d, c in con.execute(
                "SELECT decision, COUNT(*) FROM narrator_identity_matches "
                "GROUP BY decision"):
            report["decisions"][d] = c
        if report["decisions"] != EXPECTED["decisions"]:
            errors.append(f"decisions mismatch: {report['decisions']} != "
                          f"{EXPECTED['decisions']}")
        hn_linked = con.execute(
            "SELECT COUNT(*) FROM hadith_narrators "
            "WHERE narrator_id IS NOT NULL").fetchone()[0]
        report["counts"]["hadith_narrators_linked"] = hn_linked
        if hn_linked != EXPECTED["linked_verified"]:
            errors.append(f"hadith_narrators linked: {hn_linked} != "
                          f"{EXPECTED['linked_verified']}")
        row = con.execute("PRAGMA quick_check").fetchone()
        if row is None or row[0] != "ok":
            errors.append("PRAGMA quick_check != ok")
        report["quick_check"] = row[0] if row else None
        report["sha256"] = hashlib.sha256(db_path.read_bytes()).hexdigest()
        if args.log_json:
            Path(args.log_json).write_text(
                json.dumps(report, ensure_ascii=False, indent=2),
                encoding="utf-8")
        if errors:
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
            return 1
        # The links change the file, so its published hash must be
        # rewritten too — bare-hash format, exactly as build_db.py writes
        # it (the app compares the trimmed file content to the hash).
        db_path.with_suffix(".db.sha256").write_text(
            report["sha256"] + "\n", encoding="utf-8")
        print(f"  updated {db_path.with_suffix('.db.sha256')}")
        print("  verified links applied + verified:")
        print(f"    {report['counts']}")
        print(f"    decisions: {report['decisions']}")
        print(f"    sha256: {report['sha256']}")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
