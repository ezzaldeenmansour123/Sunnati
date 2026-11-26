/// Embedded-narrators integration tests (owner override 2026-11-26 17:51).
///
/// Exercises the real first-run path — [SunnatiDatabase.open] with a
/// path-aware in-memory asset loader serving the synthetic library bytes
/// for `assets/sunnati.db` and the synthetic narrators bytes for
/// `assets/narrators.db` — plus the legacy-migration and repair paths.
/// Hermetic: temp directories only, no network, no device, no real
/// asset file. No download is ever created: the embedded install is
/// the only source, and the tests assert no `.part` file appears.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/data/database.dart';

import 'synthetic_db.dart';

void main() {
  group('embedded narrators — first run, migration, repair', () {
    late Directory supportDir;
    late Uint8List libraryBytes;
    late Uint8List narratorsBytes;
    late String narratorsHash;

    setUp(() async {
      supportDir = await Directory.systemTemp.createTemp('sunnati_embed_n_');
      libraryBytes = await syntheticLibraryBytes();
      narratorsBytes = await syntheticNarratorsBytes();
      narratorsHash = sha256.convert(narratorsBytes).toString();
    });

    tearDown(() async {
      if (await supportDir.exists()) {
        await supportDir.delete(recursive: true);
      }
    });

    /// Open with a path-aware loader: library bytes for the library
    /// asset, narrators bytes for the narrators asset. [narratorsLoads]
    /// counts how many times the narrators asset was requested.
    Future<SunnatiDatabase> openWithAssets({
      Uint8List? narratorsOverride,
      bool throwForNarrators = false,
      void Function()? onNarratorsLoad,
    }) {
      return SunnatiDatabase.open(
        supportDirOverride: supportDir,
        assetLoaderOverride: (path) async {
          if (path == kEmbeddedNarratorsAssetPath) {
            onNarratorsLoad?.call();
            if (throwForNarrators) {
              throw StateError('narrators asset missing');
            }
            return narratorsOverride ?? narratorsBytes;
          }
          return libraryBytes;
        },
      );
    }

    test('fresh install: open() installs the embedded narrators and '
        'opens them', () async {
      final db = await openWithAssets();
      try {
        expect(db.isAvailable, isTrue);
        expect(db.narratorsAvailable, isTrue);
        expect(db.narratorsUnavailableReason, isEmpty);
        expect(db.narratorCount(), 1);
        final installed =
            SunnatiDatabase.installedNarratorsFile(supportDir);
        expect(await installed.exists(), isTrue);
        expect(
          (await installed.readAsBytes()).sublist(0, 16),
          'SQLite format 3\x00'.codeUnits,
        );
        // The encyclopedia reads the embedded copy.
        final all = db.listNarrators();
        expect(all.length, 1);
        expect(all.first.name, 'سفيان بن عيينة');
        expect(all.first.status, 'ثقة');
        final found = db.searchNarrators('سفيان');
        expect(found.length, 1);
        expect(found.first.name, 'سفيان بن عيينة');
        // The registry records the REAL hash of the asset install,
        // with the embedded-asset source and the NC licence.
        final rows = db.downloadedLibraries();
        expect(rows.length, 2);
        final narratorsRow = rows.firstWhere(
          (r) => r.libraryId == 'narrators',
        );
        expect(narratorsRow.sha256, narratorsHash);
        expect(narratorsRow.source, 'embedded-asset');
        expect(narratorsRow.license, 'CC BY-NC-SA 4.0');
        expect(narratorsRow.status, 'installed');
        // No download was ever created: no partial files, no extra
        // files beyond the two installed databases.
        final names = await supportDir
            .list()
            .map((e) => e.path.split('/').last)
            .toList();
        expect(names, unorderedEquals(<String>['sunnati.db', 'narrators.db']));
      } finally {
        db.close();
      }
    });

    test('migration: a valid installed copy is reused — the narrators '
        'asset is never loaded', () async {
      final installed = SunnatiDatabase.installedNarratorsFile(supportDir);
      await installed.writeAsBytes(narratorsBytes);
      var loaded = false;
      final db = await openWithAssets(
        onNarratorsLoad: () => loaded = true,
      );
      try {
        expect(loaded, isFalse);
        expect(db.narratorsAvailable, isTrue);
        expect(db.narratorCount(), 1);
        expect(
          (await installed.readAsBytes()).sublist(0, 16),
          'SQLite format 3\x00'.codeUnits,
        );
      } finally {
        db.close();
      }
    });

    test('corrupt installed narrators copy is repaired from the asset',
        () async {
      final installed = SunnatiDatabase.installedNarratorsFile(supportDir);
      await installed.writeAsBytes(
        Uint8List.fromList('this is not a database'.codeUnits),
      );
      final db = await openWithAssets();
      try {
        expect(db.narratorsAvailable, isTrue);
        expect(db.narratorCount(), 1);
        expect(
          (await installed.readAsBytes()).sublist(0, 16),
          'SQLite format 3\x00'.codeUnits,
        );
      } finally {
        db.close();
      }
    });

    test('missing narrators asset: the library still opens, narrators '
        'report honestly unavailable', () async {
      final db = await openWithAssets(throwForNarrators: true);
      try {
        expect(db.isAvailable, isTrue);
        expect(db.libraryNeedsDownload, isFalse);
        expect(db.narratorsAvailable, isFalse);
        expect(db.narratorsUnavailableReason, isNotEmpty);
        expect(db.narratorCount(), 0);
        expect(db.listNarrators(), isEmpty);
        expect(
          await SunnatiDatabase.installedNarratorsFile(supportDir).exists(),
          isFalse,
        );
      } finally {
        db.close();
      }
    });

    test('corrupt narrators asset: a failed verification installs '
        'nothing, the library still opens', () async {
      final db = await openWithAssets(
        narratorsOverride: Uint8List.fromList(
          'not a database at all'.codeUnits,
        ),
      );
      try {
        expect(db.isAvailable, isTrue);
        expect(db.narratorsAvailable, isFalse);
        expect(db.narratorsUnavailableReason, isNotEmpty);
        expect(
          await SunnatiDatabase.installedNarratorsFile(supportDir).exists(),
          isFalse,
        );
        // No half-written temp file is left behind.
        final leftovers = await supportDir
            .list()
            .where((e) => e.path.endsWith('.embedded-tmp'))
            .toList();
        expect(leftovers, isEmpty);
      } finally {
        db.close();
      }
    });

    test('installEmbeddedNarrators returns the file + real SHA-256, and '
        'refuses garbage and library bytes', () async {
      final installed = await SunnatiDatabase.installEmbeddedNarrators(
        supportDir,
        loadAsset: (_) async => narratorsBytes,
      );
      expect(installed, isNotNull);
      expect(installed!.sha256, narratorsHash);
      expect(await installed.file.exists(), isTrue);
      expect(
        await SunnatiDatabase.verifyNarratorsFile(installed.file),
        isTrue,
      );
      final refusedGarbage =
          await SunnatiDatabase.installEmbeddedNarrators(
        supportDir,
        loadAsset: (_) async =>
            Uint8List.fromList('garbage'.codeUnits),
      );
      expect(refusedGarbage, isNull);
      // Library bytes are valid SQLite but hold zero narrator rows —
      // they must never install as the narrators database.
      final refusedLibrary =
          await SunnatiDatabase.installEmbeddedNarrators(
        supportDir,
        loadAsset: (_) async => libraryBytes,
      );
      expect(refusedLibrary, isNull);
    });

    test('verifyNarratorsFile accepts a real narrators file, rejects '
        'garbage', () async {
      final good = SunnatiDatabase.installedNarratorsFile(supportDir);
      await good.writeAsBytes(narratorsBytes);
      expect(await SunnatiDatabase.verifyNarratorsFile(good), isTrue);
      await good.writeAsBytes(
        Uint8List.fromList('garbage'.codeUnits),
      );
      expect(await SunnatiDatabase.verifyNarratorsFile(good), isFalse);
    });
  });
}
