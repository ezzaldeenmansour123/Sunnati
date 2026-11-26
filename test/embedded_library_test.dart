/// Embedded-library integration tests (owner decision 2026-11-26 16:54).
///
/// Exercises the real first-run path — [SunnatiDatabase.open] with an
/// in-memory asset loader serving the synthetic bytes — plus the
/// migration and repair paths. Hermetic: temp directories only, no
/// network, no device, no real asset file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/data/database.dart';

import 'synthetic_db.dart';

void main() {
  group('embedded library — first run, migration, repair', () {
    late Directory supportDir;
    late Uint8List libraryBytes;
    late String libraryHash;

    setUp(() async {
      supportDir = await Directory.systemTemp.createTemp('sunnati_embed_');
      libraryBytes = await syntheticLibraryBytes();
      libraryHash = sha256.convert(libraryBytes).toString();
    });

    tearDown(() async {
      if (await supportDir.exists()) {
        await supportDir.delete(recursive: true);
      }
    });

    Future<SunnatiDatabase> openWithAsset({
      Uint8List? bytesOverride,
      void Function()? onLoad,
    }) {
      return SunnatiDatabase.open(
        supportDirOverride: supportDir,
        assetLoaderOverride: (_) async {
          onLoad?.call();
          return bytesOverride ?? libraryBytes;
        },
      );
    }

    test('fresh install: open() installs the embedded library and opens it',
        () async {
      final db = await openWithAsset();
      try {
        expect(db.isAvailable, isTrue);
        expect(db.libraryNeedsDownload, isFalse);
        expect(db.totalHadiths(), 1);
        final books = db.books();
        expect(books.length, 1);
        expect(books.first.name, 'صحيح البخاري');
        final installed = SunnatiDatabase.installedLibraryFile(supportDir);
        expect(await installed.exists(), isTrue);
        // The installed file is the asset's content, but NOT
        // byte-identical to it: opening the DB read-write bumps the
        // SQLite header's file-change counter (bytes 24–27), so only
        // the magic header + the content are asserted, never raw bytes.
        final installedBytes = await installed.readAsBytes();
        expect(
          installedBytes.sublist(0, 16),
          'SQLite format 3\x00'.codeUnits,
        );
        // The registry records the REAL hash of the asset install.
        final rows = db.downloadedLibraries();
        expect(rows.length, 1);
        expect(rows.first.libraryId, 'library');
        expect(rows.first.sha256, libraryHash);
      } finally {
        db.close();
      }
    });

    test('migration: a valid installed copy is reused — the library '
        'asset is never loaded', () async {
      final installed = await installSyntheticLibraryFile(supportDir);
      var libraryLoaded = false;
      var narratorsLoaded = false;
      final db = await SunnatiDatabase.open(
        supportDirOverride: supportDir,
        assetLoaderOverride: (path) async {
          if (path == kEmbeddedLibraryAssetPath) libraryLoaded = true;
          if (path == kEmbeddedNarratorsAssetPath) narratorsLoaded = true;
          return libraryBytes;
        },
      );
      try {
        expect(libraryLoaded, isFalse);
        expect(db.isAvailable, isTrue);
        expect(db.libraryNeedsDownload, isFalse);
        expect(db.totalHadiths(), 1);
        // The migrated copy is reused as-is (never re-installed from
        // the asset): its content is intact. Raw bytes are NOT
        // asserted — opening the DB read-write bumps the SQLite
        // header's file-change counter (see the fresh-install test).
        expect(await installed.exists(), isTrue);
        expect(
          (await installed.readAsBytes()).sublist(0, 16),
          'SQLite format 3\x00'.codeUnits,
        );
        // A migrated copy has no recorded hash — never invented.
        final rows = db.downloadedLibraries();
        expect(rows.length, 1);
        expect(rows.first.sha256, isEmpty);
        // The narrators asset IS requested on this path (a migrated
        // device still needs its narrators installed) — but this
        // loader serves LIBRARY bytes for it, which fail narrators
        // verification (0 narrator rows), so no narrators file is
        // created. The real narrators asset is covered by
        // test/embedded_narrators_test.dart.
        expect(narratorsLoaded, isTrue);
        expect(db.narratorsAvailable, isFalse);
        expect(
          await SunnatiDatabase.installedNarratorsFile(supportDir).exists(),
          isFalse,
        );
      } finally {
        db.close();
      }
    });

    test('corrupt installed copy (no valid header) is repaired from the '
        'asset', () async {
      final installed = SunnatiDatabase.installedLibraryFile(supportDir);
      await installed.writeAsBytes(utf8.encode('this is not a database'));
      final db = await openWithAsset();
      try {
        expect(db.isAvailable, isTrue);
        expect(db.libraryNeedsDownload, isFalse);
        expect(db.totalHadiths(), 1);
        // Repaired from the asset: valid SQLite with the asset's
        // content (raw bytes are NOT asserted — see the fresh-install
        // test: opening the DB read-write bumps the header counter).
        expect(
          (await installed.readAsBytes()).sublist(0, 16),
          'SQLite format 3\x00'.codeUnits,
        );
      } finally {
        db.close();
      }
    });

    test('header-valid but malformed copy is repaired from the asset',
        () async {
      final installed = SunnatiDatabase.installedLibraryFile(supportDir);
      final malformed = Uint8List(5016);
      const header = 'SQLite format 3\x00';
      for (var i = 0; i < header.length; i++) {
        malformed[i] = header.codeUnitAt(i);
      }
      await installed.writeAsBytes(malformed);
      final db = await openWithAsset();
      try {
        expect(db.isAvailable, isTrue);
        expect(db.libraryNeedsDownload, isFalse);
        expect(db.totalHadiths(), 1);
        expect(
          (await installed.readAsBytes()).sublist(0, 16),
          'SQLite format 3\x00'.codeUnits,
        );
      } finally {
        db.close();
      }
    });

    test('missing asset: open() falls back to the recovery download screen',
        () async {
      final db = await SunnatiDatabase.open(
        supportDirOverride: supportDir,
        assetLoaderOverride: (_) => throw StateError('asset missing'),
      );
      try {
        expect(db.isAvailable, isFalse);
        expect(db.libraryNeedsDownload, isTrue);
        expect(db.unavailableReason, isNotEmpty);
        expect(
          await SunnatiDatabase.installedLibraryFile(supportDir).exists(),
          isFalse,
        );
      } finally {
        db.close();
      }
    });

    test('corrupt asset: a failed verification installs nothing', () async {
      final db = await openWithAsset(
        bytesOverride: Uint8List.fromList(
          utf8.encode('not a database at all'),
        ),
      );
      try {
        expect(db.isAvailable, isFalse);
        expect(db.libraryNeedsDownload, isTrue);
        expect(
          await SunnatiDatabase.installedLibraryFile(supportDir).exists(),
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

    test('library bytes served for the narrators asset install nothing '
        '(0 narrator rows fail verification)', () async {
      // The shared loader serves the LIBRARY bytes for every asset
      // path, narrators included: those bytes are valid SQLite but
      // hold zero narrator rows, so the narrators verification refuses
      // them and no narrators file is created. The real narrators
      // asset path is covered by test/embedded_narrators_test.dart.
      final db = await openWithAsset();
      try {
        expect(db.isAvailable, isTrue);
        expect(db.narratorsAvailable, isFalse);
        expect(
          await SunnatiDatabase.installedNarratorsFile(supportDir).exists(),
          isFalse,
        );
      } finally {
        db.close();
      }
    });

    test('installEmbeddedLibrary returns the file + real SHA-256, and '
        'refuses garbage', () async {
      final installed = await SunnatiDatabase.installEmbeddedLibrary(
        supportDir,
        loadAsset: (_) async => libraryBytes,
      );
      expect(installed, isNotNull);
      expect(installed!.sha256, libraryHash);
      expect(await installed.file.exists(), isTrue);
      expect(
        await SunnatiDatabase.verifyLibraryFile(installed.file),
        isTrue,
      );
      final refused = await SunnatiDatabase.installEmbeddedLibrary(
        supportDir,
        loadAsset: (_) async =>
            Uint8List.fromList(utf8.encode('garbage')),
      );
      expect(refused, isNull);
    });
  });
}
