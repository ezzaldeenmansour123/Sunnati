#!/usr/bin/env python3
"""Reference search engine for SUNNATI Phase 4 (Python mirror of the Dart
``lib/search/search_service.dart`` + ``lib/search/semantic.dart``).

The Dart code is the shipped implementation; this module is the testable
reference — same normalisation (``tools/arabic_text.py``), same query
expansion, same ranking tiers, same pagination contract — run against a
work copy of the library database by ``tools/test_search_phase4.py``.

Ranking tiers (documented in the Phase 4 report and the UI):
  1. exact phrase (the normalised query as a contiguous phrase): +100
  2. all literal terms present (FTS AND): +50 (guaranteed for FTS hits)
  3. semantic expansion hit (root / synonym term): +20 per term, max +40
  4. FTS5 bm25 rank as a tie-breaker: +max(0, 10 + rank)
Within a tier, results order by score, then book order, then hadith number.

Semantic search here is LEXICAL («بحث دلالي معجمي»): query expansion by
root groups (``search_roots``, derived from the corpus vocabulary) and by
the curated synonym list (``search_synonyms``). It is NOT vector
embeddings and NOT a language model; the UI and the report say so.
Root/synonym expansion applies to TEXT search only — never to narrator
or Companion name search (names are proper nouns; expanding them would
merge different people).

Pagination: the database is NEVER fully loaded. A page is one SQL query
with LIMIT/OFFSET (plus one COUNT query for the total). The ranking pool
is capped at 500 literal + 500 expansion candidates; the total count is
exact SQL COUNTs, so a total above the pool is still reported honestly.
"""
from __future__ import annotations

import sqlite3
from dataclasses import dataclass, field

from arabic_text import (
    STOPWORDS,
    normalize_ar,
    query_terms,
    root_key,
    spelling_variants,
    strip_prefixes,
)

# Ranking pool caps (see module docstring).
POOL_LIMIT = 500
DEFAULT_PAGE_SIZE = 20
SIMILAR_THRESHOLD = 0.30
SIMILAR_CANDIDATES = 200


@dataclass
class SearchQuery:
    text: str = ""
    book_id: str | None = None
    grade: str | None = None
    chapter_id: int | None = None
    narrator: str = ""
    companion: str = ""
    # all | matn | isnad | commentary | takhrij
    scope: str = "all"
    semantic: bool = False
    page: int = 1
    page_size: int = DEFAULT_PAGE_SIZE

    @property
    def offset(self) -> int:
        return max(0, (max(1, self.page) - 1) * self.page_size)


@dataclass
class SearchHit:
    hadith_id: int
    book: str
    num: int
    chapter_id: int
    chapter_title: str
    text: str
    score: float
    tier: str  # phrase | literal | semantic
    matched_terms: list[str] = field(default_factory=list)


@dataclass
class CommentaryHit:
    commentary_id: int
    hadith_key: str
    title: str
    text: str
    explanation: str
    grade_ar: str
    source: str


@dataclass
class SearchPage:
    items: list
    total: int
    page: int
    page_size: int
    semantic_note: str = ""

    @property
    def total_pages(self) -> int:
        return max(1, -(-self.total // self.page_size))

    @property
    def has_more(self) -> bool:
        return self.page < self.total_pages


def build_fts_query(terms: list[str]) -> str:
    """Safe FTS5 MATCH string: quoted prefix terms joined with AND.

    Each term becomes ``("term"* OR "variant"*)`` when it has spelling
    variants (ابن↔بن); a joined «عبدالله» also searches the split phrase
    ``"عبد"* "الله"*``. Terms are quoted, never interpolated raw.
    Terms are normalised first: a whitespace-only or diacritics-only
    term must not emit empty quoted tokens (""*), which FTS5 rejects.
    """
    parts: list[str] = []
    for raw_term in terms:
        term = normalize_ar(raw_term)
        if not term:
            continue
        variants = [term, *spelling_variants(term)]
        alts: list[str] = []
        for v in variants:
            if " " in v:
                words = [w for w in v.split(" ") if w]
                if words:
                    alts.append(
                        " ".join(
                            f'"{w.replace(chr(34), "")}"*' for w in words
                        )
                    )
            else:
                alts.append(f'"{v.replace(chr(34), "")}"*')
        if not alts:
            continue
        parts.append("(" + " OR ".join(alts) + ")" if len(alts) > 1 else alts[0])
    return " AND ".join(parts)


def build_fts_or_query(terms: list[str]) -> str:
    """OR of quoted prefix terms (for expansion / similar candidates)."""
    clean = [normalize_ar(t) for t in terms]
    clean = [t for t in clean if t]
    return " OR ".join(f'"{t.replace(chr(34), "")}"*' for t in clean)


class SearchEngine:
    """Search over a SUNNATI library database (read-only)."""

    def __init__(self, db_path: str):
        self.con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        self.con.row_factory = sqlite3.Row
        tables = {
            r[0]
            for r in self.con.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
        self.has_spans = "hadith_spans" in tables and "hadith_spans_fts" in tables
        self.has_commentaries_fts = "commentaries_fts" in tables
        self.has_roots = "search_roots" in tables
        self.has_synonyms = "search_synonyms" in tables
        self._freq: dict[str, int] | None = None

    # -- lexicon ------------------------------------------------------------
    def root_expansions(self, term: str) -> list[str]:
        """Other vocabulary terms sharing the term's root key."""
        if not self.has_roots or len(term) < 3:
            return []
        key = root_key(term)
        if not key:
            return []
        rows = self.con.execute(
            "SELECT term_norm FROM search_roots WHERE root_key = ?"
            " ORDER BY freq DESC",
            (key,),
        ).fetchall()
        return [r[0] for r in rows if r[0] != term]

    def synonym_expansions(self, term: str) -> list[str]:
        """Curated synonym / related expansions for one term."""
        if not self.has_synonyms or len(term) < 3:
            return []
        rows = self.con.execute(
            "SELECT expansion_norm FROM search_synonyms WHERE term_norm = ?",
            (term,),
        ).fetchall()
        return [r[0] for r in rows]

    def expand(self, terms: list[str]) -> tuple[list[str], list[str], str]:
        """Return (root_terms, synonym_terms, note) for literal terms."""
        roots: list[str] = []
        syns: list[str] = []
        for t in terms:
            for e in self.root_expansions(t):
                if e not in roots and e not in terms:
                    roots.append(e)
            for e in self.synonym_expansions(t):
                if e not in syns and e not in terms and e not in roots:
                    syns.append(e)
        note = ""
        if roots or syns:
            note = (
                "بحث دلالي معجمي: وُسّع الاستعلام بجذور الكلمات والمرادفات "
                "من قواميس التطبيق (ليس تضمينات متجهية ولا نموذجاً لغوياً)."
            )
        return roots, syns, note

    # -- SQL helpers ----------------------------------------------------------
    def _filters_sql(self, q: SearchQuery) -> tuple[str, list]:
        conds: list[str] = []
        args: list = []
        if q.book_id:
            conds.append("h.book = ?")
            args.append(q.book_id)
        if q.chapter_id is not None:
            conds.append("h.chapter_id = ?")
            args.append(q.chapter_id)
        if q.grade:
            # Per-hadith grades only (hadith_grades). Bukhari/Muslim have
            # no per-hadith grade in the source (collection-level sahih)
            # and Ahmad/Darimi have none either, so a grade filter
            # honestly excludes them — the UI says so.
            conds.append(
                "EXISTS (SELECT 1 FROM hadith_grades g WHERE"
                " g.hadith_id = h.id AND g.grade_ar LIKE ?)"
            )
            args.append(f"%{q.grade}%")
        return (" AND " + " AND ".join(conds)) if conds else "", args

    def _hadith_select(self) -> str:
        return (
            "SELECT h.id, h.book, h.num, h.chapter_id,"
            " c.title AS chapter_title, h.text"
            " FROM hadiths h LEFT JOIN chapters c ON c.id = h.chapter_id"
        )

    def _run_fts(
        self,
        fts_table: str,
        match: str,
        q: SearchQuery,
        limit: int,
        with_norm: bool = False,
    ) -> list[dict]:
        """Run one FTS query with filters; returns rows with rank + norm."""
        filters, fargs = self._filters_sql(q)
        norm_sel = ""
        if with_norm:
            if fts_table == "hadiths_fts":
                norm_sel = ", f.norm AS norm"
            else:
                norm_sel = (", s.isnad_norm AS isnad_norm,"
                            " s.matn_norm AS matn_norm,"
                            " s.isnad_end_char AS isnad_end_char")
        if fts_table == "hadiths_fts":
            sql = (
                f"SELECT h.id, h.book, h.num, h.chapter_id,"
                f" c.title AS chapter_title, h.text, rank AS r{norm_sel}"
                f" FROM hadiths_fts f JOIN hadiths h ON h.id = f.rowid"
                f" LEFT JOIN chapters c ON c.id = h.chapter_id"
                f" WHERE hadiths_fts MATCH ?{filters}"
                f" ORDER BY rank LIMIT ?"
            )
        else:
            sql = (
                f"SELECT h.id, h.book, h.num, h.chapter_id,"
                f" c.title AS chapter_title, h.text, rank AS r{norm_sel}"
                f" FROM hadith_spans_fts f JOIN hadiths h ON h.id = f.rowid"
                f" JOIN hadith_spans s ON s.hadith_id = h.id"
                f" LEFT JOIN chapters c ON c.id = h.chapter_id"
                f" WHERE hadith_spans_fts MATCH ?{filters}"
                f" ORDER BY rank LIMIT ?"
            )
        rows = self.con.execute(sql, [match, *fargs, limit]).fetchall()
        return [dict(r) for r in rows]

    def _count_fts(
        self, fts_table: str, match: str, q: SearchQuery,
        anti_match: str | None = None,
    ) -> int:
        filters, fargs = self._filters_sql(q)
        anti = ""
        aargs: list = []
        if anti_match:
            if fts_table == "hadiths_fts":
                anti = (
                    " AND h.id NOT IN (SELECT rowid FROM hadiths_fts"
                    " WHERE hadiths_fts MATCH ?)"
                )
            else:
                anti = (
                    " AND h.id NOT IN (SELECT rowid FROM hadith_spans_fts"
                    " WHERE hadith_spans_fts MATCH ?)"
                )
            aargs.append(anti_match)
        if fts_table == "hadiths_fts":
            sql = (
                "SELECT COUNT(*) FROM hadiths_fts f"
                " JOIN hadiths h ON h.id = f.rowid"
                f" WHERE hadiths_fts MATCH ?{filters}{anti}"
            )
        else:
            sql = (
                "SELECT COUNT(*) FROM hadith_spans_fts f"
                " JOIN hadiths h ON h.id = f.rowid"
                f" WHERE hadith_spans_fts MATCH ?{filters}{anti}"
            )
        return self.con.execute(sql, [match, *fargs, *aargs]).fetchone()[0]

    # -- main search ----------------------------------------------------------
    def search(self, q: SearchQuery) -> SearchPage:
        if q.scope == "commentary":
            return self.search_commentaries(q)
        if q.scope == "takhrij":
            return self.search_takhrij(q)
        if q.companion.strip():
            return self.search_companion(q)
        if q.narrator.strip():
            return self.search_narrator(q)

        terms = query_terms(q.text)
        if not terms:
            return SearchPage([], 0, max(1, q.page), q.page_size)
        return self._search_text(q, terms)

    def _search_text(self, q: SearchQuery, terms: list[str]) -> SearchPage:
        use_spans = self.has_spans and q.scope in ("matn", "isnad")
        fts_table = "hadith_spans_fts" if use_spans else "hadiths_fts"
        literal = build_fts_query(terms)
        if use_spans:
            # Column-scoped FTS: each term becomes {col} : "term"*.
            col = "matn_norm" if q.scope == "matn" else "isnad_norm"
            scoped: list[str] = []
            for term in terms:
                variants = [term, *spelling_variants(term)]
                alts = []
                for v in variants:
                    if " " in v:
                        alts.append(" ".join(
                            f'{{{col}}} : "{w}"*' for w in v.split(" ")
                        ))
                    else:
                        alts.append(f'{{{col}}} : "{v}"*')
                scoped.append(
                    "(" + " OR ".join(alts) + ")" if len(alts) > 1 else alts[0]
                )
            literal = " AND ".join(scoped)

        rows = self._run_fts(fts_table, literal, q, POOL_LIMIT, with_norm=True)
        total_literal = self._count_fts(fts_table, literal, q)

        roots, syns, note = ([], [], "")
        exp_rows: list[dict] = []
        total_exp = 0
        if q.semantic:
            roots, syns, note = self.expand(terms)
            exp_terms = roots + syns
            if exp_terms:
                if use_spans:
                    col = "matn_norm" if q.scope == "matn" else "isnad_norm"
                    exp_match = " OR ".join(
                        f'{{{col}}} : "{t}"*' for t in exp_terms
                    )
                else:
                    exp_match = build_fts_or_query(exp_terms)
                exp_rows = self._run_fts(
                    fts_table, exp_match, q, POOL_LIMIT, with_norm=True
                )
                total_exp = self._count_fts(
                    fts_table, exp_match, q, anti_match=literal
                )

        # Score + merge (literal first, expansion adds; phrase is top).
        # The phrase check uses the PLAIN normalised text (no index
        # variants) with prefixes stripped per word: the stored text has
        # «الاعمال» / «بالنيات» where the query terms are «اعمال» /
        # «نيات», so the raw plain text never contains the phrase.
        # Single-term queries have no phrase tier (every hit would get it).
        scored: dict[int, SearchHit] = {}
        for r in rows:
            scored[r["id"]] = self._score(
                r, terms, "literal", fts_table,
                self._plain_norm(r, q.scope) if len(terms) >= 2 else "",
            )
        for r in exp_rows:
            if r["id"] in scored:
                continue
            hit = self._score(
                r, terms, "semantic", fts_table,
                self._plain_norm(r, q.scope) if len(terms) >= 2 else "",
            )
            hit.matched_terms = [
                t for t in (roots + syns)
                if t in (r.get("norm") or "")
                or t in (r.get("matn_norm") or "")
                or t in (r.get("isnad_norm") or "")
            ][:5]
            scored[r["id"]] = hit
        ordered = sorted(
            scored.values(),
            key=lambda h: (-h.score, h.book, h.num),
        )
        total = total_literal + total_exp
        page_items = ordered[q.offset: q.offset + q.page_size]
        return SearchPage(page_items, total, max(1, q.page), q.page_size,
                          semantic_note=note if q.semantic else "")

    def _plain_norm(self, row: dict, scope: str) -> str:
        """Plain normalised text (no index variants) for the phrase check."""
        text = row.get("text") or ""
        end = row.get("isnad_end_char")
        if scope == "matn" and end is not None:
            return normalize_ar(text[end:])
        if scope == "isnad":
            return normalize_ar(text[:end]) if end is not None else ""
        return normalize_ar(text)

    @staticmethod
    def _phrase_matches(phrase_terms: list[str], plain_norm: str) -> bool:
        """True when the phrase terms occur contiguously (after per-word
        prefix stripping) in the plain normalised text."""
        if len(phrase_terms) < 2 or not plain_norm:
            return False
        tokens = [strip_prefixes(w) for w in plain_norm.split(" ")]
        n = len(phrase_terms)
        return any(
            tokens[i:i + n] == phrase_terms
            for i in range(len(tokens) - n + 1)
        )

    def _score(self, row: dict, terms: list[str],
               tier: str, fts_table: str, plain_norm: str = "") -> SearchHit:
        norm = row.get("norm") or ""
        if fts_table == "hadith_spans_fts":
            norm = ((row.get("matn_norm") or "") + " "
                    + (row.get("isnad_norm") or ""))
        score = 50.0 if tier == "literal" else 20.0
        hit_tier = tier
        # Phrase tier: the normalised query words contiguous in the plain
        # normalised text (prefixes stripped per word).
        if self._phrase_matches(terms, plain_norm):
            score += 100.0
            hit_tier = "phrase"
        score += max(0.0, 10.0 + float(row.get("r") or 0.0))
        return SearchHit(
            hadith_id=row["id"], book=row["book"], num=row["num"],
            chapter_id=row["chapter_id"] or 0,
            chapter_title=row["chapter_title"] or "",
            text=row["text"], score=round(score, 2), tier=hit_tier,
            matched_terms=[t for t in terms if t in norm][:5],
        )

    # -- narrator / companion ---------------------------------------------------
    def search_narrator(self, q: SearchQuery) -> SearchPage:
        """Narrator-name search inside the isnad region only.

        No root/synonym expansion: names are proper nouns. When the
        verified narrators table has rows (0 rows today), a name hit
        there is listed first via hadithsForNarrator; the isnad-text
        path below is the working search until then.
        """
        terms = query_terms(q.narrator)
        if not terms:
            return SearchPage([], 0, max(1, q.page), q.page_size)
        if not self.has_spans:
            return SearchPage([], 0, max(1, q.page), q.page_size,
                              semantic_note="فهرس السند غير متوفر في هذه النسخة من المكتبة.")
        col = "isnad_norm"
        scoped = " AND ".join(
            "(" + " OR ".join(
                f'{{{col}}} : "{v}"*'
                for v in [t, *spelling_variants(t)]
            ) + ")"
            for t in terms
        )
        rows = self._run_fts("hadith_spans_fts", scoped, q, POOL_LIMIT,
                             with_norm=True)
        total = self._count_fts("hadith_spans_fts", scoped, q)
        hits = [
            self._score(r, terms, "literal", "hadith_spans_fts")
            for r in rows
        ]
        hits.sort(key=lambda h: (-h.score, h.book, h.num))
        return SearchPage(hits[q.offset: q.offset + q.page_size], total,
                          max(1, q.page), q.page_size)

    def search_companion(self, q: SearchQuery) -> SearchPage:
        """Companion search: the name must be the LAST narrator candidate
        (the parser's last_narrator_norm) — i.e. the Companion who heard
        the hadith — not merely anywhere in the isnad. Parser-derived,
        not a verified identity: the UI labels results accordingly.
        """
        terms = query_terms(q.companion)
        if not terms:
            return SearchPage([], 0, max(1, q.page), q.page_size)
        if not self.has_spans:
            return SearchPage([], 0, max(1, q.page), q.page_size,
                              semantic_note="فهرس السند غير متوفر في هذه النسخة من المكتبة.")
        conds = " AND ".join(
            "s.last_narrator_norm LIKE ?" for _ in terms
        )
        args = [f"%{t}%" for t in terms]
        filters, fargs = self._filters_sql(q)
        sql = (
            self._hadith_select()
            + " JOIN hadith_spans s ON s.hadith_id = h.id"
            f" WHERE {conds}{filters}"
            " ORDER BY h.book, h.num LIMIT ? OFFSET ?"
        )
        count_sql = (
            "SELECT COUNT(*) FROM hadiths h"
            " JOIN hadith_spans s ON s.hadith_id = h.id"
            f" WHERE {conds}{filters}"
        )
        total = self.con.execute(
            count_sql, [*args, *fargs]
        ).fetchone()[0]
        rows = self.con.execute(
            sql, [*args, *fargs, q.page_size, q.offset]
        ).fetchall()
        hits = [
            SearchHit(hadith_id=r["id"], book=r["book"], num=r["num"],
                      chapter_id=r["chapter_id"] or 0,
                      chapter_title=r["chapter_title"] or "",
                      text=r["text"], score=50.0, tier="literal",
                      matched_terms=terms)
            for r in rows
        ]
        return SearchPage(hits, total, max(1, q.page), q.page_size)

    # -- commentaries -----------------------------------------------------------
    def search_commentaries(self, q: SearchQuery) -> SearchPage:
        """Search inside HadeethEnc commentaries (text + explanation)."""
        terms = query_terms(q.text)
        if not terms or not self.has_commentaries_fts:
            return SearchPage([], 0, max(1, q.page), q.page_size,
                              semantic_note="" if self.has_commentaries_fts else
                              "فهرس الشروح غير متوفر في هذه النسخة من المكتبة.")
        match = build_fts_query(terms)
        rows = self.con.execute(
            "SELECT c.id, c.hadith_key, c.title, c.text, c.explanation,"
            " c.grade_ar, c.source, rank AS r FROM commentaries_fts f"
            " JOIN commentaries c ON c.id = f.rowid"
            " WHERE commentaries_fts MATCH ? ORDER BY rank"
            " LIMIT ? OFFSET ?",
            [match, q.page_size, q.offset],
        ).fetchall()
        total = self.con.execute(
            "SELECT COUNT(*) FROM commentaries_fts f"
            " JOIN commentaries c ON c.id = f.rowid"
            " WHERE commentaries_fts MATCH ?",
            [match],
        ).fetchone()[0]
        hits = [
            CommentaryHit(
                commentary_id=r["id"], hadith_key=r["hadith_key"],
                title=r["title"] or "", text=r["text"] or "",
                explanation=r["explanation"] or "",
                grade_ar=r["grade_ar"] or "", source=r["source"] or "",
            )
            for r in rows
        ]
        return SearchPage(hits, total, max(1, q.page), q.page_size)

    # -- takhrij scope -----------------------------------------------------------
    def search_takhrij(self, q: SearchQuery) -> SearchPage:
        """Takhrij scope — HONEST LIMIT: the takhrij table is EMPTY (no
        verified takhrij source imported), so there is no verified
        cross-reference to search. What this scope returns is the literal
        text search grouped by book (per-book counts of the result set),
        labelled as text-similarity grouping, NOT as verified takhrij.
        """
        terms = query_terms(q.text)
        if not terms:
            return SearchPage([], 0, max(1, q.page), q.page_size)
        page = self._search_text(q, terms)
        page.semantic_note = (
            "نطاق التخريج: جدول التخريج الموثق فارغ بعد — النتائج تجميع "
            "نصي حسب الكتاب (تشابه لفظي) وليست تخريجاً موثقاً."
        )
        return page

    # -- similar hadiths -----------------------------------------------------------
    def _term_freq(self) -> dict[str, int]:
        if self._freq is None:
            if "search_vocab" in {
                r[0] for r in self.con.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'")
            }:
                self._freq = {
                    r[0]: r[1]
                    for r in self.con.execute(
                        "SELECT term_norm, freq FROM search_vocab")
                }
            else:
                self._freq = {}
        return self._freq

    def content_tokens(self, norm_text: str) -> set[str]:
        """Content tokens of a normalised text: prefix-stripped (so the
        index variants «الاعمال»/«اعمال» collapse to one token),
        stopwords dropped, min length 3."""
        return {
            strip_prefixes(t)
            for t in normalize_ar(norm_text).split(" ")
            if t and t not in STOPWORDS and len(t) >= 3
        }

    def find_similar(self, hadith_id: int, limit: int = 10,
                     threshold: float = SIMILAR_THRESHOLD) -> list[dict]:
        """Hadiths with similar wording (matn only).

        Candidates come from an FTS OR over the 8 rarest content tokens
        of the base matn; similarity is Jaccard over content-token sets.
        Textual similarity alone is NOT proof of one hadith (master
        prompt §11) — the UI says so next to every result.
        """
        if self.has_spans:
            row = self.con.execute(
                "SELECT matn_norm FROM hadith_spans WHERE hadith_id = ?",
                (hadith_id,),
            ).fetchone()
            base_norm = row[0] if row else ""
            fts_col = "matn_norm"
            fts_table = "hadith_spans_fts"
        else:
            row = self.con.execute(
                "SELECT norm FROM hadiths_fts WHERE rowid = ?", (hadith_id,)
            ).fetchone()
            base_norm = row[0] if row else ""
            fts_col = "norm"
            fts_table = "hadiths_fts"
        base_tokens = self.content_tokens(base_norm)
        if len(base_tokens) < 3:
            return []
        freq = self._term_freq()
        rare = sorted(
            base_tokens, key=lambda t: (freq.get(t, 1), -len(t))
        )[:8]
        match = " OR ".join(f'{{{fts_col}}} : "{t}"*' for t in rare) \
            if self.has_spans else build_fts_or_query(rare)
        if self.has_spans:
            sql = (
                "SELECT h.id, h.book, h.num, h.chapter_id,"
                " c.title AS chapter_title, h.text, s.matn_norm AS norm"
                " FROM hadith_spans_fts f JOIN hadiths h ON h.id = f.rowid"
                " JOIN hadith_spans s ON s.hadith_id = h.id"
                " LEFT JOIN chapters c ON c.id = h.chapter_id"
                " WHERE hadith_spans_fts MATCH ? AND h.id != ?"
                " ORDER BY rank LIMIT ?"
            )
        else:
            sql = (
                "SELECT h.id, h.book, h.num, h.chapter_id,"
                " c.title AS chapter_title, h.text, f.norm AS norm"
                " FROM hadiths_fts f JOIN hadiths h ON h.id = f.rowid"
                " LEFT JOIN chapters c ON c.id = h.chapter_id"
                " WHERE hadiths_fts MATCH ? AND h.id != ?"
                " ORDER BY rank LIMIT ?"
            )
        out: list[dict] = []
        for r in self.con.execute(sql, [match, hadith_id, SIMILAR_CANDIDATES]):
            cand_tokens = self.content_tokens(r["norm"] or "")
            if not cand_tokens:
                continue
            inter = base_tokens & cand_tokens
            union = base_tokens | cand_tokens
            j = len(inter) / len(union) if union else 0.0
            if j >= threshold:
                out.append({
                    "hadith_id": r["id"], "book": r["book"], "num": r["num"],
                    "chapter_id": r["chapter_id"] or 0,
                    "chapter_title": r["chapter_title"] or "",
                    "text": r["text"], "jaccard": round(j, 3),
                    "common": len(inter),
                    "only_in_base": len(base_tokens - cand_tokens),
                    "only_in_variant": len(cand_tokens - base_tokens),
                })
        out.sort(key=lambda d: (-d["jaccard"], d["book"], d["num"]))
        return out[:limit]

    def close(self) -> None:
        self.con.close()
