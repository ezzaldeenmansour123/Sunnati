#!/usr/bin/env python3
"""SUNNATI assistant retrieval engine — Phase 6 (Python mirror).

Local, offline, retrieval-only. This module is the executable reference
implementation of the assistant logic that `lib/assistant/rag_engine.dart`
implements in Dart; the two MUST agree on:

  * normalisation (mirror of `lib/core/normalize.dart` / `tools/build_db.py`)
  * intent detection (15 categories, 7 narrator sub-intents)
  * the 14-section hadith-explanation template (master prompt §8)
  * the three explanation levels (simplified / scholarly / specialist)
  * the hard guards: no evidence -> explicit refusal, never invention.

What this engine is NOT: it is NOT a language model. It does NOT generate
rulings, biographies, grades or commentary. It retrieves rows that already
exist in `assets/sunnati.db` and quotes them with their source (book,
number, chapter, grader, attribution). Every section that has no backing
row is rendered as UNAVAILABLE ("غير متوفر في المصادر المتاحة"), never
filled with generated text.

Ground truth about the shipped database (verified 2026-11-26, read-only):
  * hadiths: 65,712 (Nine Books); hadith_grades: 67,334 rows
  * commentaries (HadeethEnc): 3,574 rows, NOT linked to Nine-Books
    hadiths — retrieved only as standalone passages, never auto-linked
  * narrators / chains / takhrij / hadith_variants / glossary /
    topics / hadith_relations: 0 rows — every answer that needs them
    refuses explicitly. Teachers/students are ZERO in the first core.
  * hadiths.expl is empty for every Nine-Books row (no transmitted
    commentary is stored on the hadith row itself).

Usage:
    python3 tools/assistant_engine.py --db assets/sunnati.db \
        --ask "أحاديث في الصلاة" --level scholarly
    python3 tools/assistant_engine.py --db assets/sunnati.db --ask "..." --json
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants — the honest strings. These exact wordings are part of the
# contract: the UI and the tests look for them.
# ---------------------------------------------------------------------------
NO_EVIDENCE = "لا توجد أدلة موثقة في القاعدة"
UNAVAILABLE = "غير متوفر في المصادر المتاحة"
CORE_ZERO_NOTE = (
    "الشيوخ والتلاميذ غير متوفرين في النواة الأولى — "
    "جدول الرواة فارغ في القاعدة الحالية (0 راوٍ موثق)."
)
NOT_A_MODEL_NOTE = (
    "مساعد استرجاعي — مطابقة نوايا بالاسترجاع فوق صياغات الأسئلة، "
    "وليست نموذجاً لغوياً توليدياً؛ لا يولّد أحكاماً ولا شروحاً ولا تراجم."
)
REFUSAL_SUFFIX = " — لم يُخترَع بديل."

BOOK_NAMES = {
    "bukhari": "صحيح البخاري",
    "muslim": "صحيح مسلم",
    "abudawud": "سنن أبي داود",
    "tirmidhi": "جامع الترمذي",
    "nasai": "سنن النسائي",
    "ibnmajah": "سنن ابن ماجه",
    "ahmad": "مسند أحمد",
    "malik": "موطأ مالك",
    "darimi": "سنن الدارمي",
}
BOOK_KEYWORDS = {
    "البخاري": "bukhari", "بخاري": "bukhari",
    "مسلم": "muslim",
    "ابي داود": "abudawud", "أبي داود": "abudawud", "ابو داود": "abudawud",
    "الترمذي": "tirmidhi", "ترمذي": "tirmidhi",
    "النسايي": "nasai", "النسائي": "nasai", "نسايي": "nasai",
    "ابن ماجه": "ibnmajah", "ابن ماجه": "ibnmajah",
    "احمد": "ahmad", "أحمد": "ahmad",
    "مالك": "malik", "الموطا": "malik", "موطا": "malik",
    "الدارمي": "darimi", "دارمي": "darimi",
}

# ---------------------------------------------------------------------------
# Normalisation — MUST match lib/core/normalize.dart / tools/build_db.py.
# ---------------------------------------------------------------------------
_DIACRITICS = "ًٌٍَُِّْٰٓـ"
_HAMZA_MAP = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ؤ": "و", "ئ": "ي", "ى": "ي", "ة": "ه"})
_PUNCT = re.compile(r"[^\u0621-\u064a\u0660-\u0669\u06f0-\u06f90-9\s]")


def normalize_ar(text: str) -> str:
    s = "".join(ch for ch in text if ch not in _DIACRITICS)
    s = s.translate(_HAMZA_MAP)
    s = _PUNCT.sub(" ", s)
    return re.sub(r"\s+", " ", s).strip()


def strip_prefixes(word: str) -> str:
    w = word
    changed = True
    while changed and len(w) > 2:
        changed = False
        if w.startswith("ال") and len(w) > 3:
            w = w[2:]
            changed = True
        elif w[0] in "وفبلك" and len(w) > 2:
            w = w[1:]
            changed = True
    return w


def query_terms(query: str) -> list[str]:
    return [strip_prefixes(w) for w in normalize_ar(query).split(" ") if w]


# Question words removed before retrieval so they never become FTS terms.
QUESTION_WORDS = {
    "ما", "من", "هل", "كيف", "اين", "متي", "لماذا", "اشرح", "شرح", "عرف",
    "اذكر", "اعطني", "اريد", "ابحث", "اورد", "هات", "حدثني", "اخبرني",
    "هو", "هي", "هذا", "هذه", "ذلك", "في", "عن", "الي", "او", "ام",
    "؟", "سوال", "سؤال",
}

# Retrieval stopwords: generic question/task nouns, book names, grade
# words and jarh verdict words. They describe the QUESTION, not the
# evidence, so they must never become FTS terms — otherwise "قارن بين
# البخاري ومسلم في الصلاة" would AND-match the book names (which do not
# occur in hadith texts) and return nothing, and "هل الزهري ثقة؟" would
# require the word "ثقة" in the text. Checked against both the raw
# normalised token and its prefix-stripped form (the stripper turns
# "البخاري" into "خاري", "كلمة" into "مه" — the same behaviour as
# lib/core/normalize.dart — so stripped forms are listed too).
RETRIEVAL_STOPWORDS = QUESTION_WORDS | {
    "حديث", "احاديث", "حديثا", "روايه", "روايات", "روايتي", "كتاب",
    "باب", "معني", "كلمه", "مه", "لفظ", "مفرده", "مفردات", "غريب",
    "فوايد", "فوائد", "مسايل", "مسائل", "احكام", "فقهيه", "فقهي",
    "فقه", "تخريج", "اسناد", "سند", "شواهد", "شاهد", "طرق", "طريق",
    "عله", "علل", "مصطلح", "راوي", "رواه", "رجال", "مقارنه", "قارن",
    "فرق", "بين", "ورد", "مواضع", "ورود", "اخرج", "خرج", "بين", "وضح",
    "فسر", "بيّن", "شيوخ", "تلاميذ", "ترجمه", "ترجمة", "اقوال",
    "العلماء", "علماء", "حال", "حاله", "قارن",
    # book names (raw and stripped forms)
    "بخاري", "خاري", "مسلم", "داود", "ترمذي", "نسايي", "ماجه",
    "احمد", "مالك", "دارمي", "موطا", "ابو", "ابن",
    # grade words (the grade branch uses _grade_word, not FTS terms)
    "صحيح", "حسن", "ضعيف", "موضوع", "منكر", "شاذ", "موقوف", "مرسل",
    "مقطوع", "معلول", "متواتر", "متفق", "عليه", "جدا",
    # jarh verdict words
    "ثقه", "صدوق", "حافظ", "مدلس", "متروك", "مجهول", "مختلف", "فيه",
    "باس", "به", "لا",
}


def content_terms(query: str) -> list[str]:
    """Content terms for FTS: normalised tokens minus retrieval
    stopwords. A token is dropped when ANY of its forms (raw, without
    the article ال, fully prefix-stripped) is a stopword — the stripper
    turns "الفقهية" into "قهيه", so checking only the final form would
    miss it and poison the FTS query with a nonsense term."""
    out: list[str] = []
    for w in normalize_ar(query).split(" "):
        if not w:
            continue
        stripped = strip_prefixes(w)
        no_article = w[2:] if w.startswith("ال") and len(w) > 3 else w
        if (w in RETRIEVAL_STOPWORDS or no_article in RETRIEVAL_STOPWORDS
                or stripped in RETRIEVAL_STOPWORDS):
            continue
        if len(stripped) > 1:
            out.append(stripped)
    return out


GRADE_WORDS_NORM = {
    "صحيح", "حسن", "ضعيف", "موضوع", "منكر", "شاذ", "غريب", "موقوف",
    "مرسل", "مقطوع", "معلول", "متواتر",
}


def fts_query(terms: list[str]) -> str:
    parts = [f'"{t.replace(chr(34), "")}"*' for t in terms if t]
    return " AND ".join(parts)


# ---------------------------------------------------------------------------
# Intents — 15 categories (master prompt §9) + 7 narrator sub-intents (§10).
# Keyword sets are matched on normalised text, in the priority order of
# detect_intent(). The Dart side (lib/assistant/intent.dart) mirrors them.
# ---------------------------------------------------------------------------
NARRATOR_INTENTS = ("who_is", "sayings", "teachers", "students", "disputed", "hadiths", "ways")

INTENT_KEYWORDS: dict[str, list[str]] = {
    # Narrator questions are detected first, with their sub-intent.
    "narrator": ["راوي", "رواه", "ترجمه", "ترجمة"],
    "takhrij": ["تخريج", "خرج", "اخرج", "اين ورد", "مواضع ورود"],
    "variant_diff": ["اختلاف الروايات", "اختلاف روايات", "اختلاف الفاظ", "اختلاف الفاظ", "روايه اخري", "رواية أخري", "روايه اخرى", "فرق بين روايتي"],
    "shawahid": ["شواهد", "شاهد", "متابعات", "متابعه", "طرق الحديث", "طرق حديث"],
    "terminology": ["عرف مصطلح", "تعريف مصطلح", "مصطلح", "ما هو الحديث", "ما الحديث"],
    "grade": ["درجه", "درجة", "حكم الحديث", "ما حكم", "صحيح ام ضعيف", "صحيح او ضعيف", "هل الحديث صحيح", "هل هذا الحديث صحيح"],
    "explain": ["اشرح", "شرح", "فسر", "ما معني الحديث", "ما معنى الحديث", "بين معني", "وضح"],
    "vocabulary": ["مفردات", "غريب الحديث", "غريب", "معني كلمه", "معنى كلمة", "معني لفظ", "ما معني كلمه"],
    "fiqh_benefits": ["فوايد فقهيه", "فوائد فقهية", "مسايل فقهيه", "مسائل فقهية", "الاحكام الفقهيه", "الأحكام الفقهية", "يستفاد", "فوايد الحديث", "فوائد الحديث"],
    "compare": ["قارن", "مقارنه", "مقارنة", "الفرق بين", "ما الفرق", "ايهما اصح", "أيهما أصح"],
    "isnad": ["اسناد", "إسناد", "سند الحديث", "سلسله الرواه", "سلسلة الرواة"],
    "rijal": ["رجال", "الرجال", "علم الرجال"],
    "jarh_tadil": ["جرح وتعديل", "جرح", "تعديل", "توثيق", "تضعيف", "ثقه", "صدوق", "ضعيف الراوي", "حاله الراوي", "حال الراوي"],
    "ilal": ["علل", "عله", "علة الحديث", "معلول", "العلل"],
    "search": ["ابحث", "احاديث في", "أحاديث في", "احاديث عن", "اورد احاديث", "اعرض احاديث"],
}
INTENT_PRIORITY = [
    "narrator", "takhrij", "variant_diff", "shawahid", "vocabulary",
    "terminology", "grade", "explain", "fiqh_benefits", "compare",
    "isnad", "rijal", "jarh_tadil", "ilal", "search",
]
INTENT_AR = {
    "search": "بحث", "explain": "شرح", "vocabulary": "مفردات",
    "narrator": "راوٍ", "grade": "أحكام", "takhrij": "تخريج",
    "variant_diff": "اختلاف روايات", "shawahid": "شواهد",
    "isnad": "أسانيد", "rijal": "رجال", "jarh_tadil": "جرح وتعديل",
    "ilal": "علل", "terminology": "مصطلح", "fiqh_benefits": "فوائد فقهية",
    "compare": "مقارنة",
}

NARRATOR_AR = {
    "who_is": "من هو هذا الراوي؟",
    "sayings": "ما أقوال العلماء فيه؟",
    "teachers": "من أشهر شيوخه؟",
    "students": "من أشهر تلاميذه؟",
    "disputed": "هل اختلف العلماء فيه؟",
    "hadiths": "ما الأحاديث التي ورد فيها؟",
    "ways": "ما الطرق الأخرى للحديث؟",
}


def detect_narrator_intent(norm: str) -> str | None:
    if "طرق" in norm and "حديث" in norm:
        return "ways"
    if "اقوال العلماء" in norm or "ماذا قال" in norm or "قال فيه" in norm:
        return "sayings"
    if "شيوخ" in norm or "روي عن" in norm or "روى عن" in norm:
        return "teachers"
    if "تلاميذ" in norm or "روي عنه" in norm or "روى عنه" in norm:
        return "students"
    if "اختلف" in norm or "مختلف" in norm:
        return "disputed"
    # "ما أحاديث X؟" is a narrator question ONLY when X is a narrator
    # name, not a topic: "أحاديث في الصلاة" is a topic search, while
    # "ما أحاديث الزهري؟" is a narrator question. The guard below keeps
    # topic words out of the narrator branch.
    if "احاديث" in norm or "ما روي" in norm or "ما روى" in norm:
        rest = norm
        for p in ("ما احاديث", "احاديث", "ما روي", "ما روى"):
            rest = rest.replace(p, " ")
        rest = re.sub(r"\s+", " ", rest).strip()
        rest_words = [strip_prefixes(w) for w in rest.split(" ") if w]
        if rest_words and not any(
                w in TOPIC_WORDS or w in GRADE_WORDS_NORM for w in rest_words):
            return "hadiths"
        return None
    if ("من هو" in norm or "من هذا الراوي" in norm or "من الراوي" in norm
            or "عرف بالراوي" in norm or "ترجمه" in norm or "ترجمة" in norm):
        return "who_is"
    return None


# Topic words (normalised, prefix-stripped) that mark a question as a
# TOPIC search, never a narrator question. Used only by the guard above.
TOPIC_WORDS = {
    "صلاه", "صيام", "زكاه", "حج", "وضوء", "طهار", "علم", "ايمان",
    "صدق", "كذب", "غيبه", "والدين", "رحم", "جهاد", "دعاء", "ذكر",
    "توبه", "صبر", "شكر", "حياء", "امانه", "عدل", "رحمه", "جار",
    "يتيم", "مرض", "جناز", "نكاح", "طلاق", "بيوع", "ربا", "نيه",
    "نيات", "قران", "سنه", "اخلاق", "بر", "صلاة",
}


def detect_intent(query: str) -> tuple[str, str | None]:
    """Return (category, narrator_sub_intent or None)."""
    norm = normalize_ar(query)
    narr = detect_narrator_intent(norm)
    if narr is not None:
        return "narrator", narr
    words = set(norm.split(" "))
    has_grade_word = bool(words & GRADE_WORDS_NORM)
    # "أحاديث صحيح" is a grade search, not a narrator question.
    if "احاديث" in norm and has_grade_word:
        return "grade", None
    # "ما معنى صحيح؟" is a terminology question about a grade word.
    if has_grade_word and ("معني" in words or "مصطلح" in norm or "تعريف" in norm):
        return "terminology", None
    for intent in INTENT_PRIORITY:
        for kw in INTENT_KEYWORDS[intent]:
            if normalize_ar(kw) in norm:
                return intent, None
    return "search", None


def extract_book_number(query: str) -> tuple[str | None, int | None]:
    """Parse 'البخاري رقم 1' / 'حديث رقم 5 في مسلم' -> (book_id, num)."""
    norm = normalize_ar(query)
    book_id = None
    for kw, bid in BOOK_KEYWORDS.items():
        if normalize_ar(kw) in norm:
            book_id = bid
            break
    m = re.search(r"رقم\s+(\d+)", norm)
    num = int(m.group(1)) if m else None
    return book_id, num


# ---------------------------------------------------------------------------
# Evidence / explanation data classes (JSON-serialisable).
# ---------------------------------------------------------------------------
@dataclass
class Evidence:
    kind: str  # 'hadith' | 'commentary' | 'grade'
    book: str = ""
    book_name: str = ""
    num: int = 0
    chapter: str = ""
    text: str = ""
    grades: list[dict] = field(default_factory=list)
    source: str = ""

    def as_dict(self) -> dict:
        return {
            "kind": self.kind, "book": self.book, "book_name": self.book_name,
            "num": self.num, "chapter": self.chapter, "text": self.text,
            "grades": self.grades, "source": self.source,
        }

    def citation(self) -> str:
        if self.kind == "hadith":
            return f"{self.book_name} رقم {self.num} — {self.chapter}".strip(" —")
        return self.source


@dataclass
class Section:
    index: int
    title: str
    content: str
    source: str
    available: bool

    def as_dict(self) -> dict:
        return {"index": self.index, "title": self.title,
                "content": self.content, "source": self.source,
                "available": self.available}


SECTION_TITLES = [
    "النص", "المصدر", "الراوي", "التخريج", "الدرجة", "الشرح الإجمالي",
    "المفردات", "الجمل", "أقوال العلماء", "الفوائد", "المسائل الفقهية",
    "الروايات الأخرى", "الشواهد والطرق", "المصادر",
]


@dataclass
class Answer:
    query: str
    intent: str
    narrator_intent: str | None
    level: str
    evidences: list[Evidence] = field(default_factory=list)
    sections: list[Section] = field(default_factory=list)
    refused: bool = False
    note: str = ""

    def as_dict(self) -> dict:
        return {
            "query": self.query, "intent": self.intent,
            "intent_ar": INTENT_AR.get(self.intent, self.intent),
            "narrator_intent": self.narrator_intent,
            "narrator_intent_ar": NARRATOR_AR.get(self.narrator_intent or "", ""),
            "level": self.level, "refused": self.refused, "note": self.note,
            "evidences": [e.as_dict() for e in self.evidences],
            "sections": [s.as_dict() for s in self.sections],
        }


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------
class AssistantEngine:
    def __init__(self, db_path: str | Path):
        self.con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        self.con.row_factory = sqlite3.Row
        self._commentaries: list[dict] | None = None

    # -- raw access ------------------------------------------------------
    def hadith_by_number(self, book: str, num: int) -> dict | None:
        row = self.con.execute(
            "SELECT h.id, h.book, h.num, h.chapter_id, c.title AS chapter_title,"
            " h.text, h.grades, h.expl, h.expl_src FROM hadiths h"
            " LEFT JOIN chapters c ON c.id = h.chapter_id"
            " WHERE h.book = ? AND h.num = ? LIMIT 1", (book, num)).fetchone()
        return dict(row) if row else None

    def hadith_exists(self, book: str, num: int) -> bool:
        return self.hadith_by_number(book, num) is not None

    def narrator_count(self) -> int:
        return self.con.execute("SELECT COUNT(*) FROM narrators").fetchone()[0]

    def search_hadiths(self, terms: list[str], limit: int = 6) -> list[dict]:
        q = fts_query(terms)
        if not q:
            return []
        rows = self.con.execute(
            "SELECT h.id, h.book, h.num, h.chapter_id, c.title AS chapter_title,"
            " h.text, h.grades, h.expl, h.expl_src FROM hadiths_fts f"
            " JOIN hadiths h ON h.id = f.rowid"
            " LEFT JOIN chapters c ON c.id = h.chapter_id"
            " WHERE hadiths_fts MATCH ? ORDER BY rank LIMIT ?",
            (q, limit)).fetchall()
        return [dict(r) for r in rows]

    def grades_for_hadith(self, hadith_id: int) -> list[dict]:
        rows = self.con.execute(
            "SELECT grader, grade_ar, grade_kind, source FROM hadith_grades"
            " WHERE hadith_id = ? ORDER BY grader", (hadith_id,)).fetchall()
        return [dict(r) for r in rows]

    def hadiths_with_grade(self, grade_word: str, limit: int = 6) -> list[dict]:
        rows = self.con.execute(
            "SELECT DISTINCT h.id, h.book, h.num, h.chapter_id,"
            " c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src"
            " FROM hadith_grades g JOIN hadiths h ON h.id = g.hadith_id"
            " LEFT JOIN chapters c ON c.id = h.chapter_id"
            " WHERE g.grade_ar LIKE ? ORDER BY h.book, h.num LIMIT ?",
            (f"%{grade_word}%", limit)).fetchall()
        return [dict(r) for r in rows]

    def commentaries(self) -> list[dict]:
        if self._commentaries is None:
            rows = self.con.execute(
                "SELECT id, hadith_key, title, explanation, grade_ar, grader,"
                " attribution_text, source FROM commentaries").fetchall()
            out = []
            for r in rows:
                d = dict(r)
                d["_norm"] = normalize_ar(
                    f"{d['title']} {d['text'] if 'text' in d else ''} {d['explanation']}")
                out.append(d)
            self._commentaries = out
        return self._commentaries

    def search_commentaries(self, terms: list[str], limit: int = 3) -> list[dict]:
        hits = []
        for c in self.commentaries():
            if all(t in c["_norm"] for t in terms):
                hits.append(c)
                if len(hits) >= limit:
                    break
        return hits

    # -- evidence builders -----------------------------------------------
    def _evidence_from_row(self, row: dict) -> Evidence:
        grades = []
        try:
            grades = json.loads(row.get("grades") or "[]")
        except json.JSONDecodeError:
            grades = []
        return Evidence(
            kind="hadith", book=row["book"],
            book_name=BOOK_NAMES.get(row["book"], row["book"]),
            num=row["num"], chapter=row.get("chapter_title") or "",
            text=row["text"], grades=grades,
            source=f"quranlab/hadith — {BOOK_NAMES.get(row['book'], row['book'])}",
        )

    def _commentary_evidence(self, c: dict) -> Evidence:
        return Evidence(
            kind="commentary", text=c["explanation"] or c["title"],
            source=f"HadeethEnc ({c['hadith_key']}) — {c['attribution_text'] or 'موسوعة الحديث HadeethEnc'}",
        )

    # -- 14-section explanation (master prompt §8) ------------------------
    def build_explanation(self, row: dict, level: str) -> list[Section]:
        """All 14 sections, in order. A section with no backing row is
        UNAVAILABLE — never filled with generated text."""
        book = row["book"]
        book_name = BOOK_NAMES.get(book, book)
        chapter = row.get("chapter_title") or ""
        grades_db = self.grades_for_hadith(row["id"])
        grades_json = []
        try:
            grades_json = json.loads(row.get("grades") or "[]")
        except json.JSONDecodeError:
            grades_json = []

        if book in ("bukhari", "muslim"):
            grade_content = (
                "صحيح على مستوى المجموعة — لا درجة لكل حديث في المصدر "
                "(إجماع أهل السنة على صحة الصحيحين)."
            )
            grade_source = "quranlab/hadith — سياسة الدرجات في المصدر"
            grade_available = True
        elif book in ("ahmad", "darimi"):
            grade_content = "لا توجد درجة في المصدر — لم تُخترَع درجة."
            grade_source = "quranlab/hadith — سياسة الدرجات في المصدر"
            grade_available = True
        elif grades_db:
            grade_content = "؛ ".join(
                f"{g['grader']}: {g['grade_ar']}" for g in grades_db)
            grade_source = "hadith_grades — " + "; ".join(
                sorted({g["source"] for g in grades_db if g["source"]}))
            grade_available = True
        else:
            grade_content = UNAVAILABLE
            grade_source = ""
            grade_available = False

        sayings_content = (
            grade_content if grades_db else
            (grade_content if book in ("bukhari", "muslim", "ahmad", "darimi") else UNAVAILABLE)
        )
        sayings_available = bool(grades_db) or book in ("bukhari", "muslim")
        if book in ("ahmad", "darimi"):
            sayings_content = "لا توجد درجة في المصدر، فلا أقوال محدثين مسجلة لهذا الحديث."
            sayings_available = True

        text = row["text"]
        if level == "simplified" and len(text) > 160:
            text_shown = text[:160] + "…"
        else:
            text_shown = text

        sections = [
            Section(1, "النص", text_shown,
                    f"{book_name} رقم {row['num']}", True),
            Section(2, "المصدر",
                    f"{book_name} — حديث رقم {row['num']}"
                    + (f" — باب/كتاب: {chapter}" if chapter else ""),
                    "quranlab/hadith (مراجعة مثبّتة 9e5d61d8)", True),
            Section(3, "الراوي", UNAVAILABLE + " — جدول الرواة فارغ (0 راوٍ موثق).", "", False),
            Section(4, "التخريج", UNAVAILABLE + " — جدول التخريج فارغ.", "", False),
            Section(5, "الدرجة", grade_content, grade_source, grade_available),
            Section(6, "الشرح الإجمالي",
                    UNAVAILABLE + " — لا شرح منقول مخزّن على صف الحديث؛ وشروح HadeethEnc غير مربوطة بالأحاديث التسعة فلا تُنسب إليها.",
                    "", False),
            Section(7, "المفردات", UNAVAILABLE + " — جدول المصطلحات/الغريب فارغ.", "", False),
            Section(8, "الجمل", UNAVAILABLE + " — لا شرح للجمل مخزّن في المصادر المتاحة.", "", False),
            Section(9, "أقوال العلماء", sayings_content,
                    grade_source if sayings_available else "", sayings_available),
            Section(10, "الفوائد", UNAVAILABLE + " — لا فوائد موثقة مخزّنة لهذا الحديث.", "", False),
            Section(11, "المسائل الفقهية", UNAVAILABLE + " — لا مسائل فقهية موثقة مخزّنة لهذا الحديث.", "", False),
            Section(12, "الروايات الأخرى", UNAVAILABLE + " — جدول الروايات فارغ.", "", False),
            Section(13, "الشواهد والطرق", UNAVAILABLE + " — جدولا التخريج والروايات فارغان.", "", False),
            Section(14, "المصادر",
                    "؛ ".join([
                        "quranlab/hadith (المتن العربي، المراجعة 9e5d61d8)",
                        f"المصدر الفرعي: {BOOK_NAMES.get(book, book)}",
                        "فهرس الأبواب: fawazahmed0/hadith-api (عناوين إنجليزية حرفية)",
                    ]),
                    "meta — قاعدة sunnati.db", True),
        ]
        return sections

    def _visible_sections(self, sections: list[Section], level: str) -> list[Section]:
        if level == "simplified":
            keep = {1, 2, 5}
            return [s for s in sections if s.index in keep]
        if level == "scholarly":
            keep = {1, 2, 5, 9, 14}
            return [s for s in sections if s.index in keep]
        return sections  # specialist: all 14, unavailable stated explicitly

    # -- main entry --------------------------------------------------------
    def ask(self, query: str, level: str = "scholarly") -> Answer:
        if level not in ("simplified", "scholarly", "specialist"):
            level = "scholarly"
        intent, narr = detect_intent(query)
        query = query.strip()
        if not query:
            return Answer(query, intent, narr, level, refused=True,
                          note="اكتب سؤالاً أو كلمة للبحث في المكتبة.")

        # --- narrator questions: answered ONLY from the narrators tables --
        if intent == "narrator":
            return self._answer_narrator(query, narr or "who_is", level)

        # --- a specific hadith by book + number ---------------------------
        # Only for intents that a numbered hadith can answer. Takhrij /
        # variant / shawahid questions must NOT be diverted here: their
        # tables are empty, so they refuse explicitly below.
        book_id, num = extract_book_number(query)
        if (num is not None and book_id is not None
                and intent not in ("takhrij", "variant_diff", "shawahid")):
            row = self.hadith_by_number(book_id, num)
            if row is None:
                return Answer(query, intent, narr, level, refused=True,
                              note=f"{NO_EVIDENCE}: لا يوجد حديث رقم {num} في "
                                   f"{BOOK_NAMES[book_id]} في القاعدة.{REFUSAL_SUFFIX}")
            ev = self._evidence_from_row(row)
            sections = self.build_explanation(row, level)
            return Answer(query, intent, narr, level, evidences=[ev],
                          sections=self._visible_sections(sections, level),
                          note=NOT_A_MODEL_NOTE)

        # --- grade / terminology: real grade rows as evidence -------------
        # Runs BEFORE the empty-terms check: these questions are answered
        # from _grade_word, not from FTS terms (grade words are retrieval
        # stopwords, so content_terms() is legitimately empty here).
        if intent in ("grade", "terminology"):
            grade_word = self._grade_word(query)
            if grade_word:
                rows = self.hadiths_with_grade(grade_word, limit=6)
                if rows:
                    evs = [self._evidence_from_row(r) for r in rows]
                    note = NOT_A_MODEL_NOTE
                    if intent == "terminology":
                        note += (" تعريف المصطلح نفسه غير متوفر في القاعدة "
                                 "(جدول المصطلحات فارغ)؛ المعروض أمثلة موثقة "
                                 "من أحاديث مدرجة بهذه الدرجة فقط.")
                    return Answer(query, intent, narr, level, evidences=evs, note=note)
            if intent == "terminology":
                return Answer(query, intent, narr, level, refused=True,
                              note=f"{NO_EVIDENCE}: تعريف هذا المصطلح غير متوفر "
                                   f"في القاعدة (جدول المصطلحات فارغ).{REFUSAL_SUFFIX}")
            return Answer(query, intent, narr, level, refused=True,
                          note=f"{NO_EVIDENCE}: لا توجد أحاديث مدرجة بهذه الدرجة "
                               f"في القاعدة.{REFUSAL_SUFFIX}")

        terms = content_terms(query)
        if not terms:
            return Answer(query, intent, narr, level, refused=True,
                          note="اكتب سؤالاً أو كلمة للبحث في المكتبة.")


        # --- takhrij / variants / shawahid / isnad / rijal / jarh / ilal --
        # These need tables that are EMPTY in the shipped DB.
        if intent in ("takhrij", "variant_diff", "shawahid", "isnad",
                      "rijal", "jarh_tadil", "ilal"):
            rows = self.search_hadiths(terms, limit=6)
            if intent in ("takhrij", "variant_diff", "shawahid"):
                return Answer(query, intent, narr, level, refused=True,
                              note=f"{NO_EVIDENCE}: جداول التخريج والروايات "
                                   f"والطرق فارغة في القاعدة الحالية.{REFUSAL_SUFFIX}")
            if not rows:
                return Answer(query, intent, narr, level, refused=True,
                              note=f"{NO_EVIDENCE}.{REFUSAL_SUFFIX}")
            evs = [self._evidence_from_row(r) for r in rows]
            return Answer(query, intent, narr, level, evidences=evs,
                          note=NOT_A_MODEL_NOTE + " عرض نصوص مطابقة فقط؛ "
                          "الأحكام والتراجم الخاصة بهذا الباب غير متوفرة.")

        # --- explain: 14-section template on the best hit -----------------
        if intent == "explain":
            rows = self.search_hadiths(terms, limit=6)
            if not rows:
                return Answer(query, intent, narr, level, refused=True,
                              note=f"{NO_EVIDENCE}.{REFUSAL_SUFFIX}")
            sections = self.build_explanation(rows[0], level)
            evs = [self._evidence_from_row(r) for r in rows[:3]]
            return Answer(query, intent, narr, level, evidences=evs,
                          sections=self._visible_sections(sections, level),
                          note=NOT_A_MODEL_NOTE)

        # --- vocabulary / fiqh benefits: no verified source rows ----------
        if intent in ("vocabulary", "fiqh_benefits"):
            rows = self.search_hadiths(terms, limit=6)
            if not rows:
                return Answer(query, intent, narr, level, refused=True,
                              note=f"{NO_EVIDENCE}.{REFUSAL_SUFFIX}")
            evs = [self._evidence_from_row(r) for r in rows]
            return Answer(query, intent, narr, level, evidences=evs,
                          note=NOT_A_MODEL_NOTE + " المعروض نصوص مطابقة فقط؛ "
                          "المفردات/الفوائد الموثقة غير متوفرة في القاعدة.")

        # --- compare: two books/grades side by side, from real rows -------
        if intent == "compare":
            evs = [self._evidence_from_row(r) for r in self.search_hadiths(terms, limit=6)]
            if not evs:
                return Answer(query, intent, narr, level, refused=True,
                              note=f"{NO_EVIDENCE}.{REFUSAL_SUFFIX}")
            return Answer(query, intent, narr, level, evidences=evs,
                          note=NOT_A_MODEL_NOTE + " مقارنة نصوص مسترجعة فقط؛ "
                          "لا ترجيح ولا حكم مولّد.")

        # --- general search: FTS + standalone HadeethEnc passages ---------
        rows = self.search_hadiths(terms, limit=6)
        evs = [self._evidence_from_row(r) for r in rows]
        if len(evs) < 3:
            for c in self.search_commentaries(terms, limit=3 - len(evs)):
                evs.append(self._commentary_evidence(c))
        if not evs:
            return Answer(query, intent, narr, level, refused=True,
                          note=f"{NO_EVIDENCE}.{REFUSAL_SUFFIX}")
        return Answer(query, intent, narr, level, evidences=evs,
                      note=NOT_A_MODEL_NOTE)

    def _grade_word(self, query: str) -> str | None:
        norm = normalize_ar(query)
        for w in ("صحيح لغيره", "ضعيف جدا", "حسن صحيح", "متفق عليه",
                  "صحيح", "حسن", "ضعيف", "موضوع", "منكر", "شاذ", "غريب",
                  "موقوف", "مرسل", "مقطوع", "معلول", "متواتر"):
            if normalize_ar(w) in norm:
                return w.replace("جدا", "جداً")
        return None

    def _answer_narrator(self, query: str, sub: str, level: str) -> Answer:
        # The narrators table is EMPTY (0 rows, verified). Every one of the
        # seven questions therefore refuses explicitly — no biography, no
        # verdict, no teacher/student list is ever invented.
        if sub == "ways":
            return Answer(query, "narrator", sub, level, refused=True,
                          note=f"{NO_EVIDENCE}: الطرق تُعرض لحديث محدد من "
                               f"جدول الروايات، وهو فارغ في القاعدة الحالية.{REFUSAL_SUFFIX}")
        if sub in ("teachers", "students"):
            return Answer(query, "narrator", sub, level, refused=True,
                          note=f"{NO_EVIDENCE}: {CORE_ZERO_NOTE}{REFUSAL_SUFFIX}")
        return Answer(query, "narrator", sub, level, refused=True,
                      note=f"{NO_EVIDENCE}: لا توجد ترجمة موثقة لهذا الراوي "
                           f"في القاعدة (جدول الرواة فارغ — 0 راوٍ).{REFUSAL_SUFFIX}")


def main() -> int:
    ap = argparse.ArgumentParser(description="SUNNATI retrieval assistant (Phase 6)")
    ap.add_argument("--db", default="assets/sunnati.db")
    ap.add_argument("--ask", required=True)
    ap.add_argument("--level", default="scholarly",
                    choices=["simplified", "scholarly", "specialist"])
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    engine = AssistantEngine(args.db)
    ans = engine.ask(args.ask, level=args.level)
    if args.json:
        print(json.dumps(ans.as_dict(), ensure_ascii=False, indent=2))
    else:
        print(f"السؤال: {ans.query}")
        print(f"النوع: {ans.intent} / {ans.narrator_intent or ''} — المستوى: {ans.level}")
        print(f"مرفوض: {ans.refused}")
        print(f"ملاحظة: {ans.note}")
        for e in ans.evidences:
            print(f"- [{e.kind}] {e.citation()}")
            print(f"  {e.text[:160]}")
            for g in e.grades:
                print(f"    درجة: {g.get('scholar')}: {g.get('grade')}")
        for s in ans.sections:
            mark = "✓" if s.available else "✗"
            print(f"  [{mark}] {s.index}. {s.title}: {s.content[:160]}")
            if s.source:
                print(f"      المصدر: {s.source}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
