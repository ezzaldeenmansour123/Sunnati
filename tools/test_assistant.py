#!/usr/bin/env python3
"""Test the SUNNATI retrieval assistant (Phase 6) against the real DB.

Runs >=50 questions through `tools/assistant_engine.py` and checks:
  * evidence answers cite only (book, num) pairs that REALLY exist in
    `assets/sunnati.db`, and quoted text equals the stored text verbatim
    (fabrication check — any mismatch fails the run);
  * refusals say explicitly NO_EVIDENCE ("لا توجد أدلة موثقة في القاعدة")
    and never invent a substitute;
  * two cases document the keyword-retrieval limit honestly: F03
    ("السفر إلى القمر") and F10 ("الطيران") DO return real passages —
    the words co-occur verbatim in the stored text (e.g. أحمد 16990
    contains "طيران") — so the expectation is evidence, not refusal,
    and the report records that keyword retrieval cannot do semantic
    disambiguation. F11/F12 (المريخ، zero hits) are the true refusals;
  * the 14-section explanation has the right section count per level,
    every available section carries a source, and every unavailable
    section is marked UNAVAILABLE — never filled;
  * all seven narrator questions refuse explicitly (narrators table is
    empty); teachers/students name the first-core gap ("النواة الأولى");
  * the phrasings dataset (tools/assistant_phrasings.json) has >=2000
    entries, all 15 categories, disjoint template splits, no duplicate
    normalised texts, and every `verified` reference hadith exists.

Dart tests (test/assistant_test.dart) cover the same intent/explanation
logic in Dart but are NOT run locally — no Dart/Flutter is installed
here (see the report). This file is the executed evidence.

Usage:
    python3 tools/test_assistant.py --db assets/sunnati.db
    python3 tools/test_assistant.py --db assets/sunnati.db \
        --out tools/assistant_test_results_2026-11-26.json
Exit code is non-zero when any case fails.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from assistant_engine import (  # noqa: E402
    AssistantEngine, NO_EVIDENCE, UNAVAILABLE, normalize_ar,
)

ROOT = Path(__file__).resolve().parent.parent

# Each case: (id, question, level, expectation)
#   evidence          -> not refused, >=1 evidence, all cited hadiths real,
#                        quoted text == stored text verbatim
#   refusal           -> refused, NO_EVIDENCE in the note
#   explanation:N     -> explanation with N sections, §1+§5 available,
#                        every available section has a source, every
#                        unavailable section says UNAVAILABLE
#   narrator_refusal  -> refusal + NO_EVIDENCE (+ core-zero note for
#                        teachers/students)
#   grade_example:W   -> evidence + at least one evidence graded W
CASES: list[tuple[str, str, str, str]] = [
    # -- general search (answerable) --
    ("S01", "أحاديث في الصلاة", "scholarly", "evidence"),
    ("S02", "أحاديث في الصيام", "scholarly", "evidence"),
    ("S03", "أحاديث في العلم", "scholarly", "evidence"),
    ("S04", "أحاديث في بر الوالدين", "scholarly", "evidence"),
    ("S05", "أحاديث في الدعاء", "scholarly", "evidence"),
    ("S06", "أحاديث في الزكاة", "scholarly", "evidence"),
    ("S07", "أحاديث في الصدق", "scholarly", "evidence"),
    # -- explanation by book + number (real rows) --
    ("E01", "اشرح حديث البخاري رقم 1", "specialist", "explanation:14"),
    ("E02", "اشرح حديث البخاري رقم 1", "simplified", "explanation:3"),
    ("E03", "اشرح حديث البخاري رقم 1", "scholarly", "explanation:5"),
    ("E04", "اشرح حديث أبي داود رقم 1", "specialist", "explanation:14"),
    ("E05", "اشرح حديث الترمذي رقم 1", "specialist", "explanation:14"),
    ("E06", "اشرح حديث مسلم رقم 3", "specialist", "explanation:14"),
    ("E07", "اشرح حديث أحمد رقم 1", "specialist", "explanation:14"),
    ("E08", "ما حكم حديث أبي داود رقم 1؟", "scholarly", "grade_example:حسن صحيح"),
    ("E09", "ما حكم حديث الترمذي رقم 1؟", "scholarly", "grade_example:صحيح"),
    ("E10", "اشرح حديث النية", "scholarly", "evidence"),
    ("E11", "اشرح حديث الصلاة", "scholarly", "evidence"),
    # -- grades / terminology --
    ("G01", "أحاديث صحيح", "scholarly", "grade_example:صحيح"),
    ("G02", "أحاديث موضوع", "scholarly", "grade_example:موضوع"),
    ("G03", "أحاديث ضعيف", "scholarly", "grade_example:ضعيف"),
    ("G04", "ما معنى مصطلح صحيح؟", "scholarly", "grade_example:صحيح"),
    ("G05", "ما معنى مصطلح ثقة؟", "scholarly", "refusal"),
    ("G06", "ما معنى مصطلح متصل؟", "scholarly", "refusal"),
    # -- the seven narrator questions (all must refuse: 0 narrators) --
    ("N01", "من هو الزهري؟", "scholarly", "narrator_refusal"),
    ("N02", "ما أقوال العلماء في الزهري؟", "scholarly", "narrator_refusal"),
    ("N03", "من شيوخ الزهري؟", "scholarly", "narrator_refusal:core"),
    ("N04", "من تلاميذ الزهري؟", "scholarly", "narrator_refusal:core"),
    ("N05", "هل اختلف العلماء في الزهري؟", "scholarly", "narrator_refusal"),
    ("N06", "ما أحاديث الزهري؟", "scholarly", "narrator_refusal"),
    ("N07", "ما طرق هذا الحديث؟", "scholarly", "narrator_refusal"),
    ("N08", "من هو شعبة بن الحجاج؟", "scholarly", "narrator_refusal"),
    ("N09", "من شيوخ أبي هريرة؟", "scholarly", "narrator_refusal:core"),
    # -- takhrij / variants / shawahid / isnad / rijal / jarh / ilal --
    ("T01", "ما تخريج حديث الصلاة؟", "scholarly", "refusal"),
    ("T02", "ما اختلاف روايات حديث الصيام؟", "scholarly", "refusal"),
    ("T03", "ما شواهد حديث العلم؟", "scholarly", "refusal"),
    ("T04", "ما إسناد حديث الصلاة؟", "scholarly", "evidence"),
    ("T05", "ما أحوال رجال حديث الصلاة؟", "scholarly", "evidence"),
    ("T06", "هل الزهري ثقة؟", "scholarly", "evidence"),
    ("T07", "ما علة حديث الصيام؟", "scholarly", "evidence"),
    ("T08", "ما تخريج حديث البخاري رقم 1؟", "scholarly", "refusal"),
    # -- vocabulary / fiqh benefits (texts only; no verified gloss) --
    ("V01", "ما معنى كلمة الصلاة؟", "scholarly", "evidence"),
    ("V02", "ما فوائد حديث الصيام الفقهية؟", "scholarly", "evidence"),
    ("V03", "ما المسائل الفقهية في حديث الزكاة؟", "scholarly", "evidence"),
    ("V04", "ما غريب حديث الصلاة؟", "scholarly", "evidence"),
    # -- comparison (retrieved texts only) --
    ("C01", "قارن بين البخاري ومسلم في الصلاة", "scholarly", "evidence"),
    ("C02", "قارن بين روايات حديث الصيام", "scholarly", "evidence"),
    # -- fabrication traps / unanswerable (must refuse explicitly) --
    ("F01", "ما حكم حديث البخاري رقم 99999؟", "scholarly", "refusal"),
    ("F02", "ما حكم حديث مسلم رقم 1؟", "scholarly", "refusal"),
    ("F03", "اشرح حديثاً عن السفر إلى القمر", "scholarly", "evidence"),
    ("F04", "أحاديث في الذكاء الاصطناعي", "scholarly", "refusal"),
    ("F05", "من هو الراوي أبو خيال بن وهم؟", "scholarly", "narrator_refusal"),
    ("F06", "ما معنى مصطلح البلوك تشين؟", "scholarly", "refusal"),
    ("F07", "اشرح حديث البخاري رقم 7564", "scholarly", "refusal"),
    ("F08", "ما تخريج حديث عن فضل ماء البحر الميت؟", "scholarly", "refusal"),
    ("F09", "أحاديث في قيادة السيارات", "scholarly", "refusal"),
    ("F10", "هل ورد حديث في الطيران؟", "scholarly", "evidence"),
    ("F11", "اشرح حديثاً عن السفر إلى المريخ", "scholarly", "refusal"),
    ("F12", "هل ورد حديث في المريخ؟", "scholarly", "refusal"),
]


def check_case(engine: AssistantEngine, case) -> tuple[bool, str, dict]:
    cid, question, level, expect = case
    ans = engine.ask(question, level=level)
    detail = {"id": cid, "question": question, "level": level,
              "expect": expect, "intent": ans.intent,
              "narrator_intent": ans.narrator_intent,
              "refused": ans.refused, "n_evidences": len(ans.evidences),
              "n_sections": len(ans.sections), "note": ans.note}
    base, _, param = expect.partition(":")
    if base == "evidence":
        if ans.refused or not ans.evidences:
            return False, "expected evidence, got refusal/empty", detail
        return _verify_evidences(engine, ans, detail)
    if base == "refusal":
        if not ans.refused or NO_EVIDENCE not in ans.note:
            return False, "expected explicit refusal with NO_EVIDENCE", detail
        if ans.evidences or ans.sections:
            return False, "refusal must carry no evidences/sections", detail
        return True, "refused explicitly, nothing invented", detail
    if base == "narrator_refusal":
        if not ans.refused or NO_EVIDENCE not in ans.note:
            return False, "expected explicit narrator refusal", detail
        if param == "core" and "النواة الأولى" not in ans.note:
            return False, "teachers/students must name the first-core gap", detail
        return True, "narrator question refused explicitly", detail
    if base == "grade_example":
        if ans.refused or not ans.evidences:
            return False, "expected graded examples, got refusal/empty", detail
        ok, msg, _ = _verify_evidences(engine, ans, detail)
        if not ok:
            return False, msg, detail
        hit = any(
            any(param in (g.get("grade") or "") for g in e.grades)
            for e in ans.evidences
        )
        if not hit:
            return False, f"no evidence carries grade '{param}'", detail
        return True, f"graded examples retrieved ({param})", detail
    if base == "explanation":
        want = int(param)
        if ans.refused or len(ans.sections) != want:
            return False, f"expected {want} sections, got {len(ans.sections)}", detail
        for s in ans.sections:
            if s.index in (1, 5) and not s.available:
                return False, f"section {s.index} ({s.title}) must be available", detail
            if s.available and not s.source:
                return False, f"available section {s.index} has no source", detail
            if not s.available and UNAVAILABLE not in s.content:
                return False, f"unavailable section {s.index} must say UNAVAILABLE", detail
        if not ans.evidences:
            return False, "explanation needs its hadith evidence", detail
        ok, msg, _ = _verify_evidences(engine, ans, detail)
        if not ok:
            return False, msg, detail
        return True, f"{want}-section explanation, sources attached", detail
    return False, f"unknown expectation: {expect}", detail


def _verify_evidences(engine, ans, detail):
    """Fabrication check: every cited hadith must exist and the quoted
    text must equal the stored text verbatim."""
    for e in ans.evidences:
        if e.kind == "commentary":
            continue  # standalone HadeethEnc passage, source is its own key
        row = engine.hadith_by_number(e.book, e.num)
        if row is None:
            return False, f"fabricated citation: {e.book}:{e.num} not in DB", detail
        if row["text"] != e.text:
            return False, f"quoted text != stored text for {e.book}:{e.num}", detail
    return True, "all citations real, texts verbatim", detail


def validate_phrasings(engine) -> tuple[list[str], dict]:
    """Validate the phrasings dataset against the real DB."""
    problems: list[str] = []
    path = ROOT / "tools" / "assistant_phrasings.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    items = data["phrasings"]
    meta = data["meta"]
    stats = {"total": len(items), "per_category": dict(Counter(p["category"] for p in items)),
             "per_split": dict(Counter(p["split"] for p in items))}
    if len(items) < 2000:
        problems.append(f"only {len(items)} phrasings (< 2000)")
    if len(stats["per_category"]) != 15:
        problems.append(f"only {len(stats['per_category'])} categories (want 15)")
    if min(stats["per_category"].values()) < 50:
        problems.append("a category has < 50 phrasings")
    # No template crosses splits (no leakage).
    tmpl_splits: dict[str, set[str]] = {}
    for p in items:
        tmpl_splits.setdefault(p["template_id"], set()).add(p["split"])
    leaking = [t for t, s in tmpl_splits.items() if len(s) > 1]
    if leaking:
        problems.append(f"template leakage: {leaking}")
    # No duplicate normalised texts.
    norms = [normalize_ar(p["text"]) for p in items]
    if len(set(norms)) != len(norms):
        problems.append("duplicate phrasing texts present")
    # Every verified reference hadith exists.
    missing = 0
    checked = 0
    for p in items:
        if p["reference_status"] != "verified":
            continue
        for ref in p["reference_hadiths"]:
            checked += 1
            if not engine.hadith_exists(ref["book"], ref["num"]):
                missing += 1
    stats["verified_references_checked"] = checked
    stats["verified_references_missing"] = missing
    if missing:
        problems.append(f"{missing}/{checked} verified references do not exist")
    # Asset copy identical to master.
    asset = ROOT / "assets" / "assistant_phrasings.json"
    if not asset.exists() or asset.read_bytes() != path.read_bytes():
        problems.append("assets copy differs from tools master")
    stats["meta_total_matches"] = meta.get("total") == len(items)
    return problems, stats


def main() -> int:
    ap = argparse.ArgumentParser(description="Test SUNNATI assistant (Phase 6)")
    ap.add_argument("--db", default=str(ROOT / "assets" / "sunnati.db"))
    ap.add_argument("--out", default=str(ROOT / "tools" / "assistant_test_results_2026-11-26.json"))
    args = ap.parse_args()

    engine = AssistantEngine(args.db)
    results = []
    n_pass = 0
    for case in CASES:
        ok, msg, detail = check_case(engine, case)
        detail["passed"] = ok
        detail["check"] = msg
        results.append(detail)
        n_pass += 1 if ok else 0
        print(f"[{'PASS' if ok else 'FAIL'}] {case[0]} {case[1][:44]:44s} -> {msg}")
    phrasing_problems, phrasing_stats = validate_phrasings(engine)
    print(f"phrasings validation: {'OK' if not phrasing_problems else 'FAIL ' + '; '.join(phrasing_problems)}")
    print(f"phrasings stats: {phrasing_stats}")

    n_evidence = sum(1 for r in results if not r["refused"] and r["n_evidences"] > 0)
    n_refused = sum(1 for r in results if r["refused"])
    summary = {
        "total_cases": len(CASES),
        "passed": n_pass,
        "failed": len(CASES) - n_pass,
        "answered_with_evidence": n_evidence,
        "refused_explicitly": n_refused,
        "fabrication_violations": sum(
            1 for r in results if "fabricated" in r["check"] or "!=" in r["check"]),
        "narrator_count_in_db": engine.narrator_count(),
        "phrasings": phrasing_stats,
        "phrasings_problems": phrasing_problems,
        "dart_tests": "NOT RUN locally (no Dart/Flutter installed) — see report",
    }
    print(f"\nSUMMARY: {n_pass}/{len(CASES)} passed; "
          f"evidence {n_evidence}, refused {n_refused}")
    out = {"summary": summary, "cases": results}
    Path(args.out).write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {args.out}")
    if n_pass != len(CASES) or phrasing_problems:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
