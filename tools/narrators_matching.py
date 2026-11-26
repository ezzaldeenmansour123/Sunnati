# -*- coding: utf-8 -*-
"""
SUNNATI Phase 5 — اختبار مطابقة أسماء الرواة (matching test only).

يقيس دقة مطابقة أسماء الرواة المستخرجة من أسانيد عينة 1,500 حديث
(500 بخاري + 500 مسلم + 500 أحمد) مقابل أسماء الرواة في hadith-kg
(جدول narrators في narrators_extract.db).

قواعد صارمة:
- قياس فقط. لا يوجد أي ربط فعلي في أي قاعدة بيانات هنا.
- النص الأصلي لا يُمس إطلاقاً: التطبيع للمطابقة فقط.
- المطابقة الاسمية وحدها ليست إثبات هوية.
- لا تُستخدم أي بيانات من Itqan إطلاقاً.

المصادر (قراءة فقط):
- المرشحون: ~/workspace/phase5-work/work.db  (جدول hadith_narrators)
  (ملف parser_results.json لا يحوي أسماء المرشحين، بل إحصاءات فقط،
  لذا تُقرأ الأسماء من work.db — وهو ما ينص عليه نص المهمة بديلاً:
  "للقراءة فقط إن احتجت نصوص الأحاديث").
  مفتاح المطابقة هو تطبيع دالة هذا السكربت لعمود narrator_norm
  (الصيغة المطبَّعة للمحلل) لأن المحلل جرّد واو العطف والفواصل؛
  النص الأصلي (narrator_text) محفوظ حرفياً ولا يُمس.
- المرجع: ~/workspace/phase5-work/hadith-kg/narrators_extract.db
  (جدول narrators، 49,844 راوياً).

الاستخدام:
    python3 matching.py            # يشغّل المطابقة ويكتب النتائج
    python3 matching.py --test     # يشغّل اختبارات الوحدة فقط

المخرجات (في مجلد هذا السكربت):
- matching_results.json : النتائج الكاملة (أعداد ونسب وتقسيمات)
- matching_candidates.csv : صف لكل مرشح من الـ 7,808 مع تصنيفه
- matching_run.log : سجل التشغيل (الأعداد والوقت)
"""

import csv
import json
import re
import sqlite3
import sys
import time
import unittest
from collections import Counter, defaultdict
from pathlib import Path

BASE = Path(__file__).resolve().parent
WORK_DB = Path.home() / "workspace/phase5-work/work.db"
KG_DB = Path.home() / "workspace/phase5-work/hadith-kg/narrators_extract.db"
RESULTS_JSON = BASE / "matching_results.json"
CANDIDATES_CSV = BASE / "matching_candidates.csv"
RUN_LOG = BASE / "matching_run.log"

# ---------------------------------------------------------------------------
# 1) دالة التطبيع — للمطابقة فقط (النص الأصلي لا يُمس)
# ---------------------------------------------------------------------------
# القواعد المطلوبة في المهمة:
#   - تجريد التشكيل
#   - توحيد الهمزات والألفات: أ/إ/آ -> ا ، ة -> ه ، ى -> ي
#   - إزالة «ال» التعريف للمقارنة
#   - توحيد «ابن/بن»
# إضافتان موثقتان (ضروريتان للمطابقة، ولا تغيّران المعنى):
#   (أ) توحيد إعراب الكنية: أبو/أبي/أبا -> أبو، لأن الإسناد يورد الكنية
#       بحسب موقعها الإعرابي (عن أبي هريرة، حدثنا أبو هريرة) بينما
#       يثبتها hadith-kg بصيغة الرفع (أبو هريرة).
#   (ب) «الله» تُستثنى من إزالة «ال» (إزالتها تعطي «له» خطأً).
# ما لا تفعله الدالة عمداً: لا تحذف واواً أولية (وقاص/وهب/وكيع أسماء
# تبدأ بواو حقيقية)، ولا تفكّ «عبدالله» الملتصقة، ولا تحذف النسب.

_DIACRITICS = set(
    "\u064b\u064c\u064d\u064e\u064f\u0650\u0651\u0652\u0653\u0654\u0655"
    "\u0656\u0657\u0658\u0659\u065a\u065b\u065c\u065d\u065e\u065f\u0670\u0640"
)
_ALEF_MAP = str.maketrans({
    "\u0623": "\u0627",  # أ -> ا
    "\u0625": "\u0627",  # إ -> ا
    "\u0622": "\u0627",  # آ -> ا
    "\u0671": "\u0627",  # ٱ -> ا
    "\u0624": "\u0648",  # ؤ -> و (توحيد الهمزات)
    "\u0626": "\u064a",  # ئ -> ي (توحيد الهمزات؛ موافق لتطبيع المحلل)
    "\u0629": "\u0647",  # ة -> ه
    "\u0649": "\u064a",  # ى -> ي
})
_PUNCT_RE = re.compile(r"[^\w\s\u0600-\u06ff]", re.UNICODE)
# علامات ترقيم عربية تقع داخل النطاق \u0600-\u06ff فلا يلتقطها _PUNCT_RE
_AR_PUNCT = "،؛؟«»„“”"


def _strip_punct(s: str, repl: str) -> str:
    for ch in _AR_PUNCT:
        s = s.replace(ch, repl)
    return _PUNCT_RE.sub(repl, s)


def normalize_token(tok: str, unify_kunya: bool = True) -> str:
    """تطبيع كلمة واحدة للمطابقة فقط."""
    s = "".join(ch for ch in tok if ch not in _DIACRITICS)
    s = s.translate(_ALEF_MAP)
    s = _strip_punct(s, "")
    s = s.strip()
    if s in ("ابن", "بن"):
        return "بن"
    if unify_kunya and s in ("ابو", "ابي", "ابا"):
        # توحيد إعراب الكنية (عن أبي هريرة == حدثنا أبو هريرة).
        # لا يُطبَّق على الكلمة المفردة وحدها: «أبي» وحدها قد تكون
        # ضميراً نسبياً (أبي/أبيه = والدي) لا كنية «أبو»، فتوحيدها
        # كان يطابقها خطأً بكل الأسماء التي تبدأ بـ«أبو» (1,636 راوياً).
        return "ابو"
    # إزالة «ال» التعريف، إلا من «الله» (وإلا صارت «له»)
    if s.startswith("ال") and len(s) > 3 and s != "الله":
        s = s[2:]
    return s


def normalize_match(text: str) -> str:
    """تطبيع اسم كامل للمطابقة فقط؛ يعيد سلسلة موحّدة مفصولة بمسافات."""
    if not text:
        return ""
    s = "".join(ch for ch in text if ch not in _DIACRITICS)
    s = s.translate(_ALEF_MAP)
    s = _strip_punct(s, " ")
    raw_toks = [t for t in s.split() if t]
    # توحيد إعراب الكنية لا يُطبَّق على الكلمة المفردة وحدها (انظر أعلاه)
    unify = len(raw_toks) > 1
    toks = [normalize_token(t, unify_kunya=unify) for t in raw_toks]
    return " ".join(t for t in toks if t)


def tokens_of(text: str) -> tuple:
    """قائمة كلمات الاسم بعد التطبيع (للمقارنة الجزئية)."""
    n = normalize_match(text)
    return tuple(n.split()) if n else ()


def is_contiguous_subseq(needle: tuple, hay: tuple) -> bool:
    """هل needle سلسلة متصلة من الكلمات داخل hay؟ (لأغراض الاختبار فقط)"""
    if not needle or len(needle) > len(hay):
        return False
    k = len(needle)
    return any(hay[i:i + k] == needle for i in range(len(hay) - k + 1))


def _match_kind(cand_tokens: tuple, kg_tokens: tuple) -> str:
    """نوع مطابقة مرشح واحد مقابل اسم/كنية واحد من kg (بعد التطبيع).

    - 'exact': تساوٍ تام.
    - 'prefix': المرشح بادئة من كلمات الاسم/الكنية
      («عبد الله بن يوسف» من «عبد الله بن يوسف التنيسي»).
    - 'skip1': المرشح بادئة بعد حذف حلقة نسب واحدة «بن/بنت X»
      من وسط الاسم، بشرط أن تكون الكلمة الأخيرة في المرشح نسبةً
      أو لقباً لا اسم أب (أي لا يسبقها «بن» في المرشح نفسه).
      مثال: «محمد بن إبراهيم التيمي» من
      «محمد بن إبراهيم بن الحارث التيمي» (سقطت حلقة قبل النسبة).
      ويُمنع الحذف حين تكون الكلمة الأخيرة اسم أب، وإلا طابق
      «عمر بن خطاب» ذرية عمر (عمر بن حمزة بن عبد الله بن عمر
      بن الخطاب)، وطابق «عبد الله بن يوسف» من أبوه محمد وجده
      يوسف (عبد الله بن محمد بن يوسف) — فالأب لا يُستبدل بالجد.
    - '': بلا مطابقة.
    """
    if not cand_tokens or len(cand_tokens) > len(kg_tokens):
        return ""
    if cand_tokens == kg_tokens:
        return "exact"
    if kg_tokens[:len(cand_tokens)] == cand_tokens:
        return "prefix"
    if len(cand_tokens) >= 2 and cand_tokens[-2] not in ("بن", "بنت"):
        for i in range(2, len(kg_tokens) - 1):
            if kg_tokens[i] in ("بن", "بنت"):
                short = kg_tokens[:i] + kg_tokens[i + 2:]
                if len(cand_tokens) <= len(short) and \
                        short[:len(cand_tokens)] == cand_tokens:
                    return "skip1"
    return ""


def _anchored_subseq(needle: tuple, hay: tuple) -> bool:
    """هل كلمات needle تظهر بنفس الترتيب داخل hay، وأولها == أول hay؟

    (قاعدة قديمة أُلغيت: كانت تطابق «عمر بن خطاب» بذرية عمر،
    و«أبو هريرة» بمولاه «أبو وهب مولى أبي هريرة». تُبقي الدالة
    للتوثيق فقط ولا تُستخدم في المطابقة.)
    """
    if not needle or len(needle) > len(hay):
        return False
    if needle[0] != hay[0]:
        return False
    it = iter(hay)
    return all(any(tok == want for tok in it) for want in needle)


# ---------------------------------------------------------------------------
# 2) نوع المرشح — من أعلام المحلل في عمود notes (flags=...)
# ---------------------------------------------------------------------------
def parse_flags(notes: str) -> set:
    """يستخرج مجموعة الأعلام من notes مثل 'chain_index=0; flags=a,b'."""
    if not notes:
        return set()
    m = re.search(r"flags=([^;]*)", notes)
    if not m:
        return set()
    return {f.strip() for f in m.group(1).split(",") if f.strip()}


def candidate_type(flags: set) -> str:
    """النوع الأساسي للمرشح (أولوية الأعلام الأخصّ)."""
    if "relative_reference" in flags:
        return "relative"          # إشارة نسبية (أبي/أبيه)
    if "kunya_only" in flags:
        return "kunya_only"        # كنية فقط
    if "single_word_name" in flags:
        return "single_word"       # اسم مفرد
    if "partial_name" in flags:
        return "partial"           # اسم ناقص (ابن شهاب)
    if "yani_clarification" in flags:
        return "yani"              # توضيح بـ«يعني»
    return "full_name"             # اسم كامل


TYPE_AR = {
    "full_name": "اسم كامل",
    "single_word": "اسم مفرد",
    "kunya_only": "كنية فقط",
    "partial": "اسم ناقص",
    "relative": "إشارة نسبية",
    "yani": "توضيح «يعني»",
}

# ---------------------------------------------------------------------------
# 3) فهرس hadith-kg (يُستبعد الـ stubs والـ placeholder غير البشري)
# ---------------------------------------------------------------------------
PLACEHOLDER_ID = 30002  # «موضع إرسال» — ليس شخصاً (STRUCTURE_LICENSE_REPORT §4.7)


class KgIndex:
    """فهرس مطابقة على جدول narrators بعد التطبيع."""

    def __init__(self, db_path: Path):
        self.excluded_stub = 0
        self.excluded_placeholder = 0
        self.rows = {}          # source_id -> dict(name, nickname, rank_no, rank, tabaka)
        self.token_rows = defaultdict(set)   # token -> {row_idx} (في الاسم أو الكنية)
        self.name_tokens = {}   # row_idx -> tuple tokens(name)
        self.nick_tokens = {}   # row_idx -> tuple tokens(nickname)
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        try:
            for sid, name, nick, rank_no, rank, tabaka, is_stub in con.execute(
                "SELECT source_id, name, nickname, rank_no, rank, tabaka, is_stub "
                "FROM narrators"
            ):
                if sid == PLACEHOLDER_ID:
                    self.excluded_placeholder += 1
                    continue
                if is_stub:
                    self.excluded_stub += 1
                    continue
                idx = len(self.rows)
                self.rows[idx] = {
                    "source_id": sid, "name": name, "nickname": nick,
                    "rank_no": rank_no, "rank": rank, "tabaka": tabaka,
                }
                nt = tokens_of(name)
                kt = tokens_of(nick)
                self.name_tokens[idx] = nt
                self.nick_tokens[idx] = kt
                for t in set(nt) | set(kt):
                    self.token_rows[t].add(idx)
        finally:
            con.close()

    def __len__(self):
        return len(self.rows)

    def match(self, cand_tokens: tuple):
        """يعيد (مجموعة معرّفات الصفوف المطابقة، نوع المطابقة الأقوى).

        قاعدة المطابقة (بعد التطبيع) — انظر _match_kind:
        تساوٍ تام، أو بادئة، أو بادئة بعد حذف حلقة نسب واحدة
        قبل نسبة/لقب أخير. الترتيب قوةً: exact > prefix > skip1.
        """
        if not cand_tokens:
            return set(), ""
        # صفوف تحوي كل كلمات المرشح (في الاسم أو في الكنية)
        sets = [self.token_rows.get(t) for t in cand_tokens]
        if any(not s for s in sets):
            return set(), ""
        common = set.intersection(*sets)
        matched = set()
        kind = ""
        rank = {"exact": 3, "prefix": 2, "skip1": 1}
        for idx in common:
            k = ""
            for toks in (self.name_tokens[idx], self.nick_tokens[idx]):
                kk = _match_kind(cand_tokens, toks)
                if rank.get(kk, 0) > rank.get(k, 0):
                    k = kk
            if k:
                matched.add(idx)
                if rank[k] > rank.get(kind, 0):
                    kind = k
        return matched, kind

    def token_carriers(self, token: str) -> set:
        """صفوف يظهر فيها token ككلمة في الاسم أو الكنية (في أي موضع).

        رقم ثانوي للتوضيح فقط (مثلاً: كم راوياً يحمل نسبة «الزهري»)،
        وليس مطابقة: فالكلمة في وسط النسب لا تعني أن الاسم المفرد
        يشير إلى صاحبها.
        """
        return set(self.token_rows.get(token, ()))


# ---------------------------------------------------------------------------
# 4) التشغيل الرئيسي
# ---------------------------------------------------------------------------
def load_candidates(db_path: Path):
    """يقرأ المرشحين من work.db (قراءة فقط) مع كتاب كل حديث."""
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        rows = list(con.execute(
            "SELECT hn.id, hn.hadith_id, h.book, hn.narrator_text, "
            "hn.narrator_norm, hn.confidence, hn.notes "
            "FROM hadith_narrators hn JOIN hadiths h ON h.id = hn.hadith_id "
            "ORDER BY hn.id"
        ))
    finally:
        con.close()
    return rows


def run():
    t0 = time.perf_counter()
    log_lines = []

    def log(msg):
        log_lines.append(msg)
        print(msg, flush=True)

    log("== SUNNATI matching test ==")
    log(f"work.db: {WORK_DB}")
    log(f"kg db:   {KG_DB}")

    kg = KgIndex(KG_DB)
    log(f"KG narrators indexed: {len(kg)} "
        f"(excluded stubs: {kg.excluded_stub}, "
        f"placeholder {PLACEHOLDER_ID}: {kg.excluded_placeholder})")

    cand_rows = load_candidates(WORK_DB)
    log(f"candidates loaded: {len(cand_rows)}")

    # تحقق اتساق التطبيع: تطبيعي لنص المرشح الأصلي == تطبيعي لـ narrator_norm
    agree = sum(
        1 for (_, _, _, text, norm, _, _) in cand_rows
        if normalize_match(text) == normalize_match(norm)
    )
    log(f"normalization consistency (my norm of narrator_text == my norm "
        f"of parser narrator_norm): {agree}/{len(cand_rows)} "
        f"= {100.0 * agree / len(cand_rows):.2f}%")

    results = []
    for (cid, hid, book, text, pnorm, conf, notes) in cand_rows:
        flags = parse_flags(notes)
        ctype = candidate_type(flags)
        # مفتاح المطابقة = تطبيعي لـ narrator_norm (الصيغة المطبَّعة للمحلل)،
        # لا للنص الخام: المحلل جرّد واو العطف من أول الاسم («ومعمر» ->
        # «معمر») والفواصل، فالنص الخام كان سيكسر ~360 مطابقة. النص
        # الأصلي محفوظ حرفياً في حقل text ولا يُمس. التشخيص أعلاه يقيس
        # نسبة اتفاق التطبيعين (92% قبل إصلاح الترقيم؛ انظر التقرير).
        ctoks = tokens_of(pnorm)
        matched, kind = kg.match(ctoks)
        n = len(matched)
        matched_ids = sorted(kg.rows[i]["source_id"] for i in matched)
        # الفئة (أ/ب/ج/د) حسب نص المهمة
        if ctype in ("kunya_only", "single_word"):
            category = "kunya_or_single"     # (د) منفصلة بطبيعتها
        elif n == 1:
            category = "unique"              # (أ) مطابق مؤكد اسمياً
        elif n > 1:
            category = "ambiguous"           # (ب) غامض
        else:
            category = "no_match"            # (ج) بلا مطابق
        # «مربوط بيقين» بموجب قاعدة المنع: اسم كامل + مطابق واحد +
        # ثقة عالية/متوسطة فقط. كل ما عداه معلّق.
        linkable = (
            category == "unique" and ctype == "full_name"
            and conf in ("high", "medium")
        )
        results.append({
            "id": cid, "hadith_id": hid, "book": book,
            "text": text, "norm": normalize_match(pnorm),
            "parser_norm": pnorm, "confidence": conf,
            "type": ctype, "flags": sorted(flags),
            "co_narrator": "co_narrator_split" in flags,
            "companion": "companion" in flags,
            "n_matches": n, "match_kind": kind if n else "",
            "category": category, "linkable": linkable,
            "matched_source_ids": matched_ids[:10],  # أول 10 فقط في JSON
            "matched_source_ids_total": len(matched_ids),
        })

    # ---- إحصاءات ----
    total = len(results)
    cat = Counter(r["category"] for r in results)
    by_type = defaultdict(Counter)
    by_book = defaultdict(Counter)
    by_conf = defaultdict(Counter)
    by_co = defaultdict(Counter)
    by_comp = defaultdict(Counter)
    for r in results:
        by_type[r["type"]][r["category"]] += 1
        by_book[r["book"]][r["category"]] += 1
        by_conf[r["confidence"]][r["category"]] += 1
        by_co["co_narrator" if r["co_narrator"] else "single_chain"][r["category"]] += 1
        by_comp["companion" if r["companion"] else "other"][r["category"]] += 1

    linkable_n = sum(1 for r in results if r["linkable"])
    # أحاديث ذات ربط مؤكد واحد على الأقل
    hadith_ids = sorted({r["hadith_id"] for r in results})
    hadith_linkable = {r["hadith_id"] for r in results if r["linkable"]}
    hadith_unique_any = {r["hadith_id"] for r in results if r["category"] == "unique"}
    # الأحاديث الـ 11 بلا مرشحين أصلاً (من parser_results: status none)
    n_hadiths_sample = 1500

    # توزيع عدد المطابقات داخل (د)
    d_sub = Counter()
    for r in results:
        if r["category"] == "kunya_or_single":
            d_sub["0" if r["n_matches"] == 0 else
                  "1" if r["n_matches"] == 1 else ">1"] += 1
    # داخل (أ): تساوٍ تام مقابل سلسلة جزئية
    a_kind = Counter(r["match_kind"] for r in results if r["category"] == "unique")
    # داخل (أ): كم منها اسم كامل بثقة عالية/متوسطة (أي linkable) مقابل ضعيف الصيغة/الثقة
    a_not_linkable = Counter()
    for r in results:
        if r["category"] == "unique" and not r["linkable"]:
            a_not_linkable[(r["type"], r["confidence"])] += 1
    # أكثر الأسماء المفردة تكراراً وعدد مطابقاتها في kg
    single_counts = Counter(
        r["norm"] for r in results if r["type"] == "single_word")
    single_match_n = {}
    for r in results:
        if r["type"] == "single_word":
            single_match_n.setdefault(r["norm"], r["n_matches"])
    top_single = [
        {"name": name, "occurrences": c, "kg_matches": single_match_n[name]}
        for name, c in single_counts.most_common(20)
    ]
    # أكثر الكنى تكراراً
    kunya_counts = Counter(
        r["norm"] for r in results if r["type"] == "kunya_only")
    kunya_match_n = {}
    for r in results:
        if r["type"] == "kunya_only":
            kunya_match_n.setdefault(r["norm"], r["n_matches"])
    top_kunya = [
        {"name": name, "occurrences": c, "kg_matches": kunya_match_n[name]}
        for name, c in kunya_counts.most_common(15)
    ]
    # أكثر الأسماء الكاملة الغامضة تكراراً
    amb_full = Counter(
        r["norm"] for r in results
        if r["category"] == "ambiguous" and r["type"] == "full_name")
    top_amb_full = [
        {"name": name, "occurrences": c}
        for name, c in amb_full.most_common(15)
    ]
    # أمثلة
    def examples(pred, limit=10):
        return [
            {"text": r["text"], "norm": r["norm"], "book": r["book"],
             "confidence": r["confidence"], "type": r["type"],
             "n_matches": r["n_matches"], "match_kind": r["match_kind"],
             "matched_source_ids": r["matched_source_ids"]}
            for r in results if pred(r)
        ][:limit]

    # ---- الحالات الصعبة المعروفة ----
    def hard_case(token_norm, label):
        occ_single = [r for r in results
                      if r["type"] == "single_word" and r["norm"] == token_norm]
        occ_kunya = [r for r in results
                     if r["type"] == "kunya_only" and r["norm"] == token_norm]
        occ_any = [r for r in results if token_norm in r["norm"].split()]
        # عدد المطابقين يُحسب من الفهرس مباشرة (لا من القوائم المقطوعة عند 10)
        matched_idx, _ = kg.match(tokens_of(token_norm))
        matched_info = []
        for i in sorted(matched_idx,
                        key=lambda j: kg.rows[j]["source_id"])[:12]:
            row = kg.rows[i]
            matched_info.append({
                "source_id": row["source_id"], "name": row["name"],
                "nickname": row["nickname"], "rank": row["rank"],
                "tabaka": row["tabaka"]})
        # حاملو الكلمة في أي موضع (رقم ثانوي توضيحي، ليس مطابقة)
        carriers = kg.token_carriers(token_norm)
        carrier_info = []
        for i in sorted(carriers,
                        key=lambda j: kg.rows[j]["source_id"])[:12]:
            row = kg.rows[i]
            carrier_info.append({
                "source_id": row["source_id"], "name": row["name"],
                "nickname": row["nickname"], "rank": row["rank"]})
        return {
            "label": label, "token_norm": token_norm,
            "occurrences_as_single_word": len(occ_single),
            "occurrences_as_kunya_only": len(occ_kunya),
            "occurrences_as_token_anywhere": len(occ_any),
            "single_word_or_kunya_in_category_D":
                len(occ_single) + len(occ_kunya),  # كلها (د) بالتعريف
            "distinct_kg_narrators_matched": len(matched_idx),
            "kg_matches_for_single_word_or_kunya": (
                (occ_single[0]["n_matches"] if occ_single
                 else occ_kunya[0]["n_matches"] if occ_kunya else 0)),
            "matched_narrators_sample": matched_info,
            "token_carriers_count": len(carriers),
            "token_carriers_sample": carrier_info,
        }

    hard_cases = {
        "sufyan": hard_case("سفيان", "سفيان (الثوري vs ابن عيينة)"),
        "zuhri": hard_case("زهري", "الزهري"),
        "shuba": hard_case("شعبه", "شعبة"),
        "amash": hard_case("اعمش", "الأعمش"),
        "hammad": hard_case("حماد", "حماد"),
        "abu_hurayra": hard_case("ابو هريره", "أبو هريرة (كنية فقط)"),
    }

    # ---- تقديرات أثر قواعد التحسين (قابلة للقياس) ----
    # 1) الغامضون الذين يمكن تمييزهم بالطبقة نظرياً: مطابقوهم في طبقات مختلفة
    amb = [r for r in results if r["category"] == "ambiguous"]
    amb_tabaka_spread = 0
    amb_tabaka_detail = Counter()
    for r in amb:
        tabs = {kg.rows[i]["tabaka"]
                for i in kg.match(tokens_of(r["norm"]))[0]}
        # نعيد حساب المطابقات كاملة (matched_source_ids مقطوعة عند 10 في JSON
        # لكننا هنا نستخدم الفهرس مباشرة)
        if len(tabs) > 1:
            amb_tabaka_spread += 1
        amb_tabaka_detail[len(tabs)] += 1
    # 2) (د) بمطابق واحد فقط — مرشحة للرفع بالكنية/اللقب المشهور
    d_unique = sum(1 for r in results
                   if r["category"] == "kunya_or_single" and r["n_matches"] == 1)
    d_unique_sahabi = 0
    for r in results:
        if r["category"] == "kunya_or_single" and r["n_matches"] == 1:
            idxs = kg.match(tokens_of(r["norm"]))[0]
            if idxs:
                row = kg.rows[next(iter(idxs))]
                if row["rank_no"] == 1:
                    d_unique_sahabi += 1
    # 3) أسماء ناقصة/نسبية بمطابق واحد (صيغة ضعيفة لكن الاسم يطابق وحيداً)
    weak_unique = sum(1 for r in results
                      if r["category"] == "unique"
                      and r["type"] in ("partial", "relative", "yani"))
    # 4) قاعدة تحسين مقاسة R1: الغامضون الذين تمتد مطابقاتهم على
    # طبقتين أو ثلاث فقط (قابلون للتضييق بقيود الطبقة/الشيخ والتلميذ)
    amb_span_1 = amb_tabaka_detail.get(1, 0)
    amb_span_2_3 = (amb_tabaka_detail.get(2, 0) +
                    amb_tabaka_detail.get(3, 0))
    amb_span_ge4 = sum(v for k, v in amb_tabaka_detail.items() if k >= 4)
    # 5) قاعدة تحسين مقاسة R3: الغامضون المعلَّمون كصحابة — حصر
    # المطابقات في rank_no==1 (صحابي) في kg
    comp_amb_rows = [r for r in results
                     if r["companion"] and r["category"] == "ambiguous"]
    r3_unique = r3_amb = r3_zero = 0
    for r in comp_amb_rows:
        sah = [i for i in kg.match(tokens_of(r["norm"]))[0]
               if kg.rows[i]["rank_no"] == 1]
        if len(sah) == 1:
            r3_unique += 1
        elif len(sah) > 1:
            r3_amb += 1
        else:
            r3_zero += 1
    # 6) قاعدة تحسين مقاسة R4: بلا مطابق من نوع «كنية + اسم»
    # (أبو اليمان الحكم بن نافع) — مطابقة الجزء الاسمي وحده
    r4_rows = [r for r in results
               if r["category"] == "no_match" and r["type"] == "full_name"
               and len(r["norm"].split()) >= 4
               and r["norm"].split()[0] in ("ابو", "ام")]
    r4_unique = r4_amb = r4_no = 0
    for r in r4_rows:
        m, _ = kg.match(tuple(r["norm"].split()[2:]))
        if len(m) == 1:
            r4_unique += 1
        elif len(m) > 1:
            r4_amb += 1
        else:
            r4_no += 1
    # 7) قاعدة تحسين مقاسة R5: بلا مطابق من نوع اسم كامل — إسقاط
    # الكلمة الأخيرة (النسبة) وإعادة المطابقة
    r5_rows = [r for r in results
               if r["category"] == "no_match" and r["type"] == "full_name"]
    r5_unique = 0
    for r in r5_rows:
        toks = tuple(r["norm"].split()[:-1])
        if len(toks) >= 2:
            m, _ = kg.match(toks)
            if len(m) == 1:
                r5_unique += 1
    # 4) تكرار الأسماء المطبّعة في kg نفسه
    norm_name_to_rows = defaultdict(set)
    for idx, row in kg.rows.items():
        norm_name_to_rows[normalize_match(row["name"])].add(idx)
        norm_name_to_rows[normalize_match(row["nickname"])].add(idx)
    dup_norm_names = sum(1 for v in norm_name_to_rows.values() if len(v) > 1)

    elapsed = time.perf_counter() - t0

    out = {
        "run": {
            "script": "matching.py",
            "date": "2026-11-26",
            "candidates_processed": total,
            "kg_narrators_indexed": len(kg),
            "kg_excluded_stubs": kg.excluded_stub,
            "kg_excluded_placeholder_30002": kg.excluded_placeholder,
            "elapsed_seconds": round(elapsed, 2),
            "normalization_consistency_pct": round(100.0 * agree / total, 2),
            "sources": {
                "candidates": str(WORK_DB) + " (hadith_narrators, read-only)",
                "kg": str(KG_DB) + " (narrators, read-only)",
                "note": "parser_results.json holds no candidate names; "
                        "names were read from work.db as the task allows.",
            },
            "matching_rule": (
                "candidate key = normalize_match(parser narrator_norm); "
                "match = normalized exact equality with kg name/nickname, "
                "or prefix of kg name/nickname tokens, or prefix after "
                "removing one ibn/bint generation pair before a trailing "
                "nisba/laqab (skip1; never when the last token is a "
                "father's name); stubs and id 30002 excluded."),
            "linkable_rule": (
                "category unique AND type full_name AND confidence "
                "high/medium; everything else is pending (معلّق)."),
        },
        "totals": {
            "candidates": total,
            "categories": {
                "unique_A": cat["unique"],
                "ambiguous_B": cat["ambiguous"],
                "no_match_C": cat["no_match"],
                "kunya_or_single_D": cat["kunya_or_single"],
            },
            "categories_pct": {
                k: round(100.0 * v / total, 2)
                for k, v in
                {"unique_A": cat["unique"], "ambiguous_B": cat["ambiguous"],
                 "no_match_C": cat["no_match"],
                 "kunya_or_single_D": cat["kunya_or_single"]}.items()
            },
            "linkable_confirmed": linkable_n,
            "linkable_confirmed_pct": round(100.0 * linkable_n / total, 2),
            "pending_not_linkable": total - linkable_n,
        },
        "by_type": {
            t: {"total": sum(by_type[t].values()),
                "unique_A": by_type[t]["unique"],
                "ambiguous_B": by_type[t]["ambiguous"],
                "no_match_C": by_type[t]["no_match"],
                "kunya_or_single_D": by_type[t]["kunya_or_single"]}
            for t in TYPE_AR
        },
        "by_book": {
            b: {"total": sum(by_book[b].values()),
                "unique_A": by_book[b]["unique"],
                "ambiguous_B": by_book[b]["ambiguous"],
                "no_match_C": by_book[b]["no_match"],
                "kunya_or_single_D": by_book[b]["kunya_or_single"]}
            for b in sorted(by_book)
        },
        "by_confidence": {
            c: {"total": sum(by_conf[c].values()),
                "unique_A": by_conf[c]["unique"],
                "ambiguous_B": by_conf[c]["ambiguous"],
                "no_match_C": by_conf[c]["no_match"],
                "kunya_or_single_D": by_conf[c]["kunya_or_single"]}
            for c in sorted(by_conf)
        },
        "by_co_narrator": {
            k: {"total": sum(by_co[k].values()),
                "unique_A": by_co[k]["unique"],
                "ambiguous_B": by_co[k]["ambiguous"],
                "no_match_C": by_co[k]["no_match"],
                "kunya_or_single_D": by_co[k]["kunya_or_single"]}
            for k in sorted(by_co)
        },
        "by_companion_flag": {
            k: {"total": sum(by_comp[k].values()),
                "unique_A": by_comp[k]["unique"],
                "ambiguous_B": by_comp[k]["ambiguous"],
                "no_match_C": by_comp[k]["no_match"],
                "kunya_or_single_D": by_comp[k]["kunya_or_single"]}
            for k in sorted(by_comp)
        },
        "category_D_match_breakdown": {
            "matches_0": d_sub["0"], "matches_1": d_sub["1"],
            "matches_gt1": d_sub[">1"],
        },
        "unique_match_kind": dict(a_kind),
        "linkable_by_match_kind": {
            k: sum(1 for r in results if r["linkable"] and r["match_kind"] == k)
            for k in ("exact", "prefix", "skip1")},
        "unique_but_not_linkable": {
            f"{t}|{c}": n for (t, c), n in sorted(a_not_linkable.items())},
        "hadith_coverage": {
            "hadiths_in_sample": n_hadiths_sample,
            "hadiths_with_candidates": len(hadith_ids),
            "hadiths_with_no_candidates": n_hadiths_sample - len(hadith_ids),
            "hadiths_with_at_least_one_linkable": len(hadith_linkable),
            "hadiths_with_at_least_one_linkable_pct_of_sample":
                round(100.0 * len(hadith_linkable) / n_hadiths_sample, 2),
            "hadiths_with_at_least_one_linkable_pct_of_with_candidates":
                round(100.0 * len(hadith_linkable) / len(hadith_ids), 2),
            "hadiths_with_no_linkable": n_hadiths_sample - len(hadith_linkable),
            "hadiths_with_at_least_one_unique_any_type":
                len(hadith_unique_any),
        },
        "top_single_word_names": top_single,
        "top_kunya_only": top_kunya,
        "top_ambiguous_full_names": top_amb_full,
        "hard_cases": hard_cases,
        "improvement_estimates": {
            "ambiguous_candidates": len(amb),
            "ambiguous_with_matches_spanning_gt1_tabaka":
                amb_tabaka_spread,
            "ambiguous_tabaka_spread_distribution": {
                str(k): v for k, v in sorted(amb_tabaka_detail.items())},
            "ambiguous_span_1_tabaka_only": amb_span_1,
            "ambiguous_span_2_or_3_tabaka": amb_span_2_3,
            "ambiguous_span_ge4_tabaka": amb_span_ge4,
            "companion_flagged_ambiguous": len(comp_amb_rows),
            "companion_restricted_to_sahabi_rank_unique": r3_unique,
            "companion_restricted_to_sahabi_rank_still_ambiguous": r3_amb,
            "companion_restricted_to_sahabi_rank_zero": r3_zero,
            "kunya_plus_name_no_match": len(r4_rows),
            "kunya_plus_name_suffix_unique": r4_unique,
            "kunya_plus_name_suffix_ambiguous": r4_amb,
            "kunya_plus_name_suffix_still_none": r4_no,
            "no_match_full_name": len(r5_rows),
            "drop_trailing_nisba_unique": r5_unique,
            "category_D_with_exactly_1_match": d_unique,
            "category_D_with_exactly_1_match_and_sahabi_rank": d_unique_sahabi,
            "weak_form_partial_relative_yani_with_unique_match": weak_unique,
            "kg_distinct_normalized_names": len(norm_name_to_rows),
            "kg_normalized_names_mapping_to_gt1_narrator": dup_norm_names,
        },
        "examples": {
            "linkable_confirmed": examples(lambda r: r["linkable"]),
            "ambiguous_full_name": examples(
                lambda r: r["category"] == "ambiguous"
                and r["type"] == "full_name"),
            "no_match_full_name": examples(
                lambda r: r["category"] == "no_match"
                and r["type"] == "full_name"),
            "kunya_or_single_unique_match": examples(
                lambda r: r["category"] == "kunya_or_single"
                and r["n_matches"] == 1),
        },
    }

    with open(RESULTS_JSON, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    with open(CANDIDATES_CSV, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "hadith_id", "book", "text", "norm", "confidence",
                    "type", "flags", "co_narrator", "companion", "n_matches",
                    "match_kind", "category", "linkable",
                    "matched_source_ids"])
        for r in results:
            w.writerow([r["id"], r["hadith_id"], r["book"], r["text"],
                        r["norm"], r["confidence"], r["type"],
                        ",".join(r["flags"]), int(r["co_narrator"]),
                        int(r["companion"]), r["n_matches"],
                        r["match_kind"], r["category"], int(r["linkable"]),
                        ";".join(str(s) for s in r["matched_source_ids"])])

    log(f"elapsed: {elapsed:.2f}s")
    log(f"categories: unique={cat['unique']} ambiguous={cat['ambiguous']} "
        f"no_match={cat['no_match']} kunya_or_single={cat['kunya_or_single']}")
    log(f"linkable_confirmed: {linkable_n} "
        f"({100.0 * linkable_n / total:.2f}% of candidates)")
    log(f"hadiths with >=1 linkable: {len(hadith_linkable)}/{n_hadiths_sample} "
        f"= {100.0 * len(hadith_linkable) / n_hadiths_sample:.2f}%")
    log(f"wrote {RESULTS_JSON}")
    log(f"wrote {CANDIDATES_CSV}")
    with open(RUN_LOG, "w", encoding="utf-8") as f:
        f.write("\n".join(log_lines) + "\n")
    log(f"wrote {RUN_LOG}")
    return out


# ---------------------------------------------------------------------------
# 5) اختبارات الوحدة (تثبت عمل دالة التطبيع وقواعد المطابقة)
# ---------------------------------------------------------------------------
class TestNormalize(unittest.TestCase):
    def test_tashkeel_and_hamza(self):
        # «الزُّهْرِيّ» تطابق «الزهري» بعد التطبيع
        self.assertEqual(normalize_match("الزُّهْرِيّ"), normalize_match("الزهري"))
        self.assertEqual(normalize_match("الزُّهْرِيّ"), "زهري")

    def test_alef_variants(self):
        self.assertEqual(normalize_match("أحمد"), normalize_match("إحمد"))
        self.assertEqual(normalize_match("أحمد"), "احمد")
        self.assertEqual(normalize_match("آدم"), "ادم")

    def test_ta_marbuta_and_ya(self):
        self.assertEqual(normalize_match("عائشة"), "عايشه")
        self.assertEqual(normalize_match("يحيى"), "يحيي")

    def test_ibn_ban_unified(self):
        self.assertEqual(normalize_match("محمد بن إبراهيم"),
                         normalize_match("محمد ابن ابراهيم"))

    def test_kunya_case_unified(self):
        # عن أبي هريرة == حدثنا أبو هريرة
        self.assertEqual(normalize_match("أبي هريرة"), normalize_match("أبو هريرة"))
        self.assertEqual(normalize_match("أبا هريرة"), "ابو هريره")

    def test_lone_abi_not_unified_to_abu(self):
        # «أبي» وحدها (ضمير نسبي) لا تتحول إلى «أبو» الكنية
        self.assertEqual(normalize_match("أبي"), "ابي")
        self.assertEqual(normalize_match("أبو"), "ابو")
        self.assertNotEqual(normalize_match("أبي"), normalize_match("أبو"))

    def test_allah_not_stripped(self):
        self.assertEqual(normalize_match("عبد الله"), "عبد الله")

    def test_ibn_shihab_not_just_shihab(self):
        # «ابن شهاب» لا تطابق «شهاب» وحده: كلمات المرشح ليست مساوية
        # ولا سلسلة متصلة داخل «شهاب» (أقصر منها)
        self.assertNotEqual(tokens_of("ابن شهاب"), tokens_of("شهاب"))
        self.assertFalse(is_contiguous_subseq(tokens_of("ابن شهاب"),
                                               tokens_of("شهاب")))

    def test_full_name_tokens(self):
        self.assertEqual(tokens_of("مُحَمَّدُ بْنُ إِبْرَاهِيمَ التَّيْمِيُّ"),
                         ("محمد", "بن", "ابراهيم", "تيمي"))

    def test_arabic_punctuation_stripped(self):
        self.assertEqual(normalize_match("الزهري، نحوه"), "زهري نحوه")
        self.assertEqual(normalize_match("أبو إدريس، عائذ"), "ابو ادريس عايذ")

    def test_waw_initial_name_kept(self):
        # واو حقيقية أول الاسم لا تُحذف
        self.assertEqual(normalize_match("وكيع"), "وكيع")
        self.assertEqual(normalize_match("وهب"), "وهب")


class TestMatchingRules(unittest.TestCase):
    """قواعد المطابقة على فهرس صغير مصنوع (لا يعتمد على hadith-kg)."""

    def _mini_index(self):
        idx = KgIndex.__new__(KgIndex)
        idx.rows = {}
        idx.token_rows = defaultdict(set)
        idx.name_tokens = {}
        idx.nick_tokens = {}
        idx.excluded_stub = 0
        idx.excluded_placeholder = 0
        fake = [
            (1, "سفيان بن سعيد الثوري", "سفيان الثوري"),
            (2, "سفيان بن عيينة الهلالي", "سفيان بن عيينة"),
            (3, "محمد بن شهاب الزهري", "محمد بن شهاب الزهري"),
            (4, "عبد الله بن يوسف التنيسي", "عبد الله بن يوسف"),
        ]
        for i, (sid, name, nick) in enumerate(fake):
            idx.rows[i] = {"source_id": sid, "name": name, "nickname": nick,
                           "rank_no": 3, "rank": "ثقة", "tabaka": 4}
            nt, kt = tokens_of(name), tokens_of(nick)
            idx.name_tokens[i], idx.nick_tokens[i] = nt, kt
            for t in set(nt) | set(kt):
                idx.token_rows[t].add(i)
        return idx

    def test_single_sufyan_is_ambiguous(self):
        idx = self._mini_index()
        m, kind = idx.match(tokens_of("سفيان"))
        self.assertEqual(len(m), 2)  # الثوري وابن عيينة

    def test_sufyan_does_not_match_son_of_sufyan(self):
        # «سفيان» وحده لا يطابق «أحمد بن سفيان» (الأب ليس الابن)
        idx = self._mini_index()
        idx.rows[4] = {"source_id": 5, "name": "أحمد بن سفيان",
                       "nickname": "أحمد بن سفيان", "rank_no": 3,
                       "rank": "ثقة", "tabaka": 4}
        idx.name_tokens[4] = tokens_of("أحمد بن سفيان")
        idx.nick_tokens[4] = tokens_of("أحمد بن سفيان")
        for t in set(idx.name_tokens[4]):
            idx.token_rows[t].add(4)
        m, kind = idx.match(tokens_of("سفيان"))
        self.assertEqual(len(m), 2)  # ما زالا الثوري وابن عيينة فقط

    def test_umar_not_matched_inside_son(self):
        # «عمر بن خطاب» لا يطابق «عبد الله بن عمر بن خطاب»
        idx = self._mini_index()
        idx.rows[4] = {"source_id": 6,
                       "name": "عبد الله بن عمر بن خطاب",
                       "nickname": "عبد الله بن عمر", "rank_no": 1,
                       "rank": "صحابي", "tabaka": 1}
        idx.name_tokens[4] = tokens_of("عبد الله بن عمر بن خطاب")
        idx.nick_tokens[4] = tokens_of("عبد الله بن عمر")
        for t in set(idx.name_tokens[4]) | set(idx.nick_tokens[4]):
            idx.token_rows[t].add(4)
        m, kind = idx.match(tokens_of("عمر بن خطاب"))
        self.assertEqual(len(m), 0)

    def test_skipped_generation_still_matches(self):
        # «محمد بن إبراهيم التيمي» يطابق «محمد بن إبراهيم بن الحارث التيمي»
        # (الإسناد يسقط حلقة قبل النسبة) — عبر الكنية المختصرة هنا
        idx = self._mini_index()
        idx.rows[4] = {"source_id": 7,
                       "name": "محمد بن إبراهيم بن الحارث التيمي",
                       "nickname": "محمد بن إبراهيم التيمي", "rank_no": 3,
                       "rank": "ثقة", "tabaka": 4}
        idx.name_tokens[4] = tokens_of("محمد بن إبراهيم بن الحارث التيمي")
        idx.nick_tokens[4] = tokens_of("محمد بن إبراهيم التيمي")
        for t in set(idx.name_tokens[4]) | set(idx.nick_tokens[4]):
            idx.token_rows[t].add(4)
        m, kind = idx.match(tokens_of("محمد بن إبراهيم التيمي"))
        self.assertEqual(len(m), 1)
        self.assertEqual(kind, "exact")  # يساوي الكنية

    def test_skip1_kind_when_only_name_has_extra_generation(self):
        # نفس الحالة لكن الكنية لا تساوي المرشح: نوع المطابقة skip1
        idx = self._mini_index()
        idx.rows[4] = {"source_id": 7,
                       "name": "محمد بن إبراهيم بن الحارث التيمي",
                       "nickname": "محمد التيمي", "rank_no": 3,
                       "rank": "ثقة", "tabaka": 4}
        idx.name_tokens[4] = tokens_of("محمد بن إبراهيم بن الحارث التيمي")
        idx.nick_tokens[4] = tokens_of("محمد التيمي")
        for t in set(idx.name_tokens[4]) | set(idx.nick_tokens[4]):
            idx.token_rows[t].add(4)
        m, kind = idx.match(tokens_of("محمد بن إبراهيم التيمي"))
        self.assertEqual(len(m), 1)
        self.assertEqual(kind, "skip1")

    def test_father_not_replaced_by_grandfather(self):
        # «عبد الله بن يوسف» لا يطابق «عبد الله بن محمد بن يوسف»
        # (الأب محمد لا يُستبدل بالجد يوسف)
        idx = self._mini_index()
        idx.rows[4] = {"source_id": 8,
                       "name": "عبد الله بن محمد بن يوسف",
                       "nickname": "عبد الله بن محمد", "rank_no": 3,
                       "rank": "ثقة", "tabaka": 4}
        idx.name_tokens[4] = tokens_of("عبد الله بن محمد بن يوسف")
        idx.nick_tokens[4] = tokens_of("عبد الله بن محمد")
        for t in set(idx.name_tokens[4]) | set(idx.nick_tokens[4]):
            idx.token_rows[t].add(4)
        m, kind = idx.match(tokens_of("عبد الله بن يوسف"))
        # المطابق الوحيد المسموح هو صف الاختبار الأصلي (التنيسي)؛
        # أما «عبد الله بن محمد بن يوسف» (source_id 8) فلا يطابق
        self.assertNotIn(4, m)
        self.assertEqual(
            {idx.rows[i]["source_id"] for i in m}, {4})

    def test_umar_not_matched_to_descendant(self):
        # «عمر بن خطاب» لا يطابق ذريته (عمر بن حمزة بن عبد الله
        # بن عمر بن الخطاب) — حذف حلقة ممنوع حين تكون الكلمة
        # الأخيرة اسم أب
        idx = self._mini_index()
        idx.rows[4] = {"source_id": 9,
                       "name": "عمر بن حمزة بن عبد الله بن عمر بن الخطاب",
                       "nickname": "عمر بن حمزة العدوي", "rank_no": 8,
                       "rank": "ضعيف الحديث", "tabaka": 5}
        idx.name_tokens[4] = tokens_of(
            "عمر بن حمزة بن عبد الله بن عمر بن الخطاب")
        idx.nick_tokens[4] = tokens_of("عمر بن حمزة العدوي")
        for t in set(idx.name_tokens[4]) | set(idx.nick_tokens[4]):
            idx.token_rows[t].add(4)
        m, kind = idx.match(tokens_of("عمر بن خطاب"))
        self.assertEqual(len(m), 0)

    def test_ibn_shihab_does_not_match_zuhri(self):
        # «ابن شهاب» وحده لا يطابق الزهري (ليس أول الاسم)
        idx = self._mini_index()
        m, kind = idx.match(tokens_of("ابن شهاب"))
        self.assertEqual(len(m), 0)

    def test_full_sufyan_thawri_unique(self):
        idx = self._mini_index()
        m, kind = idx.match(tokens_of("سفيان الثوري"))
        self.assertEqual(len(m), 1)
        self.assertEqual(kind, "exact")  # يساوي الكنية بعد التطبيع

    def test_zuhri_nickname_unique(self):
        idx = self._mini_index()
        m, kind = idx.match(tokens_of("محمد بن شهاب الزهري"))
        self.assertEqual(len(m), 1)

    def test_prefix_name_matches_longer(self):
        idx = self._mini_index()
        m, kind = idx.match(tokens_of("عبد الله بن يوسف"))
        self.assertEqual(len(m), 1)
        self.assertEqual(kind, "exact")  # يساوي الكنية المختصرة

    def test_no_match(self):
        idx = self._mini_index()
        m, kind = idx.match(tokens_of("زيد بن أسلم القرشي"))
        self.assertEqual(len(m), 0)

    def test_candidate_type_priority(self):
        self.assertEqual(
            candidate_type(parse_flags("chain_index=0; flags=relative_reference,single_word_name")),
            "relative")
        self.assertEqual(
            candidate_type(parse_flags("chain_index=0; flags=kunya_only")),
            "kunya_only")
        self.assertEqual(
            candidate_type(parse_flags("chain_index=0; flags=")), "full_name")
        self.assertEqual(
            candidate_type(parse_flags(
                "chain_index=0; flags=yani_clarification; clarification=ابن سعد")),
            "yani")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--test":
        unittest.main(argv=[sys.argv[0], "-v"])
    else:
        run()
