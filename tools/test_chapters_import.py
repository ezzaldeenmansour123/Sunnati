#!/usr/bin/env python3
"""Verify the SUNNATI Arabic-chapters import (tools/chapters_import.py).

Re-runs the import on a COPY of the pilot DB (never the original) and
checks, per book:
  * chapter rows created == rows built from the tree + mapping files
    (kitab-level rows + bab rows + the single «غير مصنّف» row);
  * every hadith of the 7 books points at an existing chapter (no
    orphans) and the linked/unclassified counts match the mapping;
  * Nasai/Malik chapters are UNTOUCHED (still the English rows);
  * the old English rows are preserved in chapters_backup_v4_en;
  * a second import is refused (guard);
  * spot samples: 5 hand-verified (hadith, Arabic bab) pairs per book
    from SUNNATI_CHAPTERS_IMPORT_VERIFICATION_2026-11-26.md.

Usage:
    python3 tools/test_chapters_import.py [--db pilot/sunnati.db]
Exit code is non-zero on any failure.
"""
from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chapters_import as ci  # noqa: E402

# Hand-verified samples: (book, app num, expected Arabic bab title
# substring). Taken from the import verification report — each was
# checked by hand against the hadith text + the Wikisource heading.
# A sample is skipped (not failed) when its hadith is unclassified
# in the mapping (honest «غير مصنّف»).
SAMPLES: list[tuple[str, int, str]] = [
    ("bukhari", 1, "بدء الوحي"),
    ("bukhari", 8, "الإيمان"),
    ("bukhari", 7563, "التوحيد"),
    ("muslim", 3, "تغليظ الكذب"),
    ("muslim", 239, "الإيمان"),
    ("abudawud", 1, "الطهارة"),
    ("abudawud", 1161, "الاستسقاء"),
    ("tirmidhi", 1, "الطهارة"),
    ("ibnmajah", 1, "مقدمة"),
    ("darimi", 1, "المقدمة"),
    # Ahmad 1 is in the source's own first section «باب العشرة
    # المبشرين» (hadiths 1-1624: the musnads of the Ten); NOT
    # «مسند أبي بكر» — the tree's verified top-level title.
    ("ahmad", 1, "العشرة المبشرين"),
]


def expected_rows(book: str, mapping: dict, repairs: dict) -> int:
    rows, _ = ci.build_chapter_rows(book, mapping, repairs)
    return len(rows)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="pilot/sunnati.db")
    args = ap.parse_args()
    src = Path(args.db)
    if not src.exists():
        print(f"FAIL: DB not found: {src}", file=sys.stderr)
        return 2
    failures: list[str] = []

    def check(cond: bool, msg: str) -> None:
        print(("  ok  " if cond else " FAIL ") + msg)
        if not cond:
            failures.append(msg)

    tmp = Path(tempfile.mkdtemp(prefix="sunnati-chapters-test-"))
    db = tmp / "test.db"
    shutil.copyfile(src, db)
    print(f"test copy: {db}")

    # English chapters before the import (for the Nasai/Malik check).
    con = sqlite3.connect(str(db))
    before = {
        r[0]: r[1] for r in con.execute(
            "SELECT book, COUNT(*) FROM chapters GROUP BY book")
    }
    before_titles = {
        (r[0], r[1]): r[2] for r in con.execute(
            "SELECT book, num, title FROM chapters "
            "WHERE book IN ('nasai','malik')")
    }
    con.close()

    repairs = {}
    rp = ci.CHAPTERS_DIR / "title_repairs.json"
    if rp.exists():
        repairs = ci.load_json(rp)

    con = sqlite3.connect(str(db))
    log: dict = {}
    try:
        stats = ci.apply_arabic_chapters(con, log)
    except Exception as e:  # noqa: BLE001 - report as test failure
        print(f"FAIL: apply_arabic_chapters raised: {e!r}", file=sys.stderr)
        return 1
    con.commit()

    # 1. Row counts per book match the rows built from tree + mapping.
    for book in ci.ARABIC_BOOKS:
        mapping = ci.load_json(ci.CHAPTERS_DIR / ci.MAPPING_FILES[book])
        exp = expected_rows(book, mapping, repairs)
        got = con.execute(
            "SELECT COUNT(*) FROM chapters WHERE book = ?", (book,)
        ).fetchone()[0]
        check(got == exp, f"{book}: {got} chapter rows (expected {exp})")
        st = stats[book]
        check(st["orphan_chapter_ids"] == 0,
              f"{book}: 0 orphan chapter_ids")
        check(st["mapping_keys_without_row"] == 0,
              f"{book}: every mapped pair has a chapter row")
        # Linked + unclassified == total, and linked == mapping entries
        # that resolve to a real bab/kitab row.
        tot = con.execute(
            "SELECT COUNT(*) FROM hadiths WHERE book = ?", (book,)
        ).fetchone()[0]
        check(st["hadiths_total"] == tot, f"{book}: {tot} hadiths total")
        check(st["hadiths_linked"] + st["hadiths_unclassified"] == tot,
              f"{book}: linked + unclassified == total")

    # 2. Nasai / Malik untouched.
    for book in ("nasai", "malik"):
        got = con.execute(
            "SELECT COUNT(*) FROM chapters WHERE book = ?", (book,)
        ).fetchone()[0]
        check(got == before.get(book, 0),
              f"{book}: {got} chapters unchanged (was {before.get(book, 0)})")
        after = {
            (r[0], r[1]): r[2] for r in con.execute(
                "SELECT book, num, title FROM chapters WHERE book = ?",
                (book,))
        }
        before_book = {k: v for k, v in before_titles.items()
                       if k[0] == book}
        check(after == before_book,
              f"{book}: titles byte-identical")
        # No Arabic rows and no «غير مترجم» change: titles still English.
        ar = con.execute(
            "SELECT COUNT(*) FROM chapters WHERE book = ? AND "
            "title_source LIKE '%arabic-wikisource%'", (book,)
        ).fetchone()[0]
        check(ar == 0, f"{book}: 0 Arabic chapter rows")

    # 3. Backup table holds the old English rows for the 7 books.
    n_backed = con.execute(
        "SELECT COUNT(*) FROM chapters_backup_v4_en").fetchone()[0]
    exp_backed = sum(before.get(b, 0) for b in ci.ARABIC_BOOKS)
    check(n_backed == exp_backed,
          f"backup: {n_backed} old English rows (expected {exp_backed})")

    # 4. Second import refused.
    try:
        ci.apply_arabic_chapters(con, {})
        check(False, "second import refused by guard")
    except RuntimeError as e:
        check("already installed" in str(e),
              f"second import refused by guard ({e})")

    # 5. Spot samples (hand-verified).
    for book, num, frag in SAMPLES:
        row = con.execute(
            "SELECT c.title FROM hadiths h JOIN chapters c "
            "ON c.id = h.chapter_id WHERE h.book = ? AND h.num = ?",
            (book, num),
        ).fetchone()
        if row is None:
            check(False, f"sample {book}:{num} not found in DB")
            continue
        title = row[0]
        if title == ci.UNCLASSIFIED_TITLE:
            print(f"  skip sample {book}:{num} (honest unclassified)")
            continue
        check(frag in title,
              f"sample {book}:{num} -> {title!r} (expect {frag!r})")

    # 6. No hadith anywhere points at a missing chapter.
    orphans = con.execute(
        "SELECT COUNT(*) FROM hadiths h LEFT JOIN chapters c "
        "ON c.id = h.chapter_id WHERE c.id IS NULL").fetchone()[0]
    check(orphans == 0, f"0 orphan hadith chapter_ids (all books)")
    con.close()

    print(f"\n{'ALL CHECKS PASSED' if not failures else 'FAILURES: ' + str(len(failures))}")
    for f in failures:
        print(f"  - {f}")
    # Always remove the 193 MB test copy (/tmp is a 512 MB tmpfs).
    shutil.rmtree(tmp, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
