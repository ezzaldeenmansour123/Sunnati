/// Synthetic test databases for SUNNATI widget/integration tests.
///
/// Builds minimal but VALID SQLite files with package:sqlite3. The
/// fixtures contain exactly one book (Bukhari), two chapters (one
/// English-titled, one Arabic), one hadith (Bukhari #1, verbatim text)
/// and two parser rows (one verified, one unlinked) — nothing invented,
/// nothing copied from the production library.
///
/// The same bytes feed the embedded-asset path ([SunnatiDatabase.open]
/// with an in-memory asset loader), so the embed tests exercise the
/// real install code without a real asset file.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sunnati/data/database.dart';
import 'package:sunnati/models/grade.dart';
import 'package:sunnati/models/hadith.dart';

/// Point package:sqlite3 at the system runtime library before its
/// first use in the test process.
///
/// The ubuntu runner (and this VM) ships only the versioned
/// `libsqlite3.so.0`; the unversioned `libsqlite3.so` exists only with
/// the `libsqlite3-dev` package installed. The `sqlite3` global loads
/// its library lazily on first access, so this override — registered
/// here, before any `sqlite3.open` in the process — makes the
/// DB-backed tests run on any Linux box without the -dev package. When
/// the versioned path does not exist (a machine with only the -dev
/// package), nothing is overridden and the default `libsqlite3.so`
/// lookup stands. The CI workflow also creates the unversioned
/// symlink; this is the belt-and-braces for local runs. Test-only: no
/// production code is affected.
void ensureSqliteLibrary() {
  const versioned = '/lib/x86_64-linux-gnu/libsqlite3.so.0';
  if (File(versioned).existsSync()) {
    open.overrideForAll(() => DynamicLibrary.open(versioned));
  }
}

/// Bukhari #1, verbatim source text. The same const seeds the fixture
/// DB and builds the [Hadith] in widget tests, so span offsets always
/// agree with the stored text.
const String kSyntheticHadithText =
    'حدثنا الحميدي عبد الله بن الزبير قال حدثنا سفيان قال حدثنا يحيى بن سعيد الأنصاري قال أخبرني محمد بن إبراهيم التيمي أنه سمع علقمة بن وقاص الليثي يقول سمعت عمر بن الخطاب رضي الله عنه على المنبر قال سمعت رسول الله صلى الله عليه وسلم يقول إنما الأعمال بالنيات وإنما لكل امرئ ما نوى فمن كانت هجرته إلى دنيا يصيبها أو إلى امرأة ينكحها فهجرته إلى ما هاجر إليه';

/// Offsets of the verified narrator name inside [kSyntheticHadithText].
int get kSyntheticVerifiedStart => kSyntheticHadithText.indexOf('سفيان');
int get kSyntheticVerifiedEnd => kSyntheticVerifiedStart + 'سفيان'.length;

/// Offsets of the unverified parser name inside [kSyntheticHadithText].
int get kSyntheticUnverifiedStart =>
    kSyntheticHadithText.indexOf('يحيى بن سعيد الأنصاري');
int get kSyntheticUnverifiedEnd =>
    kSyntheticUnverifiedStart + 'يحيى بن سعيد الأنصاري'.length;

/// The synthetic hadith as a [Hadith] object (chapter title is the
/// English verbatim title, as in the production import).
Hadith get syntheticHadith => const Hadith(
      id: 1,
      bookId: 'bukhari',
      num: 1,
      chapterId: 1,
      chapterTitle: 'Revelation',
      text: kSyntheticHadithText,
      grades: <HadithGrade>[],
      explanation: '',
      explanationSource: '',
    );

/// Schema of the synthetic library DB — the CREATE TABLE statements
/// copied from `tools/build_db.py`, restricted to the tables the code
/// under test reads. Tables the reader never touches on first paint
/// (FTS, isnad_nodes/chains, narrator_sayings) are deliberately
/// absent: their absence is itself covered (the code guards with
/// `_tableExists` or never queries them). `commentaries` MUST be
/// present (empty is fine): the reader's default شرح tab calls
/// `commentaryCount()` on build with NO `_tableExists` guard, so
/// without the table the reader crashes on first paint — added
/// 2026-11-26 for the smoothness tests, copied verbatim from
/// `tools/build_db.py`.
const String _kSyntheticLibrarySchema = '''
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS books (id TEXT PRIMARY KEY, name TEXT NOT NULL, short TEXT NOT NULL, author TEXT NOT NULL, sort INTEGER NOT NULL, cnt INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT '', license TEXT NOT NULL DEFAULT '', grade_policy TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS chapters (id INTEGER PRIMARY KEY, book TEXT NOT NULL REFERENCES books(id), num INTEGER NOT NULL, title TEXT NOT NULL, title_en TEXT NOT NULL DEFAULT '', title_lang TEXT NOT NULL DEFAULT '', title_source TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS hadiths (id INTEGER PRIMARY KEY, book TEXT NOT NULL REFERENCES books(id), num INTEGER NOT NULL, chapter_id INTEGER REFERENCES chapters(id), text TEXT NOT NULL, grades TEXT NOT NULL DEFAULT '[]', expl TEXT NOT NULL DEFAULT '', expl_src TEXT NOT NULL DEFAULT '', hadith_number TEXT NOT NULL, number_sort INTEGER NOT NULL, hadith_key TEXT NOT NULL UNIQUE, urn INTEGER NOT NULL UNIQUE, seq INTEGER NOT NULL, in_book_number INTEGER, book_number INTEGER, sunnah_url TEXT, has_encoding_issue INTEGER NOT NULL DEFAULT 0, is_muallaq INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS narrators (id INTEGER PRIMARY KEY, name TEXT NOT NULL, kunya TEXT NOT NULL DEFAULT '', tier TEXT NOT NULL DEFAULT '', death_hijri INTEGER, status TEXT NOT NULL DEFAULT '', status_src TEXT NOT NULL DEFAULT '', bio_src TEXT NOT NULL DEFAULT '', norm TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS chains (id INTEGER PRIMARY KEY, hadith_id INTEGER NOT NULL REFERENCES hadiths(id), position INTEGER NOT NULL, narrator_id INTEGER REFERENCES narrators(id), link_type TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS hadith_narrators (id INTEGER PRIMARY KEY, hadith_id INTEGER NOT NULL REFERENCES hadiths(id), narrator_id INTEGER REFERENCES narrators(id), position INTEGER NOT NULL, narrator_text TEXT NOT NULL DEFAULT '', narrator_norm TEXT NOT NULL DEFAULT '', start_char INTEGER, end_char INTEGER, link_type TEXT NOT NULL DEFAULT '', confidence TEXT NOT NULL DEFAULT '' CHECK (confidence IN ('', 'high', 'medium', 'low', 'needs_review')), match_status TEXT NOT NULL DEFAULT 'unlinked' CHECK (match_status IN ('unlinked', 'linked_verified', 'ambiguous', 'needs_review')), source TEXT NOT NULL DEFAULT '', reviewed_at TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS hadith_grades (id INTEGER PRIMARY KEY, hadith_id INTEGER NOT NULL REFERENCES hadiths(id), scholar_id INTEGER REFERENCES scholars(id), grader TEXT NOT NULL, grader_raw TEXT NOT NULL, grade_raw TEXT NOT NULL, grade_ar TEXT NOT NULL, grade_kind TEXT NOT NULL, source TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS takhrij (id INTEGER PRIMARY KEY, hadith_id INTEGER NOT NULL REFERENCES hadiths(id), source_book TEXT NOT NULL DEFAULT '', source_ref TEXT NOT NULL DEFAULT '', grade TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS hadith_variants (id INTEGER PRIMARY KEY, hadith_id INTEGER NOT NULL REFERENCES hadiths(id), variant_hadith_id INTEGER REFERENCES hadiths(id), variant_type TEXT NOT NULL DEFAULT '', diff_note TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS downloaded_libraries (id INTEGER PRIMARY KEY, library_id TEXT NOT NULL, name TEXT NOT NULL, version TEXT NOT NULL DEFAULT '', size_bytes INTEGER NOT NULL DEFAULT 0, sha256 TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT '', installed_at TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS commentaries (id INTEGER PRIMARY KEY, hadith_key TEXT NOT NULL UNIQUE, hadeethenc_id INTEGER NOT NULL UNIQUE, title TEXT NOT NULL DEFAULT '', intro TEXT NOT NULL DEFAULT '', text TEXT NOT NULL, explanation TEXT NOT NULL DEFAULT '', grade_raw TEXT NOT NULL DEFAULT '', grade_ar TEXT NOT NULL DEFAULT '', grade_kind TEXT NOT NULL DEFAULT '', grader TEXT NOT NULL DEFAULT '', grader_raw TEXT NOT NULL DEFAULT '', attribution_text TEXT NOT NULL DEFAULT '', grade_source TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', license TEXT NOT NULL DEFAULT '');
''';

/// Build the synthetic library DB bytes (valid SQLite, 1 hadith).
Future<Uint8List> syntheticLibraryBytes() async {
  ensureSqliteLibrary();
  final tmp = await Directory.systemTemp.createTemp('sunnati_synth_');
  try {
    final file = File('${tmp.path}/sunnati.db');
    final db = sqlite3.open(file.path);
    try {
      for (final stmt in _kSyntheticLibrarySchema.split(';')) {
        final trimmed = stmt.trim();
        if (trimmed.isNotEmpty) db.execute(trimmed);
      }
      db.execute("INSERT INTO meta VALUES ('version', '3')");
      db.execute(
        "INSERT INTO books VALUES ('bukhari', 'صحيح البخاري', 'البخاري', "
        "'محمد بن إسماعيل البخاري', 1, 0, '', '', '')",
      );
      db.execute(
        "INSERT INTO chapters VALUES (1, 'bukhari', 1, 'Revelation', '', '', '')",
      );
      db.execute(
        "INSERT INTO chapters VALUES (2, 'bukhari', 2, 'الإيمان', '', '', '')",
      );
      db.execute(
        'INSERT INTO hadiths (id, book, num, chapter_id, text, grades, '
        'expl, expl_src, hadith_number, number_sort, hadith_key, urn, '
        'seq, in_book_number, book_number, sunnah_url, '
        'has_encoding_issue, is_muallaq, source) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          1,
          'bukhari',
          1,
          1,
          kSyntheticHadithText,
          '[]',
          '',
          '',
          '1',
          1,
          'bukhari:1',
          1,
          1,
          null,
          null,
          null,
          0,
          0,
          '',
        ],
      );
      db.execute(
        'INSERT INTO hadith_narrators (id, hadith_id, narrator_id, '
        'position, narrator_text, narrator_norm, start_char, end_char, '
        'link_type, confidence, match_status, source, reviewed_at, notes) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          1,
          1,
          1,
          0,
          'سفيان',
          'سفيان',
          kSyntheticVerifiedStart,
          kSyntheticVerifiedEnd,
          '',
          'high',
          'linked_verified',
          '',
          '',
          '',
        ],
      );
      db.execute(
        'INSERT INTO hadith_narrators (id, hadith_id, narrator_id, '
        'position, narrator_text, narrator_norm, start_char, end_char, '
        'link_type, confidence, match_status, source, reviewed_at, notes) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          2,
          1,
          null,
          1,
          'يحيى بن سعيد الأنصاري',
          'يحيي بن سعيد الانصاري',
          kSyntheticUnverifiedStart,
          kSyntheticUnverifiedEnd,
          '',
          '',
          'unlinked',
          '',
          '',
          '',
        ],
      );
    } finally {
      db.dispose();
    }
    return await file.readAsBytes();
  } finally {
    await tmp.delete(recursive: true);
  }
}

/// Build the synthetic narrators DB bytes: one verified narrator
/// (سفيان بن عيينة — ثقة، تقريب التهذيب). Used as the legacy local copy
/// a device already holds; the app never distributes it.
Future<Uint8List> syntheticNarratorsBytes() async {
  ensureSqliteLibrary();
  final tmp = await Directory.systemTemp.createTemp('sunnati_synth_n_');
  try {
    final file = File('${tmp.path}/narrators.db');
    final db = sqlite3.open(file.path);
    try {
      // No DEFAULT '' clauses here: the fixture inserts every column
      // explicitly, and the defaults are irrelevant to the tests.
      // `scholars` + `narrator_grades` MUST be present (empty is
      // fine): the narrator detail screen calls `narratorSayings()`
      // on build with NO `_tableExists` guard when the package is
      // installed, so without them the detail page crashes — added
      // 2026-11-26 for the smoothness tests, copied verbatim from
      // `tools/build_db.py`.
      db.execute(
        'CREATE TABLE IF NOT EXISTS scholars (id INTEGER PRIMARY KEY, '
        'name_ar TEXT NOT NULL, name_en TEXT NOT NULL DEFAULT \'\', '
        'death_hijri INTEGER, bio_src TEXT NOT NULL DEFAULT \'\', '
        'notes TEXT NOT NULL DEFAULT \'\')',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS narrator_grades (id INTEGER PRIMARY KEY, '
        'narrator_id INTEGER NOT NULL REFERENCES narrators(id), '
        'scholar_id INTEGER REFERENCES scholars(id), '
        'grade_ar TEXT NOT NULL DEFAULT \'\', '
        'grade_raw TEXT NOT NULL DEFAULT \'\', '
        'grade_kind TEXT NOT NULL DEFAULT \'\', '
        'source TEXT NOT NULL DEFAULT \'\', '
        'source_ref TEXT NOT NULL DEFAULT \'\', '
        'reviewed_at TEXT NOT NULL DEFAULT \'\', '
        'confidence TEXT NOT NULL DEFAULT \'\' CHECK (confidence IN '
        '(\'\', \'high\', \'medium\', \'low\', \'needs_review\')), '
        'notes TEXT NOT NULL DEFAULT \'\')',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS narrators (id INTEGER PRIMARY KEY, '
        'name TEXT NOT NULL, kunya TEXT NOT NULL, '
        'tier TEXT NOT NULL, death_hijri INTEGER, '
        'status TEXT NOT NULL, status_src TEXT NOT NULL, '
        'bio_src TEXT NOT NULL, norm TEXT NOT NULL)',
      );
      db.execute(
        "INSERT INTO narrators VALUES (1, 'سفيان بن عيينة', 'أبو محمد', "
        "'الطبقة الثامنة', 198, 'ثقة', 'تقريب التهذيب', 'تهذيب التهذيب', "
        "'سفيان بن عيينه')",
      );
    } finally {
      db.dispose();
    }
    return await file.readAsBytes();
  } finally {
    await tmp.delete(recursive: true);
  }
}

/// Place the synthetic library as the already-installed file in
/// [supportDir] (migration case: a valid build-52/75/81 copy).
Future<File> installSyntheticLibraryFile(Directory supportDir) async {
  final file = SunnatiDatabase.installedLibraryFile(supportDir);
  await file.writeAsBytes(await syntheticLibraryBytes());
  return file;
}

/// Open a synthetic library in [supportDir] through the REAL first-run
/// path: the asset loader serves the synthetic bytes, [SunnatiDatabase
/// .open] installs them and opens the result. When [withNarrators] is
/// true, a synthetic narrators DB is also placed as the legacy local
/// copy, so `narratorsAvailable` is true and verified taps show a
/// status. [libraryBytesOverride] replaces the asset bytes (corrupt /
/// empty cases). The caller must close the returned database.
Future<SunnatiDatabase> openSyntheticDb(
  Directory supportDir, {
  bool withNarrators = false,
  Uint8List? libraryBytesOverride,
}) async {
  final bytes = libraryBytesOverride ?? await syntheticLibraryBytes();
  if (withNarrators) {
    final narrators = File('${supportDir.path}/$kNarratorsFileName');
    await narrators.writeAsBytes(await syntheticNarratorsBytes());
  }
  return SunnatiDatabase.open(
    supportDirOverride: supportDir,
    assetLoaderOverride: (_) async => bytes,
  );
}
