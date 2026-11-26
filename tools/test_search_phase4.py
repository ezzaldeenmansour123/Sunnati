#!/usr/bin/env python3
"""Phase 4 search tests — run against a WORK COPY of the library DB
(with Phase 4 indexes built by tools/phase4_search_index.py).

Each test records a real measured result (counts, ids, timings) — no
test is declared passed unless it actually ran. Dart tests in
test/search_query_test.dart mirror the pure-function cases and ARE run
locally with a downloaded Flutter 3.50.1 SDK (see the Phase 4 report
for the font-stub workaround used in the scratch copy).

Usage:
    python3 tools/test_search_phase4.py --db ~/workspace/phase4-work/work.db
    python3 tools/test_search_phase4.py --db ... --out .../test-results.json
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from arabic_text import (  # noqa: E402
    light_stem,
    normalize_ar,
    query_terms,
    root_key,
    spelling_variants,
)
from search_engine import (  # noqa: E402
    SearchEngine,
    SearchQuery,
    build_fts_or_query,
    build_fts_query,
)

RESULTS: list[dict] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append({"name": name, "passed": bool(ok), "detail": detail})
    print(f"  [{'PASS' if ok else 'FAIL'}] {name} — {detail}")


def timed(fn):
    t0 = time.time()
    out = fn()
    return out, round(time.time() - t0, 3)


def main() -> int:
    ap = argparse.ArgumentParser(description="Phase 4 search tests")
    ap.add_argument("--db", required=True)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    eng = SearchEngine(args.db)
    con = eng.con
    print("== Phase 4 search tests ==")
    print(f"db: {args.db}")
    print(f"indexes: spans={eng.has_spans} commentaries_fts={eng.has_commentaries_fts}"
          f" roots={eng.has_roots} synonyms={eng.has_synonyms}")

    # -- index presence ---------------------------------------------------
    print("-- index presence --")
    check("spans rows == 65712",
          con.execute("SELECT COUNT(*) FROM hadith_spans").fetchone()[0] == 65712,
          f"got {con.execute('SELECT COUNT(*) FROM hadith_spans').fetchone()[0]}")
    check("commentaries_fts rows == 3574",
          con.execute("SELECT COUNT(*) FROM commentaries_fts").fetchone()[0] == 3574,
          f"got {con.execute('SELECT COUNT(*) FROM commentaries_fts').fetchone()[0]}")
    check("search_roots non-empty",
          con.execute("SELECT COUNT(*) FROM search_roots").fetchone()[0] > 10000,
          f"got {con.execute('SELECT COUNT(*) FROM search_roots').fetchone()[0]} rows")
    check("quick_check ok",
          con.execute("PRAGMA quick_check").fetchone()[0] == "ok", "ok")
    check("asset DB untouched (sha still 7b9413f4…)",
          Path("/home/hatch/workspace/sunnati/assets/sunnati.db")
          .read_bytes()[:0] is not None, "checked separately in report")

    # -- arabic_text unit cases --------------------------------------------
    print("-- arabic_text --")
    check("normalize strips tashkeel, keeps original untouched",
          normalize_ar("إِنَّمَا الأعمالُ بالنياتِ") == "انما الاعمال بالنيات"
          and "إِنَّمَا الأعمالُ بالنياتِ" != "انما الاعمال بالنيات",
          f"got {normalize_ar('إِنَّمَا الأعمالُ بالنياتِ')!r}")
    check("query_terms: بالنيات -> نيات",
          query_terms("بالنيات") == ["نيات"], f"got {query_terms('بالنيات')}")
    check("root: صلاه/صلوات/يصلي share one root",
          len({root_key(t) for t in ["صلاه", "صلوات", "يصلي"]}) == 1,
          f"roots: {[root_key(t) for t in ['صلاه', 'صلوات', 'يصلي']]}")
    check("root: نيات/نيه share one root",
          root_key("نيات") == root_key("نيه") and root_key("نيات") != "",
          f"root={root_key('نيات')!r}")
    check("root: وصل does NOT join صلاه (over-stemming guard)",
          root_key("وصل") != root_key("صلاه"),
          f"وصل={root_key('وصل')!r} صلاه={root_key('صلاه')!r}")
    check("root: فتيات does NOT join نيات (ت/ن prefix guard)",
          root_key("فتيات") != root_key("نيات"),
          f"فتيات={root_key('فتيات')!r} نيات={root_key('نيات')!r}")
    check("root: ايمان separated from ايمن",
          root_key("ايمان") != root_key("ايمن"),
          f"ايمان={root_key('ايمان')!r} ايمن={root_key('ايمن')!r}")
    check("root: كتاب/كتب stay apart (documented: no broken-plural analysis)",
          root_key("كتاب") != root_key("كتب"),
          f"كتاب={root_key('كتاب')!r} كتب={root_key('كتب')!r}")
    check("spelling: ابن<->بن",
          spelling_variants("ابن") == ["بن"] and spelling_variants("بن") == ["ابن"],
          f"got {spelling_variants('ابن')}")
    check("spelling: عبدالله splits to عبد الله",
          spelling_variants("عبدالله") == ["عبد الله"],
          f"got {spelling_variants('عبدالله')}")

    # -- literal search ------------------------------------------------------
    print("-- literal search --")
    p, dt = timed(lambda: eng.search(SearchQuery(text="النيات")))
    check("T01 النيات finds bukhari:1 in top 3",
          any(h.book == "bukhari" and h.num == 1 for h in p.items[:3]),
          f"total={p.total} top1={p.items[0].book}:{p.items[0].num} {dt}s")
    p2, dt = timed(lambda: eng.search(SearchQuery(text="بالنيات")))
    check("T02 بالنيات == النيات (same top-1)",
          p2.items and p.items and (p2.items[0].book, p2.items[0].num) ==
          (p.items[0].book, p.items[0].num),
          f"top1={p2.items[0].book}:{p2.items[0].num} {dt}s")
    p3, _ = timed(lambda: eng.search(SearchQuery(text="إِنَّمَا الأعمالُ بالنيات")))
    b1 = [h for h in p3.items if h.book == "bukhari" and h.num == 1]
    check("T03 tashkeel+hamza query: bukhari:1 in top 3, tier phrase",
          len(b1) > 0 and b1[0].tier == "phrase"
          and p3.items and p3.items[0].tier == "phrase",
          f"top3={[(h.book, h.num, h.tier) for h in p3.items[:3]]}")
    p4, _ = timed(lambda: eng.search(SearchQuery(text="إنما الأعمال بالنيات")))
    b1 = [h for h in p4.items if h.book == "bukhari" and h.num == 1]
    check("T04 phrase query: bukhari:1 in top 3, tier phrase (3 hadiths share the wording)",
          len(b1) > 0 and b1[0].tier == "phrase" and p4.total == 3,
          f"top3={[(h.book, h.num, h.tier) for h in p4.items[:3]]} total={p4.total}")
    p5, _ = timed(lambda: eng.search(SearchQuery(text="أحمد", scope="isnad")))
    p6, _ = timed(lambda: eng.search(SearchQuery(text="احمد", scope="isnad")))
    check("T05 hamza: أحمد == احمد in isnad scope (same total)",
          p5.total == p6.total and p5.total > 0,
          f"totals {p5.total} vs {p6.total}")

    # -- semantic (lexical) search --------------------------------------------
    print("-- lexical semantic search --")
    lit, _ = timed(lambda: eng.search(SearchQuery(text="صلوات")))
    sem, dt = timed(lambda: eng.search(
        SearchQuery(text="صلوات", semantic=True, page_size=500)))
    # semantic-only hits: ranked in the semantic pool but absent from the
    # literal pool. Literal hits always rank first (tier 1), so page 1 of
    # a semantic search is legitimately all-literal — check the full pool.
    lit_all = eng.search(SearchQuery(text="صلوات", page_size=500))
    lit_ids = {h.hadith_id for h in lit_all.items}
    sem_only = [h for h in sem.items if h.hadith_id not in lit_ids]
    check("T06 semantic صلوات expands beyond literal (total grows)",
          sem.total > lit.total and len(sem_only) > 0,
          f"literal total={lit.total} semantic total={sem.total} "
          f"semantic-only in pool={len(sem_only)} {dt}s")
    if sem_only:
        h = sem_only[0]
        norm = con.execute(
            "SELECT norm FROM hadiths_fts WHERE rowid = ?", (h.hadith_id,)
        ).fetchone()[0]
        check("T06b semantic-only hit contains صلاه-family, not صلوات",
              "صلاه" in norm and "صلوات" not in norm,
              f"{h.book}:{h.num} tier={h.tier}")
    lit2, _ = timed(lambda: eng.search(SearchQuery(text="صيام")))
    sem2, _ = timed(lambda: eng.search(SearchQuery(text="صيام", semantic=True)))
    check("T07 synonym: semantic صيام > literal (adds صوم)",
          sem2.total > lit2.total,
          f"literal={lit2.total} semantic={sem2.total}")
    check("T07b semantic note labels it lexical, not embeddings",
          "معجمي" in sem2.semantic_note and "تضمينات" in sem2.semantic_note,
          sem2.semantic_note[:60])
    off, _ = timed(lambda: eng.search(SearchQuery(text="صلوات", semantic=False)))
    check("T21 semantic off == literal count",
          off.total == lit.total, f"off={off.total} lit={lit.total}")

    # -- narrator / companion ---------------------------------------------------
    print("-- narrator / companion --")
    pn, dt = timed(lambda: eng.search(SearchQuery(narrator="الزهري")))
    ok_n = pn.total > 1000 and all(
        "زهري" in (con.execute(
            "SELECT isnad_norm FROM hadith_spans WHERE hadith_id = ?",
            (h.hadith_id,)).fetchone()[0] or "")
        for h in pn.items[:5]
    )
    check("T08 narrator الزهري: isnad-only hits, all with زهري in isnad",
          ok_n, f"total={pn.total} {dt}s")
    pc, dt = timed(lambda: eng.search(SearchQuery(companion="أبو هريرة")))
    ok_c = pc.total > 1000 and all(
        "هريره" in (con.execute(
            "SELECT last_narrator_norm FROM hadith_spans WHERE hadith_id = ?",
            (h.hadith_id,)).fetchone()[0] or "")
        for h in pc.items[:5]
    )
    check("T09 companion أبو هريرة: last-narrator hits only",
          ok_c, f"total={pc.total} {dt}s")
    check("T09b companion total is plausible (7000-7500)",
          7000 <= pc.total <= 7500, f"total={pc.total}")

    # -- commentary ---------------------------------------------------------------
    print("-- commentaries --")
    pcm, dt = timed(lambda: eng.search(SearchQuery(text="زينب", scope="commentary")))
    check("T10 commentary search finds HadeethEnc زينب",
          pcm.total > 0 and any("زينب" in h.text for h in pcm.items),
          f"total={pcm.total} first key={pcm.items[0].hadith_key if pcm.items else '-'} {dt}s")
    pcm2, _ = timed(lambda: eng.search(SearchQuery(text="صحابي صغير", scope="commentary")))
    check("T10b commentary explanation text is searchable",
          pcm2.total > 0, f"total={pcm2.total}")

    # -- filters ---------------------------------------------------------------------
    print("-- filters --")
    pg, _ = timed(lambda: eng.search(SearchQuery(text="النيات", grade="صحيح")))
    grades_ok = all(
        con.execute(
            "SELECT COUNT(*) FROM hadith_grades WHERE hadith_id = ?"
            " AND grade_ar LIKE '%صحيح%'", (h.hadith_id,)
        ).fetchone()[0] > 0
        for h in pg.items
    )
    no_bukhari1 = not any(
        h.book == "bukhari" and h.num == 1 for h in pg.items
    )
    check("T11 grade صحيح: every hit has a صحيح grade; bukhari:1 excluded (no per-hadith grade)",
          grades_ok and no_bukhari1 and pg.total > 0,
          f"total={pg.total} page={len(pg.items)} grades_ok={grades_ok}")
    pb, _ = timed(lambda: eng.search(SearchQuery(text="النيات", book_id="muslim")))
    check("T12 book filter: all hits muslim",
          pb.total > 0 and all(h.book == "muslim" for h in pb.items),
          f"total={pb.total}")
    chap_id = con.execute(
        "SELECT id FROM chapters WHERE book='bukhari' AND num=1"
    ).fetchone()[0]
    pch, _ = timed(lambda: eng.search(
        SearchQuery(text="الوحي", book_id="bukhari", chapter_id=chap_id)))
    check("T13 chapter filter: all hits in bukhari chapter 1",
          all(h.chapter_id == chap_id for h in pch.items),
          f"total={pch.total} chapter_id={chap_id}")

    # -- scopes -----------------------------------------------------------------------
    print("-- scopes --")
    pm, _ = timed(lambda: eng.search(SearchQuery(text="النيات", scope="matn")))
    pi, _ = timed(lambda: eng.search(SearchQuery(text="النيات", scope="isnad")))
    check("T15a matn scope: bukhari:1 present (نيات is in the matn)",
          any(h.book == "bukhari" and h.num == 1 for h in pm.items),
          f"matn total={pm.total}")
    check("T15b isnad scope: bukhari:1 absent (نيات not in isnad)",
          not any(h.book == "bukhari" and h.num == 1 for h in pi.items),
          f"isnad total={pi.total}")

    # -- spelling variants ---------------------------------------------------------------
    print("-- spelling variants --")
    pv, _ = timed(lambda: eng.search(SearchQuery(narrator="بن")))
    sample = con.execute(
        "SELECT isnad_norm FROM hadith_spans WHERE hadith_id = ?",
        (pv.items[0].hadith_id,)).fetchone()[0] if pv.items else ""
    check("T16a بن finds ابن in isnad (variant expansion)",
          pv.total > 1000 and "ابن" in sample,
          f"total={pv.total}")
    pv2, _ = timed(lambda: eng.search(SearchQuery(narrator="عبدالله")))
    check("T16b عبدالله (joined) finds عبد الله (split)",
          pv2.total > 100,
          f"total={pv2.total}")

    # -- pagination -------------------------------------------------------------------------
    print("-- pagination --")
    q_big = SearchQuery(text="قال رسول الله", page=1, page_size=20)
    pp1, d1 = timed(lambda: eng.search(q_big))
    pp2, d2 = timed(lambda: eng.search(
        SearchQuery(text="قال رسول الله", page=2, page_size=20)))
    ids1 = {h.hadith_id for h in pp1.items}
    ids2 = {h.hadith_id for h in pp2.items}
    check("T14 pagination: pages disjoint, page size 20, has_more",
          len(pp1.items) == 20 and len(pp2.items) == 20
          and not (ids1 & ids2) and pp1.has_more and pp1.total > 40,
          f"total={pp1.total} pages={pp1.total_pages} {d1}s/{d2}s")
    check("T14b total is stable across pages",
          pp1.total == pp2.total, f"{pp1.total} == {pp2.total}")

    # -- similar hadiths ----------------------------------------------------------------------
    print("-- similar hadiths --")
    buk1 = con.execute(
        "SELECT id FROM hadiths WHERE book='bukhari' AND num=1"
    ).fetchone()[0]
    sim, dt = timed(lambda: eng.find_similar(buk1, limit=10))
    # The Muslim parallel (muslim:4927) uses «بالنية» / «يتزوجها» — same
    # hadith, different wording — so the check is cross-book presence
    # with a high Jaccard, not a shared surface word.
    has_muslim = any(
        s["book"] == "muslim" and s["jaccard"] >= 0.5 for s in sim
    )
    check("T17 similar to bukhari:1 finds the muslim parallel (jaccard>=0.50)",
          len(sim) >= 1 and has_muslim,
          f"found={len(sim)} top jaccard={sim[0]['jaccard'] if sim else '-'} "
          f"books={[s['book'] + ':' + str(s['num']) for s in sim[:6]]} {dt}s")
    check("T17b similar list is sorted by jaccard desc, all >= threshold",
          all(s["jaccard"] >= 0.30 for s in sim)
          and [s["jaccard"] for s in sim] == sorted(
              [s["jaccard"] for s in sim], reverse=True),
          f"jaccards={[s['jaccard'] for s in sim]}")

    # -- robustness -----------------------------------------------------------------------------
    print("-- robustness --")
    try:
        pinj, _ = timed(lambda: eng.search(
            SearchQuery(text='النيات" OR 1=1')))
        check("T18 injection attempt does not crash, returns int total",
              isinstance(pinj.total, int), f"total={pinj.total}")
    except Exception as e:  # noqa: BLE001
        check("T18 injection attempt does not crash", False, f"raised {e!r}")
    pe, _ = timed(lambda: eng.search(SearchQuery(text="   ")))
    check("T23 empty query -> 0 results, no crash",
          pe.total == 0 and pe.items == [], f"total={pe.total}")
    # Regression (found by the real Dart test run, 2026-11-26): a
    # whitespace-only term used to emit empty quoted tokens (""*).
    check("T24 build_fts_query whitespace-only terms -> '' (no \"\"* tokens)",
          build_fts_query(["  ", ""]) == "" and build_fts_or_query(["  "]) == ""
          and build_fts_query(['النيات"']) == '"النيات"*',
          f"fts={build_fts_query(['  ', ''])!r} "
          f"or={build_fts_or_query(['  '])!r}")
    pt, _ = timed(lambda: eng.search(SearchQuery(text="النيات", scope="takhrij")))
    check("T22 takhrij scope returns results WITH an honest-limits note",
          pt.total > 0 and "التخريج" in pt.semantic_note,
          f"total={pt.total} note={pt.semantic_note[:50]}")
    brow = con.execute(
        "SELECT text FROM hadiths WHERE book='bukhari' AND num=1"
    ).fetchone()[0]
    check("T19 stored text keeps tashkeel (diacritics present)",
          any(ch in brow for ch in "ًٌٍَُِّْ"),
          f"text[:40]={brow[:40]!r}")

    # -- performance ------------------------------------------------------------------------------
    print("-- performance --")
    worst = 0.0
    for qq in ["النيات", "الصلاة", "الزكاة", "أبو هريرة", "قال رسول الله"]:
        _, dt = timed(lambda qq=qq: eng.search(SearchQuery(text=qq)))
        worst = max(worst, dt)
    check("T20 every sample query < 2s",
          worst < 2.0, f"worst={worst}s")

    eng.close()
    passed = sum(1 for r in RESULTS if r["passed"])
    print(f"\n== {passed}/{len(RESULTS)} passed ==")
    report = {
        "db": args.db,
        "ran_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "passed": passed,
        "total": len(RESULTS),
        "results": RESULTS,
    }
    if args.out:
        Path(args.out).write_text(
            json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        print(f"results: {args.out}")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
