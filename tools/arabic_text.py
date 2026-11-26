#!/usr/bin/env python3
"""Arabic text helpers for SUNNATI Phase 4 search — Python mirror of the
Dart code in ``lib/core/normalize.dart`` + ``lib/core/stemming.dart`` +
``lib/search/semantic.dart``.

Rules that MUST stay in sync across Python and Dart (master prompt §7):
  * The stored hadith text is NEVER modified: diacritics are kept in the
    database. Normalisation produces a SEPARATE indexed form used only
    for search (the ``norm`` / FTS columns).
  * Normalisation: strip tashkeel/tatweel, unify hamzas, ى→ي, ة→ه,
    strip punctuation, strip prefixes و/ف/ب/ل/ك + ال (index variants).
  * Light stemming / root key: a HEURISTIC grouping key, not a real
    morphological analysis. It groups regular derivations
    (صلاة/صلوات/يصلي → «صل») but does NOT unify broken plurals or
    different patterns (كتاب/كتب/كاتب stay apart). Documented limitation.
  * Synonyms: a small HAND-CURATED list of common near-synonyms /
    related terms (see ``SYNONYMS`` / ``RELATED``). It is NOT a
    linguistic authority and NOT derived from an external dictionary:
    each pair is a search convenience, labelled as such in the UI
    («بحث دلالي معجمي» — lexical, not vector embeddings, not an LLM).
    No pair here asserts a religious ruling or an equivalence of
    meaning beyond ordinary usage.
  * Spelling variants: ابن↔بن (isnad orthography) and عبد الله written
    joined (عبدالله) vs split — handled as query variants, never by
    rewriting stored text.
"""
from __future__ import annotations

import re

# ---------------------------------------------------------------------------
# Normalisation — mirror of lib/core/normalize.dart and tools/build_db.py.
# ---------------------------------------------------------------------------
_DIACRITICS = "ًٌٍَُِّْٰٓـ"
_HAMZA_MAP = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ؤ": "و", "ئ": "ي", "ى": "ي", "ة": "ه"})
_PUNCT = re.compile(r"[^\u0621-\u064a\u0660-\u0669\u06f0-\u06f90-9\s]")


def normalize_ar(text: str) -> str:
    """Strip tashkeel/tatweel, unify hamzas, ى→ي, ة→ه, strip punctuation."""
    s = "".join(ch for ch in text if ch not in _DIACRITICS)
    s = s.translate(_HAMZA_MAP)
    s = _PUNCT.sub(" ", s)
    return re.sub(r"\s+", " ", s).strip()


def strip_prefixes(word: str) -> str:
    """Strip ال and و/ف/ب/ل/ك prefixes (same rule as normalize.dart)."""
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


def index_variants(word: str) -> list[str]:
    stripped = strip_prefixes(word)
    return [word] if stripped in (word, "") else [word, stripped]


def fts_norm(text: str) -> str:
    """Normalised text with prefix-stripped index variants per word."""
    out: list[str] = []
    for word in normalize_ar(text).split(" "):
        if word:
            out.extend(index_variants(word))
    return " ".join(out)


def query_terms(query: str) -> list[str]:
    """Normalise a user query and return its search terms (prefix-stripped)."""
    return [t for t in (strip_prefixes(w) for w in normalize_ar(query).split(" ")) if t]


# ---------------------------------------------------------------------------
# Light stemming / root key (heuristic — see module docstring).
#
# Deliberately CONSERVATIVE (precision over recall): only the article
# prefixes, ONE verb prefix (يـ), regular nominal suffixes, and a
# weak-letter ending unification (ا/و → ي). تـ/نـ/أ verb prefixes are NOT
# stripped — they collapse unrelated nouns (نيات «intentions» with فتيات
# «girls»). Trailing ي/و are NOT stripped — they collapse 2-letter
# roots across unrelated words (شر «evil» with شريك «partner»).
# Groups whose key is a stopword (علي/عليه، أن…) are dropped by the
# index builder, so a search for the Companion علي never expands into
# عليه (which occurs in almost every hadith).
# ---------------------------------------------------------------------------
# Suffixes tried longest-first. A strip is kept only if >= 3 letters
# remain — except ه and ات, which may leave >= 2 (نيه/نيات → «ني»).
# Final ن is NOT a suffix here: stripping it collapses أيمن «right-hand»
# into إيمان «faith» (ايمن → ايم).
_SUFFIXES = ("ات", "ون", "ين", "ان", "وا", "ية", "ها", "هم", "هن", "كم", "نا",
             "ه", "ي", "ك", "ة", "ت")
# Compound article prefixes stripped first (stricter than strip_prefixes:
# a bare و/ف/ب/ل/ك is stripped only when >= 4 letters remain, so «وصل»
# does NOT collapse into the «صل» root group).
_COMPOUND_PREFIXES = ("وال", "فال", "بال", "كال", "لل", "ال")


def _strip_root_prefixes(word: str) -> str:
    w = word
    changed = True
    while changed:
        changed = False
        for p in _COMPOUND_PREFIXES:
            if w.startswith(p) and len(w) - len(p) >= 3:
                w = w[len(p):]
                changed = True
                break
        else:
            if len(w) >= 5 and w[0] in "وفبلك":
                w = w[1:]
                changed = True
    return w


def light_stem(word: str) -> str:
    """Heuristic stem of one normalised word (see module docstring)."""
    w = _strip_root_prefixes(word)
    # Verb prefix يـ only, when >= 3 letters remain (يصلي → صلي).
    if len(w) >= 4 and w[0] == "ي":
        w = w[1:]
    # Up to two suffix strips, longest first.
    for _ in range(2):
        stripped = False
        for suf in _SUFFIXES:
            min_remain = 2 if suf in ("ه", "ات") else 3
            if w.endswith(suf) and len(w) - len(suf) >= min_remain:
                w = w[: -len(suf)]
                stripped = True
                break
        if not stripped:
            break
    # Weak-letter ending unification: final ا/و → ي (صلا/صلو → صلي).
    if len(w) >= 3 and w[-1] in "او":
        w = w[:-1] + "ي"
    return w


def root_key(word: str) -> str:
    """Root-group key for one normalised word.

    Returns '' when the word is too short to group safely (<= 1 letter
    after prefix stripping) — such words are never root-expanded.
    """
    base = _strip_root_prefixes(word)
    if len(base) <= 1:
        return ""
    stem = light_stem(word)
    return stem if len(stem) >= 2 else ""


# ---------------------------------------------------------------------------
# Spelling variants (orthographic only — no meaning is asserted).
# ---------------------------------------------------------------------------
# ابن <-> بن inside isnads: the same person is written both ways.
IBN_VARIANTS = {"ابن": "بن", "بن": "ابن"}


def spelling_variants(term: str) -> list[str]:
    """Extra query forms for one normalised term.

    * «ابن» <-> «بن».
    * Joined «عبدX» (عبدالله، عبدالرحمن…) also searches the split
      form «عبد X» — returned as the two-word variant ``'عبد X'``.
    """
    out: list[str] = []
    if term in IBN_VARIANTS:
        out.append(IBN_VARIANTS[term])
    if term.startswith("عبد") and len(term) > 3:
        out.append("عبد " + term[3:])
    return out


# ---------------------------------------------------------------------------
# Curated lexical synonyms / related terms (hand-written, Phase 4).
#
# Keys and values are NORMALISED forms (hamzas unified, ة→ه, ى→ي).
# kind 'synonym' = near-synonym in ordinary usage; kind 'related' =
# closely associated term a searcher usually also wants (e.g. ركوع with
# سجود). Neither kind claims the two words are interchangeable in a
# religious ruling. Expansion applies only to terms of >= 3 letters.
# ---------------------------------------------------------------------------
SYNONYMS: dict[str, list[str]] = {
    "صوم": ["صيام"],
    "صيام": ["صوم"],
    "زكاه": ["صدقه"],
    "صدقه": ["زكاه"],
    "طهاره": ["وضوء"],
    "وضوء": ["طهاره"],
    "نكاح": ["زواج"],
    "زواج": ["نكاح"],
    "جهاد": ["قتال"],
    "قتال": ["جهاد"],
    "علم": ["معرفه"],
    "معرفه": ["علم"],
    "دعاء": ["ذكر"],
    "ذكر": ["دعاء"],
    "توبه": ["استغفار"],
    "استغفار": ["توبه"],
    "بر": ["احسان"],
    "احسان": ["بر"],
    "غسل": ["اغتسال"],
    "اغتسال": ["غسل"],
    "نبي": ["رسول"],
    "رسول": ["نبي"],
    "موت": ["وفاه"],
    "وفاه": ["موت"],
    "نار": ["جهنم"],
    "جهنم": ["نار"],
    "شيطان": ["ابليس"],
    "ابليس": ["شيطان"],
    "ملائكه": ["ملك"],
    "ملك": ["ملائكه"],
    "جنه": ["فردوس"],
    "فردوس": ["جنه"],
    "طلاق": ["خلع"],
    "خلع": ["طلاق"],
}

RELATED: dict[str, list[str]] = {
    "سجود": ["ركوع"],
    "ركوع": ["سجود"],
    "حج": ["عمره"],
    "عمره": ["حج"],
}

# Common words dropped from similarity (not from search): they occur in
# almost every hadith and carry no discriminating meaning.
STOPWORDS = {
    "في", "من", "الي", "عن", "ان", "ما", "لا", "قد", "ثم", "قال", "رسول",
    "الله", "عليه", "وسلم", "صلي", "الذي", "التي", "كان", "يكون", "هذا",
    "هذه", "ذلك", "كل", "لم", "لن", "هو", "هي", "هم", "اذا", "او", "ام",
    "بل", "لكن", "علي", "مع", "بعد", "قبل", "عند", "بين", "غير", "حتي",
    "كما", "لما", "انما", "انه", "انها", "يا", "ايها", "بن", "ابن", "ابي",
    "ابو", "رضي", "عنه", "عنها", "عنهم", "قالوا", "قالت", "حدثنا", "حدثني",
    "اخبرنا", "اخبرني", "سمعت", "انبأنا", "يعني", "ح", "ثنا", "انا", "ومن",
}
