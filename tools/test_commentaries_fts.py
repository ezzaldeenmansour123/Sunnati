#!/usr/bin/env python3
"""Standalone commentaries_fts tests (rebuild 2026-11-26).

Tests ONLY `tools/phase4_search_index.py::build_commentaries_fts` — the
one Phase 4 artefact built by default in v1.0.0 — on a tiny synthetic
DB, so it runs in under a second with no library data and no network.
The full Phase 4 set is covered separately by
tools/test_search_phase4.py against a work copy with the full index.

Usage:
    python3 tools/test_commentaries_fts.py [--out .../test-results.json]
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from arabic_text import fts_norm  # noqa: E402
from phase4_search_index import build_commentaries_fts  # noqa: E402

RESULTS: list[dict] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append({"name": name, "passed": bool(ok), "detail": detail})
    print(f"  [{'PASS' if ok else 'FAIL'}] {name} — {detail}")


def make_db(path: Path, rows: list[tuple[int, str, str]]) -> sqlite3.Connection:
    if path.exists():
        path.unlink()
    con = sqlite3.connect(str(path))
    con.execute(
        "CREATE TABLE commentaries (id INTEGER PRIMARY KEY, text TEXT, "
        "explanation TEXT)"
    )
    con.executemany(
        "INSERT INTO commentaries (id, text, explanation) VALUES (?, ?, ?)",
        rows,
    )
    con.commit()
    return con


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    work = Path("/tmp/sunnati-commentaries-fts-test.db")
    print("== commentaries_fts standalone tests ==")

    rows = [
        (1, "إنما الأعمال بالنيات", "شرح النية والإخلاص في الصلاة"),
        (2, "من صلى البردين دخل الجنة", "فضل صلاة الفجر والعصر"),
        (3, "لا ضرر ولا ضرار", "قاعدة فقهية في المعاملات"),
    ]
    con = make_db(work, rows)

    log = build_commentaries_fts(con, {})
    check("build reports 3 rows",
          log.get("commentaries_fts_rows") == 3,
          f"got {log.get('commentaries_fts_rows')}")
    check("commentaries_fts holds 3 rows",
          con.execute("SELECT COUNT(*) FROM commentaries_fts").fetchone()[0] == 3,
          "count ok")
    # The app queries with the single normalised term (fts_norm strips
    # the article: صلاة -> صلاه); fts_norm('الصلاة') yields two tokens
    # and must not be used as one phrase.
    norm = fts_norm("صلاة")
    hits = con.execute(
        "SELECT c.id FROM commentaries_fts f JOIN commentaries c "
        "ON c.id = f.rowid WHERE commentaries_fts MATCH ?",
        (f'"{norm}"*',),
    ).fetchall()
    check("normalised query finds the صلاة rows (1 and 2)",
          {r[0] for r in hits} == {1, 2},
          f"got {[r[0] for r in hits]} for norm {norm!r}")
    check("quick_check ok",
          con.execute("PRAGMA quick_check").fetchone()[0] == "ok", "ok")

    # Idempotency: a second build replaces, never duplicates.
    build_commentaries_fts(con, {})
    check("second build is idempotent (still 3 rows)",
          con.execute("SELECT COUNT(*) FROM commentaries_fts").fetchone()[0] == 3,
          "count ok")

    # No other Phase 4 artefact is created by the standalone build.
    tables = {r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}
    check("standalone build creates no spans/lexicon tables",
          not (tables & {"hadith_spans", "hadith_spans_fts",
                         "search_synonyms", "search_roots", "search_vocab"}),
          f"tables={sorted(tables)}")
    con.close()

    # Empty commentaries table: 0 rows, no crash.
    con = make_db(work, [])
    log = build_commentaries_fts(con, {})
    check("empty commentaries -> 0 rows, no crash",
          log.get("commentaries_fts_rows") == 0
          and con.execute("SELECT COUNT(*) FROM commentaries_fts")
          .fetchone()[0] == 0,
          "ok")
    con.close()
    work.unlink(missing_ok=True)

    passed = sum(1 for r in RESULTS if r["passed"])
    print(f"\n== {passed}/{len(RESULTS)} passed ==")
    if args.out:
        Path(args.out).write_text(
            json.dumps(
                {"passed": passed, "total": len(RESULTS), "results": RESULTS},
                ensure_ascii=False, indent=1,
            ),
            encoding="utf-8",
        )
        print(f"results: {args.out}")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
