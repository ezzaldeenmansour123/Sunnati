/// Download-package manifest (Phase 7) — pure Dart, no Flutter import.
///
/// Format v1 (single source of truth beside `tools/package_manifest.py`
/// and `docs/PACKAGE_FORMAT.md` — the three must agree; the Python test
/// suite checks the Dart constants against the Python implementation):
///
///     format          "sunnati-package"
///     format_version  1
///     library_id      ^[a-z0-9][a-z0-9_-]{0,63}$
///     name            Arabic display name
///     version         semantic x.y.z
///     source          source name — never empty
///     license         licence identifier — never empty
///     license_url     optional canonical licence URL
///     files           [{path, sha256, size_bytes}] — every file listed
///     total_bytes     sum of files[].size_bytes
///     created_at      ISO-8601 timestamp
///     min_app_version optional, e.g. "1.0.0"
///
/// Rules enforced here and in Python:
///   * SHA-256 is 64 lowercase hex chars; the installer refuses a package
///     whose manifest hash, file hash or total size disagrees.
///   * File paths are relative, `/`-separated, never start with `/`,
///     never contain `..`, a drive letter or a backslash (path-traversal
///     guard — a package must not write outside its own directory).
///   * Allowed extensions: `.db`, `.json`, `.txt`, `.md`.
///   * A package bigger than 2 GiB is refused; it must be split or
///     flagged to the owner first.
library;

import 'dart:convert';

/// Manifest format identifier.
const String kPackageFormat = 'sunnati-package';

/// Manifest format version supported by this build.
const int kPackageFormatVersion = 1;

/// Maximum accepted package size (2 GiB).
const int kMaxPackageBytes = 2 * 1024 * 1024 * 1024;

/// Allowed file extensions inside a package.
const Set<String> kPackageAllowedExtensions = <String>{
  '.db',
  '.json',
  '.txt',
  '.md',
};

final RegExp _sha256RegExp = RegExp(r'^[0-9a-f]{64}$');
final RegExp _libraryIdRegExp = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
final RegExp _versionRegExp = RegExp(r'^\d+\.\d+\.\d+$');
final RegExp _driveRegExp = RegExp(r'^[A-Za-z]:');

/// True iff [path] is a safe relative path inside a package.
bool isSafePackagePath(String path) {
  if (path.isEmpty) return false;
  if (path.startsWith('/') || path.startsWith(r'\')) return false;
  if (path.contains(r'\') || path.contains('\x00')) return false;
  if (_driveRegExp.hasMatch(path)) return false;
  final parts = path.split('/');
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..') return false;
  }
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  if (!kPackageAllowedExtensions.contains(path.substring(dot).toLowerCase())) {
    return false;
  }
  return true;
}

/// One file inside a package.
class PackageFileEntry {
  const PackageFileEntry({
    required this.path,
    required this.sha256,
    required this.sizeBytes,
  });

  factory PackageFileEntry.fromJson(Map<String, Object?> json) {
    return PackageFileEntry(
      path: json['path'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
      sizeBytes: json['size_bytes'] as int? ?? 0,
    );
  }

  final String path;

  /// Lowercase hex SHA-256 of the file bytes.
  final String sha256;

  final int sizeBytes;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'sha256': sha256,
        'size_bytes': sizeBytes,
      };
}

/// A validated download-package manifest.
class PackageManifest {
  const PackageManifest({
    required this.libraryId,
    required this.name,
    required this.version,
    required this.source,
    required this.license,
    required this.files,
    required this.totalBytes,
    required this.createdAt,
    this.licenseUrl = '',
    this.minAppVersion = '',
  });

  /// Parse + validate. Returns null and fills [errors] on any failure —
  /// an invalid manifest is refused, never partially trusted.
  static PackageManifest? tryParse(
    Map<String, Object?> json,
    List<String> errors,
  ) {
    final found = validateManifestJson(json);
    errors.addAll(found);
    if (found.isNotEmpty) return null;
    return PackageManifest(
      libraryId: json['library_id'] as String,
      name: json['name'] as String,
      version: json['version'] as String,
      source: json['source'] as String,
      license: json['license'] as String,
      files: (json['files'] as List)
          .map(
            (e) => PackageFileEntry.fromJson(e as Map<String, Object?>),
          )
          .toList(),
      totalBytes: json['total_bytes'] as int,
      createdAt: json['created_at'] as String,
      licenseUrl: json['license_url'] as String? ?? '',
      minAppVersion: json['min_app_version'] as String? ?? '',
    );
  }

  /// Parse a manifest JSON string. Throws [FormatException] listing the
  /// validation errors when the manifest is invalid.
  factory PackageManifest.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Package manifest is not a JSON object');
    }
    final errors = <String>[];
    final manifest = PackageManifest.tryParse(decoded, errors);
    if (manifest == null) {
      throw FormatException('Invalid package manifest: ${errors.join('; ')}');
    }
    return manifest;
  }

  final String libraryId;
  final String name;
  final String version;
  final String source;
  final String license;
  final List<PackageFileEntry> files;
  final int totalBytes;
  final String createdAt;
  final String licenseUrl;
  final String minAppVersion;

  Map<String, Object?> toJson() => <String, Object?>{
        'format': kPackageFormat,
        'format_version': kPackageFormatVersion,
        'library_id': libraryId,
        'name': name,
        'version': version,
        'source': source,
        'license': license,
        if (licenseUrl.isNotEmpty) 'license_url': licenseUrl,
        'files': files.map((f) => f.toJson()).toList(),
        'total_bytes': totalBytes,
        'created_at': createdAt,
        if (minAppVersion.isNotEmpty) 'min_app_version': minAppVersion,
      };

  String toJsonString() => jsonEncode(toJson());
}

/// Validate a decoded manifest object. Returns the error list
/// (empty = valid). Mirrors `tools/package_manifest.py::validate_manifest`.
List<String> validateManifestJson(Map<String, Object?> manifest) {
  final errors = <String>[];
  if (manifest['format'] != kPackageFormat) {
    errors.add("format must be '$kPackageFormat'");
  }
  if (manifest['format_version'] != kPackageFormatVersion) {
    errors.add('format_version must be $kPackageFormatVersion');
  }
  final libraryId = manifest['library_id'];
  if (libraryId is! String || !_libraryIdRegExp.hasMatch(libraryId)) {
    errors.add('library_id is missing or malformed');
  }
  final name = manifest['name'];
  if (name is! String || name.trim().isEmpty) {
    errors.add('name is missing or empty');
  }
  final version = manifest['version'];
  if (version is! String || !_versionRegExp.hasMatch(version)) {
    errors.add('version must be semantic (x.y.z)');
  }
  final source = manifest['source'];
  if (source is! String || source.trim().isEmpty) {
    errors.add('source is missing or empty');
  }
  final license = manifest['license'];
  if (license is! String || license.trim().isEmpty) {
    errors.add('license is missing or empty');
  }
  final files = manifest['files'];
  if (files is! List || files.isEmpty) {
    errors.add('files must be a non-empty list');
    return errors;
  }
  var total = 0;
  final seen = <String>{};
  for (final entry in files) {
    if (entry is! Map<String, Object?>) {
      errors.add('files[] entry is not an object');
      continue;
    }
    final path = entry['path'];
    if (path is! String || !isSafePackagePath(path)) {
      errors.add('unsafe file path: $path');
      continue;
    }
    if (!seen.add(path)) errors.add('duplicate file path: $path');
    final sha = entry['sha256'];
    if (sha is! String || !_sha256RegExp.hasMatch(sha)) {
      errors.add('bad sha256 for $path');
    }
    final size = entry['size_bytes'];
    if (size is! int || size <= 0) {
      errors.add('bad size_bytes for $path');
    } else {
      total += size;
    }
  }
  final declared = manifest['total_bytes'];
  if (declared is! int || declared <= 0) {
    errors.add('total_bytes is missing or not a positive integer');
  } else if (declared != total) {
    errors.add('total_bytes ($declared) != sum of files ($total)');
  }
  if (total > kMaxPackageBytes) {
    errors.add('total_bytes exceeds the $kMaxPackageBytes cap');
  }
  final createdAt = manifest['created_at'];
  if (createdAt is! String || createdAt.trim().isEmpty) {
    errors.add('created_at is missing or empty');
  }
  return errors;
}

/// Download lifecycle states (master prompt §12). `paused` keeps the
/// partial file so a later resume continues from [DownloadProgress.receivedBytes].
enum DownloadStatus {
  notStarted,
  downloading,
  paused,
  verifying,
  installed,
  failed,
  deleted,
}

/// Progress snapshot for one package download.
class DownloadProgress {
  const DownloadProgress({
    required this.libraryId,
    required this.status,
    required this.receivedBytes,
    required this.totalBytes,
    this.error = '',
  });

  final String libraryId;
  final DownloadStatus status;
  final int receivedBytes;
  final int totalBytes;
  final String error;

  /// 0.0–1.0; 0 when the total is unknown.
  double get fraction =>
      totalBytes <= 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  bool get isDone => status == DownloadStatus.installed;
}

/// True when [installedVersion] is older than [availableVersion]
/// (semantic x.y.z comparison) — i.e. a partial update is available.
bool isUpdateAvailable(String installedVersion, String availableVersion) {
  List<int> parts(String v) =>
      v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final a = parts(installedVersion);
  final b = parts(availableVersion);
  for (var i = 0; i < 3; i++) {
    final ai = i < a.length ? a[i] : 0;
    final bi = i < b.length ? b[i] : 0;
    if (bi > ai) return true;
    if (bi < ai) return false;
  }
  return false;
}

// ---- External core packages (rebuild 2026-11-26) ----
//
// The core library (sunnati.db) is EMBEDDED in the APK (owner decision
// 2026-11-26 16:54): it installs from the asset on first run, no
// download. CI also publishes the same file to the `library-v1` GitHub
// release (see `.github/workflows/build.yml`, step "Publish library
// data package (library-v1)") as an external copy for
// reference/recovery only; the app downloads it ONLY on the recovery
// screen, when the embedded install failed.
//
// The narrators package (narrators.db) is EMBEDDED in the APK too —
// OWNER OVERRIDE 2026-11-26 17:51 («بجميع قواعده بكل شيء»): the owner
// explicitly overrode the KITAB gate for the in-app copy, although the
// KITAB confirmation request (kitab@aku.edu) is still unanswered and
// the content is CC BY-NC-SA 4.0 (documented licence risk — see the
// Sources screen). It is NOT an external download: no code path offers
// or starts a narrators download. Its URL below is recorded for
// identity only — the file must NEVER be published to the public
// `library-v1` release (guard (a) in `.github/workflows/build.yml`
// fails the build if any upload names it).

/// GitHub release tag that carries the published library data.
const String kLibraryReleaseTag = 'library-v1';

/// HTTPS directory holding the published library files.
const String kLibraryDownloadBaseUrl =
    'https://github.com/ezzaldeenmansour123/Sunnati/releases/download/'
    'library-v1';

/// KITAB gate — OVERRIDDEN by the owner 2026-11-26 17:51: the owner
/// ordered narrators.db EMBEDDED in the app («بجميع قواعده بكل شيء»),
/// explicitly overriding the earlier decision (7) not to distribute it
/// before KITAB replies. The confirmation request to kitab@aku.edu is
/// still unanswered and the content is CC BY-NC-SA 4.0 — the licence
/// risk is documented, not hidden (see the Sources screen and
/// `lib/data/database.dart`). The flag stays as the single switch: it
/// is false while the embedded copy ships. The file is STILL never
/// published as a standalone file to the public `library-v1` release.
const bool kNarratorsPackageHeldBack = false;

/// One externally-downloaded core package: a single file published on a
/// GitHub release, verified against its `.sha256` sidecar before use.
/// This is a registry entry, not a manifest — the SHA-256 itself is
/// fetched at download time from [sha256Url] and validated (64 lowercase
/// hex) before any byte of the payload is trusted (see
/// [buildLibraryManifest]).
class ExternalPackage {
  const ExternalPackage({
    required this.id,
    required this.fileName,
    required this.displayName,
    required this.url,
    required this.sha256Url,
    required this.required,
    required this.available,
    this.unavailableReason = '',
  });

  /// Stable id: 'library' | 'narrators'. Also the `library_id` used in
  /// `downloaded_libraries` rows and in [PackageManifest]s built for it.
  final String id;

  /// File name as published on the release (also the installed file name
  /// in the app support directory).
  final String fileName;

  /// Arabic display name.
  final String displayName;

  /// HTTPS URL of the published file.
  final String url;

  /// HTTPS URL of the bare-SHA-256 sidecar (`<hash>\n`).
  final String sha256Url;

  /// True when the app cannot work without this package.
  final bool required;

  /// True when the package may be downloaded now. False means the UI
  /// must show [unavailableReason] and offer NO download button.
  final bool available;

  /// Honest Arabic reason shown when [available] is false. Empty when
  /// available.
  final String unavailableReason;
}

/// The core library: the Nine Books (sunnati.db). EMBEDDED in the APK
/// (owner decision 2026-11-26 16:54 — no mandatory download); CI also
/// publishes the same file to `library-v1` as an external copy for
/// reference/recovery, which the recovery screen downloads only when
/// the embedded install failed. Not required as a download.
const ExternalPackage kLibraryPackage = ExternalPackage(
  id: 'library',
  fileName: 'sunnati.db',
  displayName: 'المكتبة الأساسية — الكتب التسعة',
  url: 'https://github.com/ezzaldeenmansour123/Sunnati/releases/download/library-v1/sunnati.db',
  sha256Url: 'https://github.com/ezzaldeenmansour123/Sunnati/releases/download/library-v1/sunnati.db.sha256',
  required: false,
  available: true,
);

/// The narrators package (narrators.db, OpenITI Taqrib, CC BY-NC-SA 4.0).
/// EMBEDDED in the APK by owner override 2026-11-26 17:51 (see
/// [kNarratorsPackageHeldBack]): available as an embedded asset, never
/// as a download. The URL is recorded for identity only and must never
/// be published to `library-v1` (CI guard (a) enforces this).
const ExternalPackage kNarratorsPackage = ExternalPackage(
  id: 'narrators',
  fileName: 'narrators.db',
  displayName: 'حزمة الرواة',
  url: 'https://github.com/ezzaldeenmansour123/Sunnati/releases/download/library-v1/narrators.db',
  sha256Url: 'https://github.com/ezzaldeenmansour123/Sunnati/releases/download/library-v1/narrators.db.sha256',
  required: false,
  available: true,
);

/// Exactly the two external packages above — no other download exists.
const List<ExternalPackage> kExternalPackages = <ExternalPackage>[
  kLibraryPackage,
  kNarratorsPackage,
];

/// One registry entry by id, or null.
ExternalPackage? externalPackageById(String id) {
  for (final pkg in kExternalPackages) {
    if (pkg.id == id) return pkg;
  }
  return null;
}

/// Build the validated single-file [PackageManifest] for a library
/// download, from the SHA-256 fetched from the package's [sha256Url]
/// and the payload size (from the download response's Content-Length).
/// Throws [FormatException] when the hash is not 64 lowercase hex chars
/// or the size is not positive — a bad hash is never trusted, and the
/// download is refused before it starts.
PackageManifest buildLibraryManifest({
  required ExternalPackage package,
  required String sha256,
  required int sizeBytes,
  required String createdAt,
}) {
  final manifest = PackageManifest(
    libraryId: package.id,
    name: package.displayName,
    version: '1.0.0',
    source: 'quranlab/hadith',
    license: package.id == 'library'
        ? 'ODbL-1.0 / DbCL-1.0 — see SOURCES.md'
        : 'CC BY-NC-SA 4.0',
    files: <PackageFileEntry>[
      PackageFileEntry(
        path: package.fileName,
        sha256: sha256.trim().toLowerCase(),
        sizeBytes: sizeBytes,
      ),
    ],
    totalBytes: sizeBytes,
    createdAt: createdAt,
  );
  final errors = validateManifestJson(manifest.toJson());
  if (errors.isNotEmpty) {
    throw FormatException(
      'Invalid library manifest: ${errors.join('; ')}',
    );
  }
  return manifest;
}
