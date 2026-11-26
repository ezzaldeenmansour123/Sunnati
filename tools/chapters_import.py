#!/usr/bin/env python3
"""Arabic chapters import for SUNNATI (Phase 5: chapters).

Replaces the English (hadith-api) chapter rows of the seven verifiable
books with Arabic (kitab <- bab) rows derived from Arabic Wikisource,
and re-links every hadith to its verified bab. Used by
``tools/build_db.py`` (CI rebuild) and by ``tools/test_chapters_import.py``.

Sources (all local, in ``tools/chapters/``):
  * ``{book}_kitab_bab_tree.json`` — kitab/bab tree extracted from
    Arabic Wikisource (Bayanat-Labs/arabic-wikisource-pd,
    arwikisource-20261001), CC BY-SA 4.0. Bukhari tree at the pilot root;
    the other six under their pilot sub-directories (copied here verbatim).
  * ``{book}_hadith_chapters.json`` — full urn -> [kitab_idx, bab_idx]
    mapping derived by text-matching every app hadith into the
    Wikisource text (see SUNNATI_CHAPTERS_DERIVE_MAPS_2026-11-26.py).
    ``bab_idx == -1`` means "directly under the kitab, no bab heading";
    ``bab_idx == -2`` means "unmatched -> غير مصنّف".
  * ``title_repairs.json`` — mechanical title repairs taken verbatim
    from the source heading lines (truncated «قول الله تعالى» /
    «قوله» titles and titles that swallowed hadith text); the original
    tree title is kept in the repair record for audit.
  * ``{book}_alignment_100.json`` — the 100-hadith pilot alignment
    sample (kept for audit / cross-checks; not read at import time).

Books covered: bukhari, muslim, abudawud, tirmidhi, ibnmajah, ahmad
(masanid, NOT abwab — Musnad Ahmad has no abwab by owner decision),
darimi. Nasai and Malik are NEVER touched here (no verified source;
their English rows stay, tagged «غير مترجم» by the app).

Row design (fits the existing Dart code untouched — database.dart reads
only id/book/num/title, ORDER BY num):
  * id  = book_sort * 10000 + num  (num 0 = «غير مصنّف» row)
  * num = sequential position in reading order (0, 1, 2, ...)
  * title = "كتاب {kitab} — باب {bab}" (or "كتاب {kitab}" for
    kitab-level rows, "مسند {title}" for Ahmad, "غير مصنّف").
    The reader header prepends the book name itself, so the title
    carries kitab + bab; the book name is NOT repeated inside it.
  * title_en = the old English title of the app chapter
    (book_number) that the majority of the bab's hadiths came from
    ('' when there is none — Ahmad/Darimi had no English titles).
  * title_lang = 'ar'; title_source documents the Wikisource
    provenance + CC BY-SA 4.0 + any repair / kitab-level note.

Reversibility (owner decision 9 — no data deleted without a rollback
plan): before any replacement, the old rows are copied into
``chapters_backup_v4_en`` (full row, keyed by the old chapter id).
The old chapter_id of any hadith is deterministic from its
(book, book_number) — id = sort*1000 + book_number (sort*1000 for
Ahmad/Darimi) — so a rollback is a few deterministic UPDATEs; see
SUNNATI_CHAPTERS_MIGRATION_PLAN_2026-11-26.md.

Run-once semantics: apply() refuses to run on a database whose Arabic
chapters are already installed (guard: any row with title_source
mentioning 'arabic-wikisource'); start from a fresh build / fresh copy
of the pilot DB to re-run.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
from pathlib import Path

CHAPTERS_DIR = Path(__file__).resolve().parent / "chapters"

# book -> (sort, tree file, mapping file, kind)
BOOK_SORT = {
    "bukhari": 1, "muslim": 2, "abudawud": 3, "tirmidhi": 4,
    "nasai": 5, "ibnmajah": 6, "ahmad": 7, "malik": 8, "darimi": 9,
}
ARABIC_BOOKS = ["bukhari", "muslim", "abudawud", "tirmidhi",
                "ibnmajah", "ahmad", "darimi"]
TREE_FILES = {
    "bukhari": "bukhari_kitab_bab_tree.json",
    "muslim": "muslim_kitab_bab_tree.json",
    "abudawud": "abudawud_kitab_bab_tree.json",
    "tirmidhi": "tirmidhi_kitab_bab_tree.json",
    "ibnmajah": "ibnmajah_kitab_bab_tree.json",
    "ahmad": "ahmad_musnad_tree.json",
    "darimi": "darimi_kitab_bab_tree.json",
}
MAPPING_FILES = {b: f"{b}_hadith_chapters.json" for b in ARABIC_BOOKS}
WIKISOURCE_NOTE = (
    "Arabic Wikisource (Bayanat-Labs/arabic-wikisource-pd, "
    "arwikisource-20261001), CC BY-SA 4.0 — original text public domain, "
    "digitisation / ordering CC BY-SA 4.0"
)
UNCLASSIFIED_TITLE = "غير مصنّف"
AHMAD_MISSING_TITLE = "مسند (بلا عنوان جماعي موثق)"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def kitab_label(title: str) -> str:
    """Display label for a kitab title (no invented wording)."""
    t = (title or "").strip()
    if not t:
        return "كتاب (بلا عنوان موثق في المصدر)"
    if t.startswith(("كتاب", "أبواب", "مسند", "باب", "المقدمة")):
        return t
    return f"كتاب {t}"


def bab_display_title(kitab_title: str, bab_title: str) -> str:
    """One flat chapter title carrying kitab <- bab (Dart reads title)."""
    kl = kitab_label(kitab_title)
    b = (bab_title or "").strip()
    if b.startswith("باب"):
        return f"{kl} — {b}"
    if b:
        return f"{kl} — باب {b}"
    return kl


def ordered_headings(tree: dict) -> list[dict]:
    """All kitab/bab heading events in reading order.

    Sorted by (line_no, tree order): the tree list order is reading
    order except for interleaved inline sub-headings (Tirmidhi الوتر /
    العيدين inside أبواب الصلاة; Bukhari inline kutub), which the
    line_no sort puts back in place. Within one shared line (Bukhari
    long lines hold several headings) the tree order is the text order.
    """
    events: list[dict] = []
    for ki, k in enumerate(tree["tree"]):
        events.append({
            "kind": "kitab", "kitab_idx": ki, "bab_idx": None,
            "line_no": k.get("line_no", 0), "order": (ki, -1),
            "kitab_title": k.get("kitab_title"),
            "kitab_title_raw": k.get("kitab_title_raw"),
        })
        for bi, b in enumerate(k.get("babs", [])):
            events.append({
                "kind": "bab", "kitab_idx": ki, "bab_idx": bi,
                "line_no": b.get("line_no", 0), "order": (ki, bi),
                "kitab_title": k.get("kitab_title"),
                "bab_title": b.get("bab_title"),
                "bab_title_raw": b.get("bab_title_raw"),
            })
    events.sort(key=lambda e: (e["line_no"], e["order"]))
    return events


def build_chapter_rows(book: str, mapping: dict, repairs: dict) -> tuple[list[dict], dict]:
    """Build the Arabic chapter rows for one book.

    ``mapping``: {"mapping": {urn: [kitab_idx, bab_idx]},
    "pair_title_en": {"ki:bi": old English title}, ...} with
    bab_idx -1 = kitab-level, -2 = unclassified (never a row).
    ``repairs``: {"book": {"ki:bi": {"repaired": str, ...}}}.

    Returns (rows, key_to_id) where rows are dicts ready for INSERT
    into chapters and key_to_id maps (kitab_idx, bab_idx) -> new id
    (bab_idx -1 = the kitab-level row id).
    """
    sort = BOOK_SORT[book]
    tree = load_json(CHAPTERS_DIR / TREE_FILES[book])
    book_repairs = repairs.get(book, {})
    rows: list[dict] = []
    key_to_id: dict[tuple[int, int], int] = {}

    # Which (kitab_idx, bab_idx) pairs actually occur. The majority
    # old-English title per pair is precomputed in the mapping file
    # (pair_title_en) from the pilot DB's English chapters.
    pair_en = mapping.get("pair_title_en", {})

    if book == "ahmad":
        # Masanid, not abwab: one row per top-level musnad (20).
        top = tree["top_level"]
        num = 0
        rows.append({
            "id": sort * 10000, "book": book, "num": 0,
            "title": UNCLASSIFIED_TITLE, "title_en": "",
            "title_lang": "ar",
            "title_source": "SUNNATI: hadiths with no verified musnad "
                            "assignment (unmatched by the range map)",
        })
        key_to_id[("unclassified",)] = sort * 10000
        for ki, m in enumerate(top):
            num += 1
            title = m.get("musnad_title")
            if title is None:
                title = AHMAD_MISSING_TITLE
                src = (WIKISOURCE_NOTE + f" — musnad #{ki + 1}, range "
                       f"{m['hadith_range'][0]}–{m['hadith_range'][1]}: "
                       "NO verified collective title in the source "
                       "(recorded MISSING; the pages keep the title "
                       "«مسند الأنصار» but the colophon proves الأنصار "
                       "ended at 22882; inner headings: حديث السيدة "
                       "عائشة 22883–25208, then فاطمة وأمهات المؤمنين "
                       "25209–25900 — see migration plan; nothing invented)")
            else:
                src = (WIKISOURCE_NOTE + f" — musnad #{ki + 1}, range "
                       f"{m['hadith_range'][0]}–{m['hadith_range'][1]}")
            rows.append({
                "id": sort * 10000 + num, "book": book, "num": num,
                "title": title, "title_en": "",
                "title_lang": "ar", "title_source": src,
            })
            key_to_id[(ki, -1)] = sort * 10000 + num
        return rows, key_to_id

    events = ordered_headings(tree)
    # Kitabs needing a kitab-level row: zero-bab kitabs, plus any kitab
    # with >= 1 hadith mapped to (ki, -1).
    mapped_pairs = {
        (int(k[0]), int(k[1]))
        for k in mapping.get("mapping", {}).values()
    }
    kitab_level_needed: set[int] = set()
    for ki, k in enumerate(tree["tree"]):
        if not k.get("babs"):
            kitab_level_needed.add(ki)
    for (ki, bi) in mapped_pairs:
        if bi == -1:
            kitab_level_needed.add(ki)

    # «غير مصنّف» row first (num 0), like the old scheme.
    rows.append({
        "id": sort * 10000, "book": book, "num": 0,
        "title": UNCLASSIFIED_TITLE, "title_en": "",
        "title_lang": "ar",
        "title_source": "SUNNATI: hadiths with no verified bab "
                        "assignment (unmatched by text-matching; "
                        "never assigned an invented bab)",
    })
    key_to_id[("unclassified",)] = sort * 10000

    num = 0
    current_kitab_title: str | None = None
    for ev in events:
        ki = ev["kitab_idx"]
        if ev["kind"] == "kitab":
            current_kitab_title = ev["kitab_title"]
            if ki in kitab_level_needed:
                num += 1
                kt = ev["kitab_title"]
                nb = len(tree["tree"][ki].get("babs", []))
                note = ("kitab-level row: this kitab has no bab "
                        "headings in the source" if nb == 0 else
                        "kitab-level row: these hadiths sit directly "
                        "under the kitab, before its first bab heading")
                rows.append({
                    "id": sort * 10000 + num, "book": book, "num": num,
                    "title": kitab_label(kt), "title_en": "",
                    "title_lang": "ar",
                    "title_source": f"{WIKISOURCE_NOTE} — kitab #{ki + 1}; {note}",
                })
                key_to_id[(ki, -1)] = sort * 10000 + num
            continue
        # bab event: parent title from the tree nesting (not from the
        # preceding kitab event — Tirmidhi Friday/Traveling babs revert
        # to their parent أبواب الصلاة even though الوتر/العيدين
        # headings interleave in line order).
        bi = ev["bab_idx"]
        num += 1
        kt = ev["kitab_title"]
        bt = ev["bab_title"]
        rep = book_repairs.get(f"{ki}:{bi}")
        title_source_extra = ""
        if rep:
            bt = rep["repaired"]
            title_source_extra = (
                " — title repaired verbatim from the source heading "
                "line (tree title was truncated/swallowed hadith text: "
                f"{rep['original']!r})"
            )
        en = pair_en.get(f"{ki}:{bi}", "")
        rows.append({
            "id": sort * 10000 + num, "book": book, "num": num,
            "title": bab_display_title(kt, bt),
            "title_en": en, "title_lang": "ar",
            "title_source": (f"{WIKISOURCE_NOTE} — kitab #{ki + 1}, "
                             f"bab #{bi + 1}{title_source_extra}"),
        })
        key_to_id[(ki, bi)] = sort * 10000 + num
    return rows, key_to_id


def apply_arabic_chapters(con: sqlite3.Connection, log: dict | None = None,
                          update_meta: bool = False) -> dict:
    """Replace the 7 books' English chapters with Arabic ones, in place.

    Works on a fresh build (English chapters just created) or on a copy
    of an existing DB. Refuses when Arabic chapters are already
    installed. Returns a per-book stats dict (also merged into ``log``
    when given). ``update_meta`` rewrites meta.chapters_note in place
    (standalone use); build_db.py passes False and writes meta itself.
    """
    if log is None:
        log = {}
    stats: dict = {}
    repairs = {}
    repairs_path = CHAPTERS_DIR / "title_repairs.json"
    if repairs_path.exists():
        repairs = load_json(repairs_path)

    # Guard: already imported?
    already = con.execute(
        "SELECT COUNT(*) FROM chapters WHERE title_source LIKE "
        "'%arabic-wikisource%'"
    ).fetchone()[0]
    if already:
        raise RuntimeError(
            f"Arabic chapters already installed ({already} rows with "
            "arabic-wikisource provenance) — start from a fresh build / "
            "fresh copy of the pilot DB to re-run the import."
        )

    # Backup table (idempotent: old chapter ids are the PK).
    con.execute(
        "CREATE TABLE IF NOT EXISTS chapters_backup_v4_en ("
        "  id INTEGER PRIMARY KEY, book TEXT NOT NULL, num INTEGER NOT NULL,"
        "  title TEXT NOT NULL, title_en TEXT NOT NULL DEFAULT '',"
        "  title_lang TEXT NOT NULL DEFAULT '',"
        "  title_source TEXT NOT NULL DEFAULT '',"
        "  backed_up_at TEXT NOT NULL DEFAULT '')"
    )
    from datetime import datetime, timezone
    backed_at = datetime.now(timezone.utc).isoformat()
    con.execute(
        "INSERT OR IGNORE INTO chapters_backup_v4_en "
        "(id, book, num, title, title_en, title_lang, title_source, backed_up_at) "
        "SELECT id, book, num, title, title_en, title_lang, title_source, ? "
        "FROM chapters WHERE book IN "
        "('bukhari','muslim','abudawud','tirmidhi','ibnmajah','ahmad','darimi')",
        (backed_at,),
    )
    n_backed = con.execute(
        "SELECT COUNT(*) FROM chapters_backup_v4_en"
    ).fetchone()[0]

    for book in ARABIC_BOOKS:
        sort = BOOK_SORT[book]
        tree_path = CHAPTERS_DIR / TREE_FILES[book]
        map_path = CHAPTERS_DIR / MAPPING_FILES[book]
        if not tree_path.exists() or not map_path.exists():
            raise FileNotFoundError(
                f"missing chapters source for {book}: {tree_path} / {map_path}"
            )
        mapping = load_json(map_path)
        # Drift guard: mapping must come from the current tree file.
        tree_sha = sha256_file(tree_path)
        if mapping.get("meta", {}).get("tree_sha256") != tree_sha:
            raise RuntimeError(
                f"{book}: mapping {map_path.name} was derived from a "
                "different tree file (sha mismatch) — re-run the "
                "derivation before importing."
            )
        rows, key_to_id = build_chapter_rows(book, mapping, repairs)

        # Replace chapters for this book.
        con.execute("DELETE FROM chapters WHERE book = ?", (book,))
        con.executemany(
            "INSERT INTO chapters (id, book, num, title, title_en, "
            "title_lang, title_source) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [(r["id"], r["book"], r["num"], r["title"], r["title_en"],
              r["title_lang"], r["title_source"]) for r in rows],
        )

        # Re-link hadiths: everything to «غير مصنّف» first, then the map.
        uncl_id = sort * 10000
        con.execute(
            "UPDATE hadiths SET chapter_id = ? WHERE book = ?",
            (uncl_id, book),
        )
        pairs = mapping.get("mapping", {})
        updates: list[tuple[int, int]] = []
        missing_urns: list[int] = []
        for urn_s, pair in pairs.items():
            urn = int(urn_s)
            key = (int(pair[0]), int(pair[1]))
            cid = key_to_id.get(key)
            if cid is None:
                missing_urns.append(urn)
                continue
            updates.append((cid, urn))
        con.executemany(
            "UPDATE hadiths SET chapter_id = ? WHERE id = ?", updates
        )
        # Hadiths of this book absent from the mapping entirely stay
        # «غير مصنّف» (counted below).
        n_total = con.execute(
            "SELECT COUNT(*) FROM hadiths WHERE book = ?", (book,)
        ).fetchone()[0]
        n_linked = con.execute(
            "SELECT COUNT(*) FROM hadiths WHERE book = ? AND chapter_id != ?",
            (book, uncl_id),
        ).fetchone()[0]
        n_uncl = n_total - n_linked
        n_unmatched_listed = len(mapping.get("unmatched_urns", []))
        # Orphan check: every hadith must point at an existing chapter.
        orphans = con.execute(
            "SELECT COUNT(*) FROM hadiths h LEFT JOIN chapters c "
            "ON c.id = h.chapter_id WHERE h.book = ? AND c.id IS NULL",
            (book,),
        ).fetchone()[0]
        if orphans:
            raise RuntimeError(f"{book}: {orphans} hadiths point at "
                               "missing chapters after re-linking")
        stats[book] = {
            "rows_created": len(rows),
            "bab_rows": sum(1 for r in rows if r["num"] > 0),
            "hadiths_total": n_total,
            "hadiths_linked": n_linked,
            "hadiths_unclassified": n_uncl,
            "mapping_entries": len(pairs),
            "mapping_unmatched_listed": n_unmatched_listed,
            "mapping_keys_without_row": len(missing_urns),
            "orphan_chapter_ids": orphans,
            "tree_file": TREE_FILES[book],
            "mapping_file": MAPPING_FILES[book],
        }
        print(f"  {book}: {len(rows)} Arabic chapter rows, "
              f"{n_linked}/{n_total} hadiths linked, "
              f"{n_uncl} unclassified")

    stats["chapters_backed_up_en"] = n_backed
    log["arabic_chapters"] = stats
    if update_meta:
        note = (
            "Arabic chapters (kitab <- bab) for 7 books from Arabic "
            "Wikisource (Bayanat-Labs/arabic-wikisource-pd, "
            "arwikisource-20261001), CC BY-SA 4.0; original text public "
            "domain. Nasai/Malik keep English titles (no verified source) "
            "tagged «غير مترجم». Old English rows preserved in "
            "chapters_backup_v4_en. See SUNNATI_CHAPTERS_MIGRATION_PLAN_"
            "2026-11-26.md."
        )
        con.execute(
            "UPDATE meta SET value = ? WHERE key = 'chapters_note'", (note,)
        )
    return stats
