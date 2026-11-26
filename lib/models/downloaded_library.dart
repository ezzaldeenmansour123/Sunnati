/// Installed / known download-package row (table `downloaded_libraries`,
/// schema v4) — pure Dart.
///
/// A row exists ONLY for a real package: the bundled Nine Books are not
/// rows here (they are the installed library itself), and an extended
/// library still "preparing" has no row. `status` values:
/// available | downloading | paused | verifying | installed | failed |
/// deleted. A package whose SHA-256 does not verify is NEVER `installed`.
library;

/// Human-readable byte size, e.g. 172.2 MiB. Pure helper, unit-tested
/// indirectly through the downloads screen tests.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = <String>['KiB', 'MiB', 'GiB'];
  var value = bytes / 1024.0;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

class DownloadedLibrary {
  const DownloadedLibrary({
    required this.id,
    required this.libraryId,
    required this.name,
    required this.version,
    required this.sizeBytes,
    required this.sha256,
    required this.status,
    required this.installedAt,
    this.source = '',
    this.license = '',
    this.downloadUrl = '',
    this.totalBytes = 0,
    this.downloadedBytes = 0,
    this.manifestJson = '',
    this.updatedAt = '',
  });

  factory DownloadedLibrary.fromRow(Map<String, Object?> row) {
    return DownloadedLibrary(
      id: (row['id'] as int?) ?? 0,
      libraryId: (row['library_id'] as String?) ?? '',
      name: (row['name'] as String?) ?? '',
      version: (row['version'] as String?) ?? '',
      sizeBytes: (row['size_bytes'] as int?) ?? 0,
      sha256: (row['sha256'] as String?) ?? '',
      status: (row['status'] as String?) ?? '',
      installedAt: (row['installed_at'] as String?) ?? '',
      source: (row['source'] as String?) ?? '',
      license: (row['license'] as String?) ?? '',
      downloadUrl: (row['download_url'] as String?) ?? '',
      totalBytes: (row['total_bytes'] as int?) ?? 0,
      downloadedBytes: (row['downloaded_bytes'] as int?) ?? 0,
      manifestJson: (row['manifest_json'] as String?) ?? '',
      updatedAt: (row['updated_at'] as String?) ?? '',
    );
  }

  final int id;
  final String libraryId;
  final String name;
  final String version;

  /// Installed payload size in bytes (0 until installed).
  final int sizeBytes;

  /// SHA-256 of the installed payload file ('' until verified).
  final String sha256;

  final String status;
  final String installedAt;
  final String source;
  final String license;
  final String downloadUrl;

  /// Declared total from the manifest (0 when unknown).
  final int totalBytes;

  /// Bytes downloaded so far (resume offset).
  final int downloadedBytes;

  /// The verified manifest JSON, stored for re-verification.
  final String manifestJson;

  final String updatedAt;

  bool get isInstalled => status == 'installed';
  bool get isDownloading =>
      status == 'downloading' || status == 'paused' || status == 'verifying';
  bool get isAvailable => status == 'available';

  /// Resume offset: bytes already on disk for this package.
  int get resumeOffset => downloadedBytes;

  /// Download progress 0.0–1.0 (0 when the total is unknown).
  double get progressFraction =>
      totalBytes <= 0 ? 0 : (downloadedBytes / totalBytes).clamp(0.0, 1.0);

  String get sizeLabel =>
      sizeBytes > 0 ? formatBytes(sizeBytes) : formatBytes(totalBytes);
}
