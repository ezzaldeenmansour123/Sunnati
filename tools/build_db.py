#!/usr/bin/env python3
"""Build the SUNNATI library database (Phases 2-3: full schema + import).

Imports the Nine Books (65,712 hadiths) + the HadeethEnc selection (3,574)
from `quranlab/hadith` (pinned revision) parquet files into the full SUNNATI
schema (28 tables: v2 17 tables + v3 11 isnad/narrator tables, master
prompt §5), with FTS5 search, grade normalisation, chapter titles, and
verification.

Source layout (see SUNNATI_DATA_SCOUT_2026-11-25.md):
  * fawazahmed0 schema — 7 books (bukhari, muslim, abudawud, tirmidhi,
    nasai, ibnmajah, malik): 15 columns incl. `grades` list and `book_number`.
  * mhashim6 schema — 2 books (ahmad, darimi): 12 columns, grade columns
    all NULL, no `book_number`, text without tashkeel.
  * hadeethenc-ar: 12 columns, Arabic grades, `explanation` + `attribution_text`.

Rules that MUST NOT be violated (master prompt + Phase 2/3 task):
  * Never invent a hadith, a grade, a narrator, or a chapter title.
  * `hadith_number` is stored as TEXT verbatim (suffixes like `402.2`
    preserved); sorting uses `number_sort`; the stable key is
    `hadith_key` / `urn` / `seq`.
  * Stored `text` keeps its tashkeel exactly as the source gives it; the
    search index uses a SEPARATE normalised copy (see `normalize_ar`).
    Ahmad double spaces are collapsed (whitespace only) and counted.
  * Rows containing U+FFFD are imported with `has_encoding_issue = 1`
    and their URNs listed in the build log — never silently dropped,
    never "fixed" by guessing.
  * `book_number = 0` rows (720) go under an explicit «غير مصنّف» chapter.
  * Grades: every grader's opinion is kept verbatim (`grade_raw`) plus a
    normalised Arabic form (`grade_ar`); conflicting opinions are ALL
    shown — no single "official" grade is chosen. Bukhari/Muslim are
    «صحيح على مستوى المجموعة» (collection level, no per-hadith grade);
    Ahmad/Darimi are «لا توجد درجة في المصدر» (explicitly, not invented).
  * Chapter titles: the fawazahmed0/hadith-api English titles are
    imported verbatim FIRST (title_lang='en'), then
    tools/chapters_import.py REPLACES them for the 7 verified books
    with Arabic kitab <- bab titles from Arabic Wikisource (CC BY-SA
    4.0) and re-links hadiths.chapter_id via the derived maps; the
    old English rows are preserved in chapters_backup_v4_en and the
    majority old-English title per bab is kept in chapters.title_en.
    Nasai/Malik keep English titles (no verified Arabic source).
    No Arabic title is translated or invented; any hadith with no
    verified bab stays under «غير مصنّف».
  * HadeethEnc rows go to `commentaries` ONLY, verbatim, with attribution
    and grade — never auto-linked to Nine-Books hadiths (no reliable key).
  * Tables with no verified data yet (narrators, chains, takhrij,
    scholars' biographies, topics, glossary, variants, relations) are
    created EMPTY with their full structure; `meta` records
    «لا توجد بيانات موثقة بعد — المرحلة 5» for them. No dummy rows.

Normalisation MUST match `lib/core/normalize.dart` exactly:
strip tashkeel/tatweel, unify hamzas, ى→ي, ة→ه, strip punctuation,
strip prefixes و/ف/ب/ل/ك + ال (index variants stored in FTS).

Usage (local):
    python3 tools/build_db.py --out assets/sunnati.db
    python3 tools/build_db.py --out assets/sunnati.db --data-dir ~/workspace/sunnati-data/parquet
    python3 tools/build_db.py --out /tmp/sunnati.db --log-json /tmp/sunnati-build-log.json

Usage (CI): the script downloads any missing parquet file from Hugging Face
at the pinned revision and verifies its SHA-256 before importing.
Requires `pyarrow` (CI installs it; locally use the venv that has it).

Exit code is non-zero on any failure; CI fails the build instead of
shipping a broken library.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Source pinning
# ---------------------------------------------------------------------------
SOURCE_DATASET = "quranlab/hadith"
SOURCE_REVISION = "9e5d61d8cff3c3b95745e11f9d0fe2efccb6126d"
SOURCE_URL = f"https://huggingface.co/datasets/{SOURCE_DATASET}/tree/{SOURCE_REVISION}"
HF_RESOLVE = (
    f"https://huggingface.co/datasets/{SOURCE_DATASET}"
    f"/resolve/{SOURCE_REVISION}"
)

# The Nine Books, canonical order.
BOOKS = [
    ("bukhari", "صحيح البخاري", "البخاري", "محمد بن إسماعيل البخاري", 1),
    ("muslim", "صحيح مسلم", "مسلم", "مسلم بن الحجاج النيسابوري", 2),
    ("abudawud", "سنن أبي داود", "أبو داود", "سليمان بن الأشعث السجستاني", 3),
    ("tirmidhi", "جامع الترمذي", "الترمذي", "محمد بن عيسى الترمذي", 4),
    ("nasai", "سنن النسائي", "النسائي", "أحمد بن شعيب النسائي", 5),
    ("ibnmajah", "سنن ابن ماجه", "ابن ماجه", "محمد بن يزيد ابن ماجه", 6),
    ("ahmad", "مسند أحمد", "أحمد", "أحمد بن حنبل", 7),
    ("malik", "موطأ مالك", "مالك", "مالك بن أنس", 8),
    ("darimi", "سنن الدارمي", "الدارمي", "عبد الله بن عبد الرحمن الدارمي", 9),
]

# Expected row counts (verified by the data scout from the actual files).
EXPECTED_COUNTS = {
    "bukhari": 7580, "muslim": 7360, "abudawud": 5272, "tirmidhi": 3924,
    "nasai": 5679, "ibnmajah": 4338, "ahmad": 26363, "malik": 1829,
    "darimi": 3367, "hadeethenc": 3574,
}
EXPECTED_TOTAL_NINE = 65712

# SHA-256 of the parquet files at the pinned revision (measured locally
# 2026-11-25 from ~/workspace/sunnati-data/parquet; full values).
EXPECTED_SHA256 = {
    "bukhari-ar": "11a0269164bc3da053068772d755221d2a0768cf05bd2feaeb0500a3d9d647d4",
    "muslim-ar": "25f638e1e759ca246a1235fe296ab803599173ca0660c078ac29f40c7f3c0c3b",
    "abudawud-ar": "bfa4723b34bd395fe4782ca066e19398942ccfce3a9c0aedfa6da05a92c78f8a",
    "tirmidhi-ar": "8eacd7c3288e21706f3bf987694ba83a7cb7030453582f029131908d0917fab1",
    "nasai-ar": "5b41a56ad3126425eea07c11cff569ad5dd5a3a734a92a876836966c38997d46",
    "ibnmajah-ar": "f01d56cc77701a0780c3517d74d8d28dff6ff108007746d555cc4fac26401e24",
    "ahmad-ar": "192b49fe98969c742795581eb4858b2c71d83cf3d7cd0bce4eafb7583d24ded7",
    "malik-ar": "bf2ad8cb96d26d8f67393a9e34ddee42d020e388262a6d456825a096156a79fd",
    "darimi-ar": "3a3566ee650b0719a72250aad7839dbc35e8c6b360ff98fa88524e9c6715a276",
    "hadeethenc-ar": "ffdd3c580b2144d3a1eec01d8e9628ae7b3f5c4dd2853cfe57d5ec3ac68510a4",
}

CHAPTERS_JSON_DEFAULT = Path(__file__).resolve().parent / "chapter_titles.json"

# ---------------------------------------------------------------------------
# Full schema (v2) — 17 tables, master prompt §5. Schema v3 (Phase 5,
# SCHEMA_V3 below) adds 11 isnad/narrator tables + documented extensions
# to narrators/chains, without changing any v2 column.
# Phase-1 columns are kept verbatim so lib/data/database.dart keeps working:
#   books(id, name, short, author, sort, cnt)
#   chapters(id, book, num, title)
#   hadiths(id, book, num, chapter_id, text, grades, expl, expl_src)
#   hadiths_fts(norm, expl) with rowid == hadiths.id
#   narrators(id, name, kunya, tier, death_hijri, status, status_src,
#             bio_src, norm)
#   topics(id, name, parent_id), hadith_topics(hadith_id, topic_id)
# ---------------------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS books (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  short TEXT NOT NULL,
  author TEXT NOT NULL,
  sort INTEGER NOT NULL,
  cnt INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT '',
  license TEXT NOT NULL DEFAULT '',
  grade_policy TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS chapters (
  id INTEGER PRIMARY KEY,
  book TEXT NOT NULL REFERENCES books(id),
  num INTEGER NOT NULL,
  title TEXT NOT NULL,
  title_en TEXT NOT NULL DEFAULT '',
  title_lang TEXT NOT NULL DEFAULT '',
  title_source TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS hadiths (
  id INTEGER PRIMARY KEY,
  book TEXT NOT NULL REFERENCES books(id),
  num INTEGER NOT NULL,
  chapter_id INTEGER REFERENCES chapters(id),
  text TEXT NOT NULL,
  grades TEXT NOT NULL DEFAULT '[]',
  expl TEXT NOT NULL DEFAULT '',
  expl_src TEXT NOT NULL DEFAULT '',
  hadith_number TEXT NOT NULL,
  number_sort INTEGER NOT NULL,
  hadith_key TEXT NOT NULL UNIQUE,
  urn INTEGER NOT NULL UNIQUE,
  seq INTEGER NOT NULL,
  in_book_number INTEGER,
  book_number INTEGER,
  sunnah_url TEXT,
  has_encoding_issue INTEGER NOT NULL DEFAULT 0,
  is_muallaq INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT ''
);
CREATE VIRTUAL TABLE IF NOT EXISTS hadiths_fts
  USING fts5(norm, expl, tokenize='unicode61 remove_diacritics 0');
CREATE TABLE IF NOT EXISTS narrators (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  kunya TEXT NOT NULL DEFAULT '',
  tier TEXT NOT NULL DEFAULT '',
  death_hijri INTEGER,
  status TEXT NOT NULL DEFAULT '',
  status_src TEXT NOT NULL DEFAULT '',
  bio_src TEXT NOT NULL DEFAULT '',
  norm TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS chains (
  id INTEGER PRIMARY KEY,
  hadith_id INTEGER NOT NULL REFERENCES hadiths(id),
  position INTEGER NOT NULL,
  narrator_id INTEGER REFERENCES narrators(id),
  link_type TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS hadith_variants (
  id INTEGER PRIMARY KEY,
  hadith_id INTEGER NOT NULL REFERENCES hadiths(id),
  variant_hadith_id INTEGER REFERENCES hadiths(id),
  variant_type TEXT NOT NULL DEFAULT '',
  diff_note TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS scholars (
  id INTEGER PRIMARY KEY,
  name_ar TEXT NOT NULL,
  name_en TEXT NOT NULL DEFAULT '',
  death_hijri INTEGER,
  bio_src TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS hadith_grades (
  id INTEGER PRIMARY KEY,
  hadith_id INTEGER NOT NULL REFERENCES hadiths(id),
  scholar_id INTEGER REFERENCES scholars(id),
  grader TEXT NOT NULL,
  grader_raw TEXT NOT NULL,
  grade_raw TEXT NOT NULL,
  grade_ar TEXT NOT NULL,
  grade_kind TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS commentaries (
  id INTEGER PRIMARY KEY,
  hadith_key TEXT NOT NULL UNIQUE,
  hadeethenc_id INTEGER NOT NULL UNIQUE,
  title TEXT NOT NULL DEFAULT '',
  intro TEXT NOT NULL DEFAULT '',
  text TEXT NOT NULL,
  explanation TEXT NOT NULL DEFAULT '',
  grade_raw TEXT NOT NULL DEFAULT '',
  grade_ar TEXT NOT NULL DEFAULT '',
  grade_kind TEXT NOT NULL DEFAULT '',
  grader TEXT NOT NULL DEFAULT '',
  grader_raw TEXT NOT NULL DEFAULT '',
  attribution_text TEXT NOT NULL DEFAULT '',
  grade_source TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  license TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS takhrij (
  id INTEGER PRIMARY KEY,
  hadith_id INTEGER NOT NULL REFERENCES hadiths(id),
  source_book TEXT NOT NULL DEFAULT '',
  source_ref TEXT NOT NULL DEFAULT '',
  grade TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS sources (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT '',
  url TEXT NOT NULL DEFAULT '',
  license TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS topics (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  parent_id INTEGER REFERENCES topics(id)
);
CREATE TABLE IF NOT EXISTS hadith_topics (
  hadith_id INTEGER NOT NULL REFERENCES hadiths(id),
  topic_id INTEGER NOT NULL REFERENCES topics(id),
  PRIMARY KEY (hadith_id, topic_id)
);
CREATE TABLE IF NOT EXISTS hadith_relations (
  id INTEGER PRIMARY KEY,
  hadith_id INTEGER NOT NULL REFERENCES hadiths(id),
  related_hadith_id INTEGER REFERENCES hadiths(id),
  relation_type TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS glossary (
  id INTEGER PRIMARY KEY,
  term TEXT NOT NULL,
  definition TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS user_bookmarks (
  id INTEGER PRIMARY KEY,
  hadith_key TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT '',
  tags TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE IF NOT EXISTS user_notes (
  id INTEGER PRIMARY KEY,
  hadith_key TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS downloaded_libraries (
  id INTEGER PRIMARY KEY,
  library_id TEXT NOT NULL,
  name TEXT NOT NULL,
  version TEXT NOT NULL DEFAULT '',
  size_bytes INTEGER NOT NULL DEFAULT 0,
  sha256 TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT '',
  installed_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_h_book ON hadiths(book, num);
CREATE INDEX IF NOT EXISTS idx_h_chap ON hadiths(chapter_id);
CREATE INDEX IF NOT EXISTS idx_h_key ON hadiths(hadith_key);
CREATE INDEX IF NOT EXISTS idx_h_urn ON hadiths(urn);
CREATE INDEX IF NOT EXISTS idx_h_sort ON hadiths(book, number_sort);
CREATE INDEX IF NOT EXISTS idx_c_book ON chapters(book, num);
CREATE INDEX IF NOT EXISTS idx_g_hadith ON hadith_grades(hadith_id);
CREATE INDEX IF NOT EXISTS idx_g_kind ON hadith_grades(grade_kind);
CREATE INDEX IF NOT EXISTS idx_n_norm ON narrators(norm);
CREATE INDEX IF NOT EXISTS idx_ch_hadith ON chains(hadith_id);
CREATE INDEX IF NOT EXISTS idx_cm_key ON commentaries(hadith_key);
CREATE INDEX IF NOT EXISTS idx_ub_key ON user_bookmarks(hadith_key);
CREATE INDEX IF NOT EXISTS idx_un_key ON user_notes(hadith_key);
"""

# ---------------------------------------------------------------------------
# Schema v3 (Phase 5) — isnad / narrator extension tables.
#
# Added WITHOUT changing any v2 column (all v2 columns above are kept
# verbatim so lib/data/database.dart keeps working). The 11 new tables use
# the lowercase snake_case convention of the v2 schema; the Phase 5 task
# names them in PascalCase (NarratorAliases, NarratorGrades, ...):
#   NarratorAliases        -> narrator_aliases
#   NarratorGrades         -> narrator_grades
#   NarratorScholars       -> narrator_scholars
#   NarratorTeachers       -> narrator_teachers
#   NarratorStudents       -> narrator_students
#   NarratorSources        -> narrator_sources
#   HadithNarrators        -> hadith_narrators
#   IsnadChains            -> isnad_chains
#   IsnadNodes             -> isnad_nodes
#   IsnadRelations         -> isnad_relations
#   NarratorIdentityMatches -> narrator_identity_matches
#
# Rules (master prompt + Phase 5 task):
#   * Every table is created EMPTY. No narrator, grade, biography or
#     identity row is invented or imported here: there is still no
#     verified, licensed narrator source imported (see meta
#     `no_data_yet`). The only rows these tables may ever hold before a
#     verified source exists are machine-extracted PARSER CANDIDATES in
#     hadith_narrators / isnad_chains / isnad_nodes, with narrator_id
#     NULL, match_status 'unlinked' (or 'needs_review') and a
#     parser_version stamp — never a linked identity, never a status.
#   * Every row carries its provenance: `source` (verbatim source name
#     or parser version), `reviewed_at` (ISO date of human review, ''
#     = not reviewed), `confidence` (high / medium / low /
#     needs_review) and `notes`. `confidence` uses English codes so the
#     parser, the tests and any Dart code share one enum; the Arabic
#     labels are عالية / متوسطة / منخفضة / يحتاج مراجعة
#     (see tools/isnad_parser.py CONFIDENCE_AR).
#   * The parser NEVER judges an isnad's authenticity or connectedness
#     and NEVER links a name to a narrator except on a verified match.
#     Unverified names stay `match_status='unlinked'` and are listed
#     for human review; see tools/isnad_parser.py and
#     narrator_identity_matches, which records every match DECISION
#     including the deliberate decision NOT to link.
#   * Stable identifiers: narrator identity is `narrators.id` (integer,
#     assigned only when a verified source is imported). There is no
#     second narrator key: aliases, grades, teachers/students and
#     sources all point at it. Hadith-side rows point at
#     `hadiths.id` / `isnad_chains.id` / `isnad_nodes.id`.
#
# Extensions to existing tables (documented; nothing else changed):
#   narrators += reviewed_at, confidence, identity_status
#     (review/provenance tracking for the future verified import;
#      identity_status 'unverified' by default — no row may claim a
#      verified identity until a source is imported and reviewed).
#   chains += start_char, end_char, narrator_text, confidence,
#              match_status, parser_version
#     (lets the legacy chains table store one parser-extracted span —
#      verbatim candidate text + character offsets in the ORIGINAL
#      hadith text — without requiring a narrator_id link).
# ---------------------------------------------------------------------------
SCHEMA_V3 = """
ALTER TABLE narrators ADD COLUMN reviewed_at TEXT NOT NULL DEFAULT '';
ALTER TABLE narrators ADD COLUMN confidence TEXT NOT NULL DEFAULT '';
ALTER TABLE narrators ADD COLUMN identity_status TEXT NOT NULL DEFAULT 'unverified';
ALTER TABLE chains ADD COLUMN start_char INTEGER;
ALTER TABLE chains ADD COLUMN end_char INTEGER;
ALTER TABLE chains ADD COLUMN narrator_text TEXT NOT NULL DEFAULT '';
ALTER TABLE chains ADD COLUMN confidence TEXT NOT NULL DEFAULT '';
ALTER TABLE chains ADD COLUMN match_status TEXT NOT NULL DEFAULT 'unlinked';
ALTER TABLE chains ADD COLUMN parser_version TEXT NOT NULL DEFAULT '';
CREATE TABLE IF NOT EXISTS narrator_aliases (
  id INTEGER PRIMARY KEY,
  narrator_id INTEGER NOT NULL REFERENCES narrators(id),
  alias TEXT NOT NULL,
  alias_norm TEXT NOT NULL DEFAULT '',
  alias_type TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')),
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS narrator_grades (
  id INTEGER PRIMARY KEY,
  narrator_id INTEGER NOT NULL REFERENCES narrators(id),
  scholar_id INTEGER REFERENCES scholars(id),
  grade_ar TEXT NOT NULL DEFAULT '',
  grade_raw TEXT NOT NULL DEFAULT '',
  grade_kind TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  source_ref TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')),
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS narrator_scholars (
  id INTEGER PRIMARY KEY,
  narrator_id INTEGER NOT NULL REFERENCES narrators(id),
  scholar_id INTEGER NOT NULL REFERENCES scholars(id),
  role TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')),
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS narrator_teachers (
  id INTEGER PRIMARY KEY,
  narrator_id INTEGER NOT NULL REFERENCES narrators(id),
  teacher_id INTEGER NOT NULL REFERENCES narrators(id),
  source TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')),
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS narrator_students (
  id INTEGER PRIMARY KEY,
  narrator_id INTEGER NOT NULL REFERENCES narrators(id),
  student_id INTEGER NOT NULL REFERENCES narrators(id),
  source TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')),
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS narrator_sources (
  id INTEGER PRIMARY KEY,
  narrator_id INTEGER NOT NULL REFERENCES narrators(id),
  source_name TEXT NOT NULL DEFAULT '',
  source_type TEXT NOT NULL DEFAULT '',
  source_ref TEXT NOT NULL DEFAULT '',
  url TEXT NOT NULL DEFAULT '',
  license TEXT NOT NULL DEFAULT '',
  retrieved_at TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')),
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS hadith_narrators (
  id INTEGER PRIMARY KEY,
  hadith_id INTEGER NOT NULL REFERENCES hadiths(id),
  narrator_id INTEGER REFERENCES narrators(id),
  position INTEGER NOT NULL,
  narrator_text TEXT NOT NULL DEFAULT '',
  narrator_norm TEXT NOT NULL DEFAULT '',
  start_char INTEGER,
  end_char INTEGER,
  link_type TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')),
  match_status TEXT NOT NULL DEFAULT 'unlinked' CHECK (match_status IN ('unlinked', 'linked_verified', 'ambiguous', 'needs_review')),
  source TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS isnad_chains (
  id INTEGER PRIMARY KEY,
  hadith_id INTEGER NOT NULL REFERENCES hadiths(id),
  chain_index INTEGER NOT NULL DEFAULT 0,
  is_primary INTEGER NOT NULL DEFAULT 1,
  narrator_count INTEGER NOT NULL DEFAULT 0,
  is_complete INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT '',
  parser_version TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')),
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS isnad_nodes (
  id INTEGER PRIMARY KEY,
  chain_id INTEGER NOT NULL REFERENCES isnad_chains(id),
  hadith_id INTEGER NOT NULL REFERENCES hadiths(id),
  position INTEGER NOT NULL,
  narrator_id INTEGER REFERENCES narrators(id),
  narrator_text TEXT NOT NULL DEFAULT '',
  narrator_norm TEXT NOT NULL DEFAULT '',
  start_char INTEGER,
  end_char INTEGER,
  link_type TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')),
  match_status TEXT NOT NULL DEFAULT 'unlinked' CHECK (match_status IN ('unlinked', 'linked_verified', 'ambiguous', 'needs_review')),
  source TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS isnad_relations (
  id INTEGER PRIMARY KEY,
  chain_id INTEGER NOT NULL REFERENCES isnad_chains(id),
  from_node_id INTEGER REFERENCES isnad_nodes(id),
  to_node_id INTEGER REFERENCES isnad_nodes(id),
  relation_type TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')),
  notes TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS narrator_identity_matches (
  id INTEGER PRIMARY KEY,
  candidate_text TEXT NOT NULL DEFAULT '',
  candidate_norm TEXT NOT NULL DEFAULT '',
  narrator_id INTEGER REFERENCES narrators(id),
  match_type TEXT NOT NULL DEFAULT '',
  score REAL,
  decided_by TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  decision TEXT NOT NULL DEFAULT 'unlinked' CHECK (decision IN ('unlinked', 'linked_verified', 'ambiguous', 'pending')),
  notes TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_na_narrator ON narrator_aliases(narrator_id);
CREATE INDEX IF NOT EXISTS idx_na_norm ON narrator_aliases(alias_norm);
CREATE INDEX IF NOT EXISTS idx_ng_narrator ON narrator_grades(narrator_id);
CREATE INDEX IF NOT EXISTS idx_ng_scholar ON narrator_grades(scholar_id);
CREATE INDEX IF NOT EXISTS idx_ns_narrator ON narrator_scholars(narrator_id);
CREATE INDEX IF NOT EXISTS idx_nt_narrator ON narrator_teachers(narrator_id);
CREATE INDEX IF NOT EXISTS idx_nt_teacher ON narrator_teachers(teacher_id);
CREATE INDEX IF NOT EXISTS idx_nst_narrator ON narrator_students(narrator_id);
CREATE INDEX IF NOT EXISTS idx_nst_student ON narrator_students(student_id);
CREATE INDEX IF NOT EXISTS idx_nsrc_narrator ON narrator_sources(narrator_id);
CREATE INDEX IF NOT EXISTS idx_hn_hadith ON hadith_narrators(hadith_id);
CREATE INDEX IF NOT EXISTS idx_hn_narrator ON hadith_narrators(narrator_id);
CREATE INDEX IF NOT EXISTS idx_hn_norm ON hadith_narrators(narrator_norm);
CREATE INDEX IF NOT EXISTS idx_hn_match ON hadith_narrators(match_status);
CREATE INDEX IF NOT EXISTS idx_ic_hadith ON isnad_chains(hadith_id);
CREATE INDEX IF NOT EXISTS idx_in_chain ON isnad_nodes(chain_id);
CREATE INDEX IF NOT EXISTS idx_in_hadith ON isnad_nodes(hadith_id);
CREATE INDEX IF NOT EXISTS idx_in_match ON isnad_nodes(match_status);
CREATE INDEX IF NOT EXISTS idx_ir_chain ON isnad_relations(chain_id);
CREATE INDEX IF NOT EXISTS idx_nim_norm ON narrator_identity_matches(candidate_norm);
CREATE INDEX IF NOT EXISTS idx_nim_narrator ON narrator_identity_matches(narrator_id);
"""

# ---------------------------------------------------------------------------
# Schema v4 (Phases 7-8) — downloads registry extension + admin tables.
#
# Added WITHOUT changing any v2/v3 column. The app also creates these
# tables at open time (see lib/data/database.dart `kAdminSchemaV4` — the
# same SQL, kept in sync and checked by tools/test_phase7_8.py) so an
# already-shipped v2/v3 database gains them on first run of the Phase 7-8
# build, without a rebuild of the 65,712-hadith library.
#
# Rules (master prompt §12/§15/§16 + Phases 7-8 task):
#   * downloaded_libraries gains download bookkeeping columns only.
#     A row is created ONLY for a real, verified package: no row is ever
#     created for an extended library that is still "preparing" (see
#     lib/core/extended_library.dart). `status` values:
#       available | downloading | paused | verifying | installed |
#       failed | deleted. A package whose SHA-256 does not verify is
#       NEVER marked installed.
#   * admin_staging holds EVERY admin-submitted record (book definition,
#     commentary, narrator, grade, source) with review_status
#     'pending_review' by default. Nothing in staging is published to a
#     production table by the admin panel: approval only flips the
#     review_status to 'approved' and writes an audit row; the merge into
#     the library tables is a separate, verified import pipeline (Phase 9).
#     The single exception is a *book definition* (metadata row in books
#     with cnt=0, i.e. "being imported") which the panel may insert
#     directly, because it carries no hadith/narrator/grade content.
#   * admin_audit_log is append-only from the app's point of view: the
#     panel only INSERTs and SELECTs; no UPDATE/DELETE path exists in
#     Dart. Every admin action writes one row (who/what/source/when).
#   * No PIN, secret or API key is stored in this schema. The admin PIN
#     lives as a salted iterated SHA-256 hash in SharedPreferences only
#     (see lib/core/admin_pin.dart).
# ---------------------------------------------------------------------------
SCHEMA_V4 = """
ALTER TABLE downloaded_libraries ADD COLUMN source TEXT NOT NULL DEFAULT '';
ALTER TABLE downloaded_libraries ADD COLUMN license TEXT NOT NULL DEFAULT '';
ALTER TABLE downloaded_libraries ADD COLUMN download_url TEXT NOT NULL DEFAULT '';
ALTER TABLE downloaded_libraries ADD COLUMN total_bytes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE downloaded_libraries ADD COLUMN downloaded_bytes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE downloaded_libraries ADD COLUMN manifest_json TEXT NOT NULL DEFAULT '';
ALTER TABLE downloaded_libraries ADD COLUMN updated_at TEXT NOT NULL DEFAULT '';
CREATE TABLE IF NOT EXISTS admin_audit_log (
  id INTEGER PRIMARY KEY,
  created_at TEXT NOT NULL,
  actor TEXT NOT NULL DEFAULT 'admin',
  action TEXT NOT NULL,
  entity_type TEXT NOT NULL DEFAULT '',
  entity_id TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  detail TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS admin_staging (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('book', 'commentary', 'narrator', 'grade', 'source')),
  payload_json TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT '',
  sha256 TEXT NOT NULL DEFAULT '',
  submitted_by TEXT NOT NULL DEFAULT 'admin',
  submitted_at TEXT NOT NULL,
  review_status TEXT NOT NULL DEFAULT 'pending_review' CHECK (review_status IN ('pending_review', 'approved', 'rejected')),
  reviewed_by TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT NOT NULL DEFAULT '',
  review_note TEXT NOT NULL DEFAULT '',
  validation_errors TEXT NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS idx_dl_library ON downloaded_libraries(library_id);
CREATE INDEX IF NOT EXISTS idx_dl_status ON downloaded_libraries(status);
CREATE INDEX IF NOT EXISTS idx_audit_created ON admin_audit_log(created_at);
CREATE INDEX IF NOT EXISTS idx_audit_action ON admin_audit_log(action);
CREATE INDEX IF NOT EXISTS idx_staging_status ON admin_staging(review_status);
CREATE INDEX IF NOT EXISTS idx_staging_kind ON admin_staging(kind);
"""

# ---------------------------------------------------------------------------
# Normalisation — mirror of lib/core/normalize.dart (keep in sync!).
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


# ---------------------------------------------------------------------------
# Grade normalisation (English source values -> unified Arabic).
#
# Every source value is kept verbatim in `grade_raw`; this function only
# derives the Arabic display form. Rule table (token -> Arabic fragment):
#   sahih -> صحيح | hasan -> حسن | daif -> ضعيف | very daif -> ضعيف جداً
#   mawdu -> موضوع | munkar -> منكر | shadh -> شاذ | gharib -> غريب
#   batil -> باطل | malool -> معلول
#   lighairihi -> لغيره | isnaad/sanad -> الإسناد | matn -> المتن
#   mauquf/muquf -> موقوف | maqtu -> مقطوع | mursal -> مرسل
#   mutawatir -> متواتر | agreed upon / bukhari and muslim -> (متفق عليه)
# Cross-references in parentheses, e.g. "Sahih Bukhari (1672)", are dropped
# from the Arabic form (they stay in `grade_raw`); the tokens bukhari /
# muslim / hadith / witness are likewise dropped after the base is taken.
# A bare "-" (Abu Ghuddah, 35 rows in Nasai) means "no grade value given":
# grade_ar = "" and grade_kind = "غير محدد" (kept as a row, not deleted).
# ---------------------------------------------------------------------------
_GRADE_KNOWN = {
    "sahih", "hasan", "daif", "very", "mawdu", "munkar", "shadh", "gharib",
    "batil", "malool", "lighairihi", "isnaad", "sanad", "matn", "mauquf",
    "muquf", "maqtu", "mursal", "mutawatir", "hadith", "bukhari", "muslim",
    "agreed", "upon", "and", "after", "witness",
}
_GRADE_STRENGTH_ORDER = [
    "حسن", "صحيح", "ضعيف", "ضعيف جداً", "موضوع", "منكر", "شاذ", "غريب",
    "باطل", "معلول",
]


def normalize_grade(raw: str) -> tuple[str, str, list[str]]:
    """Return (grade_ar, grade_kind, residual_tokens)."""
    s = raw.lower()
    s = re.sub(r"\([^)]*\)", " ", s)  # drop "(1672)" cross-references
    s = s.replace(",", " ").replace("-", " ").replace(".", " ")
    toks = [t for t in re.split(r"\s+", s) if t and not t.isdigit()]
    residual = [t for t in toks if t not in _GRADE_KNOWN]
    has = lambda *ws: any(w in toks for w in ws)
    strength: list[str] = []
    if has("hasan"):
        strength.append("حسن")
    if has("sahih"):
        strength.append("صحيح")
    if has("daif"):
        strength.append("ضعيف جداً" if has("very") else "ضعيف")
    if has("mawdu"):
        strength.append("موضوع")
    if has("munkar"):
        strength.append("منكر")
    if has("shadh"):
        strength.append("شاذ")
    if has("gharib"):
        strength.append("غريب")
    if has("batil"):
        strength.append("باطل")
    if has("malool"):
        strength.append("معلول")
    parts = [o for o in _GRADE_STRENGTH_ORDER if o in strength]
    if has("isnaad", "sanad"):
        parts.append("الإسناد")
    if has("matn"):
        parts.append("المتن")
    if has("lighairihi"):
        parts.append("لغيره")
    if has("mauquf", "muquf"):
        parts.append("موقوف")
    if has("maqtu"):
        parts.append("مقطوع")
    if has("mursal"):
        parts.append("مرسل")
    if has("mutawatir"):
        parts.append("متواتر")
    if has("agreed") or (has("bukhari", "muslim") and has("and")):
        parts.append("(متفق عليه)")
    grade_ar = " ".join(parts)
    if strength:
        kind = " ".join(o for o in _GRADE_STRENGTH_ORDER if o in strength)
    elif has("mauquf", "muquf"):
        kind = "موقوف"
    elif has("maqtu"):
        kind = "مقطوع"
    elif has("mursal"):
        kind = "مرسل"
    else:
        kind = "غير محدد"
    return grade_ar, kind, residual


def hadeethenc_grade_kind(grade_ar: str) -> str:
    """Kind for a verbatim Arabic HadeethEnc grade (no inference)."""
    for kw in ("موضوع", "ضعيف", "منكر", "شاذ", "حسن", "صحيح"):
        if kw in grade_ar:
            return kw
    if "موقوف" in grade_ar:
        return "موقوف"
    return "غير محدد"


# Grader names: English (verbatim in source) -> Arabic display.
# Only the name is translated; no biography or verdict is added.
GRADER_AR = {
    "Al-Albani": "الألباني",
    "Zubair Ali Zai": "زبير علي زئي",
    "Shuaib Al Arnaut": "شعيب الأرناؤوط",
    "Muhammad Muhyi Al-Din Abdul Hamid": "محمد محيي الدين عبد الحميد",
    "Ahmad Muhammad Shakir": "أحمد محمد شاكر",
    "Bashar Awad Maarouf": "بشار عواد معروف",
    "Abu Ghuddah": "أبو غدة",
    "Muhammad Fouad Abd al-Baqi": "محمد فؤاد عبد الباقي",
    "Salim al-Hilali": "سليم الهلالي",
    "HadeethEnc (IslamHouse / Saudi MoIA) editorial board":
        "هيئة تحرير موسوعة الحديث (HadeethEnc)",
}

GRADE_POLICIES = {
    "bukhari": "collection-level: صحيح على مستوى المجموعة (إجماع أهل السنة) — لا درجة لكل حديث في المصدر",
    "muslim": "collection-level: صحيح على مستوى المجموعة (إجماع أهل السنة) — لا درجة لكل حديث في المصدر",
    "abudawud": "per-hadith multi-grader",
    "tirmidhi": "per-hadith multi-grader",
    "nasai": "per-hadith multi-grader",
    "ibnmajah": "per-hadith multi-grader",
    "malik": "per-hadith multi-grader (Salim al-Hilali only)",
    "ahmad": "no-grade-in-source: لا توجد درجة في المصدر — لم تُخترَع درجة",
    "darimi": "no-grade-in-source: لا توجد درجة في المصدر — لم تُخترَع درجة",
}

BOOK_SOURCES = {
    "bukhari": ("fawazahmed0/hadith-api", "public domain (Arabic matn); aggregation via fawazahmed0/hadith-api"),
    "muslim": ("fawazahmed0/hadith-api", "public domain (Arabic matn); aggregation via fawazahmed0/hadith-api"),
    "abudawud": ("fawazahmed0/hadith-api", "public domain (Arabic matn); aggregation via fawazahmed0/hadith-api"),
    "tirmidhi": ("fawazahmed0/hadith-api", "public domain (Arabic matn); aggregation via fawazahmed0/hadith-api"),
    "nasai": ("fawazahmed0/hadith-api", "public domain (Arabic matn); aggregation via fawazahmed0/hadith-api"),
    "ibnmajah": ("fawazahmed0/hadith-api", "public domain (Arabic matn); aggregation via fawazahmed0/hadith-api"),
    "malik": ("fawazahmed0/hadith-api", "public domain (Arabic matn); aggregation via fawazahmed0/hadith-api"),
    "ahmad": ("mhashim6/Open-Hadith-Data", "ODbL-1.0 + DbCL-1.0 (digitisation); Arabic matn public domain; attribution + share-alike required"),
    "darimi": ("mhashim6/Open-Hadith-Data", "ODbL-1.0 + DbCL-1.0 (digitisation); Arabic matn public domain; attribution + share-alike required"),
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_parquet(data_dir: Path, allow_download: bool, log: dict) -> Path:
    """Return the data dir with all 10 parquet files present + verified."""
    try:
        import pyarrow  # noqa: F401
    except ImportError:
        print(
            "ERROR: pyarrow is required (pip install pyarrow). "
            "In CI it is installed by the workflow.",
            file=sys.stderr,
        )
        raise SystemExit(2)
    data_dir.mkdir(parents=True, exist_ok=True)
    missing = []
    for cfg in EXPECTED_SHA256:
        p = data_dir / f"{cfg}.parquet"
        if not p.exists():
            missing.append(cfg)
            continue
        digest = sha256_file(p)
        if digest != EXPECTED_SHA256[cfg]:
            print(
                f"ERROR: SHA-256 mismatch for {p.name}: got {digest}, "
                f"expected {EXPECTED_SHA256[cfg]}",
                file=sys.stderr,
            )
            raise SystemExit(1)
        log.setdefault("parquet_sha256_verified", {})[cfg] = digest
    if missing:
        if not allow_download:
            print(
                f"ERROR: missing parquet files in {data_dir}: "
                + ", ".join(missing)
                + " (re-run without --no-download to fetch them from "
                "Hugging Face at the pinned revision)",
                file=sys.stderr,
            )
            raise SystemExit(1)
        print(f"downloading {len(missing)} missing parquet file(s) from Hugging Face ...")
        for cfg in missing:
            url = f"{HF_RESOLVE}/{cfg}/train-00000-of-00001.parquet"
            dest = data_dir / f"{cfg}.parquet"
            print(f"  {cfg} <- {url}")
            urllib.request.urlretrieve(url, dest)
            digest = sha256_file(dest)
            if digest != EXPECTED_SHA256[cfg]:
                print(
                    f"ERROR: SHA-256 mismatch after download for {cfg}: "
                    f"got {digest}, expected {EXPECTED_SHA256[cfg]}",
                    file=sys.stderr,
                )
                raise SystemExit(1)
            log.setdefault("parquet_sha256_verified", {})[cfg] = digest
            log.setdefault("parquet_downloaded", []).append(cfg)
    return data_dir


def load_chapter_titles(path: Path, log: dict) -> dict:
    """Verbatim section titles from hadith-api (English only)."""
    data = json.loads(path.read_text(encoding="utf-8"))
    log["chapter_titles_provenance"] = data.get("provenance", {})
    return data["books"]


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Build the SUNNATI library DB (Phases 2-3: full import)"
    )
    ap.add_argument("--out", required=True, help="Output .db path")
    ap.add_argument("--data-dir", default=None,
                    help="Directory with the 10 parquet files "
                    "(default: $SUNNATI_DATA_DIR, then "
                    "~/workspace/sunnati-data/parquet, then ./sunnati-data/parquet)")
    ap.add_argument("--chapters-json", default=str(CHAPTERS_JSON_DEFAULT),
                    help="chapter_titles.json (verbatim hadith-api extract)")
    ap.add_argument("--no-download", action="store_true",
                    help="Fail instead of downloading missing parquet files")
    ap.add_argument("--log-json", default=None,
                    help="Write the full import log (JSON) here")
    args = ap.parse_args()

    import pyarrow.parquet as pq  # noqa: F401  (checked in ensure_parquet)

    log: dict = {
        "schema_version": 4,
        "source": SOURCE_DATASET,
        "source_revision": SOURCE_REVISION,
        "built_at_utc": datetime.now(timezone.utc).isoformat(),
        "warnings": [],
        "per_book": {},
        "fffd_urns": {},
        "grade_distribution": {},
        "grade_residual_tokens": {},
        "chapters": {},
        "counts": {},
    }

    # -- resolve data dir -------------------------------------------------
    candidates = []
    if args.data_dir:
        candidates.append(Path(args.data_dir).expanduser())
    if os.environ.get("SUNNATI_DATA_DIR"):
        candidates.append(Path(os.environ["SUNNATI_DATA_DIR"]).expanduser())
    candidates.append(Path.home() / "workspace" / "sunnati-data" / "parquet")
    candidates.append(Path.cwd() / "sunnati-data" / "parquet")
    data_dir = next((c for c in candidates if c.is_dir()), candidates[0])
    data_dir = ensure_parquet(data_dir, not args.no_download, log)
    print(f"data dir: {data_dir}")

    chapter_titles = load_chapter_titles(Path(args.chapters_json), log)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()

    con = sqlite3.connect(str(out))
    try:
        con.executescript(SCHEMA)
        # Schema v3 (Phase 5): isnad/narrator extension tables + the
        # documented narrators/chains column extensions. No rows are
        # inserted into any v3 narrator table here (no verified source).
        con.executescript(SCHEMA_V3)
        # Schema v4 (Phases 7-8): downloads registry extension + admin
        # staging/audit tables. Created empty; no package rows and no
        # staging rows are inserted here.
        con.executescript(SCHEMA_V4)

        # -- scholars (grader identities only; no invented biographies) --
        scholar_ids: dict[str, int] = {}
        for i, (en, ar) in enumerate(
            sorted(GRADER_AR.items(), key=lambda kv: kv[0]), start=1
        ):
            con.execute(
                "INSERT INTO scholars (id, name_ar, name_en, death_hijri, bio_src, notes)"
                " VALUES (?, ?, ?, NULL, '', 'grader identity from source data only; "
                "no biography imported — Phase 5')",
                (i, ar, en),
            )
            scholar_ids[en] = i
        log["scholars"] = len(scholar_ids)

        # -- sources (real, documented) -----------------------------------
        sources = [
            ("quranlab/hadith", "dataset",
             "https://huggingface.co/datasets/quranlab/hadith",
             "Arabic matn public domain; digitisation ODbL-1.0/DbCL-1.0 with attribution",
             f"pinned revision {SOURCE_REVISION} (2026-10-14)"),
            ("fawazahmed0/hadith-api", "upstream",
             "https://github.com/fawazahmed0/hadith-api",
             "The Unlicense; aggregation of the 7 books + chapter titles",
             "chapter titles (English only) from editions/ara-*.json, branch 1"),
            ("mhashim6/Open-Hadith-Data", "upstream",
             "https://github.com/mhashim6/Open-Hadith-Data",
             "ODbL-1.0 + DbCL-1.0; Arabic matn public domain; attribution + share-alike",
             "source of Musnad Ahmad and Sunan al-Darimi"),
            ("HadeethEnc.com (IslamHouse / Saudi MoIA)", "selection",
             "https://hadeethenc.com",
             "open-with-attribution; verbatim reproduction, no modification, removal on request; commercial_ok=False",
             "3,574 selected hadiths with explanation + grade; NOT linked to the Nine Books"),
            ("sunnah.com", "links-only",
             "https://sunnah.com",
             "links only — no text or grades copied",
             "sunnah_url per hadith (26 bukhari, 35 tirmidhi, 7 nasai, 2 ibnmajah rows have no URL)"),
        ]
        for name, typ, url, lic, notes in sources:
            con.execute(
                "INSERT INTO sources (name, type, url, license, notes) VALUES (?, ?, ?, ?, ?)",
                (name, typ, url, lic, notes),
            )

        # -- books ---------------------------------------------------------
        for book_id, name, short, author, sort in BOOKS:
            src, lic = BOOK_SOURCES[book_id]
            con.execute(
                "INSERT INTO books (id, name, short, author, sort, cnt, source, license, grade_policy)"
                " VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)",
                (book_id, name, short, author, sort, src, lic, GRADE_POLICIES[book_id]),
            )

        grade_dist: Counter = Counter()
        grade_residual: Counter = Counter()
        unknown_graders: Counter = Counter()
        total_fffd = 0
        total_unclassified = 0
        total_double_space_fixed = 0
        total_newline_texts = 0
        chapters_created = 0

        for book_id, _name, _short, _author, sort in BOOKS:
            table = pq.read_table(str(data_dir / f"{book_id}-ar.parquet"))
            rows = table.to_pylist()
            actual = len(rows)
            expected = EXPECTED_COUNTS[book_id]
            status = "OK" if actual == expected else "MISMATCH"
            if actual != expected:
                log["warnings"].append(
                    f"{book_id}: row count {actual} != expected {expected}"
                )
            print(f"  {book_id}: {actual} rows (expected {expected}) [{status}]")

            # -- chapters for this book -----------------------------------
            if book_id in ("ahmad", "darimi"):
                # No book_number in the source at all: one explicit chapter.
                chapter_id = sort * 1000
                con.execute(
                    "INSERT INTO chapters (id, book, num, title, title_en, title_lang, title_source)"
                    " VALUES (?, ?, 0, 'غير مصنّف', '', 'ar', 'SUNNATI: no chapter division in source')",
                    (chapter_id, book_id),
                )
                chapter_of = {None: chapter_id}
                chapters_created += 1
                log["chapters"][book_id] = {"count": 1, "note": "no chapter division in source"}
            else:
                book_numbers = sorted({r.get("book_number") for r in rows})
                titles = chapter_titles.get(book_id, {})
                created = 0
                chapter_of = {}
                for bn in book_numbers:
                    chapter_id = sort * 1000 + int(bn)
                    if bn == 0:
                        title, title_en, lang, src = (
                            "غير مصنّف", "", "ar",
                            "SUNNATI: book_number=0 in source (unclassified); "
                            "hadith-api section 0 title noted in build log, not used",
                        )
                        total_unclassified += sum(
                            1 for r in rows if r.get("book_number") == 0
                        )
                    else:
                        en = (titles.get(str(bn)) or "").strip()
                        if en:
                            title, title_en, lang, src = (
                                en, en, "en",
                                "fawazahmed0/hadith-api editions/ara-"
                                f"{book_id}.json (verbatim, English only)",
                            )
                        else:
                            title, title_en, lang, src = (
                                f"الكتاب رقم {bn}", "", "ar",
                                "SUNNATI fallback: no verified title in hadith-api for this book_number",
                            )
                            log["warnings"].append(
                                f"{book_id} book_number {bn}: no title in hadith-api; "
                                "used 'الكتاب رقم N' fallback"
                            )
                    con.execute(
                        "INSERT INTO chapters (id, book, num, title, title_en, title_lang, title_source)"
                        " VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (chapter_id, book_id, int(bn), title, title_en, lang, src),
                    )
                    chapter_of[bn] = chapter_id
                    created += 1
                chapters_created += created
                log["chapters"][book_id] = {
                    "count": created,
                    "book_numbers": [int(b) for b in book_numbers],
                    "titles_lang": "en (verbatim hadith-api) except book_number 0 = غير مصنّف",
                }

            # -- hadith rows ----------------------------------------------
            fffd_urns: list[int] = []
            hadith_rows = []
            fts_rows = []
            grade_rows = []
            n_grades = 0
            n_no_grade = 0
            for r in rows:
                text = r["text"] or ""
                if "\n" in text or "\t" in text:
                    total_newline_texts += 1
                if book_id == "ahmad" and "  " in text:
                    text = re.sub(r" {2,}", " ", text)
                    total_double_space_fixed += 1
                text = text.strip()
                has_fffd = 1 if "\ufffd" in text else 0
                if has_fffd:
                    fffd_urns.append(int(r["urn"]))
                urn = int(r["urn"])
                grades_list = r.get("grades") or []
                grades_json: list[dict] = []
                for g in grades_list:
                    grader_raw = (g.get("grader") or "").strip()
                    grade_raw = (g.get("grade") or "").strip()
                    grader_ar = GRADER_AR.get(grader_raw)
                    if grader_ar is None:
                        grader_ar = grader_raw
                        unknown_graders[grader_raw] += 1
                    grade_ar, kind, residual = normalize_grade(grade_raw)
                    for tok in residual:
                        grade_residual[tok] += 1
                    grade_dist[grade_ar or "(empty)"] += 1
                    grade_rows.append((
                        urn, scholar_ids.get(grader_raw), grader_ar,
                        grader_raw, grade_raw, grade_ar, kind,
                        BOOK_SOURCES[book_id][0],
                    ))
                    grades_json.append({
                        "scholar": grader_ar,
                        "grade": grade_ar,
                        "scholar_raw": grader_raw,
                        "grade_raw": grade_raw,
                    })
                    n_grades += 1
                if not grades_list:
                    n_no_grade += 1
                chapter_id = chapter_of.get(r.get("book_number"))
                if chapter_id is None:
                    # ahmad/darimi (no book_number key) -> the single chapter
                    chapter_id = chapter_of.get(None)
                hadith_rows.append((
                    urn, book_id, int(r["number_sort"]),
                    chapter_id, text, json.dumps(grades_json, ensure_ascii=False),
                    "", "",
                    str(r["hadith_number"]), int(r["number_sort"]),
                    str(r["hadith_key"]), urn, int(r["seq"]),
                    r.get("in_book_number"), r.get("book_number"),
                    r.get("sunnah_url"), has_fffd,
                    1 if r.get("is_muallaq") else 0,
                    BOOK_SOURCES[book_id][0],
                ))
                fts_rows.append((urn, fts_norm(text), ""))
            con.executemany(
                "INSERT INTO hadiths (id, book, num, chapter_id, text, grades,"
                " expl, expl_src, hadith_number, number_sort, hadith_key, urn,"
                " seq, in_book_number, book_number, sunnah_url,"
                " has_encoding_issue, is_muallaq, source)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                hadith_rows,
            )
            con.executemany(
                "INSERT INTO hadiths_fts (rowid, norm, expl) VALUES (?, ?, ?)",
                fts_rows,
            )
            con.executemany(
                "INSERT INTO hadith_grades (hadith_id, scholar_id, grader,"
                " grader_raw, grade_raw, grade_ar, grade_kind, source)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                grade_rows,
            )
            con.execute(
                "UPDATE books SET cnt = ? WHERE id = ?", (actual, book_id)
            )
            total_fffd += len(fffd_urns)
            log["fffd_urns"][book_id] = fffd_urns
            log["per_book"][book_id] = {
                "rows": actual, "expected": expected,
                "grades": n_grades, "no_grade_rows": n_no_grade,
                "fffd_rows": len(fffd_urns),
            }
            print(f"    -> {actual} hadiths, {n_grades} grade opinions, "
                  f"{len(fffd_urns)} U+FFFD rows, {n_no_grade} rows without grades")

        # -- HadeethEnc -> commentaries (verbatim, unlinked) --------------
        enc_table = pq.read_table(str(data_dir / "hadeethenc-ar.parquet"))
        enc_rows = enc_table.to_pylist()
        enc_actual = len(enc_rows)
        if enc_actual != EXPECTED_COUNTS["hadeethenc"]:
            log["warnings"].append(
                f"hadeethenc: row count {enc_actual} != expected "
                f"{EXPECTED_COUNTS['hadeethenc']}"
            )
        enc_insert = []
        enc_grade_dist: Counter = Counter()
        for r in enc_rows:
            grade_raw = (r.get("grade") or "").strip()
            kind = hadeethenc_grade_kind(grade_raw)
            enc_grade_dist[kind] += 1
            grader_raw = (r.get("grader") or "").strip()
            grader_ar = GRADER_AR.get(grader_raw, grader_raw)
            enc_insert.append((
                str(r["hadith_key"]), int(r["hadeethenc_id"]),
                (r.get("title") or ""), (r.get("intro") or ""),
                (r.get("text") or ""), (r.get("explanation") or ""),
                grade_raw, grade_raw, kind, grader_ar, grader_raw,
                (r.get("attribution_text") or ""),
                (r.get("grade_source") or ""),
                "HadeethEnc.com",
                "HadeethEnc terms: verbatim reproduction with attribution, "
                "no modification, removal on request; commercial_ok=False",
            ))
        con.executemany(
            "INSERT INTO commentaries (hadith_key, hadeethenc_id, title, intro,"
            " text, explanation, grade_raw, grade_ar, grade_kind, grader,"
            " grader_raw, attribution_text, grade_source, source, license)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            enc_insert,
        )
        log["counts"]["hadeethenc_commentaries"] = enc_actual
        log["hadeethenc_grade_kinds"] = dict(enc_grade_dist)
        print(f"  hadeethenc: {enc_actual} commentaries (verbatim, unlinked)")

        # -- commentaries_fts ONLY (rebuild 2026-11-26) ------------------
        # The commentaries search scope needs ONLY this one index: a
        # contentless FTS5 over the HadeethEnc rows (measured +2.87 MiB
        # on the real DB, ~6 s — see
        # SUNNATI_REBUILD_WORK_B_2026-11-26.md). It is built ALWAYS,
        # independent of the SUNNATI_BUILD_PHASE4_INDEX size gate below,
        # which still governs the FULL Phase 4 set (spans / lexicon,
        # +94 MB) pending the owner's v1.1 decision. Additive only: a
        # failure here must NEVER break the library build — the app
        # degrades gracefully (commentary scope returns no results) and
        # the failure is logged.
        try:
            from phase4_search_index import build_commentaries_fts

            log["commentaries_fts"] = build_commentaries_fts(con, {})
            print(
                "  commentaries_fts: "
                f"{log['commentaries_fts'].get('commentaries_fts_rows')} rows"
            )
        except Exception as e:  # noqa: BLE001 - index is additive
            log["warnings"].append(
                f"commentaries_fts index failed: {e!r} (commentary search "
                "scope will return no results)"
            )
            print(
                f"  WARNING: commentaries_fts index failed: {e!r}",
                file=sys.stderr,
            )

        # -- Phase 4 search indexes (spans / FTS / lexicon) --------------
        # Additive only: hadith_spans (+ FTS), search_synonyms,
        # search_roots, search_vocab. (commentaries_fts is built
        # separately above — small, always on — and is NOT part of this
        # gate.) A failure here must NEVER break the library build — the
        # app degrades gracefully (full-text search only) and the failure
        # is logged.
        # SIZE GATE (merge 2026-11-26, measured): the indexes add +94 MB
        # (DB 181 -> 275 MB, APK ~300 MB) which sits exactly on the
        # owner's 300 MB flag threshold — so they are OPT-IN here:
        # set SUNNATI_BUILD_PHASE4_INDEX=1 to build them. Default (v1.0.0):
        # skip them; the app falls back to FTS5 keyword search by design
        # (see database.dart hasSpansIndex / hasLexicon guards).
        if os.environ.get("SUNNATI_BUILD_PHASE4_INDEX", "") != "1":
            log["phase4_search_index"] = {
                "skipped": True,
                "reason": (
                    "SUNNATI_BUILD_PHASE4_INDEX != 1 — skipped by size gate "
                    "(measured +94 MB; APK would reach ~300 MB, the owner's "
                    "flag threshold). FTS5 keyword search remains."
                ),
            }
            print(
                "  phase4 index: SKIPPED by size gate "
                "(set SUNNATI_BUILD_PHASE4_INDEX=1 to build; +94 MB measured)"
            )
        else:
            try:
                from phase4_search_index import build_phase4_index

                log["phase4_search_index"] = build_phase4_index(con, {})
                p4 = log["phase4_search_index"]
                print(
                    f"  phase4 index: {p4.get('spans_rows')} spans,"
                    f" {p4.get('commentaries_fts_rows')} commentaries FTS,"
                    f" {p4.get('root_groups_kept')} root groups,"
                    f" db {p4.get('db_size_bytes', 0) // 1048576} MB"
                )
            except Exception as e:  # noqa: BLE001 - index is additive
                log["warnings"].append(
                    f"phase4 search index failed: {e!r} (library still usable;"
                    " FTS scopes degrade to full-text search)"
                )
                print(
                    f"  WARNING: phase4 search index failed: {e!r}",
                    file=sys.stderr,
                )

        # -- Arabic chapters (kitab <- bab) for the 7 verified books ----
        # MANDATORY (owner's 2026-11-26 order): replaces the English
        # chapter rows of the 7 books with Arabic ones from Arabic
        # Wikisource (CC BY-SA 4.0) and re-links hadiths.chapter_id via
        # the derived maps (tools/chapters/*_hadith_chapters.json).
        # Nasai/Malik are NOT touched (no verified source — English
        # titles stay, tagged «غير مترجم» in the app). Old English rows
        # are preserved in chapters_backup_v4_en (rollback plan:
        # SUNNATI_CHAPTERS_MIGRATION_PLAN_2026-11-26.md). A failure
        # here fails the build — a library without Arabic chapters
        # must not ship. tools/chapters_import.py holds the logic.
        from chapters_import import apply_arabic_chapters

        arabic_stats = apply_arabic_chapters(con, log)
        log["counts"]["arabic_chapters_rows"] = sum(
            s["rows_created"] for s in arabic_stats.values()
            if isinstance(s, dict)
        )
        log["counts"]["arabic_chapters_hadiths_linked"] = sum(
            s["hadiths_linked"] for s in arabic_stats.values()
            if isinstance(s, dict)
        )
        print(
            "  arabic chapters: "
            f"{log['counts']['arabic_chapters_rows']} rows, "
            f"{log['counts']['arabic_chapters_hadiths_linked']} hadiths linked"
        )

        # -- totals + meta --------------------------------------------------
        total = con.execute("SELECT COUNT(*) FROM hadiths").fetchone()[0]
        total_grades = con.execute("SELECT COUNT(*) FROM hadith_grades").fetchone()[0]
        log["counts"]["total_hadiths"] = total
        log["counts"]["total_grade_opinions"] = total_grades
        log["counts"]["chapters_created"] = chapters_created
        log["counts"]["unclassified_book0_rows"] = total_unclassified
        log["counts"]["fffd_rows"] = total_fffd
        log["counts"]["ahmad_double_space_fixed"] = total_double_space_fixed
        log["counts"]["texts_with_newline_or_tab"] = total_newline_texts
        log["grade_distribution"] = dict(grade_dist)
        log["grade_residual_tokens"] = dict(grade_residual)
        log["unknown_graders"] = dict(unknown_graders)
        if grade_residual:
            log["warnings"].append(
                f"grade normalisation residuals (unrecognised tokens): "
                f"{dict(grade_residual)} — grade_raw preserved verbatim"
            )
        if unknown_graders:
            log["warnings"].append(
                f"unknown graders kept verbatim: {dict(unknown_graders)}"
            )

        meta = {
            "source": SOURCE_DATASET,
            "source_url": SOURCE_URL,
            "source_revision": SOURCE_REVISION,
            "schema_version": "4",
            "phase": "2-3-imported + 5-schema-v3 (empty narrator tables) + 7-8-schema-v4 (empty admin/download tables)",
            "total_hadiths": str(total),
            "import_status": f"imported {total} hadiths (Nine Books) + "
                             f"{enc_actual} HadeethEnc commentaries; "
                             "see build log for counts and warnings",
            "import_date_utc": log["built_at_utc"],
            "counts_per_book": json.dumps(
                {b: log["per_book"][b]["rows"] for b in EXPECTED_COUNTS
                 if b != "hadeethenc"}, ensure_ascii=False),
            "hadeethenc_commentaries": str(enc_actual),
            "chapters_note": (
                "Arabic chapters (kitab <- bab) for 7 books — bukhari, "
                "muslim, abudawud, tirmidhi, ibnmajah, ahmad (20 masanid, "
                "not abwab), darimi — from Arabic Wikisource "
                "(Bayanat-Labs/arabic-wikisource-pd, arwikisource-20261001), "
                "CC BY-SA 4.0; original text public domain. Hadiths are "
                "re-linked to their Arabic bab by the derived offset/ "
                "alignment maps (tools/chapters/*_hadith_chapters.json); "
                "any hadith with no verified bab stays under an explicit "
                "«غير مصنّف» chapter — no bab is ever invented. Nasai/Malik "
                "keep their English titles (no verified Arabic source) "
                "tagged «غير مترجم». The old English chapter rows are "
                "preserved in chapters_backup_v4_en (rollback plan: "
                "SUNNATI_CHAPTERS_MIGRATION_PLAN_2026-11-26.md)."
            ),
            "grades_note": (
                "Grades are grader-attributed, never asserted by SUNNATI. "
                "Every opinion is kept (grade_raw verbatim + grade_ar "
                "normalised); conflicting opinions are all shown. "
                "Bukhari/Muslim: collection-level sahih only, no per-hadith "
                "grade in the source. Ahmad/Darimi: no grade in the source."
            ),
            "no_data_yet": (
                "narrators, chains, narrator_aliases, narrator_grades, "
                "narrator_scholars, narrator_teachers, narrator_students, "
                "narrator_sources, narrator_identity_matches, takhrij, "
                "hadith_variants, topics, hadith_relations, glossary: "
                "لا توجد بيانات موثقة بعد — المرحلة 5. Tables exist empty "
                "with full structure; no dummy rows. hadith_narrators / "
                "isnad_chains / isnad_nodes may hold ONLY machine-extracted "
                "parser candidates (narrator_id NULL, match_status "
                "'unlinked'/'needs_review', parser_version stamped) — "
                "never a linked narrator identity or a status verdict."
            ),
            "encoding_issues": (
                f"{total_fffd} rows contain U+FFFD (replacement character); "
                "imported with has_encoding_issue=1; URNs listed in the build log."
            ),
            "licenses": json.dumps(
                {
                    "quranlab/hadith": "Arabic matn public domain; digitisation ODbL-1.0/DbCL-1.0 with attribution (ahmad, darimi)",
                    "hadeethenc": "HadeethEnc terms: no modification, cite source + version, removal on request",
                    "hadith-api chapter titles": "The Unlicense (fawazahmed0/hadith-api) — old English titles preserved in chapters_backup_v4_en",
                    "arabic-wikisource chapters": "CC BY-SA 4.0 (Bayanat-Labs/arabic-wikisource-pd, arwikisource-20261001); original text public domain, digitisation/ordering CC BY-SA 4.0 — see Sources & Licences page",
                    "amiri_font": "SIL OFL 1.1",
                },
                ensure_ascii=False,
            ),
        }
        con.executemany(
            "INSERT INTO meta (key, value) VALUES (?, ?)", meta.items()
        )
        con.commit()

        # -- verification ---------------------------------------------------
        errors = []
        if total != EXPECTED_TOTAL_NINE:
            errors.append(
                f"total hadiths {total} != expected {EXPECTED_TOTAL_NINE}"
            )
        for book_id, _n, _s, _a, _so in BOOKS:
            got = con.execute(
                "SELECT COUNT(*) FROM hadiths WHERE book = ?", (book_id,)
            ).fetchone()[0]
            if got != EXPECTED_COUNTS[book_id]:
                errors.append(f"{book_id}: {got} != {EXPECTED_COUNTS[book_id]}")
        row = con.execute("PRAGMA quick_check").fetchone()
        if row is None or row[0] != "ok":
            errors.append("PRAGMA quick_check != ok")
        # FTS smoke test: «النيات» must find Bukhari 1 («بالنيات»).
        fts = con.execute(
            "SELECT h.hadith_key FROM hadiths_fts f JOIN hadiths h "
            "ON h.id = f.rowid WHERE hadiths_fts MATCH ? LIMIT 5",
            ('"نيات"*',),
        ).fetchall()
        fts_keys = [r[0] for r in fts]
        log["fts_smoke_test"] = {
            "query": "النيات -> \"نيات\"*",
            "found_keys": fts_keys,
            "bukhari_1_found": "bukhari:1" in fts_keys,
        }
        if "bukhari:1" not in fts_keys:
            errors.append(f"FTS smoke test failed: 'bukhari:1' not in {fts_keys}")
        # Phase 4 spans smoke test: matn «نيات» must find Bukhari 1.
        # Guarded: on a build where the phase-4 index failed (logged as
        # a warning above) the spans tables may be absent — that is a
        # degraded build, not a failed verification.
        try:
            spans_total = con.execute(
                "SELECT COUNT(*) FROM hadith_spans"
            ).fetchone()[0]
        except Exception:  # noqa: BLE001 - table may not exist
            spans_total = 0
        log["phase4_spans_smoke_test"] = {"spans_rows": spans_total}
        if spans_total:
            if spans_total != total:
                errors.append(
                    f"spans rows {spans_total} != total hadiths {total}"
                )
            spans_keys = [
                r[0] for r in con.execute(
                    "SELECT h.hadith_key FROM hadith_spans_fts f "
                    "JOIN hadiths h ON h.id = f.rowid "
                    "WHERE hadith_spans_fts MATCH ? LIMIT 5",
                    ('{matn_norm} : "نيات"*',),
                ).fetchall()
            ]
            log["phase4_spans_smoke_test"]["matn_niyat_keys"] = spans_keys
            if "bukhari:1" not in spans_keys:
                errors.append(
                    "spans smoke test failed: 'bukhari:1' not in "
                    f"{spans_keys}"
                )
        # hadith_number with suffix preserved as text.
        suf = con.execute(
            "SELECT COUNT(*) FROM hadiths WHERE hadith_number LIKE '%.%'"
        ).fetchone()[0]
        log["counts"]["hadith_number_with_dot_suffix"] = suf
        if errors:
            for e in errors:
                print(f"VERIFY FAILED: {e}", file=sys.stderr)
            return 1
        print(f"verified: total={total}, quick_check=ok, "
              f"FTS 'النيات' -> {fts_keys}, dot-suffix numbers={suf}")
        con.execute("PRAGMA optimize")
        con.commit()
    finally:
        con.close()

    # VACUUM after close (needs its own connection).
    con = sqlite3.connect(str(out))
    try:
        con.execute("VACUUM")
        con.commit()
    finally:
        con.close()

    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    size = out.stat().st_size
    out.with_suffix(".db.sha256").write_text(digest + "\n", encoding="utf-8")
    log["db_sha256"] = digest
    log["db_size_bytes"] = size
    if args.log_json:
        Path(args.log_json).write_text(
            json.dumps(log, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        print(f"build log: {args.log_json}")
    print(f"built {out} — schema v3, {total} hadiths, "
          f"{log['counts']['hadeethenc_commentaries']} commentaries, "
          f"{size} bytes")
    print(f"sha256: {digest}")
    if log["warnings"]:
        print("WARNINGS:")
        for w in log["warnings"]:
            print(f"  - {w}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
