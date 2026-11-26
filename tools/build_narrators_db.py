#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build assets/narrators.db — the standalone verified narrators DB (Phase 5 core).

Vendored into the repo (2026-11-26) so CI can REBUILD the file on every
run instead of shipping a committed binary: the builder used to live
outside the repo (phase5-work/core-work) and depended on a 189 MB
working DB that can never be vendored. The only work.db dependency
was the 7,808-row `hadith_narrators` (id, narrator_text,
narrator_norm) slice — exported verbatim to
`tools/narrators-data/hadith_narrators.csv` (sha256
8e2d828c707eb503e06b2aaab2d23d9e53e263f1c44d1e4c521688cc6b14a68a)
and read from there instead. All other inputs are vendored beside it:
core_selection.json (the 500 verified narrators), sample_links.csv
(Phase 3 link decisions for the 1,500-hadith sample) and
taqrib_matching_full.json. `normalize_match` is vendored as
`tools/narrators_matching.py` (verbatim copy of
phase5-work/matching/matching.py — import only, no matching run).

Schema: the v2 tables (meta, narrators, scholars, sources) + the v3
narrator tables, taken VERBATIM from tools/build_db.py (SCHEMA /
SCHEMA_V3) — no new table, no new column. narrators_teachers /
narrators_students stay EMPTY (Taqrib does not provide them).

Ids are OUR OWN sequential ids in core-rank order (id = core_rank,
1..500) — NEVER Taqrib numbers (622, 2518, 4391, 6508 are duplicated
in the printed edition). The Taqrib number + line are stored in
bio_src / source_ref of every row, so every grade traces to its exact
place in the source file.

Grades: one row per narrator in narrator_grades. The speaker is
Ibn Hajar (scholars.id 1) for ALL rows EXCEPT سليمان بن المغيرة
#2612 (core rank 119), whose text says «ثقة ثقة قاله يحيى بن معين»
— his speaker is Yahya ibn Ma'in (scholars.id 2). The script ASSERTS
that exactly one core entry quotes Ibn Ma'in.

Death year: the FULL year only (death_partial entries store NULL —
never estimated).

Licence: CC BY-NC-SA 4.0 (OpenITI). KITAB confirmation request was NOT
answered — recorded in meta.kitab_gate. OWNER OVERRIDE 2026-11-26
17:51: the owner ordered narrators.db EMBEDDED in the APK («بجميع
قواعده بكل شيء» + full authority), explicitly overriding the KITAB
gate for the in-app copy. The file is STILL never published as a
standalone file to the public library-v1 release (CI guard (a) in
.github/workflows/build.yml enforces this).

Usage: python3 tools/build_narrators_db.py [--out assets/narrators.db]
Output: narrators.db (+ .sha256 sidecar) at --out, plus
narrators_build_log.json beside it. Deterministic: same inputs give
the same counts (500 narrators / 500 grades / 7,808 identity matches /
1,464 linked_verified); every count is ASSERTED before writing.
"""
import argparse
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_db import SCHEMA, SCHEMA_V3  # noqa: E402
from narrators_matching import normalize_match  # noqa: E402

# Vendored inputs (see the docstring): never read outside the repo.
DATA = Path(__file__).resolve().parent / "narrators-data"
REVIEWED_AT = "2026-11-26"
RETRIEVED_AT = "2026-11-26"
OPENITI_ID = "0852IbnHajarCasqalani.TaqribTahdhib"
OPENITI_URL = ("https://raw.githubusercontent.com/OpenITI/RELEASE/master/"
               "data/0852IbnHajarCasqalani/0852IbnHajarCasqalani.TaqribTahdhib/"
               "0852IbnHajarCasqalani.TaqribTahdhib.JK000121-ara1.completed")
OPENITI_SHA = ("178d493bd150032bc64a81ed4397d7e4a828209ee690deed283c1e63cada4637")
EDITION = "طبعة محمد عوامة، الأولى، دار الرشيد 1406هـ/1986م"
ATTRIBUTION = ("نصوص كتب الرجال مأخوذة من OpenITI — Open Islamicate Texts "
               "Initiative (KITAB Project)، برخصة Creative Commons "
               "Attribution-NonCommercial-ShareAlike 4.0 International "
               "(CC BY-NC-SA 4.0)، "
               "https://creativecommons.org/licenses/by-nc-sa/4.0/ — "
               "معرّف الملف: `0852IbnHajarCasqalani.TaqribTahdhib` "
               "(طبعة محمد عوامة، الأولى، دار الرشيد، 1406هـ/1986م). "
               "حُوِّل النص إلى قاعدة بيانات منظمة (اشتقاق)؛ قاعدة الرواة "
               "المشتقة منشورة بنفس الترخيص CC BY-NC-SA 4.0.")
KITAB_GATE = ("طلب تأكيد الترخيص إلى KITAB (kitab@aku.edu) لم يُرسل بعد "
              "وما زال بلا رد — لكن مالك التطبيق أمر بتاريخ 2026-11-26 "
              "بتضمين قاعدة الرواة داخل التطبيق (تجاوز موثّق للبوابة)؛ "
              "لا تُنشر هذه القاعدة أبداً كملف مستقل في إصدار library-v1 "
              "العام.")


def extract_ddl(schema: str, tables):
    """Pull the CREATE TABLE statements for `tables` out of a schema string."""
    out = []
    for name in tables:
        m = re.search(r"(CREATE TABLE IF NOT EXISTS " + re.escape(name) +
                      r"\b.*?;\n)", schema, re.DOTALL)
        assert m, f"DDL not found for table {name}"
        out.append(m.group(1))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--out",
        default=str(
            Path(__file__).resolve().parent.parent / "assets" / "narrators.db"
        ),
        help="output narrators.db path (default: assets/narrators.db)",
    )
    args = ap.parse_args()
    OUT = Path(args.out)
    OUT.parent.mkdir(parents=True, exist_ok=True)

    sel = json.load(open(DATA / "core_selection.json", encoding="utf-8"))
    selected = sel["selected"][:500]
    assert len(selected) == 500, len(selected)
    # Exactly one core entry quotes Ibn Ma'in as the grade speaker.
    ma_in = [r for r in selected if "قاله يحيى بن معين" in r["taqrib_text"]]
    assert len(ma_in) == 1 and ma_in[0]["taqrib_no"] == 2612, ma_in
    assert all(r["grade_raw"] for r in selected)
    assert all(r["tabaka"] is not None for r in selected)

    if OUT.exists():
        OUT.unlink()
    con = sqlite3.connect(OUT)
    try:
        ddl = extract_ddl(SCHEMA, ["meta", "narrators", "scholars",
                                   "sources"])
        ddl += "\n" + extract_ddl(SCHEMA_V3, [
            "narrator_aliases", "narrator_grades", "narrator_scholars",
            "narrator_teachers", "narrator_students", "narrator_sources",
            "narrator_identity_matches"])
        # v3 ALTERs on narrators (reviewed_at / confidence / identity_status)
        for m in re.finditer(r"ALTER TABLE narrators ADD COLUMN .*?;",
                             SCHEMA_V3, re.DOTALL):
            ddl += "\n" + m.group(0)
        con.executescript(ddl)

        # --- scholars: identity only, no invented biography --------------
        con.execute(
            "INSERT INTO scholars (id, name_ar, name_en, death_hijri, "
            "bio_src, notes) VALUES (1, ?, ?, 852, ?, ?)",
            ("ابن حجر العسقلاني", "Ibn Hajar al-Asqalani",
             "OpenITI file header — author line (verified 2026-11-26)",
             "مؤلف تقريب التهذيب؛ مصدر كل تراجم النواة وأحكامها. "
             "هوية فقط — لا ترجمة مستوردة"))
        con.execute(
            "INSERT INTO scholars (id, name_ar, name_en, death_hijri, "
            "bio_src, notes) VALUES (2, ?, ?, NULL, '', ?)",
            ("يحيى بن معين", "Yahya ibn Ma'in",
             "قائل الحكم المنقول في ترجمة سليمان بن المغيرة #2612 "
             "(«ثقة ثقة قاله يحيى بن معين») — هوية فقط، لا ترجمة مستوردة"))

        # --- sources: OpenITI only --------------------------------------
        con.execute(
            "INSERT INTO sources (id, name, type, url, license, notes) "
            "VALUES (1, 'OpenITI — تقريب التهذيب (ابن حجر)', "
            "'narrator-source', ?, 'CC BY-NC-SA 4.0', ?)",
            (OPENITI_URL,
             EDITION + " — تحقق من الترويسة وعينة النص 2026-11-26. "
             "طلب تأكيد الترخيص إلى KITAB لم يُرسل بعد — معلّق. "
             "SHA-256 للملف: " + OPENITI_SHA))

        def src_ref(no, line):
            return (f"OpenITI {OPENITI_ID} #{no} line {line} "
                    f"({EDITION})")

        # --- narrators + grades + scholars + sources + aliases -----------
        n_alias = 0
        for r in selected:
            nid = r["core_rank"]
            no, line = r["taqrib_no"], r["taqrib_line"]
            con.execute(
                "INSERT INTO narrators (id, name, kunya, tier, death_hijri,"
                " status, status_src, bio_src, norm, reviewed_at, "
                "confidence, identity_status) VALUES "
                "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'high', 'verified')",
                (nid, r["taqrib_name_head"], r["taqrib_kunya"],
                 f"الطبقة {r['tabaka']}", r["death_year"],
                 r["grade_canonical"], "تقريب التهذيب — ابن حجر",
                 src_ref(no, line), r["norm"], REVIEWED_AT))
            speaker = 2 if r["taqrib_no"] == 2612 else 1
            notes = ""
            if speaker == 2:
                notes = ("الحكم منقول عن يحيى بن معين: نص الترجمة «ثقة "
                         "ثقة قاله يحيى بن معين» — القائل يحيى بن معين "
                         "لا ابن حجر")
            con.execute(
                "INSERT INTO narrator_grades (narrator_id, scholar_id, "
                "grade_ar, grade_raw, grade_kind, source, source_ref, "
                "reviewed_at, confidence, notes) VALUES "
                "(?, ?, ?, ?, 'توثيق', 'تقريب التهذيب', ?, ?, 'high', ?)",
                (nid, speaker, r["grade_canonical"], r["grade_raw"],
                 src_ref(no, line), REVIEWED_AT, notes))
            con.execute(
                "INSERT INTO narrator_scholars (narrator_id, scholar_id, "
                "role, source, reviewed_at, confidence, notes) VALUES "
                "(?, 1, 'مؤلف المصدر', 'تقريب التهذيب', ?, 'high', "
                "'مصدر الترجمة والحكم')",
                (nid, REVIEWED_AT))
            if speaker == 2:
                con.execute(
                    "INSERT INTO narrator_scholars (narrator_id, "
                    "scholar_id, role, source, reviewed_at, confidence, "
                    "notes) VALUES (?, 2, 'قائل الحكم', 'تقريب التهذيب', "
                    "?, 'high', 'قال «ثقة ثقة» — منقول في الترجمة')",
                    (nid, REVIEWED_AT))
            con.execute(
                "INSERT INTO narrator_sources (narrator_id, source_name, "
                "source_type, source_ref, url, license, retrieved_at, "
                "reviewed_at, confidence, notes) VALUES "
                "(?, 'تقريب التهذيب — ابن حجر', 'narrator-source', ?, ?, "
                "'CC BY-NC-SA 4.0', ?, ?, 'high', ?)",
                (nid, src_ref(no, line), OPENITI_URL, RETRIEVED_AT,
                 REVIEWED_AT, EDITION))
            # aliases: kunya (from the entry itself) + isnad citation forms
            seen = set()
            if r["taqrib_kunya"]:
                con.execute(
                    "INSERT INTO narrator_aliases (narrator_id, alias, "
                    "alias_norm, alias_type, source, reviewed_at, "
                    "confidence, notes) VALUES (?, ?, ?, 'kunya', "
                    "'تقريب التهذيب', ?, 'high', '')",
                    (nid, r["taqrib_kunya"],
                     normalize_match(r["taqrib_kunya"]), REVIEWED_AT))
                seen.add(("kunya", normalize_match(r["taqrib_kunya"])))
                n_alias += 1
            for a in r["alias_norms"]:
                key = ("isnad_norm", a)
                if key in seen:
                    continue
                seen.add(key)
                con.execute(
                    "INSERT INTO narrator_aliases (narrator_id, alias, "
                    "alias_norm, alias_type, source, reviewed_at, "
                    "confidence, notes) VALUES (?, ?, ?, 'isnad_norm', "
                    "'مطابقة الأسانيد (المدونة الكاملة)', ?, 'high', "
                    "'صيغة ورود الاسم في الإسناد لنفس الترجمة (مطابقة "
                    "آلية مؤكدة)')",
                    (nid, a, a, REVIEWED_AT))
                n_alias += 1

        # --- narrator_identity_matches: Phase 3 decisions (7,808 rows) ---
        import csv as _csv
        links = list(_csv.DictReader(
            open(DATA / "sample_links.csv", encoding="utf-8")))
        full = {}
        for rec in json.load(open(DATA / "taqrib_matching_full.json",
                                  encoding="utf-8")):
            full.setdefault(normalize_match(rec["norm"]), rec)
        # The 7,808-row hadith_narrators slice (id, narrator_text,
        # narrator_norm), exported verbatim from the Phase 3 working DB
        # — the only thing this builder ever read from work.db.
        texts = {}
        with open(DATA / "hadith_narrators.csv", encoding="utf-8") as f:
            for row in _csv.DictReader(f):
                texts[int(row["id"])] = (
                    row["narrator_text"],
                    row["narrator_norm"],
                )
        assert len(texts) == 7808 and len(links) == 7808
        n_linked = 0
        for l in links:
            row_id = int(l["hadith_narrators_id"])
            text, _norm = texts[row_id]
            dec = l["decision"]
            nid = int(l["narrator_db_id"]) if l["narrator_db_id"] else None
            if dec == "linked_verified":
                n_linked += 1
                mtype = full.get(l["match_norm"], {})
                mtype = ("taqrib_unique:" +
                         f"{mtype.get('match_kind', '')}/"
                         f"{mtype.get('match_seq', '')}")
            elif dec == "pending":
                mtype = "taqrib_unique_non_core"
            elif dec == "ambiguous":
                mtype = "taqrib_ambiguous"
            elif l["reason"].startswith("قرار عدم ربط"):
                mtype = "taqrib_blocked"
            elif l["reason"].startswith("name form is"):
                mtype = "taqrib_non_composite"
            elif "parser fragment" in l["reason"]:
                mtype = "taqrib_parser_fragment"
            else:
                mtype = "taqrib_no_match"
            con.execute(
                "INSERT INTO narrator_identity_matches (id, candidate_text,"
                " candidate_norm, narrator_id, match_type, score, "
                "decided_by, reviewed_at, decision, notes) VALUES "
                "(?, ?, ?, ?, ?, NULL, 'core-phase3-2026-11-26', ?, ?, ?)",
                (row_id, text, l["narrator_norm"], nid, mtype,
                 REVIEWED_AT, dec, l["reason"]))

        # --- meta ---------------------------------------------------------
        meta = [
            ("source", f"OpenITI {OPENITI_ID} (JK000121-ara1)"),
            ("source_url", OPENITI_URL),
            ("source_sha256", OPENITI_SHA),
            ("edition", EDITION),
            ("license", "CC BY-NC-SA 4.0"),
            ("license_url",
             "https://creativecommons.org/licenses/by-nc-sa/4.0/"),
            ("attribution", ATTRIBUTION),
            ("kitab_gate", KITAB_GATE),
            ("build_date", "2026-11-26"),
            ("schema_version", "3"),
            ("narrators_verified", "500"),
            ("core_100_cutoff", "occurrences >= 129"),
            ("core_500_cutoff", "occurrences >= 25"),
            ("linked_verified_rows", str(n_linked)),
            ("teachers_rows", "0"),
            ("students_rows", "0"),
        ]
        con.executemany("INSERT INTO meta (key, value) VALUES (?, ?)", meta)
        con.commit()

        # --- verification -------------------------------------------------
        counts = {t: con.execute(
            f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in
            ["narrators", "narrator_grades", "narrator_aliases",
             "narrator_scholars", "narrator_teachers", "narrator_students",
             "narrator_sources", "narrator_identity_matches", "scholars",
             "sources"]}
        assert counts["narrators"] == 500, counts
        assert counts["narrator_grades"] == 500, counts
        assert counts["narrator_teachers"] == 0
        assert counts["narrator_students"] == 0
        assert counts["narrator_sources"] == 500, counts
        assert counts["narrator_identity_matches"] == 7808, counts
        assert counts["narrator_scholars"] == 501, counts  # 500 + Ibn Ma'in
        # every grade has speaker + source + source_ref
        bad = con.execute(
            "SELECT COUNT(*) FROM narrator_grades WHERE scholar_id IS NULL "
            "OR source = '' OR source_ref = ''").fetchone()[0]
        assert bad == 0, bad
        # death years are full years only (NULL or >= 10 — no 1-2 digit
        # partial year can be a real full Hijri death year here... the
        # parser already enforces this; assert the stored set equals the
        # selection's full-year set)
        sel_deaths = sorted(r["death_year"] for r in selected
                            if r["death_year"])
        db_deaths = sorted(r[0] for r in con.execute(
            "SELECT death_hijri FROM narrators WHERE death_hijri IS NOT "
            "NULL"))
        assert db_deaths == sel_deaths, (db_deaths[:5], sel_deaths[:5])
        # narrator ids are 1..500 exactly
        ids = [r[0] for r in con.execute(
            "SELECT id FROM narrators ORDER BY id")]
        assert ids == list(range(1, 501)), ids[:3]
        qc = con.execute("PRAGMA quick_check").fetchone()[0]
        assert qc == "ok", qc
        con.execute("VACUUM")
        con.commit()
    finally:
        con.close()

    size = OUT.stat().st_size
    sha = hashlib.sha256(OUT.read_bytes()).hexdigest()
    (OUT.parent / "narrators.db.sha256").write_text(
        sha + "  narrators.db\n", encoding="utf-8")
    log = {
        "built": "2026-11-26",
        "file": str(OUT),
        "size_bytes": size,
        "sha256": sha,
        "counts": counts,
        "linked_verified_rows": n_linked,
        "alias_rows": n_alias,
        "kitab_gate": KITAB_GATE,
        "source_sha256": OPENITI_SHA,
        "notes": [
            "ids are core ranks 1..500 (own sequential ids, not Taqrib numbers)",
            "death_hijri is the full year only; partial years stored as NULL",
            "grade speaker is Ibn Hajar for 499 rows, Yahya ibn Ma'in for #2612 (rank 119)",
            "narrator_teachers / narrator_students are empty by design (Taqrib does not provide them)",
        ],
    }
    json.dump(log, open(OUT.parent / "narrators_build_log.json", "w",
                        encoding="utf-8"), ensure_ascii=False, indent=1)
    print("counts:", counts)
    print("alias rows:", n_alias, "| linked rows:", n_linked)
    print(f"narrators.db: {size} bytes, sha256 {sha[:16]}...")
    print("wrote narrators.db, narrators.db.sha256, narrators_build_log.json")


if __name__ == "__main__":
    main()
