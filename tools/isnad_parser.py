#!/usr/bin/env python3
"""Isnad parser — SUNNATI Phase 5 (tools/isnad_parser.py).

Extracts narrator *candidates* (in order) from a hadith's `text` field,
where the isnad is merged with the matn in the source. The parser works
only on the text in front of it; it NEVER judges an isnad's authenticity
or connectedness, and it NEVER links a name to a narrator row: every
candidate has ``narrator_id = None`` and ``match_status`` ``'unlinked'``
(or ``'needs_review'``). Linking is a separate, future step that requires
a verified, licensed narrator source plus human review — no such source
has been imported (narrators table: 0 rows), so nothing is linked here.

What the parser does
--------------------
* Normalisation is used for MATCHING ONLY. The original text is never
  modified: every candidate records ``start_char`` / ``end_char`` offsets
  into the original text, and ``narrator_text`` is the verbatim slice
  (with tashkeel exactly as the source gives it).
* The isnad is segmented on performance formulae (صيغ الأداء):
  حدثنا / حدثني / أخبرنا / أخبرني / أنبأنا / سمعت / عن / قال ...
  A name is the run of name-like words between two formulae.
* The isnad ends at the first detected matn boundary: a mention of
  رسول الله / النبي as the subject of قال / سمعت / أن, a قال after a
  companion marked رضي الله عنه, or a قال / أن followed by matn
  content (a non-performance verb such as أرسل / سأل / قام / خطب).
* Co-narrators joined by واو العطف (``مسعر وسفيان عن ...``) are split
  into separate candidates sharing one position (``link_type =
  'co_narrator'``) and flagged for review.
* ``يعني`` clarifications (``إسماعيل يعني ابن أبي خالد``) are attached
  to the preceding candidate as ``clarification`` (the clarifying words
  complete the candidate span) and flagged for review — never treated
  as a second narrator.
* The letter ح (tahwil) closes the current chain and opens a second
  chain in the same hadith (``isnad_chains.chain_index`` 0, 1, ...).
* Relative references (``حدثنا أبي`` / ``عن أبيه``), single-word names
  (``سفيان`` / ``شعيب`` / ``الزهري``), partial names (``ابن شهاب``) and
  kunya-only mentions (``أبو هريرة``) are extracted as candidates but
  marked ``needs_review``: the span is certain, the IDENTITY is not.

Confidence (per extraction) — Arabic labels in CONFIDENCE_AR
------------------------------------------------------------
* ``high``    (عالية):   >= 3 name words, clear formulae on both sides,
  no review flag (e.g. ``يحيى بن سعيد الأنصاري``).
* ``medium``  (متوسطة): exactly 2 name words, no review flag, or a
  single-word name explicitly marked as a Companion (``علي رضي الله
  عنه`` — the رضي marker identifies the Companion as the matn source).
* ``low``     (منخفضة): extracted, but the segment boundary itself is
  uncertain (implicit link with no performance formula, uncertain
  co-narrator split, truncated scan).
* ``needs_review`` (يحتاج مراجعة): the span is extracted but the
  identity is ambiguous by construction — single-word name, partial
  name (``ابن + اسم``), kunya only, relative reference, or a ``يعني``
  clarification. These stay ``unlinked`` in the review queue.

``isnad_status`` (structural only — NOT a judgement of ittisal/sihha):
* ``complete``            — a matn boundary was found and >= 2
  narrators were extracted, with no review flag on any of them.
* ``complete_with_review``— same, but >= 1 narrator / segment needs
  review (the common case: a single-word name inside a full isnad).
* ``partial``             — >= 1 narrator but no matn boundary found
  (truncated or uncertain end).
* ``none``                — no narrator extracted (e.g. muallaq-style
  text starting directly with the matn).

Normalisation mirrors ``tools/build_db.py::normalize_ar`` (and
``lib/core/normalize.dart``): strip tashkeel/tatweel, unify hamzas,
ى→ي, ة→ه. It is duplicated here (not imported) so this module stays
usable standalone in tests and in the sample runner.

Usage:
    python3 tools/isnad_parser.py --text "حدثنا وكيع قال ..."
    python3 tools/isnad_parser.py --db ~/workspace/phase5-work/work.db \\
        --limit 500 --store --out ~/workspace/phase5-work/parser_results.json
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
import statistics
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

PARSER_VERSION = "isnad_parser v1.0 (phase5)"

CONFIDENCE_AR = {
    "high": "عالية",
    "medium": "متوسطة",
    "low": "منخفضة",
    "needs_review": "يحتاج مراجعة",
}

# ---------------------------------------------------------------------------
# Normalisation (matching only — original text is never modified).
# ---------------------------------------------------------------------------
_DIACRITICS = (
    "\u064b\u064c\u064d\u064e\u064f\u0650\u0651\u0652\u0653\u0654\u0655"
    "\u0670\u0640"
)
_HAMZA_MAP = str.maketrans({
    "أ": "ا", "إ": "ا", "آ": "ا", "ؤ": "و", "ئ": "ي",
    "ى": "ي", "ة": "ه", "ٱ": "ا",
})
_TOKEN_SPLIT = re.compile(
    r"[^\s\u060c\u061b\u061f\u0640\u200e\u200f\u061c"
    r"«»\"\"''()\[\]{}<>،,؛:.؟!…\-–—/\\|*_=+@#%^&~`]+"
)


def normalize_text(text: str) -> str:
    """Strip tashkeel/tatweel, unify hamzas, ى→ي, ة→ه (matching only)."""
    s = "".join(ch for ch in text if ch not in _DIACRITICS)
    s = s.translate(_HAMZA_MAP)
    return re.sub(r"\s+", " ", s).strip()


def normalize_token(token: str) -> str:
    s = "".join(ch for ch in token if ch not in _DIACRITICS)
    return s.translate(_HAMZA_MAP)


@dataclass
class Token:
    text: str          # verbatim slice (with tashkeel)
    norm: str          # normalised form (matching only)
    start: int         # char offset in the ORIGINAL text
    end: int           # char offset (exclusive) in the ORIGINAL text


def tokenize(text: str) -> list[Token]:
    out: list[Token] = []
    for m in _TOKEN_SPLIT.finditer(text):
        raw = m.group(0)
        out.append(Token(text=raw, norm=normalize_token(raw),
                         start=m.start(), end=m.end()))
    return out


# ---------------------------------------------------------------------------
# Vocabulary (all in normalised form).
# ---------------------------------------------------------------------------
# Performance formulae that introduce a narrator.
TELL = {
    "حدثنا", "حدثني", "حدثه", "حدثهم", "حدثتنا", "حدثا", "حدثوا",
    "حدث", "حدثت", "حدثني",
    "اخبرنا", "اخبرني", "اخبره", "اخبرهم", "اخبرتنا", "اخبرا",
    "اخبر", "اخبرت",
    "انبانا", "انباني", "انبا", "انباه", "انباهم", "انبات",
}
HEAR = {"سمعت", "سمعنا", "سمع", "سمعا", "سمعوا", "سمعته", "سمعتها"}
AN = {"عن"}                       # عن X — the core isnad connector
LINK_MARKERS = TELL | HEAR | AN
SAY = {"قال", "قالت", "قالا", "قالوا", "قلت", "قلنا",
       "يقول", "تقول", "يقولون"}
COMPLEMENT = {"ان", "انه", "انها", "اني", "اننا", "انهم", "انهما"}
# Words that may carry a و/ف/ب prefix before a known form
# (وحدثنا، فأخبرنا، بأن ...).
_PREFIXABLE = LINK_MARKERS | SAY | COMPLEMENT | {
    "هذا", "هذه", "ذلك", "تلك", "حديثه", "حديثها", "حديثهم",
}
KUNYA = {"ابو", "ابا", "ابي", "ام", "ابن", "ابنه", "بن", "بنت"}
RELATIVE_REFS = {"ابي", "ابيه", "ابيها", "ابوه", "ابيهم", "امي", "امه"}
PROPHET_WORDS = {"رسول", "النبي", "نبي"}
BLESSING = {"صلى", "عليه", "وسلم", "الله"}
# Prepositions whose following word is scene-setting, not a narrator
# (على المنبر، في قوله تعالى ...): the word after them is skipped.
# NOTE: these are NORMALISED forms. على normalises to علي — the same
# string as the name علي. At the top level a bare علي is treated as
# the preposition (a narrator علي always follows a formula and is
# collected inside _collect_segment); inside a segment, is_name_like()
# only accepts علي as the first word or after بن/ابن.
PREP_SKIP = {"في", "علي", "الي", "من", "عند", "مع", "بين",
             "بعد", "قبل", "حتى"}
# Chain-note tokens (parenthetical, not narrators): وهذا حديثه.
CHAIN_NOTE = {"حديثه", "حديثها", "حديثهم", "حديثي", "هذا", "هذه",
              "ذلك", "تلك"}
# Matn verbs: after a name, they mean the matn has started, not a
# narration (أرسل إليه، سأل رسول الله، قام أبو بكر فحمد الله، خطبنا ...).
MATN_VERBS = {
    "ارسل", "سال", "قام", "خطب", "خطبنا", "خرج", "دخل", "وقف",
    "جلس", "بكى", "ضحك", "نام", "اكل", "شرب", "مشى", "ركب",
    "نظر", "اشترى", "كان", "كانت", "يكون", "اول", "بدئ",
}
STOPWORDS = {
    "في", "من", "الى", "الي", "عن", "ان", "انه", "انها", "اني",
    "انا", "انت", "هو", "هي", "هم", "هن", "هذا", "هذه", "ذلك", "تلك",
    "ثم", "اذا", "اذ", "حين", "يوم", "لما", "قد", "لم", "لن", "لا",
    "ما", "الذي", "التي", "الذين", "كما", "اما", "لكن", "بل", "او",
    "حتى", "بعد", "قبل", "عند", "مع", "بين", "غير", "كل",
    "بعض", "اي", "يا", "ايها", "انما", "حيث", "منذ", "الا", "كان",
    "كانت", "يكون", "تكون", "وهو", "وهي", "وهم", "عنه", "عنها",
    "عنهم", "عنهما", "عليه", "عليها", "اليه", "اليها", "فيه",
    "فيها", "به", "بها", "له", "لها", "منه", "منها", "رضي", "الله",
    "صلى", "عليه", "وسلم", "يعني", "ح", "اول", "ثم", "كنت", "كنا",
    "كانوا",
}
NOT_NAME = MATN_VERBS | {
    "قال", "قالت", "قالا", "قالوا", "يقول", "تقول", "سمعت", "سمع",
    "حدثنا", "حدثني", "اخبرنا", "اخبرني", "رسول", "النبي", "نبي",
    "قوله", "قول", "حديث", "حديثه", "حديثها", "حديثهم", "يحدث",
    "تحدث", "فتح", "سمعت", "ليمنعني", "يمنعني",
}

REVIEW_MESSAGES = {
    "single_word_name": "اسم مفرد (مثل سفيان / شعيب / الزهري) — الهوية غامضة؛ لا يُربط تلقائياً ويحتاج تحديداً من مصدر موثوق",
    "partial_name": "اسم ناقص (ابن + اسم واحد، مثل ابن شهاب) — الهوية غامضة؛ لا يُربط تلقائياً",
    "kunya_only": "كنية فقط بلا اسم (مثل أبو هريرة / أبو صالح) — الهوية غامضة؛ لا تُربط تلقائياً",
    "relative_reference": "إشارة نسبية بلا اسم صريح (أبي / أبيه) — لا يمكن ربطها براوٍ",
    "yani_clarification": "توضيح بـ«يعني» — أُلحق التوضيح بالاسم السابق كمرشح واحد؛ يحتاج مراجعة بشرية",
    "co_narrator_split": "رواة متوازون بواو العطف — قُسّموا كمرشحين منفصلين بنفس المرتبة؛ يحتاج مراجعة بشرية",
    "chain_break_tahwil": "حرف تحويل (ح) — سلسلة ثانية في الحديث نفسه",
    "implicit_link": "اسم بلا صيغة أداء صريحة — استخراج منخفض الثقة",
    "truncated_isnad": "توقف المسح عند حدّ الأمان قبل تحديد نهاية السند",
    "no_matn_boundary": "لم يُعثر على بداية متن واضحة — السند جزئي",
    "empty_segment": "صيغة أداء بلا اسم بعدها",
}


def verb_base(norm: str) -> str:
    """Strip a leading و/ف/ب when the remainder is a known form.

    Never strips و from a name such as وكيع: stripping happens only
    when the remainder is in the known-form set (وحدثنا -> حدثنا).
    """
    s = norm
    for _ in range(2):
        if len(s) > 1 and s[0] in "وفب" and s[1:] in _PREFIXABLE:
            s = s[1:]
        else:
            break
    return s


def is_name_like(tok: Token, prev_norm: str | None = None) -> bool:
    n = tok.norm
    # «ابن عُلَيَّةَ»: the proper name علية normalises to عليه, which
    # collides with the pronoun عليه — after ابن/بن it is a name.
    if n == "عليه" and prev_norm in ("ابن", "بن"):
        return True
    # «عبد الله» / «عبيد الله»: الله is part of the name after عبد/عبيد.
    if n == "الله" and prev_norm in ("عبد", "عبيد"):
        return True
    # على (preposition) normalises to علي, the name: accept علي as a
    # name only as the first word of a name or after بن/ابن
    # (محمد بن علي); after any other word it is the preposition.
    if n == "علي" and prev_norm not in (None, "بن", "ابن"):
        return False
    # A و/ف-prefixed particle is not a name (وما، وفي، ومن ...):
    # strip one prefix and re-check the sets. Genuine و-initial names
    # (وكيع، وقاص، وهب) survive: their remainder is in no set.
    if len(n) > 2 and n[0] in "وف":
        core = n[1:]
        if (core in STOPWORDS or core in NOT_NAME or core in LINK_MARKERS
                or core in SAY or core in COMPLEMENT):
            return False
    if len(n) < 2 or not re.fullmatch(r"[\u0621-\u064a\u0660-\u0669]+", n):
        return False
    if n in STOPWORDS or n in NOT_NAME or n in LINK_MARKERS or n in SAY:
        return False
    if n in PROPHET_WORDS or n in BLESSING:
        return False
    if verb_base(n) in LINK_MARKERS or verb_base(n) in SAY:
        return False
    if verb_base(n) in COMPLEMENT:
        return False
    if verb_base(n) in CHAIN_NOTE:
        return False
    return True


def is_nisba(norm: str) -> bool:
    return norm.startswith("ال") and norm.endswith("ي") and len(norm) > 3


@dataclass
class NarratorCandidate:
    position: int                    # 1-based rank in its chain
    narrator_text: str               # verbatim slice of the original text
    narrator_norm: str               # normalised form (matching only)
    start_char: int
    end_char: int
    link_type: str                   # haddathana | akhbarana | anbaana |
                                     # sami'a | an | qala | anna | co_narrator
                                     # | implicit
    confidence: str                  # high | medium | low | needs_review
    match_status: str = "unlinked"   # always unlinked / needs_review here
    narrator_id: int | None = None   # ALWAYS None: no verified source
    companion_marked: bool = False   # followed by رضي الله عنه(ا)
    clarification: str = ""          # text after يعني, if any
    flags: list[str] = field(default_factory=list)
    notes: str = ""

    def to_dict(self) -> dict:
        d = asdict(self)
        d["confidence_ar"] = CONFIDENCE_AR[self.confidence]
        return d


@dataclass
class ChainResult:
    chain_index: int
    narrators: list[NarratorCandidate] = field(default_factory=list)
    is_primary: bool = True


@dataclass
class ParseResult:
    hadith_id: int | None = None
    book: str = ""
    hadith_number: str = ""
    narrators: list[NarratorCandidate] = field(default_factory=list)
    chains: list[ChainResult] = field(default_factory=list)
    isnad_text: str = ""
    isnad_start_char: int | None = None
    matn_start_char: int | None = None
    boundary_reason: str = ""
    isnad_complete: bool = False
    isnad_status: str = "none"
    companion_marked: bool = False
    review_items: list[dict] = field(default_factory=list)
    parser_version: str = PARSER_VERSION

    def to_dict(self) -> dict:
        return {
            "hadith_id": self.hadith_id,
            "book": self.book,
            "hadith_number": self.hadith_number,
            "hadith_key": f"{self.book}:{self.hadith_number}" if self.book else "",
            "narrators": [n.to_dict() for n in self.narrators],
            "chains": [
                {"chain_index": c.chain_index,
                 "is_primary": c.is_primary,
                 "narrator_count": len(c.narrators),
                 "positions": [n.position for n in c.narrators]}
                for c in self.chains
            ],
            "narrator_count": len(self.narrators),
            "isnad_text": self.isnad_text,
            "isnad_start_char": self.isnad_start_char,
            "matn_start_char": self.matn_start_char,
            "boundary_reason": self.boundary_reason,
            "isnad_complete": self.isnad_complete,
            "isnad_status": self.isnad_status,
            "companion_marked": self.companion_marked,
            "review_items": self.review_items,
            "parser_version": self.parser_version,
        }


# ---------------------------------------------------------------------------
# Identity resolution — deliberately a stub until a verified source exists.
# ---------------------------------------------------------------------------
def resolve_identity(candidate_norm: str,
                     verified_narrators: list[dict] | None = None) -> dict:
    """Decide whether a candidate may be linked to a narrator row.

    With no verified narrator source (the real situation: narrators
    table is EMPTY), the answer is always ``unlinked``. If a caller
    supplies verified rows, a single-word / partial candidate that
    matches more than one row is ``ambiguous`` and is still NOT linked.
    A positive link is only ever returned for an exact full-name match
    against a caller-supplied verified row — that path is untested by
    design here because no verified source exists yet.
    """
    verified = verified_narrators or []
    if not verified:
        return {"narrator_id": None, "decision": "unlinked",
                "match_type": "no_verified_source",
                "reason": "no verified narrator source imported yet"}
    exact = [r for r in verified
             if normalize_text(r.get("name", "")) == candidate_norm]
    if len(exact) == 1:
        return {"narrator_id": exact[0].get("id"), "decision": "linked_verified",
                "match_type": "exact_full_name", "reason": ""}
    if len(exact) > 1:
        return {"narrator_id": None, "decision": "ambiguous",
                "match_type": "multiple_exact_matches",
                "reason": "more than one verified narrator shares this name"}
    # No exact match. A short candidate that is the first name of
    # several verified narrators (bare «سفيان» vs الثوري / ابن عيينة)
    # is ambiguous by construction — still NOT linked.
    first_token = candidate_norm.split(" ")[0] if candidate_norm else ""
    sharing = [r for r in verified
               if normalize_text(r.get("name", "")).split(" ")[0:1]
               == [first_token]
               and normalize_text(r.get("name", "")) != candidate_norm]
    if len(sharing) >= 2:
        return {"narrator_id": None, "decision": "ambiguous",
                "match_type": "shared_first_name",
                "reason": "candidate is a bare first name shared by "
                          f"{len(sharing)} verified narrators"}
    return {"narrator_id": None, "decision": "unlinked",
            "match_type": "no_match",
            "reason": "no verified narrator matches this candidate"}


# ---------------------------------------------------------------------------
# The parser.
# ---------------------------------------------------------------------------
MAX_ISNAD_TOKENS = 80        # safety cap: isnads are a prefix, not the text
MAX_ISNAD_CHARS = 2500


def _confidence_for(words: list[Token], flags: set[str]) -> str:
    if flags & {"yani_clarification", "relative_reference",
                "partial_name", "kunya_only"}:
        return "needs_review"
    if len(words) == 1:
        if "companion" in flags:
            return "medium"      # علي رضي الله عنه — رضي marks the Companion
        return "needs_review"
    if flags & {"implicit_link", "co_narrator_uncertain", "truncated"}:
        return "low"
    if len(words) >= 3:
        return "high"
    if len(words) == 2:
        return "medium"
    return "needs_review"


class _Scanner:
    def __init__(self, text: str):
        self.text = text
        self.tokens = tokenize(text)
        self.n = len(self.tokens)
        self.i = 0
        self.chains: list[ChainResult] = [ChainResult(chain_index=0)]
        self.review_items: list[dict] = []
        self.boundary_reason = ""
        self.matn_start: int | None = None
        self.isnad_start: int | None = None
        self.truncated = False

    # -- helpers ------------------------------------------------------
    @property
    def chain(self) -> ChainResult:
        return self.chains[-1]

    def _review(self, code: str, position: int | None = None,
                narrator_text: str = "") -> None:
        self.review_items.append({
            "code": code,
            "message": REVIEW_MESSAGES[code],
            "narrator_position": position,
            "narrator_text": narrator_text,
        })

    def _tok(self, j: int) -> Token | None:
        return self.tokens[j] if 0 <= j < self.n else None

    def _is_marker_at(self, j: int) -> bool:
        t = self._tok(j)
        return t is not None and verb_base(t.norm) in LINK_MARKERS

    def _is_say_at(self, j: int) -> bool:
        t = self._tok(j)
        return t is not None and verb_base(t.norm) in SAY

    def _name_run_end(self, j: int) -> int:
        """End index (exclusive) of a run of name-like tokens from j."""
        k = j
        # The run's first token is judged on its own (a run starting
        # with علي is a name); later tokens use the previous run token
        # as context (علي after بن/ابن is a name, otherwise على).
        prev: str | None = None
        while k < self.n and is_name_like(self.tokens[k], prev):
            prev = self.tokens[k].norm
            k += 1
        return k

    def _say_decision(self, j: int) -> str:
        """Decide what a قال-family token at j does.

        Returns 'filler' (قال introduces a narrator / another formula),
        or 'matn' (قال opens the matn). Consecutive قال tokens are
        looked through: قال قال رسول الله -> matn.
        """
        k = j
        while k < self.n and self._is_say_at(k):
            k += 1
        if k >= self.n:
            return "matn"
        t = self.tokens[k]
        b = verb_base(t.norm)
        if b in LINK_MARKERS:
            # قال سمعت رسول الله -> the سمعت belongs to the matn.
            if b in HEAR:
                after = self._tok(k + 1)
                if after is not None and after.norm in PROPHET_WORDS:
                    return "matn"
            return "filler"
        if t.norm in PROPHET_WORDS:
            return "matn"
        if is_name_like(t):
            run_end = self._name_run_end(k)
            nxt = self._tok(run_end)
            if nxt is not None and (
                    verb_base(nxt.norm) in LINK_MARKERS
                    or self._is_say_at(run_end)):
                # قال ابن شهاب وأخبرني ... / قال جابر ... قال ...
                # The name IS a narrator; the following قال opens matn.
                # A name run ending in رضي is NOT collected here: e.g.
                # قال الحارث بن هشام رضي الله عنه سأل رسول الله —
                # that man is the matn's questioner, not a narrator.
                return "filler"
            return "matn"
        return "matn"

    def _an_decision(self, j: int) -> str:
        """Decide what an أن-family token at j does.

        Returns 'filler' (أن + narrator + formula: collect the name),
        'marker_next' (أن followed directly by a formula: consume أن),
        or 'matn'.
        """
        k = j + 1
        if k >= self.n:
            return "matn"
        t = self.tokens[k]
        b = verb_base(t.norm)
        if b in LINK_MARKERS:
            if b in HEAR:
                after = self._tok(k + 1)
                if after is not None and after.norm in PROPHET_WORDS:
                    return "matn"
            return "marker_next"
        if t.norm in PROPHET_WORDS:
            return "matn"
        if self._is_say_at(k):
            return "matn" if self._say_decision(k) == "matn" else "marker_next"
        if is_name_like(t):
            run_end = self._name_run_end(k)
            nxt = self._tok(run_end)
            if nxt is not None and (
                    verb_base(nxt.norm) in LINK_MARKERS
                    or self._is_say_at(run_end)):
                return "filler"
            return "matn"
        return "matn"

    # -- segment collection -------------------------------------------
    def _collect_segment(self, link_type: str) -> list[NarratorCandidate]:
        """Collect one (or several co-) narrator candidate(s) at self.i.

        self.i points at the first token after the performance formula.
        Returns the candidates (possibly empty) and advances self.i past
        the segment. Stops before the next formula / matn trigger.
        """
        out: list[NarratorCandidate] = []
        words: list[Token] = []
        flags: set[str] = set()
        clarification = ""
        co_next = False
        start_of_words: int | None = None

        def finish_words() -> NarratorCandidate | None:
            nonlocal words, flags, clarification, co_next
            if not words:
                return None
            if start_of_words is None:
                return None
            cand_flags = set(flags)
            if len(words) == 1:
                cand_flags.add("single_word_name")
            if len(words) == 2 and words[0].norm in ("ابن", "بن"):
                cand_flags.add("partial_name")
            if (len(words) == 2 and words[0].norm in
                    ("ابو", "ابا", "ابي", "ام")):
                cand_flags.add("kunya_only")
            if len(words) == 1 and words[0].norm in RELATIVE_REFS:
                cand_flags.add("relative_reference")
            conf = _confidence_for(words, cand_flags)
            raw = self.text[words[0].start:words[-1].end]
            # Canonicalise the kunya's case in the MATCHING form only
            # (أبا/أبي سفيان -> أبو سفيان): the verbatim slice keeps the
            # original case. A lone أبي/أبيه (relative reference) is
            # NOT canonicalised, so it stays distinguishable.
            norm_words = [
                ("ابو" if (i == 0 and len(words) >= 2
                           and w.norm in ("ابا", "ابي")) else w.norm)
                for i, w in enumerate(words)
            ]
            cand = NarratorCandidate(
                position=0,  # assigned by the caller
                narrator_text=raw,
                narrator_norm=" ".join(norm_words),
                start_char=words[0].start,
                end_char=words[-1].end,
                link_type=("co_narrator" if co_next else link_type),
                confidence=conf,
                match_status=("needs_review"
                              if conf in ("needs_review", "low")
                              else "unlinked"),
                companion_marked="companion" in cand_flags,
                clarification=clarification,
                flags=sorted(cand_flags),
                notes=("; ".join(REVIEW_MESSAGES[c]
                                  for c in sorted(cand_flags)
                                  if c in REVIEW_MESSAGES)),
            )
            words = []
            flags = set()
            clarification = ""
            co_next = False
            return cand

        while self.i < self.n:
            tok = self.tokens[self.i]
            b = verb_base(tok.norm)
            # Next formula / قال / أن / تحويل ends the segment.
            if (b in LINK_MARKERS or self._is_say_at(self.i)
                    or b in COMPLEMENT or tok.norm == "ح"):
                break
            if tok.norm in PROPHET_WORDS:
                break
            # Chain-note words (وهذا حديثه) end the segment.
            if b in CHAIN_NOTE or tok.norm in CHAIN_NOTE:
                break
            # Companion marker: رضي الله عنه / عنها — ends the segment.
            if tok.norm == "رضي":
                flags.add("companion")
                self.i += 1
                # consume الله عنه / عنها / عنهم
                for _ in range(3):
                    t2 = self._tok(self.i)
                    if t2 is None:
                        break
                    if t2.norm in ("الله", "عنه", "عنها", "عنهم", "عنهما"):
                        self.i += 1
                    else:
                        break
                break
            if tok.norm == "يعني":
                flags.add("yani_clarification")
                self.i += 1
                clar: list[Token] = []
                prev_norm = words[-1].norm if words else None
                while (self.i < self.n and len(clar) < 4
                       and is_name_like(self.tokens[self.i], prev_norm)):
                    clar.append(self.tokens[self.i])
                    prev_norm = self.tokens[self.i].norm
                    self.i += 1
                if clar:
                    clarification = " ".join(c.text for c in clar)
                    words.extend(clar)   # the clarification completes the name
                continue
            if ((tok.norm in STOPWORDS or tok.norm in NOT_NAME)
                    and not is_name_like(
                        tok, words[-1].norm if words else None)):
                # Context exceptions (عبد الله / ابن علية) are names:
                # is_name_like() with the previous word decides.
                break
            # و-conjunction: possible co-narrator split.
            # Guard: a name ending in بن/ابن is INCOMPLETE, so a و-word
            # after it continues the same name (علقمة بن وقاص — وقاص
            # is the father's name, not و + قاص). A split happens only
            # when the remainder is a kunya starter, when a formula
            # follows the و-word (مسعر وسفيان عن ...), or when the
            # current name is already complete (>= 2 words, not
            # ending in بن/ابن).
            if (words and tok.norm.startswith("و") and len(tok.norm) > 2
                    and tok.norm[1:] not in STOPWORDS
                    and (tok.norm[1:] in KUNYA
                         or is_name_like(Token(tok.text, tok.norm[1:],
                                               tok.start, tok.end)))):
                nxt = self._tok(self.i + 1)
                nxt_is_marker = (
                    nxt is not None
                    and (verb_base(nxt.norm) in LINK_MARKERS
                         or self._is_say_at(self.i + 1)))
                name_complete = (len(words) >= 2
                                 and words[-1].norm not in (
                                     "بن", "ابن", "ابي", "ابو", "ابا",
                                     "ام", "بنت"))
                # A name ending in بن/ابن/أبي/أبو/أم/بنت is INCOMPLETE: the
                # next word is the father's (or kunya's) name even when it
                # starts with و (سعد بن أبي وقاص — وقاص is the father's
                # name, not و + قاص; ابن وهب) — never split there.
                if words[-1].norm in ("بن", "ابن", "ابي", "ابو", "ابا",
                                      "ام", "بنت"):
                    can_split = False
                else:
                    can_split = (tok.norm[1:] in KUNYA or nxt_is_marker
                                 or name_complete)
                if can_split:
                    done = finish_words()
                    if done is not None:
                        done.flags = sorted(
                            set(done.flags) | {"co_narrator_split"})
                        out.append(done)
                    flags.add("co_narrator_split")
                    co_next = True
                    stripped = Token(tok.text, tok.norm[1:],
                                     tok.start, tok.end)
                    words = [stripped]
                    if start_of_words is None:
                        start_of_words = stripped.start
                    self.i += 1
                    continue
            if is_name_like(tok, words[-1].norm if words else None):
                if start_of_words is None:
                    start_of_words = tok.start
                words.append(tok)
                self.i += 1
                continue
            break

        done = finish_words()
        if done is not None:
            out.append(done)
        return out

    # -- main scan ------------------------------------------------------
    def run(self) -> ParseResult:
        res = ParseResult()
        skip_scene = 0          # words to skip after على / في ...
        scanned = 0
        while self.i < self.n:
            tok = self.tokens[self.i]
            if tok.start > MAX_ISNAD_CHARS or scanned >= MAX_ISNAD_TOKENS:
                self.truncated = True
                self._review("truncated_isnad")
                break
            scanned += 1
            # Scene words after a preposition (على المنبر، في قوله
            # تعالى) are skipped — but never a formula, a قال, or a
            # Prophet mention: those end / continue the isnad.
            if skip_scene > 0:
                b_sc = verb_base(tok.norm)
                if (b_sc in LINK_MARKERS or b_sc in COMPLEMENT
                        or tok.norm in PROPHET_WORDS or tok.norm == "ح"
                        or self._is_say_at(self.i)):
                    skip_scene = 0
                else:
                    skip_scene -= 1
                    self.i += 1
                    continue
            b = verb_base(tok.norm)

            # Chain break: حرف التحويل ح.
            if tok.norm == "ح":
                self._review("chain_break_tahwil")
                self.chains.append(
                    ChainResult(chain_index=len(self.chains),
                                is_primary=False))
                self.i += 1
                continue
            # Prophet mention at top level: the matn has started.
            if tok.norm in PROPHET_WORDS:
                self.matn_start = tok.start
                self.boundary_reason = "prophet_mention"
                break
            # Performance formula: collect the following name segment.
            if b in LINK_MARKERS:
                # عن / سمعت رسول الله — matn, not a narrator.
                nxt = self._tok(self.i + 1)
                if nxt is not None and nxt.norm in PROPHET_WORDS:
                    self.matn_start = nxt.start
                    self.boundary_reason = "prophet_mention"
                    break
                # سمعت من رسول الله — من + رسول.
                if nxt is not None and nxt.norm == "من":
                    after = self._tok(self.i + 2)
                    if after is not None and after.norm in PROPHET_WORDS:
                        self.matn_start = after.start
                        self.boundary_reason = "prophet_mention"
                        break
                link_map = {"عن": "an"}
                if b in TELL:
                    link_type = ("haddathana" if b.startswith("حدث")
                                 else "akhbarana" if b.startswith("اخبر")
                                 else "anbaana")
                elif b in HEAR:
                    link_type = "sami'a"
                else:
                    link_type = link_map.get(b, "an")
                if self.isnad_start is None:
                    self.isnad_start = tok.start
                self.i += 1
                # Nothing name-like follows: no segment (e.g. stray من).
                nxt2 = self._tok(self.i)
                if nxt2 is None or (not is_name_like(nxt2)
                                    and nxt2.norm not in ("يعني",)
                                    and not (nxt2.norm.startswith("و")
                                             and len(nxt2.norm) > 2)):
                    continue
                cands = self._collect_segment(link_type)
                if not cands:
                    self._review("empty_segment")
                    continue
                self._append_candidates(cands, link_type)
                continue
            # قال-family: filler or matn opener.
            if self._is_say_at(self.i):
                decision = self._say_decision(self.i)
                if decision == "filler":
                    # قال حدثنا ... / قال ابن شهاب وأخبرني ...
                    # Consume the قال token(s); a following name is
                    # collected by the name branch below / next loop.
                    while self.i < self.n and self._is_say_at(self.i):
                        # If a name follows the قال, collect it now with
                        # link_type 'qala'; otherwise just skip قال.
                        nxt = self._tok(self.i + 1)
                        if (nxt is not None and is_name_like(nxt)
                                and self._say_decision(self.i) == "filler"):
                            if self.isnad_start is None:
                                self.isnad_start = tok.start
                            self.i += 1
                            cands = self._collect_segment("qala")
                            if cands:
                                self._append_candidates(cands, "qala")
                            break
                        self.i += 1
                    continue
                self.matn_start = tok.start
                self.boundary_reason = "matn_after_qala"
                break
            # أن-family: narrator introducer or matn opener.
            if b in COMPLEMENT:
                decision = self._an_decision(self.i)
                if decision == "marker_next":
                    self.i += 1
                    continue
                if decision == "filler":
                    if self.isnad_start is None:
                        self.isnad_start = tok.start
                    self.i += 1
                    cands = self._collect_segment("anna")
                    if cands:
                        self._append_candidates(cands, "anna")
                    continue
                self.matn_start = tok.start
                self.boundary_reason = "matn_after_anna"
                break
            # Chain-note / demonstrative tokens: skip, keep scanning.
            if tok.norm in CHAIN_NOTE or b in CHAIN_NOTE:
                self.i += 1
                continue
            # Preposition: the next word(s) are scene-setting.
            if tok.norm in PREP_SKIP:
                skip_scene = 2
                self.i += 1
                continue
            # A bare name with no formula: only accept it when it looks
            # like a person name (ابن / أبو / nisba / رضي follows);
            # otherwise it is matn content and the isnad is over.
            if is_name_like(tok):
                nxt = self._tok(self.i + 1)
                nxt2 = self._tok(self.i + 2)
                looks_like_name = (
                    tok.norm in KUNYA
                    or (nxt is not None and nxt.norm in ("بن", "ابن"))
                    or is_nisba(tok.norm)
                    or (nxt is not None and nxt.norm == "رضي")
                    or (nxt2 is not None and nxt2.norm == "رضي"))
                if looks_like_name and not self.chain.narrators:
                    if self.isnad_start is None:
                        self.isnad_start = tok.start
                    cands = self._collect_segment("implicit")
                    for c in cands:
                        c.flags = sorted(set(c.flags) | {"implicit_link"})
                        c.confidence = "low"
                        c.match_status = "needs_review"
                    if cands:
                        self._append_candidates(cands, "implicit")
                    continue
                if self.chain.narrators or self.chains[0].narrators:
                    self.matn_start = tok.start
                    self.boundary_reason = "matn_content_word"
                    break
                self.i += 1
                continue
            # Anything else after narrators exist: matn. Before any
            # narrator: skip leading filler.
            if self.chains[0].narrators or self.chain.narrators:
                self.matn_start = tok.start
                self.boundary_reason = "matn_content_word"
                break
            self.i += 1

        # -- assemble ---------------------------------------------------
        all_narrators: list[NarratorCandidate] = []
        for ch in self.chains:
            all_narrators.extend(ch.narrators)
        res.narrators = all_narrators
        res.chains = self.chains
        res.review_items = self.review_items
        res.matn_start_char = self.matn_start
        res.isnad_start_char = self.isnad_start
        res.boundary_reason = self.boundary_reason
        if self.matn_start is not None and self.isnad_start is not None:
            res.isnad_text = self.text[self.isnad_start:self.matn_start]
        elif self.isnad_start is not None and all_narrators:
            res.isnad_text = self.text[
                self.isnad_start:all_narrators[-1].end_char]
        res.companion_marked = any(n.companion_marked
                                   for n in all_narrators)
        if not all_narrators:
            res.isnad_status = "none"
            res.isnad_complete = False
            if self.boundary_reason == "":
                res.boundary_reason = "no_narrator_found"
        elif self.matn_start is not None:
            res.isnad_complete = True
            needs = any(n.confidence in ("needs_review", "low")
                        for n in all_narrators)
            res.isnad_status = ("complete_with_review" if needs
                                else "complete")
        else:
            res.isnad_status = "partial"
            res.isnad_complete = False
            if not self.truncated:
                self._review("no_matn_boundary")
                res.review_items = self.review_items
        # Per-narrator review items (one per flag, de-duplicated).
        seen: set[tuple] = set()
        for n in all_narrators:
            for fl in n.flags:
                if fl in REVIEW_MESSAGES and fl not in ("companion",):
                    key = (fl, n.position, n.narrator_text)
                    if key in seen:
                        continue
                    seen.add(key)
                    self._review(fl, position=n.position,
                                 narrator_text=n.narrator_text)
        res.review_items = self.review_items
        return res

    def _append_candidates(self, cands: list[NarratorCandidate],
                           link_type: str) -> None:
        # Rank, not row count: co-narrators share one position, so the
        # next rank is max(position) + 1, not len(narrators) + 1.
        base = max((n.position for n in self.chain.narrators), default=0)
        for k, cand in enumerate(cands):
            cand.position = base + k + 1
            if cand.link_type == "co_narrator":
                # Co-narrators share the rank of the narrator they
                # stand beside: same position value as the first
                # candidate of this batch.
                cand.position = base + 1
            self.chain.narrators.append(cand)


def parse_isnad(text: str, hadith_id: int | None = None,
                book: str = "", hadith_number: str = "") -> ParseResult:
    """Parse one hadith text into ordered narrator candidates."""
    scanner = _Scanner(text or "")
    res = scanner.run()
    res.hadith_id = hadith_id
    res.book = book
    res.hadith_number = hadith_number
    return res


# ---------------------------------------------------------------------------
# Sample runner: parse first N hadiths per book, store candidates, measure.
# ---------------------------------------------------------------------------
SAMPLE_BOOKS = ("bukhari", "muslim", "ahmad")
STORE_SOURCE = (f"{PARSER_VERSION} — machine-extracted candidates, "
                "unverified, narrator_id NULL")


def _chain_confidence(narrators: list[NarratorCandidate]) -> str:
    confs = [n.confidence for n in narrators]
    if "needs_review" in confs:
        return "needs_review"
    if "low" in confs:
        return "low"
    if "medium" in confs:
        return "medium"
    return "high" if confs else ""


def store_result(con: sqlite3.Connection, res: ParseResult) -> dict:
    """Store one parse result as CANDIDATES (narrator_id always NULL).

    Writes isnad_chains + isnad_nodes + hadith_narrators +
    isnad_relations + narrator_identity_matches. Never writes a
    narrators row, never sets a narrator_id, never records a status.
    Returns counts of rows written.
    """
    counts = {"chains": 0, "nodes": 0, "hadith_narrators": 0,
              "relations": 0, "identity_matches": 0}
    if res.hadith_id is None:
        return counts
    for ch in res.chains:
        if not ch.narrators and ch.chain_index != 0:
            continue
        cur = con.execute(
            "INSERT INTO isnad_chains (hadith_id, chain_index, is_primary,"
            " narrator_count, is_complete, status, parser_version, source,"
            " reviewed_at, confidence, notes) VALUES (?, ?, ?, ?, ?, ?, ?,"
            " ?, '', ?, ?)",
            (res.hadith_id, ch.chain_index, 1 if ch.is_primary else 0,
             len(ch.narrators), 1 if res.isnad_complete else 0,
             res.isnad_status, PARSER_VERSION, STORE_SOURCE,
             _chain_confidence(ch.narrators),
             f"boundary={res.boundary_reason}; "
             f"review_codes={sorted({i['code'] for i in res.review_items})}; "
             f"companion_marked={res.companion_marked}"),
        )
        chain_id = cur.lastrowid
        counts["chains"] += 1
        node_ids: list[int] = []
        for n in ch.narrators:
            cur = con.execute(
                "INSERT INTO isnad_nodes (chain_id, hadith_id, position,"
                " narrator_id, narrator_text, narrator_norm, start_char,"
                " end_char, link_type, confidence, match_status, source,"
                " reviewed_at, notes) VALUES (?, ?, ?, NULL, ?, ?, ?, ?,"
                " ?, ?, ?, ?, '', ?)",
                (chain_id, res.hadith_id, n.position, n.narrator_text,
                 n.narrator_norm, n.start_char, n.end_char, n.link_type,
                 n.confidence, n.match_status, STORE_SOURCE,
                 f"flags={','.join(n.flags)}"
                 + (f"; clarification={n.clarification}"
                    if n.clarification else "")),
            )
            node_ids.append(cur.lastrowid)
            counts["nodes"] += 1
            con.execute(
                "INSERT INTO hadith_narrators (hadith_id, narrator_id,"
                " position, narrator_text, narrator_norm, start_char,"
                " end_char, link_type, confidence, match_status, source,"
                " reviewed_at, notes) VALUES (?, NULL, ?, ?, ?, ?, ?, ?,"
                " ?, ?, ?, '', ?)",
                (res.hadith_id, n.position, n.narrator_text,
                 n.narrator_norm, n.start_char, n.end_char, n.link_type,
                 n.confidence, n.match_status, STORE_SOURCE,
                 f"chain_index={ch.chain_index}; flags={','.join(n.flags)}"
                 + (f"; clarification={n.clarification}"
                    if n.clarification else "")),
            )
            counts["hadith_narrators"] += 1
            decision = ("ambiguous" if n.confidence == "needs_review"
                        else "unlinked")
            match_type = ("single_word_name" if "single_word_name" in n.flags
                          else "partial_name" if "partial_name" in n.flags
                          else "kunya_only" if "kunya_only" in n.flags
                          else "relative_reference"
                          if "relative_reference" in n.flags
                          else "yani_clarification"
                          if "yani_clarification" in n.flags
                          else "no_verified_source")
            con.execute(
                "INSERT INTO narrator_identity_matches (candidate_text,"
                " candidate_norm, narrator_id, match_type, score,"
                " decided_by, reviewed_at, decision, notes)"
                " VALUES (?, ?, NULL, ?, NULL, ?, '', ?, ?)",
                (n.narrator_text, n.narrator_norm, match_type,
                 f"{PARSER_VERSION} — automatic, no verified narrator "
                 "source exists", decision,
                 "deliberately NOT linked: identity unverified"),
            )
            counts["identity_matches"] += 1
        for a, b in zip(node_ids, node_ids[1:]):
            con.execute(
                "INSERT INTO isnad_relations (chain_id, from_node_id,"
                " to_node_id, relation_type, source, reviewed_at,"
                " confidence, notes) VALUES (?, ?, ?, 'heard_from', ?,"
                " '', ?, ?)",
                (chain_id, a, b, STORE_SOURCE,
                 _chain_confidence(ch.narrators),
                 "from_node heard from to_node (chain order); "
                 "no authenticity judgement"),
            )
            counts["relations"] += 1
    return counts


def _time_query(con: sqlite3.Connection, sql: str, params: tuple = (),
                repeats: int = 5) -> dict:
    times: list[float] = []
    rows = None
    for _ in range(repeats):
        t0 = time.perf_counter()
        rows = con.execute(sql, params).fetchall()
        times.append((time.perf_counter() - t0) * 1000.0)
    return {"sql": sql, "params": [str(p) for p in params],
            "median_ms": round(statistics.median(times), 3),
            "min_ms": round(min(times), 3),
            "max_ms": round(max(times), 3),
            "repeats": repeats, "rows": len(rows or [])}


def measure_query_performance(con: sqlite3.Connection,
                              sample_ids: list[int]) -> dict:
    """Time the queries the narrator UI will run, on the big DB."""
    out: dict = {}
    out["count_hadith_narrators"] = _time_query(
        con, "SELECT COUNT(*) FROM hadith_narrators")
    out["count_isnad_nodes"] = _time_query(
        con, "SELECT COUNT(*) FROM isnad_nodes")
    out["count_isnad_chains"] = _time_query(
        con, "SELECT COUNT(*) FROM isnad_chains")
    out["count_narrators_still_zero"] = _time_query(
        con, "SELECT COUNT(*) FROM narrators")
    hid = sample_ids[len(sample_ids) // 2]
    out["lookup_hadith_narrators_by_hadith"] = _time_query(
        con, "SELECT position, narrator_text, confidence, match_status"
             " FROM hadith_narrators WHERE hadith_id = ?"
             " ORDER BY position", (hid,))
    out["lookup_isnad_chains_by_hadith"] = _time_query(
        con, "SELECT chain_index, narrator_count, is_complete, status"
             " FROM isnad_chains WHERE hadith_id = ?", (hid,))
    out["lookup_nodes_by_chain"] = _time_query(
        con, "SELECT position, narrator_text FROM isnad_nodes"
             " WHERE chain_id = (SELECT id FROM isnad_chains"
             " WHERE hadith_id = ? ORDER BY chain_index LIMIT 1)"
             " ORDER BY position", (hid,))
    # 100 point lookups, as the reader screen would do while scrolling.
    t0 = time.perf_counter()
    total_rows = 0
    for h in sample_ids[:100]:
        total_rows += len(con.execute(
            "SELECT 1 FROM hadith_narrators WHERE hadith_id = ?",
            (h,)).fetchall())
    dt = (time.perf_counter() - t0) * 1000.0
    out["hundred_point_lookups"] = {
        "total_ms": round(dt, 3), "avg_ms_per_lookup": round(dt / 100, 3),
        "rows": total_rows}
    out["join_hadiths_needs_review"] = _time_query(
        con, "SELECT h.book, h.num, hn.narrator_text FROM hadith_narrators hn"
             " JOIN hadiths h ON h.id = hn.hadith_id"
             " WHERE hn.match_status = 'needs_review' LIMIT 20")
    out["aggregate_confidence"] = _time_query(
        con, "SELECT confidence, COUNT(*) FROM hadith_narrators"
             " GROUP BY confidence")
    out["aggregate_match_status"] = _time_query(
        con, "SELECT match_status, COUNT(*) FROM hadith_narrators"
             " GROUP BY match_status")
    out["explain_lookup"] = con.execute(
        "EXPLAIN QUERY PLAN SELECT position, narrator_text FROM"
        " hadith_narrators WHERE hadith_id = ?", (hid,)).fetchall()
    out["explain_lookup"] = [list(r) for r in out["explain_lookup"]]
    out["explain_join"] = con.execute(
        "EXPLAIN QUERY PLAN SELECT h.book FROM hadith_narrators hn"
        " JOIN hadiths h ON h.id = hn.hadith_id"
        " WHERE hn.match_status = 'needs_review' LIMIT 20").fetchall()
    out["explain_join"] = [list(r) for r in out["explain_join"]]
    out["db_page_count"] = con.execute("PRAGMA page_count").fetchone()[0]
    out["db_page_size"] = con.execute("PRAGMA page_size").fetchone()[0]
    return out


def run_sample(db_path: str, limit: int = 500,
               books: tuple[str, ...] = SAMPLE_BOOKS,
               store: bool = False) -> dict:
    """Parse the first `limit` hadiths (by seq) of each book."""
    con = sqlite3.connect(db_path)
    try:
        import hashlib
        db_sha = hashlib.sha256(Path(db_path).read_bytes()).hexdigest()
        if store:
            # Idempotent re-runs: the v3 candidate tables in the work DB
            # hold ONLY parser output, so wipe parser rows once up front
            # (per-hadith deletes cannot work for
            # narrator_identity_matches, which carries no hadith_id).
            con.execute("DELETE FROM isnad_relations")
            con.execute("DELETE FROM isnad_nodes")
            con.execute("DELETE FROM isnad_chains")
            con.execute("DELETE FROM hadith_narrators")
            con.execute("DELETE FROM narrator_identity_matches"
                        " WHERE decided_by LIKE 'isnad_parser%'")
            con.commit()
        per_book: dict = {}
        per_hadith: list[dict] = []
        totals = {"hadiths": 0, "narrators": 0, "chains": 0}
        conf_dist: dict[str, int] = {}
        status_dist: dict[str, int] = {}
        review_code_dist: dict[str, int] = {}
        parse_times: list[float] = []
        stored_counts = {"chains": 0, "nodes": 0, "hadith_narrators": 0,
                         "relations": 0, "identity_matches": 0}
        sample_ids: list[int] = []
        for book in books:
            rows = con.execute(
                "SELECT id, num, hadith_number, text FROM hadiths"
                " WHERE book = ? ORDER BY seq LIMIT ?",
                (book, limit)).fetchall()
            b_stats = {"hadiths": len(rows), "narrators": 0,
                       "complete": 0, "complete_with_review": 0,
                       "partial": 0, "none": 0, "companion_marked": 0,
                       "review_items": 0, "multi_chain": 0,
                       "parse_ms_total": 0.0}
            for hid, num, hnum, text in rows:
                sample_ids.append(hid)
                t0 = time.perf_counter()
                res = parse_isnad(text, hadith_id=hid, book=book,
                                  hadith_number=str(hnum))
                dt_ms = (time.perf_counter() - t0) * 1000.0
                parse_times.append(dt_ms)
                b_stats["parse_ms_total"] += dt_ms
                b_stats["narrators"] += len(res.narrators)
                b_stats[res.isnad_status] += 1
                if res.companion_marked:
                    b_stats["companion_marked"] += 1
                b_stats["review_items"] += len(res.review_items)
                if len(res.chains) > 1:
                    b_stats["multi_chain"] += 1
                totals["hadiths"] += 1
                totals["narrators"] += len(res.narrators)
                totals["chains"] += len(res.chains)
                status_dist[res.isnad_status] = (
                    status_dist.get(res.isnad_status, 0) + 1)
                for n in res.narrators:
                    conf_dist[n.confidence] = (
                        conf_dist.get(n.confidence, 0) + 1)
                for item in res.review_items:
                    review_code_dist[item["code"]] = (
                        review_code_dist.get(item["code"], 0) + 1)
                per_hadith.append({
                    "hadith_id": hid, "hadith_key": f"{book}:{hnum}",
                    "narrator_count": len(res.narrators),
                    "chain_count": len(res.chains),
                    "isnad_status": res.isnad_status,
                    "isnad_complete": res.isnad_complete,
                    "companion_marked": res.companion_marked,
                    "boundary_reason": res.boundary_reason,
                    "confidences": [n.confidence for n in res.narrators],
                    "review_codes": sorted(
                        {i["code"] for i in res.review_items}),
                    "parse_ms": round(dt_ms, 3),
                })
                if store:
                    sc = store_result(con, res)
                    for k, v in sc.items():
                        stored_counts[k] += v
            per_book[book] = b_stats
        if store:
            con.commit()
        query_perf = measure_query_performance(con, sample_ids)
        narrators_rows = con.execute(
            "SELECT COUNT(*) FROM narrators").fetchone()[0]
        result = {
            "parser_version": PARSER_VERSION,
            "db_path": db_path,
            "db_sha256": db_sha,
            "sample": {"books": list(books), "limit_per_book": limit,
                       "definition": "first N hadiths per book by seq"},
            "totals": totals,
            "per_book": per_book,
            "isnad_status_distribution": status_dist,
            "confidence_distribution": conf_dist,
            "review_code_distribution": review_code_dist,
            "review_items_total": sum(review_code_dist.values()),
            "parse_time_ms": {
                "mean": round(statistics.mean(parse_times), 3),
                "median": round(statistics.median(parse_times), 3),
                "p95": round(sorted(parse_times)[int(len(parse_times) * 0.95)],
                             3),
                "max": round(max(parse_times), 3),
                "total": round(sum(parse_times), 3),
                "n": len(parse_times),
            },
            "stored_rows": stored_counts if store else None,
            "narrators_rows_in_db": narrators_rows,
            "query_performance": query_perf,
            "definitions": {
                "isnad_complete": "matn boundary found AND >= 2 narrators"
                                  " extracted (structural only; NOT a"
                                  " judgement of ittisal or sihha)",
                "complete_with_review": "complete, but >= 1 narrator needs"
                                        " review (e.g. single-word name)",
                "confidence": CONFIDENCE_AR,
                "match_status": "all candidates unlinked/needs_review;"
                                " narrator_id is always NULL — no verified"
                                " narrator source imported yet",
            },
            "per_hadith": per_hadith,
        }
        return result
    finally:
        con.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="SUNNATI isnad parser (Phase 5)")
    ap.add_argument("--text", default=None, help="Parse one hadith text")
    ap.add_argument("--db", default=None, help="Work DB path for the sample run")
    ap.add_argument("--limit", type=int, default=500)
    ap.add_argument("--books", default="bukhari,muslim,ahmad")
    ap.add_argument("--store", action="store_true",
                    help="Store candidates in the work DB (narrator_id NULL)")
    ap.add_argument("--out", default=None, help="Write sample JSON here")
    args = ap.parse_args(argv)
    if args.text is not None:
        res = parse_isnad(args.text)
        print(json.dumps(res.to_dict(), ensure_ascii=False, indent=1))
        return 0
    if args.db is None:
        ap.error("--db is required for the sample run (or use --text)")
    result = run_sample(args.db, limit=args.limit,
                        books=tuple(b.strip() for b in args.books.split(",")),
                        store=args.store)
    if args.out:
        Path(args.out).write_text(
            json.dumps(result, ensure_ascii=False, indent=1),
            encoding="utf-8")
        print(f"wrote {args.out}")
    t = result["totals"]
    print(f"parsed {t['hadiths']} hadiths -> {t['narrators']} narrator"
          f" candidates in {t['chains']} chains")
    print(f"status: {result['isnad_status_distribution']}")
    print(f"confidence: {result['confidence_distribution']}")
    print(f"review items: {result['review_items_total']}")
    print(f"parse time mean {result['parse_time_ms']['mean']} ms/hadith")
    print(f"narrators rows in DB (must stay 0): "
          f"{result['narrators_rows_in_db']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
