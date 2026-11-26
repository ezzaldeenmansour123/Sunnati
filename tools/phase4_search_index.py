#!/usr/bin/env python3
"""Build the Phase 4 search indexes on a SUNNATI library database.

Creates (idempotently) on the target DB — a WORK COPY for testing, or the
fresh build produced by ``tools/build_db.py`` (which calls
:func:`build_phase4_index` before verification):

  * ``hadith_spans`` — one row per hadith: the isnad / matn split produced
    by the Phase 5 isnad parser (``tools/isnad_parser.py``), as SEPARATE
    normalised forms. The stored hadith text is NEVER changed; these are
    derived index columns only. ``isnad_end_char`` is the parser's matn
    boundary (NULL when no boundary was found); ``last_narrator_norm`` is
    the normalised name of the last narrator candidate (usually the
    Companion) — a parser-derived candidate, NOT a verified identity.
  * ``hadith_spans_fts`` — FTS5 over (isnad_norm, matn_norm), an
    EXTERNAL-CONTENT table over ``hadith_spans`` (no duplicated text:
    the shipped database must stay close to its current ~172 MB).
    rowid == hadith id. Enables scope search: متن only / سند only.
  * ``commentaries_fts`` — FTS5 over a ``norm`` column added to
    ``commentaries`` (external-content, rowid == commentaries.id).
    Enables search inside الشروح (commentaries).
  * ``search_synonyms`` — the curated lexical synonym/related pairs
    from ``tools/arabic_text.py`` (hand-written, documented there).
  * ``search_roots`` — root groups derived from the corpus vocabulary
    itself: every distinct normalised token of ``hadiths_fts`` is
    stemmed (``arabic_text.root_key``); tokens sharing a root key form
    one expansion group. Groups are capped at the 40 most frequent
    members (oversize groups are truncated, never dropped whole — the
    most useful groups, e.g. صلاة, are the largest); stopword tokens are
    excluded from membership, so a group of only stopwords (علي/عليه…)
    collapses and is dropped while the صلاة family keyed «صلي» survives.
  * ``search_vocab`` — the full corpus vocabulary (every distinct
    normalised token + its document frequency). Used by similar-hadith
    search to pick the RAREST content tokens as FTS candidates: the
    frequency must come from the vocabulary itself, not from
    ``search_roots`` (a token dropped from root groups is not rare).

Honest limits, recorded in ``meta``:
  * The isnad/matn split is the parser's heuristic (Phase 5 report:
    99.1% structurally complete on a 1,500-hadith sample); rows whose
    status is ``partial`` / ``none`` keep ``isnad_norm`` empty and their
    full text as ``matn_norm``.
  * ``takhrij`` stays EMPTY (no verified takhrij source imported) —
    this script does NOT invent takhrij rows. The takhrij scope in the
    app is text-similarity grouping, labelled as such.
  * ``topics`` stays EMPTY (no Arabic topics taxonomy imported) — the
    app's topic filter uses chapter divisions, labelled as such.

Usage:
    python3 tools/phase4_search_index.py --db /tmp/sunnati-work.db
    python3 tools/phase4_search_index.py --db /tmp/sunnati-work.db --log-json /tmp/phase4-index-log.json
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from arabic_text import (  # noqa: E402
    RELATED,
    STOPWORDS,
    SYNONYMS,
    fts_norm,
    normalize_ar,
    root_key,
)
from isnad_parser import PARSER_VERSION, parse_isnad  # noqa: E402

PHASE4_INDEX_VERSION = "phase4-1"
MAX_ROOT_GROUP_SIZE = 40

SCHEMA_PHASE4 = """
CREATE TABLE IF NOT EXISTS hadith_spans (
  hadith_id INTEGER PRIMARY KEY REFERENCES hadiths(id),
  isnad_norm TEXT NOT NULL DEFAULT '',
  matn_norm TEXT NOT NULL DEFAULT '',
  isnad_end_char INTEGER,
  isnad_status TEXT NOT NULL DEFAULT '',
  boundary_reason TEXT NOT NULL DEFAULT '',
  narrator_count INTEGER NOT NULL DEFAULT 0,
  last_narrator_norm TEXT NOT NULL DEFAULT '',
  last_narrator_text TEXT NOT NULL DEFAULT '',
  companion_marked INTEGER NOT NULL DEFAULT 0,
  parser_version TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS search_synonyms (
  term_norm TEXT NOT NULL,
  expansion_norm TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'synonym',
  source TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (term_norm, expansion_norm)
);
CREATE TABLE IF NOT EXISTS search_roots (
  root_key TEXT NOT NULL,
  term_norm TEXT NOT NULL,
  freq INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (root_key, term_norm)
);
CREATE TABLE IF NOT EXISTS search_vocab (
  term_norm TEXT PRIMARY KEY,
  freq INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_sr_term ON search_roots(term_norm);
"""


def build_commentaries_fts(
    con: sqlite3.Connection, log: dict | None = None
) -> dict:
    """Build ONLY the commentaries FTS index on an open connection.

    Standalone subset of :func:`build_phase4_index` (rebuild 2026-11-26):
    a CONTENTLESS FTS5 over the HadeethEnc ``commentaries`` rows
    (``norm`` = ``fts_norm(text + explanation)``, rowid == commentaries.id).
    Display comes from the ``commentaries`` table itself via JOIN on rowid,
    so no text is duplicated. Measured on the real library DB: +2.87 MiB,
    ~6 s, 3,574 rows. No dependency on the isnad parser, the hadith
    vocabulary, or any other Phase 4 table — this is the ONLY Phase 4
    artefact built by default in v1.0.0; the full set stays behind the
    ``SUNNATI_BUILD_PHASE4_INDEX`` size gate in ``tools/build_db.py``.

    Idempotent (DROP + rebuild). Returns a report dict.
    """
    log = log if log is not None else {}
    t0 = time.time()
    enc_rows = con.execute(
        "SELECT id, text, explanation FROM commentaries"
    ).fetchall()
    con.execute("DROP TABLE IF EXISTS commentaries_fts")
    con.execute(
        "CREATE VIRTUAL TABLE commentaries_fts USING fts5("
        "norm, content='', tokenize='unicode61 remove_diacritics 0')"
    )
    con.executemany(
        "INSERT INTO commentaries_fts (rowid, norm) VALUES (?, ?)",
        [(cid, fts_norm(f"{text} {expl}")) for cid, text, expl in enc_rows],
    )
    con.commit()
    log["commentaries_fts_rows"] = len(enc_rows)
    log["elapsed_seconds"] = round(time.time() - t0, 1)
    return log


def build_phase4_index(con: sqlite3.Connection, log: dict | None = None) -> dict:
    """Build all Phase 4 indexes on an open connection. Returns a report."""
    log = log if log is not None else {}
    t0 = time.time()
    con.executescript(SCHEMA_PHASE4)

    total_hadiths = con.execute("SELECT COUNT(*) FROM hadiths").fetchone()[0]
    log["hadiths_total"] = total_hadiths

    # -- hadith_spans: parse every hadith once ---------------------------
    status_counts: Counter = Counter()
    spans_rows: list[tuple] = []
    n_parsed = 0
    for hid, text in con.execute("SELECT id, text FROM hadiths ORDER BY id"):
        res = parse_isnad(text or "", hadith_id=hid)
        status_counts[res.isnad_status] += 1
        if res.matn_start_char is not None:
            isnad_text = (text or "")[: res.matn_start_char]
            matn_text = (text or "")[res.matn_start_char:]
        else:
            isnad_text, matn_text = "", text or ""
        last = res.narrators[-1] if res.narrators else None
        spans_rows.append((
            hid,
            fts_norm(isnad_text) if isnad_text else "",
            fts_norm(matn_text),
            res.matn_start_char,
            res.isnad_status,
            res.boundary_reason,
            len(res.narrators),
            last.narrator_norm if last else "",
            last.narrator_text if last else "",
            1 if res.companion_marked else 0,
            PARSER_VERSION,
        ))
        n_parsed += 1
    con.execute("DELETE FROM hadith_spans")
    con.executemany(
        "INSERT INTO hadith_spans (hadith_id, isnad_norm, matn_norm,"
        " isnad_end_char, isnad_status, boundary_reason, narrator_count,"
        " last_narrator_norm, last_narrator_text, companion_marked,"
        " parser_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        spans_rows,
    )
    # External-content FTS over hadith_spans: the inverted index only,
    # no duplicated text (keeps the shipped DB close to its ~172 MB).
    con.execute("DROP TABLE IF EXISTS hadith_spans_fts")
    con.execute(
        "CREATE VIRTUAL TABLE hadith_spans_fts USING fts5("
        "isnad_norm, matn_norm, content='hadith_spans',"
        " content_rowid='hadith_id',"
        " tokenize='unicode61 remove_diacritics 0')"
    )
    con.execute(
        "INSERT INTO hadith_spans_fts(hadith_spans_fts)"
        " VALUES ('rebuild')"
    )
    log["spans_rows"] = n_parsed
    log["spans_status_counts"] = dict(status_counts)
    log["spans_with_boundary"] = sum(
        1 for r in spans_rows if r[3] is not None
    )
    log["spans_with_last_narrator"] = sum(
        1 for r in spans_rows if r[7]
    )

    # -- commentaries_fts ---------------------------------------------------
    # Standalone subset (see build_commentaries_fts): the full Phase 4
    # build reuses it so the two can never drift apart.
    commentaries_log = build_commentaries_fts(con, {})
    log["commentaries_fts_rows"] = commentaries_log["commentaries_fts_rows"]

    # -- search_synonyms (curated, from arabic_text) -----------------------
    syn_rows: list[tuple] = []
    for term, exps in SYNONYMS.items():
        for e in exps:
            syn_rows.append((term, e, "synonym", "SUNNATI phase4 curated list (hand-written)"))
    for term, exps in RELATED.items():
        for e in exps:
            syn_rows.append((term, e, "related", "SUNNATI phase4 curated list (hand-written)"))
    con.execute("DELETE FROM search_synonyms")
    con.executemany(
        "INSERT INTO search_synonyms (term_norm, expansion_norm, kind, source)"
        " VALUES (?, ?, ?, ?)",
        syn_rows,
    )
    log["synonym_pairs"] = len(syn_rows)
    log["synonym_terms"] = len(set(SYNONYMS) | set(RELATED))

    # -- search_roots: vocabulary-derived root groups ----------------------
    vocab: Counter = Counter()
    for (norm,) in con.execute("SELECT norm FROM hadiths_fts"):
        for tok in norm.split(" "):
            if tok:
                vocab[tok] += 1
    log["vocabulary_distinct_tokens"] = len(vocab)
    con.execute("DELETE FROM search_vocab")
    con.executemany(
        "INSERT INTO search_vocab (term_norm, freq) VALUES (?, ?)",
        [(tok, freq) for tok, freq in vocab.items()],
    )
    log["vocab_rows"] = len(vocab)
    groups: dict[str, list[tuple[str, int]]] = defaultdict(list)
    for tok, freq in vocab.items():
        key = root_key(tok)
        if key:
            groups[key].append((tok, freq))
    # Keep groups of >= 2 members; oversize groups keep their 40 most
    # frequent members (truncated, never dropped whole — the most useful
    # groups are the largest). Stopword TOKENS are excluded from
    # membership (not the group itself): a group keyed by a stopword
    # survives when its other members are real words — e.g. the صلاة
    # family keyed «صلي» (صلى in the salutation is a stopword token,
    # صلاة/صلوات/يصلي are not) — while a group of only stopwords, e.g.
    # علي/عليه/عليها, collapses to nothing and is dropped.
    kept: dict[str, list[tuple[str, int]]] = {}
    truncated = 0
    for k, v in groups.items():
        members = [(tok, freq) for tok, freq in v if tok not in STOPWORDS]
        if len(members) < 2:
            continue
        if len(members) > MAX_ROOT_GROUP_SIZE:
            truncated += 1
        kept[k] = sorted(members, key=lambda tv: -tv[1])[:MAX_ROOT_GROUP_SIZE]
    log["root_groups_kept"] = len(kept)
    log["root_groups_truncated_to_40"] = truncated
    log["root_groups_dropped_all_stopword"] = sum(
        1
        for v in groups.values()
        if len([tok for tok, _ in v if tok not in STOPWORDS]) < 2
    )
    log["root_groups_singleton"] = sum(1 for v in groups.values() if len(v) == 1)
    con.execute("DELETE FROM search_roots")
    con.executemany(
        "INSERT INTO search_roots (root_key, term_norm, freq) VALUES (?, ?, ?)",
        [(k, tok, freq) for k, terms in kept.items() for tok, freq in terms],
    )
    log["root_rows"] = sum(len(v) for v in kept.values())

    con.execute("PRAGMA optimize")
    con.commit()
    # Reclaim freelist pages left by DROP/CREATE cycles above so the
    # reported size is the true shipped size.
    con.execute("VACUUM")
    con.commit()
    log["db_size_bytes"] = con.execute(
        "SELECT page_count * page_size FROM pragma_page_count(),"
        " pragma_page_size()"
    ).fetchone()[0]
    con.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES"
        " ('search_index_version', ?)",
        (f"{PHASE4_INDEX_VERSION} ({PARSER_VERSION}; built "
         f"{datetime.now(timezone.utc).isoformat()})",),
    )
    con.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES"
        " ('search_index_limits', ?)",
        ("isnad/matn split: isnad_parser heuristic (see Phase 5 report); "
         "last_narrator is a parser candidate, not a verified identity; "
         "semantic search is LEXICAL (roots + curated synonyms), not "
         "vector embeddings and not an LLM; takhrij table is empty — "
         "takhrij scope is text-similarity grouping, labelled as such; "
         "topics table is empty — topic filter uses chapter divisions.",),
    )
    con.commit()
    log["elapsed_seconds"] = round(time.time() - t0, 1)
    log["index_version"] = PHASE4_INDEX_VERSION
    return log


def main() -> int:
    ap = argparse.ArgumentParser(description="Build Phase 4 search indexes")
    ap.add_argument("--db", required=True, help="Target .db file (work copy)")
    ap.add_argument("--log-json", default=None)
    args = ap.parse_args()
    con = sqlite3.connect(args.db)
    try:
        log = build_phase4_index(con)
    finally:
        con.close()
    print(json.dumps(log, ensure_ascii=False, indent=1))
    if args.log_json:
        Path(args.log_json).write_text(
            json.dumps(log, ensure_ascii=False, indent=1), encoding="utf-8"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
