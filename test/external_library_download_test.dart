import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/core/package_manifest.dart';
import 'package:sunnati/data/database.dart';
import 'package:sunnati/data/download_manager.dart';
import 'package:sunnati/models/downloaded_library.dart';

/// External-download rebuild (2026-11-26) tests — hermetic only: no
/// network beyond a local loopback [HttpServer], no device, no assets.
/// The production download is HTTPS-only; the local server tests pass
/// `allowHttpForTests: true` explicitly (test-only flag, never set by
/// app code).
void main() {
  group('external package registry', () {
    test('defines exactly two packages', () {
      expect(kExternalPackages.length, 2);
      expect(
        kExternalPackages.map((p) => p.id).toList(),
        <String>['library', 'narrators'],
      );
    });

    test('library package: exact URL, required, available', () {
      expect(kLibraryPackage.id, 'library');
      expect(kLibraryPackage.fileName, 'sunnati.db');
      expect(
        kLibraryPackage.url,
        'https://github.com/ezzaldeenmansour123/Sunnati/releases/download/library-v1/sunnati.db',
      );
      expect(
        kLibraryPackage.sha256Url,
        'https://github.com/ezzaldeenmansour123/Sunnati/releases/download/library-v1/sunnati.db.sha256',
      );
      expect(kLibraryPackage.required, isTrue);
      expect(kLibraryPackage.available, isTrue);
      expect(kLibraryPackage.unavailableReason, isEmpty);
    });

    test('narrators package: held back, exact pending-approval reason',
        () {
      expect(kNarratorsPackageHeldBack, isTrue);
      expect(kNarratorsPackage.id, 'narrators');
      expect(kNarratorsPackage.fileName, 'narrators.db');
      expect(
        kNarratorsPackage.url,
        'https://github.com/ezzaldeenmansour123/Sunnati/releases/download/library-v1/narrators.db',
      );
      expect(
        kNarratorsPackage.sha256Url,
        'https://github.com/ezzaldeenmansour123/Sunnati/releases/download/library-v1/narrators.db.sha256',
      );
      expect(kNarratorsPackage.required, isFalse);
      expect(kNarratorsPackage.available, isFalse);
      expect(
        kNarratorsPackage.unavailableReason,
        'حزمة الرواة قيد انتظار الموافقة — ستتوفر حالتها فور اعتمادها',
      );
      expect(externalPackageById('narrators'), kNarratorsPackage);
      expect(externalPackageById('nope'), isNull);
    });
  });

  group('buildLibraryManifest', () {
    test('builds a valid single-file manifest from a fetched hash', () {
      final manifest = buildLibraryManifest(
        package: kLibraryPackage,
        sha256: 'b' * 64,
        sizeBytes: 189984768,
        createdAt: '2026-11-26T00:00:00Z',
      );
      expect(manifest.libraryId, 'library');
      expect(manifest.files.length, 1);
      expect(manifest.files.first.path, 'sunnati.db');
      expect(manifest.files.first.sha256, 'b' * 64);
      expect(manifest.totalBytes, 189984768);
      expect(validateManifestJson(manifest.toJson()), isEmpty);
    });

    test('refuses a malformed hash', () {
      expect(
        () => buildLibraryManifest(
          package: kLibraryPackage,
          sha256: 'not-a-hash',
          sizeBytes: 100,
          createdAt: '2026-11-26T00:00:00Z',
        ),
        throwsFormatException,
      );
    });

    test('refuses a non-positive size', () {
      expect(
        () => buildLibraryManifest(
          package: kLibraryPackage,
          sha256: 'b' * 64,
          sizeBytes: 0,
          createdAt: '2026-11-26T00:00:00Z',
        ),
        throwsFormatException,
      );
    });
  });

  group('decideLibraryInstall (first-run gating + migration)', () {
    test('valid installed copy is reused — no forced re-download', () {
      expect(
        decideLibraryInstall(fileExists: true, fileValid: true),
        LibraryInstallDecision.useExisting,
      );
    });

    test('missing file needs the first-run download', () {
      expect(
        decideLibraryInstall(fileExists: false, fileValid: false),
        LibraryInstallDecision.needsDownload,
      );
      expect(
        decideLibraryInstall(fileExists: false, fileValid: true),
        LibraryInstallDecision.needsDownload,
      );
    });

    test('corrupt installed copy is re-downloaded', () {
      expect(
        decideLibraryInstall(fileExists: true, fileValid: false),
        LibraryInstallDecision.corruptNeedsRedownload,
      );
    });
  });

  group('SHA-256 verification + resume state (no network)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sunnati_workb_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('verifyFileSha256 accepts the right hash, rejects tampering',
        () async {
      final file = File('${tmp.path}/probe.bin');
      final bytes = utf8.encode('sunnati-library-probe');
      await file.writeAsBytes(bytes);
      final hash = sha256.convert(bytes).toString();
      expect(await verifyFileSha256(file, hash), isTrue);
      await file.writeAsBytes(utf8.encode('tampered'));
      expect(await verifyFileSha256(file, hash), isFalse);
    });

    test('partialResumeOffset: none, partial, oversized', () async {
      final target = File('${tmp.path}/sunnati.db');
      expect(await partialResumeOffset(target, 1000), 0);
      final partial = File('${target.path}.part');
      await partial.writeAsBytes(List<int>.filled(400, 1));
      expect(await partialResumeOffset(target, 1000), 400);
      await partial.writeAsBytes(List<int>.filled(1200, 1));
      expect(await partialResumeOffset(target, 1000), 0);
      expect(await partial.exists(), isFalse);
    });

    test('DownloadedLibrary resume offset + progress fraction', () {
      const row = DownloadedLibrary(
        id: 1,
        libraryId: 'library',
        name: 'المكتبة الأساسية — الكتب التسعة',
        version: '1.0.0',
        sizeBytes: 0,
        sha256: '',
        status: 'paused',
        installedAt: '',
        totalBytes: 1000,
        downloadedBytes: 400,
      );
      expect(row.resumeOffset, 400);
      expect(row.progressFraction, 0.4);
    });
  });

  group('downloadSingleFile against a local server (hermetic)', () {
    late Directory tmp;
    late HttpServer server;
    late List<int> payload;
    late String payloadHash;
    String? lastRangeHeader;

    Future<void> startServer({bool ignoreRange = false}) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final range = request.headers.value('range');
        lastRangeHeader = range;
        if (range != null && !ignoreRange) {
          final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
          final start = match == null ? 0 : int.parse(match.group(1)!);
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes $start-${payload.length - 1}/${payload.length}',
          );
          request.response.headers.contentLength = payload.length - start;
          request.response.add(payload.sublist(start));
        } else {
          request.response.statusCode = 200;
          request.response.headers.contentLength = payload.length;
          request.response.add(payload);
        }
        await request.response.close();
      });
    }

    // Local helper (a function, not a getter: getters cannot be
    // declared inside a group callback — integrator fix 2026-11-26).
    Uri url() => Uri.parse(
          'http://127.0.0.1:${server.port}/sunnati.db',
        );

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sunnati_workb_dl_');
      payload = List<int>.generate(65536, (i) => i % 251);
      payloadHash = sha256.convert(payload).toString();
      lastRangeHeader = null;
    });

    tearDown(() async {
      await server.close(force: true);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('full download verifies SHA-256 and installs the file', () async {
      await startServer();
      final target = File('${tmp.path}/sunnati.db');
      final received = await downloadSingleFile(
        url: url(),
        target: target,
        expectedSha256: payloadHash,
        expectedTotalBytes: payload.length,
        allowHttpForTests: true,
      );
      expect(received, payload.length);
      expect(await target.readAsBytes(), payload);
      expect(await File('${target.path}.part').exists(), isFalse);
    });

    test('resume continues from a partial file via Range', () async {
      await startServer();
      final target = File('${tmp.path}/sunnati.db');
      final partial = File('${target.path}.part');
      await partial.writeAsBytes(payload.sublist(0, 16384));
      await downloadSingleFile(
        url: url(),
        target: target,
        expectedSha256: payloadHash,
        expectedTotalBytes: payload.length,
        allowHttpForTests: true,
      );
      expect(lastRangeHeader, 'bytes=16384-');
      expect(await target.readAsBytes(), payload);
    });

    test('server ignoring Range restarts the file from 0', () async {
      await startServer(ignoreRange: true);
      final target = File('${tmp.path}/sunnati.db');
      final partial = File('${target.path}.part');
      await partial.writeAsBytes(payload.sublist(0, 16384));
      await downloadSingleFile(
        url: url(),
        target: target,
        expectedSha256: payloadHash,
        expectedTotalBytes: payload.length,
        allowHttpForTests: true,
      );
      expect(lastRangeHeader, 'bytes=16384-');
      expect(await target.readAsBytes(), payload);
    });

    test('SHA-256 mismatch rejects the download and deletes files',
        () async {
      await startServer();
      final target = File('${tmp.path}/sunnati.db');
      final wrongHash = sha256.convert(utf8.encode('other')).toString();
      await expectLater(
        downloadSingleFile(
          url: url(),
          target: target,
          expectedSha256: wrongHash,
          expectedTotalBytes: payload.length,
          allowHttpForTests: true,
        ),
        throwsA(
          isA<PackageException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(await target.exists(), isFalse);
      expect(await File('${target.path}.part').exists(), isFalse);
    });

    test('cancel pauses and keeps the partial file for resume', () async {
      await startServer();
      final target = File('${tmp.path}/sunnati.db');
      await expectLater(
        downloadSingleFile(
          url: url(),
          target: target,
          expectedSha256: payloadHash,
          expectedTotalBytes: payload.length,
          shouldCancel: () => true,
          allowHttpForTests: true,
        ),
        throwsA(isA<DownloadPausedException>()),
      );
      expect(await File('${target.path}.part').exists(), isTrue);
      expect(await target.exists(), isFalse);
    });

    test('non-HTTPS is refused without the test flag', () async {
      await startServer();
      final target = File('${tmp.path}/sunnati.db');
      await expectLater(
        downloadSingleFile(
          url: url(),
          target: target,
          expectedSha256: payloadHash,
        ),
        throwsA(isA<PackageException>()),
      );
    });
  });
}
