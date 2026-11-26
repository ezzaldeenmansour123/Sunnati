/// Local SQLite library database.
///
/// The library database is built in CI by `tools/build_db.py` from the
/// licensed source (`quranlab/hadith`, pinned revision) and PUBLISHED by
/// CI to the `library-v1` GitHub release — it is NOT embedded in the APK
/// (rebuild 2026-11-26, external-download decision). After install the
/// app downloads it once (`lib/ui/first_run_download_screen.dart`) into
/// the app support directory, verifies it (SHA-256 + PRAGMA quick_check)
/// and only then opens it. A device that already has a VALID installed
/// copy (e.g. migrated from build 52, which copied the embedded asset)
/// keeps using it as-is — no forced re-download (see
/// [LibraryInstallDecision]).
///
/// There is NO code path in this file that loads `sunnati.db` from
/// Flutter assets: the embedded-asset copy was removed with the
/// external-download decision. `assets/assistant_phrasings.json` is the
/// only data asset left in the APK, and it is loaded by
/// `lib/assistant/phrasings.dart`, not here.
///
/// In Phase 1 the database contains the schema, the nine-books metadata and
/// `meta` only — no hadith rows yet (full import is Phase 2/3). The app
/// therefore reports [isAvailable] == false until a real library is
/// installed, and every screen says so honestly instead of showing fake
/// content. Nothing here invents a hadith.
///
/// Phase 5 core (2026-11-26): the verified narrators live in a SEPARATE
/// database (`narrators.db`, CC BY-NC-SA 4.0, OpenITI Taqrib al-Tahdhib)
/// — never merged into this file, because this file's hadith content is
/// ODbL/Unlicense and the two licences are incompatible. The narrators
/// package is HELD BACK by the KITAB gate
/// (`kNarratorsPackageHeldBack` in `lib/core/package_manifest.dart`):
/// it is NOT distributed by this build, NOT offered for download, and
/// there is no asset-install path for it. The ONLY narrators copy this
/// build will ever use is a valid one ALREADY on the device from a
/// previous install (legacy local copy, read-only, never re-distributed);
/// when it is absent the app keeps working: narrator queries read the
/// local (empty) `narrators` table and every screen reports honestly
/// that no verified narrators are installed — with the registry's
/// pending-approval reason. Nothing here invents a narrator, a grade,
/// or a link.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../core/normalize.dart';
import '../core/package_manifest.dart';
import '../core/stemming.dart';
import '../models/admin_record.dart';
import '../models/book.dart';
import '../models/chain.dart';
import '../models/commentary.dart';
import '../models/downloaded_library.dart';
import '../models/grade.dart';
import '../models/hadith.dart';
import '../models/narrator.dart';
import '../models/takhrij.dart';

/// Where the installed library database lives on the device.
const String kDatabaseFileName = 'sunnati.db';

/// Where the installed narrators database lives on the device.
const String kNarratorsFileName = 'narrators.db';

/// First-run / migration decision for the installed library file.
/// Pure logic (see [decideLibraryInstall]) so it is unit-testable
/// without a device, a database, or a network.
enum LibraryInstallDecision {
  /// A valid installed copy exists: use it as-is. This is the migration
  /// path for users of build 52 (whose install already holds a valid
  /// `sunnati.db`): they are NEVER forced to re-download ~190 MB.
  useExisting,

  /// No installed copy exists: the first-run download screen must run.
  needsDownload,

  /// An installed copy exists but fails verification: delete it and
  /// re-download (the first-run download screen must run).
  corruptNeedsRedownload,
}

/// Decide what to do with an installed library file, from two facts
/// only: whether the file exists and whether it passed verification
/// (SQLite header + `PRAGMA quick_check` + at least one hadith row).
/// No I/O, no network — the caller supplies the facts.
LibraryInstallDecision decideLibraryInstall({
  required bool fileExists,
  required bool fileValid,
}) {
  if (!fileExists) return LibraryInstallDecision.needsDownload;
  if (!fileValid) return LibraryInstallDecision.corruptNeedsRedownload;
  return LibraryInstallDecision.useExisting;
}

/// Admin/download tables of schema v4 (Phases 7-8). These statements are
/// safe to run on every open (CREATE ... IF NOT EXISTS). The
/// `downloaded_libraries` column additions live in
/// [kDownloadedLibrariesV4Columns] and are applied only when the column
/// is missing (see [_ensureAdminSchema]) — a bare ALTER would throw on
/// the second run. The SQL here must stay in sync with SCHEMA_V4 in
/// `tools/build_db.py`; `tools/test_phase7_8.py` checks the parity.
const String kAdminSchemaV4Tables = '''
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
''';

/// Schema-v4 columns added to `downloaded_libraries` (column → SQL
/// definition). Applied only when missing.
const Map<String, String> kDownloadedLibrariesV4Columns =
    <String, String>{
  'source': "TEXT NOT NULL DEFAULT ''",
  'license': "TEXT NOT NULL DEFAULT ''",
  'download_url': "TEXT NOT NULL DEFAULT ''",
  'total_bytes': 'INTEGER NOT NULL DEFAULT 0',
  'downloaded_bytes': 'INTEGER NOT NULL DEFAULT 0',
  'manifest_json': "TEXT NOT NULL DEFAULT ''",
  'updated_at': "TEXT NOT NULL DEFAULT ''",
};

/// NOTE (rebuild 2026-11-26): there are NO asset paths for either
/// database any more. `sunnati.db` is downloaded after install (see
/// [kLibraryPackage]) and `narrators.db` is held back by the KITAB gate
/// (see [kNarratorsPackageHeldBack]) — neither is loaded from Flutter
/// assets by any code path. The integrator still has to remove the two
/// entries from `pubspec.yaml` (see
/// SUNNATI_REBUILD_WORK_B_2026-11-26.md); until then the asset entries
/// are dead declarations that nothing reads.

/// One FTS hit row: the hadith plus the ranking inputs the search
/// service needs (FTS5 rank, the indexed norm text, and — for the
/// spans table — the parser's matn boundary). Returned by [ftsSearch]
/// and [similarCandidates]; the service scores and paginates in code.
class FtsHitRow {
  const FtsHitRow({
    required this.hadith,
    required this.rank,
    required this.norm,
    required this.isnadNorm,
    required this.matnNorm,
    this.isnadEndChar,
  });

  final Hadith hadith;

  /// FTS5 bm25 rank (negative; closer to 0 is better).
  final double rank;

  /// Indexed norm text (`hadiths_fts.norm`; empty for spans hits).
  final String norm;

  /// Indexed isnad norm (`hadith_spans.isnad_norm`; empty otherwise).
  final String isnadNorm;

  /// Indexed matn norm (`hadith_spans.matn_norm`; empty otherwise).
  final String matnNorm;

  /// Parser's matn boundary (char offset in the original text), or null
  /// when no boundary was found.
  final int? isnadEndChar;
}

/// The parser-derived isnad/matn split of one hadith (Phase 4 index).
/// The split is the isnad parser's heuristic (Phase 5 report); the
/// last narrator is a parser CANDIDATE, not a verified identity.
class HadithSpans {
  const HadithSpans({
    required this.hadithId,
    required this.isnadNorm,
    required this.matnNorm,
    this.isnadEndChar,
    required this.isnadStatus,
    required this.lastNarratorNorm,
    required this.lastNarratorText,
    required this.companionMarked,
  });

  factory HadithSpans.fromRow(Map<String, Object?> row) {
    return HadithSpans(
      hadithId: (row['hadith_id'] as int?) ?? 0,
      isnadNorm: (row['isnad_norm'] as String?) ?? '',
      matnNorm: (row['matn_norm'] as String?) ?? '',
      isnadEndChar: row['isnad_end_char'] as int?,
      isnadStatus: (row['isnad_status'] as String?) ?? '',
      lastNarratorNorm: (row['last_narrator_norm'] as String?) ?? '',
      lastNarratorText: (row['last_narrator_text'] as String?) ?? '',
      companionMarked: ((row['companion_marked'] as int?) ?? 0) != 0,
    );
  }

  final int hadithId;
  final String isnadNorm;
  final String matnNorm;
  final int? isnadEndChar;
  final String isnadStatus;
  final String lastNarratorNorm;
  final String lastNarratorText;
  final bool companionMarked;
}

class SunnatiDatabase {
  SunnatiDatabase._(
    this._db, {
    required this.isAvailable,
    this.narratorsAvailable = false,
    this.libraryNeedsDownload = false,
  });

  final Database? _db;

  /// True only when a verified database with at least one hadith row is
  /// installed. False when no library has been downloaded yet, when the
  /// installed copy fails verification, or when the database holds no
  /// hadith rows.
  final bool isAvailable;

  /// True when the first-run download screen must run: no installed
  /// library file exists, or the installed copy failed verification and
  /// was removed. False when a valid library is installed (including a
  /// migrated build-52 copy) or when the database is present but empty.
  final bool libraryNeedsDownload;

  /// True only when a narrators database ALREADY on the device from a
  /// previous install (legacy local copy — NOT distributed by this
  /// build) is verified and attached as `narrators_db`. False when no
  /// such copy exists or it fails verification — narrator screens then
  /// report honestly that no verified narrators are installed, with the
  /// registry's pending-approval reason.
  final bool narratorsAvailable;

  /// Human-readable status for the library screen, e.g. the reason the
  /// library is not available yet. Empty when available.
  String unavailableReason = '';

  /// Human-readable reason the narrators database is not available.
  /// Empty when available.
  String narratorsUnavailableReason = '';

  /// The installed library file in [dir] (app support directory).
  static File installedLibraryFile(Directory dir) =>
      File('${dir.path}/$kDatabaseFileName');

  /// The installed narrators file in [dir] (app support directory).
  static File installedNarratorsFile(Directory dir) =>
      File('${dir.path}/$kNarratorsFileName');

  /// Verify an installed library file WITHOUT opening it for use:
  /// SQLite header + `PRAGMA quick_check` + at least one hadith row.
  /// Used by the first-run download screen after a download, before it
  /// reports success — a download is never reported successful on the
  /// strength of the SHA-256 alone. Never throws.
  static Future<bool> verifyLibraryFile(File file) async {
    if (!await _verifyFile(file)) return false;
    try {
      final sqlite = sqlite3.open(file.path, mode: OpenMode.readOnly);
      try {
        final result = sqlite.select('PRAGMA quick_check');
        final quickOk = result.isNotEmpty &&
            result.first['quick_check'].toString() == 'ok';
        if (!quickOk) return false;
        final countRow =
            sqlite.select('SELECT COUNT(*) AS c FROM hadiths');
        return ((countRow.first['c'] as int?) ?? 0) > 0;
      } finally {
        sqlite.dispose();
      }
    } catch (_) {
      return false;
    }
  }

  /// Open the installed library database.
  ///
  /// The library is NOT installed from assets any more: if no VALID
  /// installed copy exists, this returns a database with [isAvailable]
  /// == false and [libraryNeedsDownload] == true, and the caller (see
  /// `lib/main.dart`) shows the first-run download screen instead of
  /// crashing or pretending the library is there. A valid installed
  /// copy — including one migrated from build 52 — is used as-is.
  ///
  /// Never throws for a missing/corrupt install: it returns a database
  /// with [isAvailable] == false and [unavailableReason] set, so the UI
  /// can explain the state instead of crashing.
  static Future<SunnatiDatabase> open() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = installedLibraryFile(dir);
      final exists = await file.exists();
      if (!exists) {
        final db = SunnatiDatabase._(
          null,
          isAvailable: false,
          libraryNeedsDownload: true,
        );
        db.unavailableReason =
            'المكتبة غير منزّلة بعد — نزّلها عند أول تشغيل لتعمل دون إنترنت.';
        return db;
      }
      if (!await _verifyFile(file)) {
        // Corrupt install: remove it so the first-run download can
        // replace it cleanly on the next run.
        try {
          await file.delete();
        } catch (_) {}
        final db = SunnatiDatabase._(
          null,
          isAvailable: false,
          libraryNeedsDownload: true,
        );
        db.unavailableReason =
            'تعذّر التحقق من سلامة المكتبة المثبّتة؛ ستُعاد محاولة التنزيل عند التشغيل التالي.';
        return db;
      }
      final sqlite = sqlite3.open(file.path);
      final result = sqlite.select('PRAGMA quick_check');
      final quickOk = result.isNotEmpty &&
          result.first['quick_check'].toString() == 'ok';
      if (!quickOk) {
        sqlite.dispose();
        try {
          await file.delete();
        } catch (_) {}
        final db = SunnatiDatabase._(
          null,
          isAvailable: false,
          libraryNeedsDownload: true,
        );
        db.unavailableReason = 'فشل فحص سلامة قاعدة بيانات المكتبة.';
        return db;
      }
      // Schema v4 (Phases 7-8): admin + downloads-registry tables. The
      // published library DB ships as v2, so this runs on every open and
      // is idempotent — an already-migrated database is untouched.
      _ensureAdminSchema(sqlite);
      final countRow =
          sqlite.select('SELECT COUNT(*) AS c FROM hadiths');
      final total = (countRow.first['c'] as int?) ?? 0;
      // Phase 5 core (optional, never fatal): attach a narrators
      // database ALREADY on the device from a previous install as
      // `narrators_db` (legacy local copy only — this build distributes
      // no narrators file and offers no narrators download; see
      // [_attachLegacyNarratorsDb]). Without it every narrator query
      // reads the local (empty) `narrators` table and the UI reports
      // honestly that no verified narrators are installed.
      final narrators = await _attachLegacyNarratorsDb(dir, sqlite);
      final db = SunnatiDatabase._(
        sqlite,
        isAvailable: total > 0,
        narratorsAvailable: narrators.ok,
      );
      if (!narrators.ok) {
        db.narratorsUnavailableReason = narrators.reason;
      }
      if (total == 0) {
        db.unavailableReason =
            'المكتبة تُبنى — الكتب التسعة قيد الاستيراد. لا توجد أحاديث بعد.';
      } else {
        // Record the installed core library in the downloads registry
        // when no row exists yet (migration: build-52 users have a
        // valid library file but never downloaded it through this
        // build, so no row was ever written). The SHA-256 is left
        // empty for a migrated copy — it was never verified against a
        // published hash by this build, and claiming one would be
        // inventing data. A fresh download records its real hash
        // (see the first-run download screen).
        _ensureLibraryRegistryRow(sqlite, file);
      }
      return db;
    } catch (e) {
      final db = SunnatiDatabase._(null, isAvailable: false);
      db.unavailableReason = 'تعذّر فتح المكتبة: $e';
      return db;
    }
  }

  /// Insert the `downloaded_libraries` row for the core library when
  /// none exists (migration case). Best-effort and never throws: a
  /// registry failure must never break opening the library.
  static void _ensureLibraryRegistryRow(Database sqlite, File file) {
    try {
      final existing = sqlite.select(
        'SELECT COUNT(*) AS c FROM downloaded_libraries '
        "WHERE library_id = 'library'",
      );
      if (((existing.first['c'] as int?) ?? 0) > 0) return;
      final size = file.lengthSync();
      final now = DateTime.now().toUtc().toIso8601String();
      sqlite.execute(
        'INSERT INTO downloaded_libraries (library_id, name, version, '
        'size_bytes, sha256, status, installed_at, source, license, '
        'download_url, total_bytes, downloaded_bytes, manifest_json, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          kLibraryPackage.id,
          kLibraryPackage.displayName,
          '1.0.0',
          size,
          '',
          'installed',
          now,
          'quranlab/hadith',
          '',
          kLibraryPackage.url,
          size,
          size,
          '',
          now,
        ],
      );
    } catch (_) {
      // Registry bookkeeping must never break the library open.
    }
  }

  /// Attach a narrators database ALREADY on the device from a previous
  /// install (legacy local copy) as `narrators_db` on [sqlite], after
  /// verifying it (header + quick_check + at least one narrator row).
  /// Best-effort and never throws.
  ///
  /// KITAB GATE — read carefully. This build distributes NO narrators
  /// file, offers NO narrators download, and installs NOTHING from
  /// assets: there is no source to reinstall a missing or corrupt copy
  /// from while the gate is closed. The legacy copy is therefore kept
  /// read-only and used as-is when it verifies, because deleting it
  /// would destroy data the user already holds and that cannot be
  /// re-fetched; a corrupt legacy copy is LEFT ON DISK (not deleted)
  /// and reported as unavailable, so it can still be inspected or
  /// repaired by hand. When no legacy copy exists the reason returned
  /// is the registry's pending-approval reason
  /// ([kNarratorsPackage.unavailableReason]), word for word.
  static Future<({bool ok, String reason})> _attachLegacyNarratorsDb(
    Directory dir,
    Database sqlite,
  ) async {
    final file = installedNarratorsFile(dir);
    if (!await file.exists()) {
      return (ok: false, reason: kNarratorsPackage.unavailableReason);
    }
    try {
      if (!await _verifyFile(file)) {
        return (
          ok: false,
          reason: 'ملف قاعدة الرواة المحلي على الجهاز تالف ولا يمكن '
              'فتحه — بقي الملف دون حذف.',
        );
      }
      sqlite.execute(
        "ATTACH DATABASE '${file.path.replaceAll("'", "''")}' "
        'AS narrators_db',
      );
      final result = sqlite.select('PRAGMA narrators_db.quick_check');
      final quickOk = result.isNotEmpty &&
          result.first['quick_check'].toString() == 'ok';
      if (!quickOk) {
        sqlite.execute('DETACH DATABASE narrators_db');
        return (ok: false, reason: 'فشل فحص سلامة قاعدة الرواة المحلية.');
      }
      final count = sqlite.select(
        'SELECT COUNT(*) AS c FROM narrators_db.narrators',
      );
      final total = (count.first['c'] as int?) ?? 0;
      if (total == 0) {
        sqlite.execute('DETACH DATABASE narrators_db');
        return (ok: false, reason: 'قاعدة الرواة المحلية مثبّتة لكنها فارغة.');
      }
      return (ok: true, reason: '');
    } catch (e) {
      try {
        sqlite.execute('DETACH DATABASE narrators_db');
      } catch (_) {}
      return (ok: false, reason: 'تعذّر فتح قاعدة الرواة المحلية: $e');
    }
  }

  /// Verify an installed file: exists, non-empty, SQLite header present.
  static Future<bool> _verifyFile(File file) async {
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length < 100) return false;
    final header = await file.openRead(0, 16).first;
    return utf8.decode(header, allowMalformed: true).startsWith('SQLite');
  }

  /// Create the schema-v4 admin/download tables and add the v4 columns
  /// to `downloaded_libraries` when missing. Idempotent: safe to run on
  /// every open, including on a database that already has v4.
  /// Statements are executed one at a time — `Database.execute` takes a
  /// single statement.
  static void _ensureAdminSchema(Database sqlite) {
    for (final statement in kAdminSchemaV4Tables.split(';')) {
      final trimmed = statement.trim();
      if (trimmed.isNotEmpty) sqlite.execute(trimmed);
    }
    final existing = <String>{
      for (final row
          in sqlite.select('PRAGMA table_info(downloaded_libraries)'))
        (row['name'] as String?) ?? '',
    };
    for (final entry in kDownloadedLibrariesV4Columns.entries) {
      if (!existing.contains(entry.key)) {
        sqlite.execute(
          'ALTER TABLE downloaded_libraries ADD COLUMN '
          '${entry.key} ${entry.value}',
        );
      }
    }
  }

  /// Total hadith rows installed (0 in Phase 1).
  int totalHadiths() {
    final db = _db;
    if (db == null) return 0;
    final row = db.select('SELECT COUNT(*) AS c FROM hadiths');
    return (row.first['c'] as int?) ?? 0;
  }

  /// Library metadata: source, revision, build date, totals.
  Map<String, String> meta() {
    final db = _db;
    if (db == null) return const <String, String>{};
    final rows = db.select('SELECT key, value FROM meta');
    return <String, String>{
      for (final r in rows) (r['key'] as String): (r['value'] as String),
    };
  }

  /// The nine books with their actually-imported counts (from the DB).
  List<Book> books() {
    final db = _db;
    if (db == null) return nineBooks;
    final rows = db.select(
      'SELECT b.id, b.name, b.short, b.author, b.sort, '
      'COUNT(h.id) AS cnt FROM books b '
      'LEFT JOIN hadiths h ON h.book = b.id '
      'GROUP BY b.id ORDER BY b.sort',
    );
    return rows.map((r) {
      final map = <String, Object?>{
        'id': r['id'],
        'name': r['name'],
        'short': r['short'],
        'author': r['author'],
        'sort': r['sort'],
        'cnt': r['cnt'],
      };
      return Book.fromRow(map);
    }).toList();
  }

  /// Chapters of one book, in order.
  List<Chapter> chapters(String bookId) {
    final db = _db;
    if (db == null) return const <Chapter>[];
    final rows = db.select(
      'SELECT c.id, c.book, c.num, c.title, '
      'COUNT(h.id) AS cnt FROM chapters c '
      'LEFT JOIN hadiths h ON h.chapter_id = c.id '
      'WHERE c.book = ? GROUP BY c.id ORDER BY c.num',
      <Object?>[bookId],
    );
    return rows
        .map((r) => Chapter.fromRow(<String, Object?>{
              'id': r['id'],
              'book': r['book'],
              'num': r['num'],
              'title': r['title'],
              'cnt': r['cnt'],
            }))
        .toList();
  }

  /// Hadiths of one chapter, in number order.
  List<Hadith> hadithsForChapter(int chapterId) {
    final db = _db;
    if (db == null) return const <Hadith>[];
    final rows = db.select(
      'SELECT h.id, h.book, h.num, h.chapter_id, '
      'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src '
      'FROM hadiths h LEFT JOIN chapters c ON c.id = h.chapter_id '
      'WHERE h.chapter_id = ? ORDER BY h.num',
      <Object?>[chapterId],
    );
    return rows.map(_hadithFromRow).toList();
  }

  /// One hadith by book + number, or null.
  Hadith? hadithByNumber(String bookId, int num) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
      'SELECT h.id, h.book, h.num, h.chapter_id, '
      'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src '
      'FROM hadiths h LEFT JOIN chapters c ON c.id = h.chapter_id '
      'WHERE h.book = ? AND h.num = ? LIMIT 1',
      <Object?>[bookId, num],
    );
    if (rows.isEmpty) return null;
    return _hadithFromRow(rows.first);
  }

  /// FTS5 search over the normalised text. [ftsQuery] must already be a
  /// valid FTS5 query string (see `lib/search/search_service.dart`).
  /// Returns at most [limit] rows ordered by rank.
  List<Hadith> searchFts(String ftsQuery, {int limit = 50}) {
    final db = _db;
    if (db == null || ftsQuery.trim().isEmpty) return const <Hadith>[];
    final rows = db.select(
      'SELECT h.id, h.book, h.num, h.chapter_id, '
      'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src '
      'FROM hadiths_fts f JOIN hadiths h ON h.id = f.rowid '
      'LEFT JOIN chapters c ON c.id = h.chapter_id '
      'WHERE hadiths_fts MATCH ? ORDER BY rank LIMIT ?',
      <Object?>[ftsQuery, limit],
    );
    return rows.map(_hadithFromRow).toList();
  }

  // ---- Phase 4 search (scopes, lexicon, commentaries, similar) ----

  /// True when the Phase 4 isnad/matn index exists (`hadith_spans` +
  /// `hadith_spans_fts`). False on a library built before Phase 4 — the
  /// search service then degrades to full-text search and says so.
  bool get hasSearchSpans =>
      _tableExists('hadith_spans') && _tableExists('hadith_spans_fts');

  /// True when the Phase 4 commentaries FTS index exists.
  bool get hasCommentariesFts => _tableExists('commentaries_fts');

  /// True when the Phase 4 lexicon tables exist (`search_roots`,
  /// `search_synonyms`, `search_vocab`).
  bool get hasSearchLexicon =>
      _tableExists('search_roots') &&
      _tableExists('search_synonyms') &&
      _tableExists('search_vocab');

  /// SQL fragment + argument for the per-hadith grade filter. Grades are
  /// matched through `hadith_grades` (grader-attributed, never asserted
  /// by SUNNATI). Bukhari/Muslim have no per-hadith grade in the source
  /// (collection-level sahih) and Ahmad/Darimi have none either, so a
  /// grade filter honestly excludes them — the UI says so.
  ({String sql, List<Object?> args}) _gradeFilter(String? grade) {
    if (grade == null || grade.isEmpty) {
      return (sql: '', args: const <Object?>[]);
    }
    return (
      sql: 'EXISTS (SELECT 1 FROM hadith_grades g WHERE '
          'g.hadith_id = h.id AND g.grade_ar LIKE ?)',
      args: <Object?>['%$grade%'],
    );
  }

  /// One FTS query with book / chapter / grade filters, returning the
  /// ranking inputs the search service needs ([FtsHitRow]).
  ///
  /// [useSpans] queries `hadith_spans_fts` (scope متن/سند); otherwise
  /// `hadiths_fts` (full text). [ftsQuery] must already be a valid FTS5
  /// query string. Returns at most [limit] rows ordered by rank.
  List<FtsHitRow> ftsSearch(
    String ftsQuery, {
    required bool useSpans,
    String? bookId,
    String? grade,
    int? chapterId,
    int limit = 500,
  }) {
    final db = _db;
    if (db == null || ftsQuery.trim().isEmpty) return const <FtsHitRow>[];
    final conditions = <String>[];
    final args = <Object?>[];
    if (bookId != null) {
      conditions.add('h.book = ?');
      args.add(bookId);
    }
    if (chapterId != null) {
      conditions.add('h.chapter_id = ?');
      args.add(chapterId);
    }
    final g = _gradeFilter(grade);
    if (g.sql.isNotEmpty) {
      conditions.add(g.sql);
      args.addAll(g.args);
    }
    final filter =
        conditions.isEmpty ? '' : ' AND ${conditions.join(' AND ')}';
    final List<Row> rows;
    if (!useSpans) {
      rows = db.select(
        'SELECT h.id, h.book, h.num, h.chapter_id, '
        'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src, '
        'rank AS r, f.norm AS norm '
        'FROM hadiths_fts f JOIN hadiths h ON h.id = f.rowid '
        'LEFT JOIN chapters c ON c.id = h.chapter_id '
        'WHERE hadiths_fts MATCH ?$filter ORDER BY rank LIMIT ?',
        <Object?>[ftsQuery, ...args, limit],
      );
      return rows
          .map(
            (r) => FtsHitRow(
              hadith: _hadithFromRow(r),
              rank: (r['r'] as num?)?.toDouble() ?? 0.0,
              norm: (r['norm'] as String?) ?? '',
              isnadNorm: '',
              matnNorm: '',
            ),
          )
          .toList();
    }
    rows = db.select(
      'SELECT h.id, h.book, h.num, h.chapter_id, '
      'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src, '
      'rank AS r, s.isnad_norm AS isnad_norm, s.matn_norm AS matn_norm, '
      's.isnad_end_char AS isnad_end_char '
      'FROM hadith_spans_fts f JOIN hadiths h ON h.id = f.rowid '
      'JOIN hadith_spans s ON s.hadith_id = h.id '
      'LEFT JOIN chapters c ON c.id = h.chapter_id '
      'WHERE hadith_spans_fts MATCH ?$filter ORDER BY rank LIMIT ?',
      <Object?>[ftsQuery, ...args, limit],
    );
    return rows
        .map(
          (r) => FtsHitRow(
            hadith: _hadithFromRow(r),
            rank: (r['r'] as num?)?.toDouble() ?? 0.0,
            norm: '',
            isnadNorm: (r['isnad_norm'] as String?) ?? '',
            matnNorm: (r['matn_norm'] as String?) ?? '',
            isnadEndChar: r['isnad_end_char'] as int?,
          ),
        )
        .toList();
  }

  /// Exact COUNT for one FTS query with the same filters as [ftsSearch].
  /// With [antiMatch], rows also matching [antiMatch] are excluded
  /// (used to count semantic-expansion-only hits).
  int ftsCount(
    String ftsQuery, {
    required bool useSpans,
    String? bookId,
    String? grade,
    int? chapterId,
    String? antiMatch,
  }) {
    final db = _db;
    if (db == null || ftsQuery.trim().isEmpty) return 0;
    final conditions = <String>[];
    final args = <Object?>[];
    if (bookId != null) {
      conditions.add('h.book = ?');
      args.add(bookId);
    }
    if (chapterId != null) {
      conditions.add('h.chapter_id = ?');
      args.add(chapterId);
    }
    final g = _gradeFilter(grade);
    if (g.sql.isNotEmpty) {
      conditions.add(g.sql);
      args.addAll(g.args);
    }
    final filter =
        conditions.isEmpty ? '' : ' AND ${conditions.join(' AND ')}';
    final table = useSpans ? 'hadith_spans_fts' : 'hadiths_fts';
    final anti = antiMatch == null
        ? ''
        : ' AND h.id NOT IN (SELECT rowid FROM $table WHERE $table MATCH ?)';
    final allArgs = <Object?>[ftsQuery, ...args];
    if (antiMatch != null) allArgs.add(antiMatch);
    final row = db.select(
      'SELECT COUNT(*) AS c FROM $table f '
      'JOIN hadiths h ON h.id = f.rowid '
      'WHERE $table MATCH ?$filter$anti',
      allArgs,
    );
    return (row.first['c'] as int?) ?? 0;
  }

  /// Other vocabulary terms sharing [term]'s root key (from
  /// `search_roots`, derived from the corpus vocabulary). Empty when the
  /// lexicon is absent, the term is too short, or it has no group.
  List<String> rootExpansions(String term) {
    final db = _db;
    if (db == null || !hasSearchLexicon || term.length < 3) {
      return const <String>[];
    }
    final key = rootKey(term);
    if (key.isEmpty) return const <String>[];
    final rows = db.select(
      'SELECT term_norm FROM search_roots WHERE root_key = ? '
      'ORDER BY freq DESC',
      <Object?>[key],
    );
    return rows
        .map((r) => (r['term_norm'] as String?) ?? '')
        .where((t) => t.isNotEmpty && t != term)
        .toList();
  }

  /// Curated synonym / related expansions for [term] (from
  /// `search_synonyms`). Empty when the lexicon is absent or the term
  /// is too short.
  List<String> synonymExpansions(String term) {
    final db = _db;
    if (db == null || !hasSearchLexicon || term.length < 3) {
      return const <String>[];
    }
    final rows = db.select(
      'SELECT expansion_norm FROM search_synonyms WHERE term_norm = ?',
      <Object?>[term],
    );
    return rows
        .map((r) => (r['expansion_norm'] as String?) ?? '')
        .where((t) => t.isNotEmpty)
        .toList();
  }

  /// Document frequency of one normalised term in the corpus vocabulary
  /// (`search_vocab`). 1 when the lexicon is absent or the term is
  /// unknown — the similar-hadith search treats unknown as rare.
  int vocabFreq(String term) {
    final db = _db;
    if (db == null || !hasSearchLexicon) return 1;
    final rows = db.select(
      'SELECT freq FROM search_vocab WHERE term_norm = ? LIMIT 1',
      <Object?>[term],
    );
    if (rows.isEmpty) return 1;
    return (rows.first['freq'] as int?) ?? 1;
  }

  /// The indexed norm text of one hadith (`hadiths_fts.norm`), or null.
  /// Used by similar-hadith search when the Phase 4 spans index is
  /// absent (fallback to full-text tokens).
  String? normFor(int hadithId) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
      'SELECT norm FROM hadiths_fts WHERE rowid = ? LIMIT 1',
      <Object?>[hadithId],
    );
    if (rows.isEmpty) return null;
    return (rows.first['norm'] as String?) ?? '';
  }

  /// The parser-derived isnad/matn split of one hadith, or null when
  /// the Phase 4 index is absent.
  HadithSpans? spansFor(int hadithId) {
    final db = _db;
    if (db == null || !hasSearchSpans) return null;
    final rows = db.select(
      'SELECT hadith_id, isnad_norm, matn_norm, isnad_end_char, '
      'isnad_status, last_narrator_norm, last_narrator_text, '
      'companion_marked FROM hadith_spans WHERE hadith_id = ? LIMIT 1',
      <Object?>[hadithId],
    );
    if (rows.isEmpty) return null;
    return HadithSpans.fromRow(
      <String, Object?>{for (final c in rows.first.keys) c: rows.first[c]},
    );
  }

  /// FTS candidate rows for similar-hadith search: hadiths sharing any
  /// of [terms] (OR of prefix terms) in the matn (spans) or full text,
  /// best rank first. The caller computes Jaccard similarity.
  List<FtsHitRow> similarCandidates(
    List<String> terms, {
    required bool useSpans,
    int limit = 200,
  }) {
    final db = _db;
    if (db == null || terms.isEmpty) return const <FtsHitRow>[];
    final col = useSpans ? 'matn_norm' : 'norm';
    final match = terms
        .map((t) => '{$col} : "${t.replaceAll('"', '')}"*')
        .join(' OR ');
    return ftsSearch(match, useSpans: useSpans, limit: limit);
  }

  /// Commentaries (HadeethEnc) matching [ftsQuery], one page. The
  /// commentaries are verbatim and unlinked — see [Commentary].
  List<Commentary> searchCommentariesFts(
    String ftsQuery, {
    int limit = 20,
    int offset = 0,
  }) {
    final db = _db;
    if (db == null ||
        !hasCommentariesFts ||
        ftsQuery.trim().isEmpty) {
      return const <Commentary>[];
    }
    final rows = db.select(
      'SELECT c.id, c.hadith_key, c.title, c.text, c.explanation, '
      'c.grade_ar, c.grader, c.attribution_text, c.source '
      'FROM commentaries_fts f JOIN commentaries c ON c.id = f.rowid '
      'WHERE commentaries_fts MATCH ? ORDER BY rank LIMIT ? OFFSET ?',
      <Object?>[ftsQuery, limit, offset],
    );
    return rows
        .map(
          (r) => Commentary.fromRow(
            <String, Object?>{for (final c in r.keys) c: r[c]},
          ),
        )
        .toList();
  }

  /// Exact COUNT for [searchCommentariesFts].
  int countCommentariesFts(String ftsQuery) {
    final db = _db;
    if (db == null ||
        !hasCommentariesFts ||
        ftsQuery.trim().isEmpty) {
      return 0;
    }
    final row = db.select(
      'SELECT COUNT(*) AS c FROM commentaries_fts f '
      'JOIN commentaries c ON c.id = f.rowid '
      'WHERE commentaries_fts MATCH ?',
      <Object?>[ftsQuery],
    );
    return (row.first['c'] as int?) ?? 0;
  }

  /// Companion search: hadiths whose LAST narrator candidate (the
  /// parser's `last_narrator_norm` — usually the Companion) contains
  /// every term of [terms]. Parser-derived, not a verified identity.
  /// One page, in book/number order.
  List<Hadith> companionSearch(
    List<String> terms, {
    String? bookId,
    String? grade,
    int? chapterId,
    int limit = 20,
    int offset = 0,
  }) {
    final db = _db;
    if (db == null || !hasSearchSpans || terms.isEmpty) {
      return const <Hadith>[];
    }
    final conditions = <String>[
      for (final _ in terms) 's.last_narrator_norm LIKE ?',
    ];
    final args = <Object?>[
      for (final t in terms) '%$t%',
    ];
    if (bookId != null) {
      conditions.add('h.book = ?');
      args.add(bookId);
    }
    if (chapterId != null) {
      conditions.add('h.chapter_id = ?');
      args.add(chapterId);
    }
    final g = _gradeFilter(grade);
    if (g.sql.isNotEmpty) {
      conditions.add(g.sql);
      args.addAll(g.args);
    }
    final rows = db.select(
      'SELECT h.id, h.book, h.num, h.chapter_id, '
      'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src '
      'FROM hadiths h JOIN hadith_spans s ON s.hadith_id = h.id '
      'LEFT JOIN chapters c ON c.id = h.chapter_id '
      'WHERE ${conditions.join(' AND ')} '
      'ORDER BY h.book, h.num LIMIT ? OFFSET ?',
      <Object?>[...args, limit, offset],
    );
    return rows.map(_hadithFromRow).toList();
  }

  /// Exact COUNT for [companionSearch].
  int countCompanion(
    List<String> terms, {
    String? bookId,
    String? grade,
    int? chapterId,
  }) {
    final db = _db;
    if (db == null || !hasSearchSpans || terms.isEmpty) return 0;
    final conditions = <String>[
      for (final _ in terms) 's.last_narrator_norm LIKE ?',
    ];
    final args = <Object?>[
      for (final t in terms) '%$t%',
    ];
    if (bookId != null) {
      conditions.add('h.book = ?');
      args.add(bookId);
    }
    if (chapterId != null) {
      conditions.add('h.chapter_id = ?');
      args.add(chapterId);
    }
    final g = _gradeFilter(grade);
    if (g.sql.isNotEmpty) {
      conditions.add(g.sql);
      args.addAll(g.args);
    }
    final row = db.select(
      'SELECT COUNT(*) AS c FROM hadiths h '
      'JOIN hadith_spans s ON s.hadith_id = h.id '
      'WHERE ${conditions.join(' AND ')}',
      args,
    );
    return (row.first['c'] as int?) ?? 0;
  }

  /// The narrators table to read: the attached derived database
  /// (`narrators_db.narrators`, Phase 5 core) when installed, else the
  /// local (empty) `narrators` table. Callers get honest empty results
  /// when the derived DB is absent — never an exception, never fake rows.
  String get _narratorsTable =>
      narratorsAvailable ? 'narrators_db.narrators' : 'narrators';

  /// Narrators matching [query] (normalised). Reads the Phase 5 core
  /// (`narrators_db.narrators`) when installed, else the local (empty)
  /// table — an empty result then means "no verified narrators
  /// installed", never a missing feature.
  ///
  /// Matches the name (via the `norm` column), the kunya and the laqab,
  /// and a part of the name: the query is normalised with [normalizeArabic]
  /// and matched with LIKE, so `زهر` finds `الزهري`. Optional [tier] and
  /// [status] restrict to one generation / one jarh-wa-ta'dil verdict;
  /// pass null to leave that dimension open.
  List<Narrator> searchNarrators(
    String query, {
    String? tier,
    String? status,
  }) {
    final db = _db;
    if (db == null) return const <Narrator>[];
    final norm = normalizeArabic(query);
    if (norm.isEmpty) return const <Narrator>[];
    final conditions = <String>[
      '(norm LIKE ? OR kunya LIKE ? OR name LIKE ?)',
    ];
    final args = <Object?>['%$norm%', '%$query%', '%$query%'];
    if (tier != null && tier.isNotEmpty) {
      conditions.add('tier = ?');
      args.add(tier);
    }
    if (status != null && status.isNotEmpty) {
      conditions.add('status = ?');
      args.add(status);
    }
    final rows = db.select(
      'SELECT id, name, kunya, tier, death_hijri, status, status_src, '
      'bio_src FROM $_narratorsTable WHERE ${conditions.join(' AND ')} '
      'ORDER BY name LIMIT 50',
      args,
    );
    return rows.map(_narratorFromRow).toList();
  }

  /// All narrators, optionally restricted by [tier] / [status], in name
  /// order. Used by the encyclopedia's browse list (no query typed yet).
  List<Narrator> listNarrators({
    String? tier,
    String? status,
    int limit = 100,
  }) {
    final db = _db;
    if (db == null) return const <Narrator>[];
    final conditions = <String>[];
    final args = <Object?>[];
    if (tier != null && tier.isNotEmpty) {
      conditions.add('tier = ?');
      args.add(tier);
    }
    if (status != null && status.isNotEmpty) {
      conditions.add('status = ?');
      args.add(status);
    }
    final where =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')} ';
    final rows = db.select(
      'SELECT id, name, kunya, tier, death_hijri, status, status_src, '
      'bio_src FROM $_narratorsTable $where'
      'ORDER BY name LIMIT ?',
      <Object?>[...args, limit],
    );
    return rows.map(_narratorFromRow).toList();
  }

  /// Distinct generations (طبقات) actually recorded in the narrators
  /// table — the encyclopedia's tier filter offers only these, never a
  /// fixed list that the data does not contain.
  List<String> narratorTiers() {
    final db = _db;
    if (db == null) return const <String>[];
    final rows = db.select(
      "SELECT DISTINCT tier FROM $_narratorsTable WHERE tier != '' "
      'ORDER BY tier',
    );
    return rows.map((r) => (r['tier'] as String?) ?? '').toList();
  }

  /// Distinct jarh-wa-ta'dil verdicts actually recorded — the filter
  /// offers only these, so it can never promise a verdict with no rows.
  List<String> narratorStatuses() {
    final db = _db;
    if (db == null) return const <String>[];
    final rows = db.select(
      "SELECT DISTINCT status FROM $_narratorsTable WHERE status != '' "
      'ORDER BY status',
    );
    return rows.map((r) => (r['status'] as String?) ?? '').toList();
  }

  /// Installed narrator rows: the Phase 5 core count (500) when
  /// `narrators.db` is attached, else 0 — the encyclopedia then says
  /// honestly that no verified narrators are installed.
  int narratorCount() {
    final db = _db;
    if (db == null) return 0;
    final row = db.select('SELECT COUNT(*) AS c FROM $_narratorsTable');
    return (row.first['c'] as int?) ?? 0;
  }

  /// Installed chain rows in the v2 `chains` table (0 — the Phase-5
  /// import stores chains in `hadith_narrators` instead; see
  /// [chainForHadith]).
  int chainCount() {
    final db = _db;
    if (db == null) return 0;
    final row = db.select('SELECT COUNT(*) AS c FROM chains');
    return (row.first['c'] as int?) ?? 0;
  }

  /// One narrator by id, or null. Teachers/students ids are filled from
  /// verified `hadith_narrators` adjacency (see [_adjacentNarrators]);
  /// sayings are loaded separately via [narratorSayings].
  Narrator? narratorById(int id) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
      'SELECT id, name, kunya, tier, death_hijri, status, status_src, '
      'bio_src FROM $_narratorsTable WHERE id = ? LIMIT 1',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    final base = _narratorFromRow(rows.first);
    return Narrator(
      id: base.id,
      name: base.name,
      kunya: base.kunya,
      tier: base.tier,
      deathYearHijri: base.deathYearHijri,
      status: base.status,
      statusSource: base.statusSource,
      biographySource: base.biographySource,
      laqab: base.laqab,
      lineage: base.lineage,
      country: base.country,
      birthYearHijri: base.birthYearHijri,
      teachersIds:
          teachersOfNarrator(id).map((n) => n.id).toList(),
      studentsIds:
          studentsOfNarrator(id).map((n) => n.id).toList(),
    );
  }

  /// Verified narrators of one hadith, in chain order. Only links with a
  /// narrator row are returned — these are exactly the names the reader
  /// may tap. An empty list means no verified chain is recorded for the
  /// hadith, and the reader shows the text untapped.
  List<Narrator> narratorsForHadith(int hadithId) {
    return chainForHadith(hadithId)
        .where((l) => l.narrator != null)
        .map((l) => l.narrator!)
        .toList();
  }

  /// The full chain of one hadith, in position order, including
  /// unconfirmed links (rows with no narrator attached). Reads the v3
  /// `hadith_narrators` table (Phase 5 import, 0-based positions) and
  /// attaches verified narrators from `narrators_db` — a narrator is
  /// attached only for rows with match_status 'linked_verified'.
  /// Only the PRIMARY chain (`isnad_chains.is_primary = 1`): a hadith
  /// may have secondary chains, and interleaving them would repeat
  /// positions with different narrators. Falls back to the v2 `chains`
  /// table on a pre-v3 database. Without the attached narrators DB every
  /// link stays unconfirmed (honest, never guessed).
  List<ChainLink> chainForHadith(int hadithId) {
    final db = _db;
    if (db == null) return const <ChainLink>[];
    final List<Row> rows;
    if (_tableExists('hadith_narrators')) {
      final hasChains =
          _tableExists('isnad_nodes') && _tableExists('isnad_chains');
      final chainFilter = hasChains
          ? 'JOIN isnad_nodes nd ON nd.id = hn.id '
              'JOIN isnad_chains c ON c.id = nd.chain_id '
              'AND c.is_primary = 1 '
          : '';
      final narratorJoin = narratorsAvailable
          ? 'LEFT JOIN narrators_db.narrators n '
              'ON n.id = hn.narrator_id '
              "AND hn.match_status = 'linked_verified' "
          : '';
      final narratorCols = narratorsAvailable
          ? 'n.id AS nid, n.name, n.kunya, n.tier, n.death_hijri, '
              'n.status, n.status_src, n.bio_src'
          : 'NULL AS nid, NULL AS name, NULL AS kunya, NULL AS tier, '
              'NULL AS death_hijri, NULL AS status, NULL AS status_src, '
              'NULL AS bio_src';
      rows = db.select(
        'SELECT hn.position, hn.narrator_id, hn.link_type, hn.source, '
        'hn.notes, hn.narrator_text, hn.start_char, hn.end_char, '
        'hn.match_status, $narratorCols FROM hadith_narrators hn '
        '$chainFilter$narratorJoin'
        'WHERE hn.hadith_id = ? ORDER BY hn.position',
        <Object?>[hadithId],
      );
    } else {
      rows = db.select(
        'SELECT c.position, c.narrator_id, c.link_type, c.source, c.notes, '
        'n.id AS nid, n.name, n.kunya, n.tier, n.death_hijri, n.status, '
        'n.status_src, n.bio_src FROM chains c '
        'LEFT JOIN narrators n ON n.id = c.narrator_id '
        'WHERE c.hadith_id = ? ORDER BY c.position',
        <Object?>[hadithId],
      );
    }
    return rows.map((r) {
      Narrator? narrator;
      if (r['nid'] != null) {
        narrator = _narratorFromRow(<String, Object?>{
          'id': r['nid'],
          'name': r['name'],
          'kunya': r['kunya'],
          'tier': r['tier'],
          'death_hijri': r['death_hijri'],
          'status': r['status'],
          'status_src': r['status_src'],
          'bio_src': r['bio_src'],
        });
      }
      return ChainLink.fromRow(
        <String, Object?>{
          'position': r['position'],
          'narrator_id': r['narrator_id'],
          'link_type': r['link_type'],
          'source': r['source'],
          'notes': r['notes'],
          // Parser row fields selected above (integrator fix 2026-11-26:
          // the SELECT already carried them, but this map dropped them,
          // so hasOffsets was always false at runtime).
          'narrator_text': r['narrator_text'],
          'start_char': r['start_char'],
          'end_char': r['end_char'],
          'match_status': r['match_status'],
        },
        narrator: narrator,
      );
    }).toList();
  }

  /// Hadiths one narrator is recorded in, most recent book order first.
  /// Only VERIFIED links count: `hadith_narrators` rows with
  /// match_status 'linked_verified' (Phase 5 core). Falls back to the v2
  /// `chains` table on a pre-v3 database.
  List<Hadith> hadithsForNarrator(int narratorId, {int limit = 50}) {
    final db = _db;
    if (db == null) return const <Hadith>[];
    final linkTable =
        _tableExists('hadith_narrators') ? 'hadith_narrators' : 'chains';
    final verified = _tableExists('hadith_narrators')
        ? "AND ch.match_status = 'linked_verified' "
        : '';
    final rows = db.select(
      'SELECT DISTINCT h.id, h.book, h.num, h.chapter_id, '
      'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src '
      'FROM $linkTable ch JOIN hadiths h ON h.id = ch.hadith_id '
      'LEFT JOIN chapters c ON c.id = h.chapter_id '
      'WHERE ch.narrator_id = ? $verified'
      'ORDER BY h.book, h.num LIMIT ?',
      <Object?>[narratorId, limit],
    );
    return rows.map(_hadithFromRow).toList();
  }

  /// How many hadiths one narrator is recorded in (verified links only,
  /// see [hadithsForNarrator]).
  int countHadithsForNarrator(int narratorId) {
    final db = _db;
    if (db == null) return 0;
    final linkTable =
        _tableExists('hadith_narrators') ? 'hadith_narrators' : 'chains';
    final verified = _tableExists('hadith_narrators')
        ? "AND match_status = 'linked_verified' "
        : '';
    final row = db.select(
      'SELECT COUNT(DISTINCT hadith_id) AS c FROM $linkTable '
      'WHERE narrator_id = ? $verified',
      <Object?>[narratorId],
    );
    return (row.first['c'] as int?) ?? 0;
  }

  /// Teachers (شيوخ) of one narrator, derived from verified chains:
  /// narrators at the next position IN THE SAME CHAIN where this
  /// narrator appears (Phase 5 core: `isnad_nodes`, both links
  /// 'linked_verified'). This relies on the documented position
  /// convention (position 0 closest to the compiler, increasing towards
  /// the Prophet ﷺ) — the Phase-5 import follows it.
  List<Narrator> teachersOfNarrator(int narratorId) {
    return _adjacentNarrators(narratorId, 1);
  }

  /// Students (تلاميذ) of one narrator, derived from verified chains:
  /// narrators at the previous position in the same chain where this
  /// narrator appears.
  List<Narrator> studentsOfNarrator(int narratorId) {
    return _adjacentNarrators(narratorId, -1);
  }

  List<Narrator> _adjacentNarrators(int narratorId, int delta) {
    final db = _db;
    if (db == null) return const <Narrator>[];
    if (_tableExists('isnad_nodes') && _tableExists('isnad_chains')) {
      // Phase 5 core: adjacency WITHIN one chain (same chain_id) between
      // two verified links. Cross-chain adjacency would be false — two
      // chains of one hadith are different transmissions.
      if (!narratorsAvailable) return const <Narrator>[];
      final rows = db.select(
        'SELECT DISTINCT n.id, n.name, n.kunya, n.tier, n.death_hijri, '
        'n.status, n.status_src, n.bio_src FROM isnad_nodes n1 '
        'JOIN isnad_nodes n2 ON n2.chain_id = n1.chain_id '
        'AND n2.position = n1.position + ? '
        'JOIN narrators_db.narrators n ON n.id = n2.narrator_id '
        'WHERE n1.narrator_id = ? '
        "AND n1.match_status = 'linked_verified' "
        "AND n2.match_status = 'linked_verified' ORDER BY n.name",
        <Object?>[delta, narratorId],
      );
      return rows.map(_narratorFromRow).toList();
    }
    final rows = db.select(
      'SELECT DISTINCT n.id, n.name, n.kunya, n.tier, n.death_hijri, '
      'n.status, n.status_src, n.bio_src FROM chains c1 '
      'JOIN chains c2 ON c2.hadith_id = c1.hadith_id '
      'AND c2.position = c1.position + ? '
      'JOIN narrators n ON n.id = c2.narrator_id '
      'WHERE c1.narrator_id = ? ORDER BY n.name',
      <Object?>[delta, narratorId],
    );
    return rows.map(_narratorFromRow).toList();
  }

  /// Critics' sayings about one narrator, each with its source.
  ///
  /// Phase 5 core: one row per narrator from
  /// `narrators_db.narrator_grades` — the grade wording verbatim
  /// (`grade_raw`) with its speaker (`scholars.name_ar`) and the exact
  /// source reference. The speaker is Ibn Hajar for every narrator
  /// except Sulayman b. al-Mughira (#2612), whose grade is quoted from
  /// Yahya b. Ma'in and is shown as his, not Ibn Hajar's. Empty when
  /// the narrators DB is not installed; the UI then says so honestly.
  List<NarratorSaying> narratorSayings(int narratorId) {
    final db = _db;
    if (db == null) return const <NarratorSaying>[];
    if (narratorsAvailable) {
      final rows = db.select(
        'SELECT s.name_ar AS scholar, g.grade_raw AS saying, '
        "g.source || ' — ' || g.source_ref AS source "
        'FROM narrators_db.narrator_grades g '
        'JOIN narrators_db.scholars s ON s.id = g.scholar_id '
        'WHERE g.narrator_id = ? ORDER BY s.name_ar',
        <Object?>[narratorId],
      );
      return rows
          .map((r) => NarratorSaying.fromRow(<String, Object?>{
                'scholar': r['scholar'],
                'saying': r['saying'],
                'source': r['source'],
              }))
          .toList();
    }
    if (!_tableExists('narrator_sayings')) {
      return const <NarratorSaying>[];
    }
    final rows = db.select(
      'SELECT scholar, saying, source FROM narrator_sayings '
      'WHERE narrator_id = ? ORDER BY scholar',
      <Object?>[narratorId],
    );
    return rows
        .map((r) => NarratorSaying.fromRow(<String, Object?>{
              'scholar': r['scholar'],
              'saying': r['saying'],
              'source': r['source'],
            }))
        .toList();
  }

  /// Recorded routes (طرق) of one hadith, with the variant hadith row
  /// when it is installed. Empty until the Phase-5 import.
  List<HadithVariant> variantsForHadith(int hadithId) {
    final db = _db;
    if (db == null) return const <HadithVariant>[];
    final rows = db.select(
      'SELECT v.variant_hadith_id, v.variant_type, v.diff_note, v.source, '
      'h.id AS hid, h.book, h.num, h.chapter_id, '
      'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src '
      'FROM hadith_variants v '
      'LEFT JOIN hadiths h ON h.id = v.variant_hadith_id '
      'LEFT JOIN chapters c ON c.id = h.chapter_id '
      'WHERE v.hadith_id = ? ORDER BY v.id',
      <Object?>[hadithId],
    );
    return rows.map((r) {
      Hadith? variant;
      if (r['hid'] != null) {
        variant = Hadith.fromRow(<String, Object?>{
          'id': r['hid'],
          'book': r['book'],
          'num': r['num'],
          'chapter_id': r['chapter_id'],
          'chapter_title': r['chapter_title'],
          'text': r['text'],
          'grades': r['grades'],
          'expl': r['expl'],
          'expl_src': r['expl_src'],
        });
      }
      return HadithVariant.fromRow(
        <String, Object?>{
          'variant_hadith_id': r['variant_hadith_id'],
          'variant_type': r['variant_type'],
          'diff_note': r['diff_note'],
          'source': r['source'],
        },
        variant: variant,
      );
    }).toList();
  }

  /// Takhrij records of one hadith: other books reporting it, with the
  /// grade recorded for each occurrence. Empty until the Phase-5 import.
  List<TakhrijEntry> takhrijForHadith(int hadithId) {
    final db = _db;
    if (db == null) return const <TakhrijEntry>[];
    final rows = db.select(
      'SELECT source_book, source_ref, grade, notes, source FROM takhrij '
      'WHERE hadith_id = ? ORDER BY id',
      <Object?>[hadithId],
    );
    return rows
        .map((r) => TakhrijEntry.fromRow(<String, Object?>{
              'source_book': r['source_book'],
              'source_ref': r['source_ref'],
              'grade': r['grade'],
              'notes': r['notes'],
              'source': r['source'],
            }))
        .toList();
  }

  bool _tableExists(String name) {
    final db = _db;
    if (db == null) return false;
    final rows = db.select(
      'SELECT COUNT(*) AS c FROM sqlite_master '
      "WHERE type = 'table' AND name = ?",
      <Object?>[name],
    );
    return ((rows.first['c'] as int?) ?? 0) > 0;
  }

  /// One hadith's recorded graders' opinions, from `hadith_grades`
  /// (Phase 6). Every opinion is returned verbatim with its kind and
  /// source — conflicting opinions are ALL shown, never collapsed into
  /// one verdict. Empty for Bukhari/Muslim (collection-level) and
  /// Ahmad/Darimi (no grade in the source); the explanation template
  /// states that explicitly instead of inventing a grade.
  List<HadithGradeDetail> gradeRecordsForHadith(int hadithId) {
    final db = _db;
    if (db == null) return const <HadithGradeDetail>[];
    final rows = db.select(
      'SELECT grader, grade_ar, grade_kind, source FROM hadith_grades '
      'WHERE hadith_id = ? ORDER BY grader',
      <Object?>[hadithId],
    );
    return rows
        .map((r) => HadithGradeDetail.fromRow(<String, Object?>{
              'grader': r['grader'],
              'grade_ar': r['grade_ar'],
              'grade_kind': r['grade_kind'],
              'source': r['source'],
            }))
        .toList();
  }

  /// Hadiths carrying a grade whose Arabic text contains [gradeWord]
  /// (e.g. `صحيح`), most recent book order first. Used by grade /
  /// terminology questions to show REAL graded examples — never a
  /// definition, since no glossary rows exist.
  List<Hadith> hadithsWithGrade(String gradeWord, {int limit = 6}) {
    final db = _db;
    if (db == null || gradeWord.isEmpty) return const <Hadith>[];
    final rows = db.select(
      'SELECT DISTINCT h.id, h.book, h.num, h.chapter_id, '
      'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src '
      'FROM hadith_grades g JOIN hadiths h ON h.id = g.hadith_id '
      'LEFT JOIN chapters c ON c.id = h.chapter_id '
      'WHERE g.grade_ar LIKE ? ORDER BY h.book, h.num LIMIT ?',
      <Object?>['%$gradeWord%', limit],
    );
    return rows.map(_hadithFromRow).toList();
  }

  /// All HadeethEnc commentary entries (3,574 rows). The caller filters
  /// them in Dart by normalised text: the table has no FTS index, and
  /// the rows must NEVER be auto-linked to Nine-Books hadiths — each
  /// entry is shown only as its own standalone passage with its own
  /// HadeethEnc key and attribution.
  List<Commentary> allCommentaries() {
    final db = _db;
    if (db == null) return const <Commentary>[];
    final rows = db.select(
      'SELECT id, hadith_key, title, explanation, grade_ar, grader, '
      'attribution_text, source FROM commentaries',
    );
    return rows
        .map((r) => Commentary.fromRow(<String, Object?>{
              'id': r['id'],
              'hadith_key': r['hadith_key'],
              'title': r['title'],
              'explanation': r['explanation'],
              'grade_ar': r['grade_ar'],
              'grader': r['grader'],
              'attribution_text': r['attribution_text'],
              'source': r['source'],
            }))
        .toList();
  }

  /// Installed HadeethEnc commentary rows (3,574 in the shipped DB).
  int commentaryCount() {
    final db = _db;
    if (db == null) return 0;
    final row = db.select('SELECT COUNT(*) AS c FROM commentaries');
    return (row.first['c'] as int?) ?? 0;
  }

  // NOTE (Phase 4, 2026-11-26): parameter widened Row -> Map. The
  // chainForHadith call site (Phase 5) passes a hand-built Map, and
  // `Row` already implements Map<String, dynamic>, so all call sites
  // keep working. This fixes a pre-existing compile error that blocked
  // `flutter analyze`/`flutter test` for the whole project.
  Narrator _narratorFromRow(Map<String, Object?> row) {
    return Narrator.fromRow(<String, Object?>{
      'id': row['id'],
      'name': row['name'],
      'kunya': row['kunya'],
      'tier': row['tier'],
      'death_hijri': row['death_hijri'],
      'status': row['status'],
      'status_src': row['status_src'],
      'bio_src': row['bio_src'],
    });
  }

  Hadith _hadithFromRow(Row row) {
    return Hadith.fromRow(<String, Object?>{
      'id': row['id'],
      'book': row['book'],
      'num': row['num'],
      'chapter_id': row['chapter_id'],
      'chapter_title': row['chapter_title'],
      'text': row['text'],
      'grades': row['grades'],
      'expl': row['expl'],
      'expl_src': row['expl_src'],
    });
  }

  // ---- Pagination & streaming (Phase 7, master prompt §12) ----
  //
  // Large lists are NEVER loaded whole into memory: every list query
  // takes LIMIT/OFFSET, and [streamHadithsForChapter] yields one page
  // at a time so a chapter with thousands of hadiths is read in
  // bounded-memory chunks.

  /// One page of hadiths of a chapter (number order).
  List<Hadith> hadithsForChapterPaged(
    int chapterId, {
    int offset = 0,
    int limit = 50,
  }) {
    final db = _db;
    if (db == null) return const <Hadith>[];
    final rows = db.select(
      'SELECT h.id, h.book, h.num, h.chapter_id, '
      'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src '
      'FROM hadiths h LEFT JOIN chapters c ON c.id = h.chapter_id '
      'WHERE h.chapter_id = ? ORDER BY h.num LIMIT ? OFFSET ?',
      <Object?>[chapterId, limit, offset],
    );
    return rows.map(_hadithFromRow).toList();
  }

  /// Hadiths of one chapter as a stream of pages: yields [pageSize]
  /// rows at a time and stops at the end of the chapter. Memory use
  /// stays bounded by one page, however large the chapter is.
  Stream<List<Hadith>> streamHadithsForChapter(
    int chapterId, {
    int pageSize = 100,
  }) async* {
    var offset = 0;
    while (true) {
      final page = hadithsForChapterPaged(
        chapterId,
        offset: offset,
        limit: pageSize,
      );
      if (page.isEmpty) break;
      yield page;
      if (page.length < pageSize) break;
      offset += page.length;
    }
  }

  /// One page of FTS5 search results.
  List<Hadith> searchFtsPaged(
    String ftsQuery, {
    int offset = 0,
    int limit = 50,
  }) {
    final db = _db;
    if (db == null || ftsQuery.trim().isEmpty) return const <Hadith>[];
    final rows = db.select(
      'SELECT h.id, h.book, h.num, h.chapter_id, '
      'c.title AS chapter_title, h.text, h.grades, h.expl, h.expl_src '
      'FROM hadiths_fts f JOIN hadiths h ON h.id = f.rowid '
      'LEFT JOIN chapters c ON c.id = h.chapter_id '
      'WHERE hadiths_fts MATCH ? ORDER BY rank LIMIT ? OFFSET ?',
      <Object?>[ftsQuery, limit, offset],
    );
    return rows.map(_hadithFromRow).toList();
  }

  /// One page of narrators (browse list), in name order.
  List<Narrator> listNarratorsPaged({
    String? tier,
    String? status,
    int offset = 0,
    int limit = 50,
  }) {
    final db = _db;
    if (db == null) return const <Narrator>[];
    final conditions = <String>[];
    final args = <Object?>[];
    if (tier != null && tier.isNotEmpty) {
      conditions.add('tier = ?');
      args.add(tier);
    }
    if (status != null && status.isNotEmpty) {
      conditions.add('status = ?');
      args.add(status);
    }
    final where =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')} ';
    final rows = db.select(
      'SELECT id, name, kunya, tier, death_hijri, status, status_src, '
      'bio_src FROM $_narratorsTable $where'
      'ORDER BY name LIMIT ? OFFSET ?',
      <Object?>[...args, limit, offset],
    );
    return rows.map(_narratorFromRow).toList();
  }

  /// Hadith count of one book (used by pagination controls).
  int countHadithsForBook(String bookId) {
    final db = _db;
    if (db == null) return 0;
    final row = db.select(
      'SELECT COUNT(*) AS c FROM hadiths WHERE book = ?',
      <Object?>[bookId],
    );
    return (row.first['c'] as int?) ?? 0;
  }

  // ---- Downloaded libraries registry (Phase 7, schema v4) ----

  /// All known package rows, installed first, then by name.
  List<DownloadedLibrary> downloadedLibraries() {
    final db = _db;
    if (db == null) return const <DownloadedLibrary>[];
    final rows = db.select(
      'SELECT * FROM downloaded_libraries '
      "ORDER BY CASE status WHEN 'installed' THEN 0 ELSE 1 END, name",
    );
    return rows
        .map(
          (r) => DownloadedLibrary.fromRow(
            <String, Object?>{for (final c in r.keys) c: r[c]},
          ),
        )
        .toList();
  }

  /// One package row by library id, or null.
  DownloadedLibrary? downloadedLibraryById(String libraryId) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
      'SELECT * FROM downloaded_libraries WHERE library_id = ? LIMIT 1',
      <Object?>[libraryId],
    );
    if (rows.isEmpty) return null;
    return DownloadedLibrary.fromRow(
      <String, Object?>{for (final c in rows.first.keys) c: rows.first[c]},
    );
  }

  /// Insert or update a package row (matched by library_id). The row is
  /// only ever written with a real manifest behind it — see the
  /// downloads screen and `DownloadManager`.
  void upsertDownloadedLibrary(DownloadedLibrary row) {
    final db = _db;
    if (db == null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    final existing = downloadedLibraryById(row.libraryId);
    if (existing == null) {
      db.execute(
        'INSERT INTO downloaded_libraries (library_id, name, version, '
        'size_bytes, sha256, status, installed_at, source, license, '
        'download_url, total_bytes, downloaded_bytes, manifest_json, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          row.libraryId,
          row.name,
          row.version,
          row.sizeBytes,
          row.sha256,
          row.status,
          row.installedAt,
          row.source,
          row.license,
          row.downloadUrl,
          row.totalBytes,
          row.downloadedBytes,
          row.manifestJson,
          now,
        ],
      );
    } else {
      db.execute(
        'UPDATE downloaded_libraries SET name = ?, version = ?, '
        'size_bytes = ?, sha256 = ?, status = ?, installed_at = ?, '
        'source = ?, license = ?, download_url = ?, total_bytes = ?, '
        'downloaded_bytes = ?, manifest_json = ?, updated_at = ? '
        'WHERE library_id = ?',
        <Object?>[
          row.name,
          row.version,
          row.sizeBytes,
          row.sha256,
          row.status,
          row.installedAt,
          row.source,
          row.license,
          row.downloadUrl,
          row.totalBytes,
          row.downloadedBytes,
          row.manifestJson,
          now,
          row.libraryId,
        ],
      );
    }
  }

  /// Delete a package row (after its files were deleted).
  void deleteDownloadedLibrary(String libraryId) {
    final db = _db;
    if (db == null) return;
    db.execute(
      'DELETE FROM downloaded_libraries WHERE library_id = ?',
      <Object?>[libraryId],
    );
  }

  // ---- Admin staging + audit (Phase 8, schema v4) ----

  /// Insert a validated staged record. Returns the new row id.
  int stageInsert({
    required String kind,
    required String payloadJson,
    required String source,
    required String sha256,
    String validationErrorsJson = '[]',
  }) {
    final db = _db;
    if (db == null) return -1;
    final now = DateTime.now().toUtc().toIso8601String();
    db.execute(
      'INSERT INTO admin_staging (kind, payload_json, source, sha256, '
      'submitted_by, submitted_at, review_status, validation_errors) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        kind,
        payloadJson,
        source,
        sha256,
        'admin',
        now,
        ReviewStatus.pending,
        validationErrorsJson,
      ],
    );
    final row = db.select('SELECT last_insert_rowid() AS id');
    return (row.first['id'] as int?) ?? -1;
  }

  /// Staged records, newest first, with LIMIT/OFFSET paging.
  List<StagedRecord> stagingList({
    String? status,
    String? kind,
    int limit = 50,
    int offset = 0,
  }) {
    final db = _db;
    if (db == null) return const <StagedRecord>[];
    final conditions = <String>[];
    final args = <Object?>[];
    if (status != null && status.isNotEmpty) {
      conditions.add('review_status = ?');
      args.add(status);
    }
    if (kind != null && kind.isNotEmpty) {
      conditions.add('kind = ?');
      args.add(kind);
    }
    final where =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')} ';
    final rows = db.select(
      'SELECT * FROM admin_staging $where'
      'ORDER BY id DESC LIMIT ? OFFSET ?',
      <Object?>[...args, limit, offset],
    );
    return rows
        .map(
          (r) => StagedRecord.fromRow(
            <String, Object?>{for (final c in r.keys) c: r[c]},
          ),
        )
        .toList();
  }

  /// One staged record by id, or null.
  StagedRecord? stagingById(int id) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
      'SELECT * FROM admin_staging WHERE id = ? LIMIT 1',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return StagedRecord.fromRow(
      <String, Object?>{for (final c in rows.first.keys) c: rows.first[c]},
    );
  }

  /// Record a review decision on a staged record. Only the review
  /// columns change — the payload itself is never edited in place.
  void stagingReview({
    required int id,
    required String status,
    required String reviewedBy,
    required String reviewedAt,
    String note = '',
  }) {
    final db = _db;
    if (db == null) return;
    db.execute(
      'UPDATE admin_staging SET review_status = ?, reviewed_by = ?, '
      'reviewed_at = ?, review_note = ? WHERE id = ?',
      <Object?>[status, reviewedBy, reviewedAt, note, id],
    );
  }

  /// Append one audit row. The audit log is append-only from the app:
  /// no UPDATE/DELETE method exists for it.
  void auditInsert({
    required String action,
    String entityType = '',
    String entityId = '',
    String source = '',
    String detail = '',
    String actor = 'admin',
  }) {
    final db = _db;
    if (db == null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    db.execute(
      'INSERT INTO admin_audit_log (created_at, actor, action, '
      'entity_type, entity_id, source, detail) VALUES (?, ?, ?, ?, ?, ?, ?)',
      <Object?>[now, actor, action, entityType, entityId, source, detail],
    );
  }

  /// Audit rows, newest first, with LIMIT/OFFSET paging.
  List<AuditEntry> auditList({int limit = 50, int offset = 0}) {
    final db = _db;
    if (db == null) return const <AuditEntry>[];
    final rows = db.select(
      'SELECT * FROM admin_audit_log ORDER BY id DESC LIMIT ? OFFSET ?',
      <Object?>[limit, offset],
    );
    return rows
        .map(
          (r) => AuditEntry.fromRow(
            <String, Object?>{for (final c in r.keys) c: r[c]},
          ),
        )
        .toList();
  }

  /// Panel overview counts.
  Map<String, int> adminStats() {
    final db = _db;
    if (db == null) return const <String, int>{};
    int count(String sql) {
      final row = db.select(sql);
      return (row.first['c'] as int?) ?? 0;
    }

    return <String, int>{
      'staging_pending': count(
        'SELECT COUNT(*) AS c FROM admin_staging '
        "WHERE review_status = 'pending_review'",
      ),
      'staging_approved': count(
        'SELECT COUNT(*) AS c FROM admin_staging '
        "WHERE review_status = 'approved'",
      ),
      'staging_rejected': count(
        'SELECT COUNT(*) AS c FROM admin_staging '
        "WHERE review_status = 'rejected'",
      ),
      'audit_rows': count('SELECT COUNT(*) AS c FROM admin_audit_log'),
      'packages_installed': count(
        'SELECT COUNT(*) AS c FROM downloaded_libraries '
        "WHERE status = 'installed'",
      ),
      'narrators': count('SELECT COUNT(*) AS c FROM $_narratorsTable'),
      'hadiths': count('SELECT COUNT(*) AS c FROM hadiths'),
    };
  }

  /// One book definition by id, or null.
  Book? bookById(String id) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
      'SELECT b.id, b.name, b.short, b.author, b.sort, '
      'COUNT(h.id) AS cnt FROM books b '
      'LEFT JOIN hadiths h ON h.book = b.id '
      'WHERE b.id = ? GROUP BY b.id LIMIT 1',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return Book.fromRow(
      <String, Object?>{for (final c in rows.first.keys) c: rows.first[c]},
    );
  }

  /// Insert a book *definition* only: metadata row with cnt=0
  /// ("being imported"), no hadith content. Called only from the admin
  /// review path after a staged book definition is approved.
  void defineBook({
    required String id,
    required String name,
    required String shortName,
    required String author,
    String source = '',
    String license = '',
  }) {
    final db = _db;
    if (db == null) return;
    final sortRow = db.select('SELECT MAX(sort) AS m FROM books');
    final sort = ((sortRow.first['m'] as int?) ?? 9) + 1;
    db.execute(
      'INSERT INTO books (id, name, short, author, sort, cnt, source, '
      'license) VALUES (?, ?, ?, ?, ?, 0, ?, ?)',
      <Object?>[id, name, shortName, author, sort, source, license],
    );
  }

  /// Rebuild the FTS5 search index (admin action after a verified
  /// import). Runs inside SQLite; no rows are read into Dart memory.
  void rebuildSearchIndex() {
    final db = _db;
    if (db == null) return;
    db.execute("INSERT INTO hadiths_fts(hadiths_fts) VALUES('rebuild')");
  }

  void close() {
    _db?.dispose();
  }
}
