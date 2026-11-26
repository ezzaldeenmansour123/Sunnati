import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/core/extended_library.dart';
import 'package:sunnati/core/package_manifest.dart';
import 'package:sunnati/models/downloaded_library.dart';

Map<String, Object?> validManifestJson() => <String, Object?>{
      'format': 'sunnati-package',
      'format_version': 1,
      'library_id': 'darqutni',
      'name': 'سنن الدارقطني',
      'version': '1.0.0',
      'source': 'verified-source',
      'license': 'ODbL-1.0',
      'files': <Map<String, Object?>>[
        <String, Object?>{
          'path': 'darqutni.db',
          'sha256': 'a' * 64,
          'size_bytes': 12345,
        },
      ],
      'total_bytes': 12345,
      'created_at': '2026-11-26T00:00:00Z',
    };

void main() {
  group('PackageManifest validation', () {
    test('accepts a valid manifest', () {
      final errors = <String>[];
      final manifest =
          PackageManifest.tryParse(validManifestJson(), errors);
      expect(errors, isEmpty);
      expect(manifest, isNotNull);
      expect(manifest!.libraryId, 'darqutni');
      expect(manifest.totalBytes, 12345);
    });

    test('round-trips through JSON', () {
      final manifest =
          PackageManifest.tryParse(validManifestJson(), <String>[])!;
      final restored =
          PackageManifest.fromJsonString(manifest.toJsonString());
      expect(restored.libraryId, manifest.libraryId);
      expect(restored.files.first.path, 'darqutni.db');
    });

    test('refuses a missing licence', () {
      final json = validManifestJson()..['license'] = '';
      expect(validateManifestJson(json), isNotEmpty);
    });

    test('refuses a missing source', () {
      final json = validManifestJson()..remove('source');
      expect(validateManifestJson(json), isNotEmpty);
    });

    test('refuses a total_bytes mismatch', () {
      final json = validManifestJson()..['total_bytes'] = 999;
      expect(
        validateManifestJson(json).join(' '),
        contains('total_bytes'),
      );
    });

    test('refuses a malformed sha256', () {
      final json = validManifestJson();
      (json['files'] as List).first['sha256'] = 'not-a-hash';
      expect(validateManifestJson(json), isNotEmpty);
    });

    test('refuses path traversal in file entries', () {
      final json = validManifestJson();
      (json['files'] as List).first['path'] = '../evil.db';
      expect(validateManifestJson(json), isNotEmpty);
      final json2 = validManifestJson();
      (json2['files'] as List).first['path'] = '/etc/passwd';
      expect(validateManifestJson(json2), isNotEmpty);
    });

    test('refuses a disallowed extension', () {
      final json = validManifestJson();
      (json['files'] as List).first['path'] = 'run.sh';
      expect(validateManifestJson(json), isNotEmpty);
    });
  });

  group('isSafePackagePath', () {
    test('accepts normal relative paths', () {
      expect(isSafePackagePath('darqutni.db'), isTrue);
      expect(isSafePackagePath('data/part-1.db'), isTrue);
      expect(isSafePackagePath('LICENSE.txt'), isTrue);
    });

    test('refuses traversal, absolute and drive paths', () {
      expect(isSafePackagePath('../x.db'), isFalse);
      expect(isSafePackagePath('a/../../x.db'), isFalse);
      expect(isSafePackagePath('/abs/x.db'), isFalse);
      expect(isSafePackagePath(r'C:\x.db'), isFalse);
      expect(isSafePackagePath(r'a\b.db'), isFalse);
    });
  });

  group('isUpdateAvailable', () {
    test('compares semantic versions', () {
      expect(isUpdateAvailable('1.0.0', '1.0.1'), isTrue);
      expect(isUpdateAvailable('1.0.0', '1.0.0'), isFalse);
      expect(isUpdateAvailable('1.2.0', '1.1.9'), isFalse);
      expect(isUpdateAvailable('1.9.9', '2.0.0'), isTrue);
    });
  });

  group('extended library catalogue', () {
    test('lists the eight books and six collections as preparing', () {
      expect(extendedLibraries.length, 14);
      expect(
        extendedLibraries.where((e) => e.isBook).length,
        8,
      );
      expect(
        extendedLibraries.where((e) => !e.isBook).length,
        6,
      );
      // No entry carries a size, URL or licence — preparation only.
      for (final entry in extendedLibraries) {
        expect(entry.id, isNotEmpty);
        expect(entry.name, isNotEmpty);
      }
      expect(extendedLibraries.map((e) => e.id).toSet().length, 14);
    });
  });

  group('formatBytes', () {
    test('formats sizes', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KiB');
      expect(formatBytes(180596736), '172.2 MiB');
    });
  });

  group('DownloadProgress', () {
    test('fraction is bounded and zero when total is unknown', () {
      const p = DownloadProgress(
        libraryId: 'x',
        status: DownloadStatus.downloading,
        receivedBytes: 50,
        totalBytes: 100,
      );
      expect(p.fraction, 0.5);
      const unknown = DownloadProgress(
        libraryId: 'x',
        status: DownloadStatus.downloading,
        receivedBytes: 50,
        totalBytes: 0,
      );
      expect(unknown.fraction, 0);
    });
  });
}
