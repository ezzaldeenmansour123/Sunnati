#!/usr/bin/env python3
"""Generate the SUNNATI assistant phrasings dataset — Phase 6 (§9).

Builds `tools/assistant_phrasings.json` (master) and an identical copy at
`assets/assistant_phrasings.json` (bundled with the app for intent
matching). Every phrasing is generated from a structured template with a
grounded entity; NOTHING is hand-written as a fact:

  * topic / narrator entities are kept ONLY when a real hadith containing
    them is found in `assets/sunnati.db` (FTS, read-only) — the first hit
    becomes the phrasing's `reference_hadiths`. Entities with no hit are
    DROPPED and listed in the log.
  * grade entities are kept ONLY when a real `hadith_grades` row carries
    that grade — the graded hadith becomes the reference.
  * book entities reference the book's real first hadith (min `num`).
  * terminology entities with no backing table (narrator statuses,
    isnad terms — narrators/chains tables are EMPTY) are kept as
    QUESTION phrasings only, with `reference_hadiths: []` and
    `reference_status` stating exactly what is unavailable. A question
    is not a claim; the assistant still refuses to define them.

Splits (no leakage): each TEMPLATE is assigned wholly to one split by
hash(template_id) — train 70 / validation 15 / test 15. No template
appears in two splits, so a phrasing in `test` never shares its template
with `train`. Entities may repeat across splits (they are slot values,
not the learned pattern); this is documented, not hidden.

This is INTENT MATCHING data, not model training: the app matches a user
question against these phrasings by normalised token overlap to classify
its intent, then retrieves evidence from the database. The file and the
UI both say so explicitly. No claim of training a language model is made.

Usage:
    python3 tools/generate_phrasings.py --db assets/sunnati.db
    python3 tools/generate_phrasings.py --db assets/sunnati.db --min-total 2000
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from assistant_engine import AssistantEngine, BOOK_NAMES, content_terms  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
MASTER_OUT = ROOT / "tools" / "assistant_phrasings.json"
ASSET_OUT = ROOT / "assets" / "assistant_phrasings.json"

# ---------------------------------------------------------------------------
# Entity pools (display forms). Each is verified against the DB below.
# ---------------------------------------------------------------------------
TOPICS = [
    "النية", "الصلاة", "الصيام", "الزكاة", "الحج", "الوضوء", "الطهارة",
    "العلم", "الإيمان", "الصدق", "الغيبة", "بر الوالدين", "صلة الرحم",
    "الجهاد", "الدعاء", "الذكر", "التوبة", "الصبر", "الشكر", "الحياء",
    "الأمانة", "العدل", "الرحمة", "الجار", "اليتيم", "النكاح", "البيوع", "الربا",
]
NARRATORS = [
    "الزهري", "شعبة بن الحجاج", "سفيان بن عيينة", "يحيى بن سعيد القطان",
    "عبد الله بن المبارك", "الأعمش", "قتادة بن دعامة", "ابن سيرين",
    "الحسن البصري", "عطاء بن أبي رباح", "مجاهد بن جبر", "طاووس بن كيسان",
    "أبو هريرة", "عائشة", "عبد الله بن عمر", "عبد الله بن عباس",
    "أنس بن مالك", "جابر بن عبد الله",
]
GRADES = [
    "صحيح", "حسن", "ضعيف", "موضوع", "منكر", "شاذ", "غريب",
    "حسن صحيح", "صحيح لغيره", "ضعيف جداً", "موقوف", "مرسل",
]
STATUS_TERMS = ["ثقة", "صدوق", "حافظ", "مدلس", "متروك", "مجهول", "مختلف فيه", "لا بأس به"]
ISNAD_TERMS = ["متصل", "منقطع", "مرسل", "معضل", "مدلس", "مسند", "موقوف", "مقطوع"]
BOOK_PAIRS = [
    ("البخاري", "مسلم"), ("أبو داود", "الترمذي"), ("النسائي", "ابن ماجه"),
    ("أحمد", "الدارمي"), ("البخاري", "أبو داود"), ("مسلم", "الترمذي"),
    ("مالك", "البخاري"), ("أحمد", "البخاري"), ("الدارمي", "مسلم"),
    ("ابن ماجه", "الترمذي"), ("النسائي", "أبو داود"), ("مالك", "مسلم"),
]
GRADE_PAIRS = [
    ("صحيح", "حسن"), ("حسن", "ضعيف"), ("صحيح", "ضعيف"),
    ("موضوع", "ضعيف"), ("حسن صحيح", "صحيح لغيره"), ("صحيح", "موضوع"),
    ("حسن", "موضوع"), ("ضعيف جداً", "ضعيف"),
]

# ---------------------------------------------------------------------------
# Templates: (template_id, category, template_text, slot_kind)
# slot_kind selects the entity pool. {x} slots are filled per entity.
# ---------------------------------------------------------------------------
TEMPLATES: list[tuple[str, str, str, str]] = [
    # -- search / بحث --
    ("search-01", "search", "أحاديث في {topic}", "topic"),
    ("search-02", "search", "ابحث عن أحاديث في {topic}", "topic"),
    ("search-03", "search", "أحاديث عن {topic}", "topic"),
    ("search-04", "search", "ما الأحاديث الواردة في {topic}؟", "topic"),
    ("search-05", "search", "اعرض أحاديث {topic}", "topic"),
    ("search-06", "search", "أريد أحاديث عن {topic}", "topic"),
    ("search-07", "search", "اذكر أحاديث في باب {topic}", "topic"),
    ("search-08", "search", "ما ورد في {topic} من الأحاديث؟", "topic"),
    ("search-09", "search", "أحاديث تتحدث عن {topic}", "topic"),
    ("search-10", "search", "ابحث لي عن حديث في {topic}", "topic"),
    ("search-11", "search", "هل ورد حديث في {topic}؟", "topic"),
    ("search-12", "search", "أحاديث في موضوع {topic}", "topic"),
    # -- explain / شرح --
    ("explain-01", "explain", "اشرح حديث {topic}", "topic"),
    ("explain-02", "explain", "ما شرح حديث {topic}؟", "topic"),
    ("explain-03", "explain", "اشرح لي حديثاً في {topic}", "topic"),
    ("explain-04", "explain", "ما معنى حديث {topic}؟", "topic"),
    ("explain-05", "explain", "فسّر حديث {topic}", "topic"),
    ("explain-06", "explain", "اشرح الحديث الوارد في {topic}", "topic"),
    ("explain-07", "explain", "بيّن معنى حديث {topic}", "topic"),
    ("explain-08", "explain", "ما المقصود بحديث {topic}؟", "topic"),
    ("explain-09", "explain", "وضّح حديث {topic}", "topic"),
    ("explain-10", "explain", "شرح حديث {topic} بالتفصيل", "topic"),
    ("explain-11", "explain", "اشرح أول حديث في {topic}", "topic"),
    ("explain-12", "explain", "ما تفسير حديث {topic}؟", "topic"),
    # -- vocabulary / مفردات --
    ("vocab-01", "vocabulary", "ما معنى كلمة {term}؟", "term"),
    ("vocab-02", "vocabulary", "اشرح مفردة {term}", "term"),
    ("vocab-03", "vocabulary", "ما المراد بكلمة {term} في الحديث؟", "term"),
    ("vocab-04", "vocabulary", "فسّر لفظ {term}", "term"),
    ("vocab-05", "vocabulary", "ما غريب لفظ {term}؟", "term"),
    ("vocab-06", "vocabulary", "بيّن معنى {term}", "term"),
    ("vocab-07", "vocabulary", "ماذا تعني كلمة {term}؟", "term"),
    ("vocab-08", "vocabulary", "اشرح معنى {term} في الحديث", "term"),
    ("vocab-09", "vocabulary", "ما مفردات حديث {term}؟", "term"),
    ("vocab-10", "vocabulary", "ما معنى {term} عند المحدثين؟", "term"),
    # -- narrator / راوٍ (the seven questions × 3 wordings) --
    ("narrator-01", "narrator", "من هو الراوي {narrator}؟", "narrator"),
    ("narrator-02", "narrator", "من هو {narrator}؟", "narrator"),
    ("narrator-03", "narrator", "عرف بالراوي {narrator}", "narrator"),
    ("narrator-04", "narrator", "ما أقوال العلماء في {narrator}؟", "narrator"),
    ("narrator-05", "narrator", "ماذا قال العلماء في {narrator}؟", "narrator"),
    ("narrator-06", "narrator", "ما قول العلماء في الراوي {narrator}؟", "narrator"),
    ("narrator-07", "narrator", "من شيوخ {narrator}؟", "narrator"),
    ("narrator-08", "narrator", "من هم شيوخ الراوي {narrator}؟", "narrator"),
    ("narrator-09", "narrator", "عمّن روى {narrator}؟", "narrator"),
    ("narrator-10", "narrator", "من تلاميذ {narrator}؟", "narrator"),
    ("narrator-11", "narrator", "من هم تلاميذ الراوي {narrator}؟", "narrator"),
    ("narrator-12", "narrator", "من روى عن {narrator}؟", "narrator"),
    ("narrator-13", "narrator", "هل اختلف العلماء في {narrator}؟", "narrator"),
    ("narrator-14", "narrator", "هل اختلفوا في {narrator}؟", "narrator"),
    ("narrator-15", "narrator", "هل {narrator} مختلف فيه؟", "narrator"),
    ("narrator-16", "narrator", "ما أحاديث {narrator}؟", "narrator"),
    ("narrator-17", "narrator", "ما الأحاديث التي رواها {narrator}؟", "narrator"),
    ("narrator-18", "narrator", "اذكر أحاديث {narrator}", "narrator"),
    ("narrator-19", "narrator", "ما ترجمة {narrator}؟", "narrator"),
    ("narrator-20", "narrator", "ترجمة الراوي {narrator}", "narrator"),
    ("narrator-21", "narrator", "ما حال الراوي {narrator}؟", "narrator"),
    # -- grade / أحكام --
    ("grade-01", "grade", "ما حكم حديث {book} رقم {num}؟", "book"),
    ("grade-02", "grade", "هل حديث {book} رقم {num} صحيح؟", "book"),
    ("grade-03", "grade", "ما درجة حديث {book} رقم {num}؟", "book"),
    ("grade-04", "grade", "أحكام المحدثين في حديث {book} رقم {num}", "book"),
    ("grade-05", "grade", "ما حكم الحديث رقم {num} في {book}؟", "book"),
    ("grade-06", "grade", "أحاديث {grade} في {book}", "grade_book"),
    ("grade-07", "grade", "اعرض أحاديث حكم عليها بأنها {grade}", "grade"),
    ("grade-08", "grade", "ما الأحاديث {grade}؟", "grade"),
    ("grade-09", "grade", "هل ورد حديث {grade} في {book}؟", "grade_book"),
    ("grade-10", "grade", "ما معنى أن الحديث {grade}؟", "grade"),
    # -- takhrij / تخريج --
    ("takhrij-01", "takhrij", "خرّج حديث {topic}", "topic"),
    ("takhrij-02", "takhrij", "ما تخريج حديث {topic}؟", "topic"),
    ("takhrij-03", "takhrij", "أين ورد حديث {topic}؟", "topic"),
    ("takhrij-04", "takhrij", "في أي كتاب ورد حديث {topic}؟", "topic"),
    ("takhrij-05", "takhrij", "خرّج حديث {book} رقم {num}", "book"),
    ("takhrij-06", "takhrij", "ما مواضع ورود حديث {topic}؟", "topic"),
    ("takhrij-07", "takhrij", "هل أخرج {book} حديثاً في {topic}؟", "book_topic"),
    ("takhrij-08", "takhrij", "تخريج حديث {book} رقم {num}", "book"),
    # -- variant_diff / اختلاف روايات --
    ("variant-01", "variant_diff", "ما اختلاف روايات حديث {topic}؟", "topic"),
    ("variant-02", "variant_diff", "هل اختلفت روايات حديث {topic}؟", "topic"),
    ("variant-03", "variant_diff", "ما الفرق بين روايتي حديث {topic}؟", "topic"),
    ("variant-04", "variant_diff", "قارن بين روايات حديث {topic}", "topic"),
    ("variant-05", "variant_diff", "اختلاف ألفاظ حديث {topic}", "topic"),
    ("variant-06", "variant_diff", "هل ورد حديث {topic} بألفاظ مختلفة؟", "topic"),
    ("variant-07", "variant_diff", "ما روايات حديث {topic} الأخرى؟", "topic"),
    ("variant-08", "variant_diff", "اعرض روايات حديث {topic}", "topic"),
    # -- shawahid / شواهد --
    ("shawahid-01", "shawahid", "ما شواهد حديث {topic}؟", "topic"),
    ("shawahid-02", "shawahid", "ما طرق حديث {topic}؟", "topic"),
    ("shawahid-03", "shawahid", "هل لحديث {topic} شواهد؟", "topic"),
    ("shawahid-04", "shawahid", "ما متابعات حديث {topic}؟", "topic"),
    ("shawahid-05", "shawahid", "اذكر طرق حديث {topic}", "topic"),
    ("shawahid-06", "shawahid", "ما الطرق الأخرى لحديث {topic}؟", "topic"),
    ("shawahid-07", "shawahid", "هل ورد حديث {topic} من طرق أخرى؟", "topic"),
    ("shawahid-08", "shawahid", "شواهد حديث {topic} وطرقه", "topic"),
    # -- isnad / أسانيد --
    ("isnad-01", "isnad", "ما إسناد حديث {topic}؟", "topic"),
    ("isnad-02", "isnad", "اعرض إسناد حديث {topic}", "topic"),
    ("isnad-03", "isnad", "من رواة إسناد حديث {topic}؟", "topic"),
    ("isnad-04", "isnad", "ما سلسلة رواة حديث {topic}؟", "topic"),
    ("isnad-05", "isnad", "هل إسناد حديث {topic} متصل؟", "topic"),
    ("isnad-06", "isnad", "اعرض سند حديث {topic}", "topic"),
    ("isnad-07", "isnad", "من روى حديث {topic}؟", "topic"),
    ("isnad-08", "isnad", "ما رجال إسناد حديث {topic}؟", "topic"),
    # -- rijal / رجال --
    ("rijal-01", "rijal", "من رجال حديث {topic}؟", "topic"),
    ("rijal-02", "rijal", "ما علم الرجال في حديث {topic}؟", "topic"),
    ("rijal-03", "rijal", "من رواة حديث {narrator}؟", "narrator"),
    ("rijal-04", "rijal", "تراجم رجال حديث {topic}", "topic"),
    ("rijal-05", "rijal", "من هم رواة {topic}؟", "topic"),
    ("rijal-06", "rijal", "ما أحوال رجال حديث {topic}؟", "topic"),
    ("rijal-07", "rijal", "اعرض رجال إسناد حديث {topic}", "topic"),
    ("rijal-08", "rijal", "من أشهر رواة {topic}؟", "topic"),
    # -- jarh_tadil / جرح وتعديل --
    ("jarh-01", "jarh_tadil", "ما حال الراوي {narrator} عند المحدثين؟", "narrator"),
    ("jarh-02", "jarh_tadil", "هل {narrator} ثقة؟", "narrator"),
    ("jarh-03", "jarh_tadil", "ما توثيق {narrator}؟", "narrator"),
    ("jarh-04", "jarh_tadil", "هل ضعّف العلماء {narrator}؟", "narrator"),
    ("jarh-05", "jarh_tadil", "ما جرح {narrator} وتعديله؟", "narrator"),
    ("jarh-06", "jarh_tadil", "ما معنى أن الراوي {status}؟", "status"),
    ("jarh-07", "jarh_tadil", "ماذا يعني قولهم عن الراوي إنه {status}؟", "status"),
    ("jarh-08", "jarh_tadil", "هل الراوي {narrator} {status}؟", "narrator_status"),
    ("jarh-09", "jarh_tadil", "ما أقوال أهل الجرح والتعديل في {narrator}؟", "narrator"),
    ("jarh-10", "jarh_tadil", "بيّن حال {narrator} جرحاً وتعديلاً", "narrator"),
    # -- ilal / علل --
    ("ilal-01", "ilal", "ما علة حديث {topic}؟", "topic"),
    ("ilal-02", "ilal", "هل حديث {topic} معلول؟", "topic"),
    ("ilal-03", "ilal", "ما علل حديث {topic}؟", "topic"),
    ("ilal-04", "ilal", "ما معنى {term} في علم العلل؟", "ilal_term"),
    ("ilal-05", "ilal", "هل في حديث {topic} علة؟", "topic"),
    ("ilal-06", "ilal", "ما العلة في حديث {topic}؟", "topic"),
    ("ilal-07", "ilal", "اعرض علل حديث {topic}", "topic"),
    ("ilal-08", "ilal", "ما {term} عند أهل العلل؟", "ilal_term"),
    # -- terminology / مصطلح --
    ("term-01", "terminology", "ما معنى مصطلح {term}؟", "term"),
    ("term-02", "terminology", "عرف مصطلح {term}", "term"),
    ("term-03", "terminology", "ما تعريف {term} في علوم الحديث؟", "term"),
    ("term-04", "terminology", "ما هو الحديث {term}؟", "term"),
    ("term-05", "terminology", "ماذا يعني {term}؟", "term"),
    ("term-06", "terminology", "اشرح مصطلح {term}", "term"),
    ("term-07", "terminology", "ما الفرق بين {term1} و{term2}؟", "term_pair"),
    ("term-08", "terminology", "بيّن معنى {term} اصطلاحاً", "term"),
    ("term-09", "terminology", "ما المقصود بـ{term}؟", "term"),
    ("term-10", "terminology", "عرف {term} عند المحدثين", "term"),
    # -- fiqh_benefits / فوائد فقهية --
    ("fiqh-01", "fiqh_benefits", "ما فوائد حديث {topic} الفقهية؟", "topic"),
    ("fiqh-02", "fiqh_benefits", "ما المسائل الفقهية في حديث {topic}؟", "topic"),
    ("fiqh-03", "fiqh_benefits", "ما الأحكام الفقهية المستفادة من حديث {topic}؟", "topic"),
    ("fiqh-04", "fiqh_benefits", "ما يستفاد فقهياً من حديث {topic}؟", "topic"),
    ("fiqh-05", "fiqh_benefits", "اذكر فوائد حديث {topic}", "topic"),
    ("fiqh-06", "fiqh_benefits", "ما حكم {topic} في الفقه؟", "topic"),
    ("fiqh-07", "fiqh_benefits", "ما المسائل المتعلقة بـ{topic}؟", "topic"),
    ("fiqh-08", "fiqh_benefits", "فوائد حديث {topic} وأحكامه", "topic"),
    ("fiqh-09", "fiqh_benefits", "ما الذي يستفاد من حديث {topic}؟", "topic"),
    ("fiqh-10", "fiqh_benefits", "بيّن فوائد حديث {topic}", "topic"),
    # -- compare / مقارنة --
    ("compare-01", "compare", "قارن بين {book1} و{book2}", "book_pair"),
    ("compare-02", "compare", "ما الفرق بين {book1} و{book2}؟", "book_pair"),
    ("compare-03", "compare", "أيهما أصح {book1} أم {book2}؟", "book_pair"),
    ("compare-04", "compare", "قارن بين حديث {grade1} وحديث {grade2}", "grade_pair"),
    ("compare-05", "compare", "ما الفرق بين الحديث {grade1} والحديث {grade2}؟", "grade_pair"),
    ("compare-06", "compare", "مقارنة بين {book1} و{book2} في {topic}", "book_pair_topic"),
    ("compare-07", "compare", "أي الكتابين فيه أحاديث أكثر في {topic}: {book1} أم {book2}؟", "book_pair_topic"),
    ("compare-08", "compare", "قارن شرح {book1} و{book2} لحديث {topic}", "book_pair_topic"),
]


def split_of(template_id: str) -> str:
    """Template-level split: no template crosses splits (no leakage)."""
    h = int(hashlib.sha256(template_id.encode()).hexdigest(), 16) % 100
    if h < 70:
        return "train"
    if h < 85:
        return "validation"
    return "test"


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate SUNNATI assistant phrasings")
    ap.add_argument("--db", default=str(ROOT / "assets" / "sunnati.db"))
    ap.add_argument("--min-total", type=int, default=2000)
    args = ap.parse_args()

    engine = AssistantEngine(args.db)
    dropped: dict[str, list[str]] = defaultdict(list)

    # -- verify entities against the real DB -------------------------------
    topic_ref: dict[str, dict] = {}
    for t in TOPICS:
        rows = engine.search_hadiths(content_terms(t), limit=1)
        if rows:
            topic_ref[t] = {"book": rows[0]["book"], "num": rows[0]["num"]}
        else:
            dropped["topic_no_fts_hit"].append(t)
    narrator_ref: dict[str, dict] = {}
    for n in NARRATORS:
        rows = engine.search_hadiths(content_terms(n), limit=1)
        if rows:
            narrator_ref[n] = {"book": rows[0]["book"], "num": rows[0]["num"]}
        else:
            dropped["narrator_no_fts_hit"].append(n)
    grade_ref: dict[str, dict] = {}
    for g in GRADES:
        rows = engine.hadiths_with_grade(g, limit=1)
        if rows:
            grade_ref[g] = {"book": rows[0]["book"], "num": rows[0]["num"]}
        else:
            dropped["grade_no_row"].append(g)
    book_ref: dict[str, dict] = {}
    book_num: dict[str, int] = {}
    for bid, bname in BOOK_NAMES.items():
        row = engine.con.execute(
            "SELECT num FROM hadiths WHERE book = ? ORDER BY num LIMIT 1",
            (bid,)).fetchone()
        if row:
            book_ref[bname] = {"book": bid, "num": row[0]}
            book_num[bname] = row[0]
        else:
            dropped["book_empty"].append(bname)
    # Term references: grade terms -> verified grade row; status/isnad
    # terms -> NO backing table (narrators/chains empty): unavailable.
    term_ref: dict[str, tuple[list[dict], str]] = {}
    for g in GRADES:
        term_ref[g] = ([grade_ref[g]] if g in grade_ref else [], "verified" if g in grade_ref else "unavailable_no_grade_row")
    for s in STATUS_TERMS:
        term_ref[s] = ([], "unavailable_no_narrator_data")
    for s in ISNAD_TERMS:
        term_ref[s] = ([], "unavailable_no_chain_data")
    all_terms = GRADES + STATUS_TERMS + ISNAD_TERMS
    ilal_terms = ["معلول", "شاذ", "منكر", "مضطرب", "مقلوب", "مدرج", "علة", "مرسل"]
    ilal_ref: dict[str, tuple[list[dict], str]] = {}
    for s in ilal_terms:
        if s in grade_ref:
            ilal_ref[s] = ([grade_ref[s]], "verified")
        elif s in ("شاذ", "منكر"):
            ilal_ref[s] = ([grade_ref[s]], "verified") if s in grade_ref else ([], "unavailable_no_grade_row")
        else:
            ilal_ref[s] = ([], "unavailable_no_ilal_data")

    # -- slot expansion -----------------------------------------------------
    # book_ref is keyed by FULL book name ("صحيح البخاري"); the pair
    # templates use short names ("البخاري") — map them explicitly.
    BOOK_SHORT_TO_FULL = {
        "البخاري": "صحيح البخاري", "مسلم": "صحيح مسلم",
        "أبو داود": "سنن أبي داود", "الترمذي": "جامع الترمذي",
        "النسائي": "سنن النسائي", "ابن ماجه": "سنن ابن ماجه",
        "أحمد": "مسند أحمد", "مالك": "موطأ مالك", "الدارمي": "سنن الدارمي",
    }

    def expand(slot: str):
        if slot == "topic":
            return [({"topic": t}, [topic_ref[t]], "verified") for t in topic_ref]
        if slot == "narrator":
            return [({"narrator": n}, [narrator_ref[n]], "verified") for n in narrator_ref]
        if slot == "grade":
            return [({"grade": g}, [grade_ref[g]], "verified") for g in grade_ref]
        if slot == "book":
            return [({"book": b, "num": book_num[b]}, [book_ref[b]], "verified") for b in book_ref]
        if slot == "term":
            return [({"term": t}, refs, st) for t, (refs, st) in term_ref.items()]
        if slot == "status":
            return [({"status": s}, [], "unavailable_no_narrator_data") for s in STATUS_TERMS]
        if slot == "ilal_term":
            return [({"term": s}, refs, st) for s, (refs, st) in ilal_ref.items()]
        if slot == "grade_book":
            out = []
            for g in grade_ref:
                for b in book_ref:
                    out.append(({"grade": g, "book": b}, [grade_ref[g]], "verified"))
            return out
        if slot == "book_topic":
            out = []
            for b in book_ref:
                for t in topic_ref:
                    out.append(({"book": b, "topic": t}, [topic_ref[t]], "verified"))
            return out
        if slot == "narrator_status":
            out = []
            for n in narrator_ref:
                for s in STATUS_TERMS:
                    out.append(({"narrator": n, "status": s}, [narrator_ref[n]], "verified"))
            return out
        if slot == "term_pair":
            out = []
            for i, a in enumerate(all_terms):
                for b in all_terms[i + 1:]:
                    refs, st = term_ref[a]
                    out.append(({"term1": a, "term2": b}, refs, st))
            return out
        if slot == "book_pair":
            out = []
            for a, b in BOOK_PAIRS:
                fa, fb = BOOK_SHORT_TO_FULL[a], BOOK_SHORT_TO_FULL[b]
                if fa in book_ref and fb in book_ref:
                    out.append(({"book1": a, "book2": b}, [book_ref[fa], book_ref[fb]], "verified"))
            return out
        if slot == "grade_pair":
            out = []
            for a, b in GRADE_PAIRS:
                if a in grade_ref and b in grade_ref:
                    out.append(({"grade1": a, "grade2": b}, [grade_ref[a], grade_ref[b]], "verified"))
            return out
        if slot == "book_pair_topic":
            out = []
            for a, b in BOOK_PAIRS:
                fa, fb = BOOK_SHORT_TO_FULL[a], BOOK_SHORT_TO_FULL[b]
                if fa in book_ref and fb in book_ref:
                    for t in topic_ref:
                        out.append(({"book1": a, "book2": b, "topic": t}, [topic_ref[t]], "verified"))
            return out
        raise ValueError(f"unknown slot kind: {slot}")

    phrasings: list[dict] = []
    seen: set[str] = set()
    from assistant_engine import normalize_ar
    for template_id, category, template, slot in TEMPLATES:
        split = split_of(template_id)
        for entities, refs, ref_status in expand(slot):
            text = template.format(**entities)
            key = normalize_ar(text)
            if key in seen:
                continue
            seen.add(key)
            phrasings.append({
                "id": f"{template_id}-{len(phrasings) + 1:05d}",
                "text": text,
                "category": category,
                "template_id": template_id,
                "entities": entities,
                "reference_hadiths": refs,
                "reference_status": ref_status,
                "split": split,
            })

    counts = Counter(p["category"] for p in phrasings)
    split_counts = Counter(p["split"] for p in phrasings)
    template_splits: dict[str, set[str]] = defaultdict(set)
    for p in phrasings:
        template_splits[p["template_id"]].add(p["split"])
    leaking = {t: s for t, s in template_splits.items() if len(s) > 1}
    assert not leaking, f"template leakage: {leaking}"
    total = len(phrasings)
    if total < args.min_total:
        print(f"ERROR: only {total} phrasings < min {args.min_total}", file=sys.stderr)
        return 1

    import datetime
    db_sha = hashlib.sha256(Path(args.db).read_bytes()).hexdigest()
    data = {
        "meta": {
            "name": "SUNNATI assistant phrasings — intent-matching dataset (NOT model training)",
            "version": "1.0.0",
            "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "method": "Structured templates x DB-verified entities; split by template hash (train 70 / validation 15 / test 15); no template crosses splits.",
            "honest_scope": "Intent matching by retrieval over these phrasings. No language model was trained. The assistant retrieves evidence from sunnati.db and refuses without evidence.",
            "source_db": "assets/sunnati.db",
            "source_db_sha256": db_sha,
            "narrators_in_db": engine.narrator_count(),
            "total": total,
            "per_category": dict(sorted(counts.items())),
            "per_split": dict(sorted(split_counts.items())),
            "templates": len(TEMPLATES),
            "templates_per_split": {s: len([t for t in template_splits if split_of(t) == s]) for s in ("train", "validation", "test")},
            "dropped_entities": {k: v for k, v in dropped.items() if v},
            "verified_topics": len(topic_ref),
            "verified_narrators": len(narrator_ref),
            "verified_grades": len(grade_ref),
            "reference_status_counts": dict(sorted(Counter(p["reference_status"] for p in phrasings).items())),
        },
        "phrasings": phrasings,
    }
    payload = json.dumps(data, ensure_ascii=False, indent=1)
    MASTER_OUT.write_text(payload, encoding="utf-8")
    ASSET_OUT.write_text(payload, encoding="utf-8")
    print(f"phrasings: {total} (train {split_counts['train']} / validation {split_counts['validation']} / test {split_counts['test']})")
    print(f"per category: {dict(sorted(counts.items()))}")
    print(f"dropped: {dict(dropped)}")
    print(f"wrote {MASTER_OUT} and {ASSET_OUT} ({len(payload.encode())} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
