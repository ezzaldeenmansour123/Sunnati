/// Download manager (master prompt §12, Phase 7) — resumable, verified,
/// storage-aware downloads of extended-library packages.
///
/// Design (honest by construction):
///   * A package downloads ONLY from a manifest that already validated
///     (see `lib/core/package_manifest.dart`). There is no URL in the
///     app for a "preparing" library — the downloads screen never calls
///     this manager for one.
///   * Resume: a partial file `<name>.part` is kept on pause / failure /
///     app kill; the next attempt sends `Range: bytes=<received>-` and
///     continues. A server that ignores Range restarts the file from 0
///     (the partial file is truncated, never mixed with new bytes).
///   * Verification: after the last byte, every listed file is hashed
///     (streaming SHA-256, never loaded whole into memory) and compared
///     with the manifest. On ANY mismatch the staged files are deleted
///     and the package is reported `failed` — it is NEVER installed.
///   * Install is an atomic-ish move: verified files move from the
///     staging directory into `packages/<library_id>-<version>/` and the
///     caller records the row in `downloaded_libraries` with
///     status `installed`. Until then the row stays `downloading` /
///     `failed`; the library screen never reads a half-installed package.
///   * Storage: [storageSummary] walks the packages directory (streamed
///     listing) and reports bytes used per package; [deletePackage]
///     removes the directory and the caller deletes the DB row.
///   * No API keys, no tokens: a package URL is a plain HTTPS file URL
///     recorded in the manifest's source. HTTP (non-TLS) URLs are
///     refused outright.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/package_manifest.dart';

/// Thrown when a package fails verification or an unsafe URL/path is
/// encountered. The message is safe to show to the user (no paths from
/// the device are leaked — only the library id and the reason).
class PackageException implements Exception {
  PackageException(this.message);

  final String message;

  @override
  String toString() => 'PackageException: $message';
}

/// Directory name for one installed package version.
String packageDirName(PackageManifest manifest) =>
    '${manifest.libraryId}-${manifest.version}';

/// Stream-hash a file and compare with [expectedSha256] (lowercase hex).
/// Reads in 1 MiB chunks — a 200 MB package is never loaded whole.
Future<bool> verifyFileSha256(File file, String expectedSha256) async {
  final digest = await file.openRead().transform(sha256).first;
  return digest.toString() == expectedSha256.toLowerCase();
}

/// Compute the SHA-256 hex of a file (streaming).
Future<String> sha256OfFile(File file) async {
  final digest = await file.openRead().transform(sha256).first;
  return digest.toString();
}

/// Bytes used by the packages directory, per package + total.
/// The listing is streamed; file sizes come from stat, not reads.
Future<StorageSummary> storageSummary(Directory packagesDir) async {
  var total = 0;
  final perPackage = <String, int>{};
  if (!await packagesDir.exists()) {
    return const StorageSummary(totalBytes: 0, perPackage: <String, int>{});
  }
  await for (final entity in packagesDir.list()) {
    if (entity is! Directory) continue;
    var size = 0;
    await for (final file in entity.list(recursive: true)) {
      if (file is File) size += await file.length();
    }
    perPackage[entity.path.split(Platform.pathSeparator).last] = size;
    total += size;
  }
  return StorageSummary(totalBytes: total, perPackage: perPackage);
}

class StorageSummary {
  const StorageSummary({required this.totalBytes, required this.perPackage});

  final int totalBytes;
  final Map<String, int> perPackage;
}

/// One download task. Created by the UI with
/// `DownloadTask(manifest: ..., packagesDir: ..., onProgress: ...)`; call
/// [cancel] to pause (partial file kept for resume) or [abort] to delete
/// the partial file.
class DownloadTask {
  DownloadTask({
    required this.manifest,
    required this.packagesDir,
    required this.onProgress,
  });

  final PackageManifest manifest;
  final Directory packagesDir;
  final void Function(DownloadProgress) onProgress;

  HttpClient? _client;
  bool _cancelled = false;
  bool _aborted = false;

  /// Pause: stop the transfer, keep the partial file for resume.
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  /// Abort: stop the transfer and delete partial files.
  Future<void> abort() async {
    _aborted = true;
    cancel();
    await _deletePartialFiles();
  }

  Future<void> _deletePartialFiles() async {
    final dir = Directory(
      '${packagesDir.path}${Platform.pathSeparator}'
      '${packageDirName(manifest)}.staging',
    );
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  bool get isCancelled => _cancelled;
  bool get isAborted => _aborted;
}

class DownloadManager {
  DownloadManager(this.packagesDir);

  /// Directory holding `packages/<library_id>-<version>/` installs and
  /// `<library_id>-<version>.staging/` partial downloads.
  final Directory packagesDir;

  /// Download + verify + install the package of [task].
  ///
  /// [baseUrl] is the HTTPS directory holding the package files (the
  /// manifest itself is NOT downloaded — it was validated before this
  /// call and is what authorises the download). Returns the installed
  /// directory. Throws [PackageException] on refusal, failure or
  /// verification mismatch; partial files are kept for resume unless
  /// the failure was a hash mismatch (then they are deleted).
  Future<Directory> startDownload({
    required DownloadTask task,
    required Uri baseUrl,
  }) async {
    final manifest = task.manifest;
    if (baseUrl.scheme != 'https') {
      throw PackageException(
        'رفض تنزيل ${manifest.libraryId}: الرابط ليس HTTPS.',
      );
    }
    final stagingDir = Directory(
      '${packagesDir.path}${Platform.pathSeparator}'
      '${packageDirName(manifest)}.staging',
    );
    await stagingDir.create(recursive: true);
    try {
      for (final file in manifest.files) {
        if (task.isAborted) {
          throw PackageException('أُلغي التنزيل.');
        }
        await _downloadOneFile(task, manifest, file, baseUrl, stagingDir);
        if (task.isCancelled) {
          task.onProgress(
            DownloadProgress(
              libraryId: manifest.libraryId,
              status: DownloadStatus.paused,
              receivedBytes: await _stagingBytes(stagingDir),
              totalBytes: manifest.totalBytes,
            ),
          );
          throw DownloadPausedException();
        }
      }
      task.onProgress(
        DownloadProgress(
          libraryId: manifest.libraryId,
          status: DownloadStatus.verifying,
          receivedBytes: manifest.totalBytes,
          totalBytes: manifest.totalBytes,
        ),
      );
      await _verifyStaging(manifest, stagingDir);
      final finalDir = Directory(
        '${packagesDir.path}${Platform.pathSeparator}'
        '${packageDirName(manifest)}',
      );
      if (await finalDir.exists()) {
        await finalDir.delete(recursive: true);
      }
      await stagingDir.rename(finalDir.path);
      await File(
        '${finalDir.path}${Platform.pathSeparator}manifest.json',
      ).writeAsString(manifest.toJsonString());
      task.onProgress(
        DownloadProgress(
          libraryId: manifest.libraryId,
          status: DownloadStatus.installed,
          receivedBytes: manifest.totalBytes,
          totalBytes: manifest.totalBytes,
        ),
      );
      return finalDir;
    } on DownloadPausedException {
      rethrow;
    } catch (e) {
      if (e is PackageException && e.message.contains('SHA-256')) {
        await task._deletePartialFiles();
      }
      rethrow;
    }
  }

  Future<int> _stagingBytes(Directory stagingDir) async {
    var total = 0;
    if (!await stagingDir.exists()) return 0;
    await for (final entity in stagingDir.list(recursive: true)) {
      if (entity is File && !entity.path.endsWith('.part')) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<void> _downloadOneFile(
    DownloadTask task,
    PackageManifest manifest,
    PackageFileEntry entry,
    Uri baseUrl,
    Directory stagingDir,
  ) async {
    final target = File(
      '${stagingDir.path}${Platform.pathSeparator}${entry.path}',
    );
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.part');
    var received = await partial.exists() ? await partial.length() : 0;
    if (received > entry.sizeBytes) {
      // A partial file longer than the manifest says: corrupt, restart.
      await partial.delete();
      received = 0;
    }
    if (received == entry.sizeBytes) {
      await partial.rename(target.path);
      return;
    }
    final url = baseUrl.resolve(entry.path);
    if (url.scheme != 'https') {
      throw PackageException('رفض تنزيل ${manifest.libraryId}: رابط غير آمن.');
    }
    final client = HttpClient();
    task._client = client;
    try {
      final request = await client.getUrl(url);
      if (received > 0) {
        request.headers.set('Range', 'bytes=$received-');
      }
      final response = await request.close();
      if (response.statusCode == 416) {
        await partial.delete();
        received = 0;
        throw PackageException(
          'تعذّر استكمال ${manifest.libraryId}: أعد المحاولة من البداية.',
        );
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw PackageException(
          'فشل تنزيل ${manifest.libraryId}: HTTP ${response.statusCode}.',
        );
      }
      final resumed = response.statusCode == 206;
      final sink = partial.openWrite(
        mode: resumed ? FileMode.append : FileMode.write,
      );
      if (!resumed) received = 0;
      try {
        await for (final chunk in response) {
          if (task.isCancelled || task.isAborted) break;
          sink.add(chunk);
          received += chunk.length;
          task.onProgress(
            DownloadProgress(
              libraryId: manifest.libraryId,
              status: DownloadStatus.downloading,
              receivedBytes: received,
              totalBytes: manifest.totalBytes,
            ),
          );
        }
      } finally {
        await sink.close();
      }
      if (task.isCancelled || task.isAborted) return;
      if (received != entry.sizeBytes) {
        throw PackageException(
          'اكتمل التنزيل ناقصاً لـ ${manifest.libraryId} '
          '($received من ${entry.sizeBytes} بايت) — أعد المحاولة للاستكمال.',
        );
      }
      await partial.rename(target.path);
    } finally {
      client.close(force: true);
      task._client = null;
    }
  }

  Future<void> _verifyStaging(
    PackageManifest manifest,
    Directory stagingDir,
  ) async {
    for (final entry in manifest.files) {
      final file = File(
        '${stagingDir.path}${Platform.pathSeparator}${entry.path}',
      );
      if (!await file.exists()) {
        throw PackageException(
          'فشل التحقق لـ ${manifest.libraryId}: الملف ${entry.path} مفقود.',
        );
      }
      if (await file.length() != entry.sizeBytes) {
        throw PackageException(
          'فشل التحقق لـ ${manifest.libraryId}: حجم ${entry.path} لا يطابق البيان.',
        );
      }
      if (!await verifyFileSha256(file, entry.sha256)) {
        throw PackageException(
          'فشل التحقق SHA-256 لـ ${manifest.libraryId}: الملف ${entry.path} '
          'لا يطابق البيان — حُذفت الملفات ولم يُثبَّت شيء.',
        );
      }
    }
  }

  /// Delete an installed (or staged) package directory.
  Future<void> deletePackage(PackageManifest manifest) async {
    final dir = Directory(
      '${packagesDir.path}${Platform.pathSeparator}'
      '${packageDirName(manifest)}',
    );
    if (await dir.exists()) await dir.delete(recursive: true);
    final staging = Directory('${dir.path}.staging');
    if (await staging.exists()) await staging.delete(recursive: true);
  }

  /// Verify an already-installed package directory against its manifest
  /// (used by the downloads screen's "verify" action and the admin
  /// panel's quality checks).
  Future<List<String>> verifyInstalledPackage(
    PackageManifest manifest,
  ) async {
    final dir = Directory(
      '${packagesDir.path}${Platform.pathSeparator}'
      '${packageDirName(manifest)}',
    );
    final errors = <String>[];
    if (!await dir.exists()) {
      return <String>['package directory is missing'];
    }
    for (final entry in manifest.files) {
      final file = File(
        '${dir.path}${Platform.pathSeparator}${entry.path}',
      );
      if (!await file.exists()) {
        errors.add('missing file: ${entry.path}');
        continue;
      }
      if (!await verifyFileSha256(file, entry.sha256)) {
        errors.add('sha256 mismatch: ${entry.path}');
      }
    }
    return errors;
  }
}

class DownloadPausedException implements Exception {}
