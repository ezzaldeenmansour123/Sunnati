import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../core/extended_library.dart';
import '../core/package_manifest.dart';
import '../core/theme.dart';
import '../data/database.dart';
import '../data/download_manager.dart';
import '../models/downloaded_library.dart';
import 'library_download_card.dart';

/// Downloads manager (master prompt §12) — Phase 7, embed 2026-11-26.
///
/// The core library (the Nine Books) is EMBEDDED in the APK (owner
/// decision 2026-11-26 16:54): it installs from the asset on first run
/// with no download, and this screen shows its real state — installed,
/// with SHA-256 verify. The shared [LibraryDownloadCard] appears here
/// only as a recovery path when the embedded install failed. The
/// library itself can never be deleted from this screen: a corrupt copy
/// is repaired automatically from the embedded asset on the next boot.
/// A migrated build-52 install shows as installed here with its real
/// counts; its SHA-256 is reported as "not recorded for this migrated
/// copy" when no hash was ever stored (never invented).
///
/// The narrators package is EMBEDDED in the APK (owner override
/// 2026-11-26 17:51 — the KITAB gate is overridden for the in-app
/// copy; the file is still never published to `library-v1`): a fresh
/// install shows it as installed from the embedded asset, with its
/// real counts. A valid copy already on the device from a previous
/// install (legacy local copy, labelled as such) is still used as-is.
/// There is NO download button for narrators — never a dead button.
/// When the embedded install failed, the screen shows the honest
/// reason instead of the old "pending approval" state.
///
/// Extended libraries are PREPARATION ONLY (see
/// `lib/core/extended_library.dart`): they are listed as "preparing —
/// not available yet" with NO download button, NO size and NO URL. A
/// download button for a package with no verified files would be a fake
/// button.
///
/// The download machinery itself is real and wired: when a package row
/// with status `available` exists (created only after a verified
/// package is published with a valid manifest), this screen offers a
/// working download with progress, pause/resume, retry, SHA-256
/// verification and delete — through [DownloadManager].
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, required this.db});

  final SunnatiDatabase db;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  late SunnatiDatabase _db;
  List<DownloadedLibrary> _packages = const <DownloadedLibrary>[];
  StorageSummary? _storage;
  DownloadManager? _manager;
  DownloadTask? _activeTask;
  DownloadProgress? _activeProgress;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _db = widget.db;
    _refresh();
  }

  Future<Directory> _packagesDir() async {
    final dir = await getApplicationSupportDirectory();
    final packages = Directory('${dir.path}/packages');
    await packages.create(recursive: true);
    return packages;
  }

  Future<void> _refresh() async {
    final dir = await _packagesDir();
    final manager = DownloadManager(dir);
    final summary = await storageSummary(dir);
    if (!mounted) return;
    setState(() {
      _manager = manager;
      _packages = _db.downloadedLibraries();
      _storage = summary;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  DownloadedLibrary? get _libraryRow {
    for (final pkg in _packages) {
      if (pkg.libraryId == kLibraryPackage.id) return pkg;
    }
    return null;
  }

  Future<void> _download(DownloadedLibrary pkg) async {
    final manager = _manager;
    if (manager == null) return;
    if (pkg.downloadUrl.isEmpty || pkg.manifestJson.isEmpty) {
      _snack('هذه الحزمة بلا بيان موثق — لا يمكن تنزيلها.');
      return;
    }
    PackageManifest manifest;
    try {
      manifest = PackageManifest.fromJsonString(pkg.manifestJson);
    } on FormatException catch (e) {
      _snack('بيان الحزمة غير صالح: ${e.message}');
      return;
    }
    final baseUrl = Uri.tryParse(pkg.downloadUrl);
    if (baseUrl == null || baseUrl.scheme != 'https') {
      _snack('رابط الحزمة غير آمن أو غير صالح — رُفض التنزيل.');
      return;
    }
    late final DownloadTask task;
    task = DownloadTask(
      manifest: manifest,
      packagesDir: manager.packagesDir,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() {
          _activeProgress = progress;
          _activeTask = task;
        });
      },
    );
    setState(() {
      _activeTask = task;
      _activeProgress = DownloadProgress(
        libraryId: manifest.libraryId,
        status: DownloadStatus.downloading,
        receivedBytes: pkg.downloadedBytes,
        totalBytes: manifest.totalBytes,
      );
      _notice = null;
    });
    _db.upsertDownloadedLibrary(
      _withStatus(pkg, 'downloading', downloadedBytes: pkg.downloadedBytes),
    );
    try {
      await manager.startDownload(task: task, baseUrl: baseUrl);
      final dir = Directory(
        '${manager.packagesDir.path}/${packageDirName(manifest)}',
      );
      var size = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) size += await entity.length();
      }
      _db.upsertDownloadedLibrary(
        _withStatus(
          pkg,
          'installed',
          sizeBytes: size,
          downloadedBytes: manifest.totalBytes,
        ),
      );
      _db.auditInsert(
        action: 'package_installed',
        entityType: 'package',
        entityId: manifest.libraryId,
        source: manifest.source,
        detail: 'installed ${manifest.libraryId} ${manifest.version} '
            '(SHA-256 verified)',
      );
      if (mounted) {
        setState(() {
          _notice = 'تم تثبيت «${manifest.name}» بعد التحقق من سلامتها.';
        });
      }
    } on DownloadPausedException {
      // Pause is not an error: the partial file stays for resume.
      _db.upsertDownloadedLibrary(
        _withStatus(
          pkg,
          'paused',
          downloadedBytes: _activeProgress?.receivedBytes ?? 0,
        ),
      );
    } on PackageException catch (e) {
      _db.upsertDownloadedLibrary(_withStatus(pkg, 'failed'));
      if (mounted) _snack(e.message);
    } finally {
      if (mounted) {
        setState(() {
          _activeTask = null;
          _activeProgress = null;
        });
        await _refresh();
      }
    }
  }

  DownloadedLibrary _withStatus(
    DownloadedLibrary pkg,
    String status, {
    int? sizeBytes,
    int? downloadedBytes,
  }) {
    return DownloadedLibrary(
      id: pkg.id,
      libraryId: pkg.libraryId,
      name: pkg.name,
      version: pkg.version,
      sizeBytes: sizeBytes ?? pkg.sizeBytes,
      sha256: pkg.sha256,
      status: status,
      installedAt: pkg.installedAt,
      source: pkg.source,
      license: pkg.license,
      downloadUrl: pkg.downloadUrl,
      totalBytes: pkg.totalBytes,
      downloadedBytes: downloadedBytes ?? pkg.downloadedBytes,
      manifestJson: pkg.manifestJson,
      updatedAt: pkg.updatedAt,
    );
  }

  Future<void> _delete(DownloadedLibrary pkg) async {
    final manager = _manager;
    if (manager == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('حذف «${pkg.name}»؟'),
        content: const Text(
          'ستُحذف ملفات الحزمة من الجهاز. يمكن إعادة تنزيلها لاحقاً إن بقيت متاحة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    PackageManifest? manifest;
    if (pkg.manifestJson.isNotEmpty) {
      try {
        manifest = PackageManifest.fromJsonString(pkg.manifestJson);
      } catch (_) {
        manifest = null;
      }
    }
    if (manifest != null) await manager.deletePackage(manifest);
    _db.deleteDownloadedLibrary(pkg.libraryId);
    _db.auditInsert(
      action: 'package_deleted',
      entityType: 'package',
      entityId: pkg.libraryId,
      detail: 'deleted ${pkg.libraryId} ${pkg.version}',
    );
    await _refresh();
    _snack('تم حذف الحزمة.');
  }

  Future<void> _verifyInstalled(DownloadedLibrary pkg) async {
    final manager = _manager;
    if (manager == null || pkg.manifestJson.isEmpty) return;
    PackageManifest manifest;
    try {
      manifest = PackageManifest.fromJsonString(pkg.manifestJson);
    } on FormatException {
      _snack('بيان الحزمة غير صالح — لا يمكن التحقق منها.');
      return;
    }
    final errors = await manager.verifyInstalledPackage(manifest);
    if (!mounted) return;
    _snack(
      errors.isEmpty
          ? 'الحزمة سليمة — جميع الملفات تطابق SHA-256.'
          : 'مشكلة في الحزمة: ${errors.join('؛ ')}',
    );
  }

  /// Verify the installed CORE library: SQLite header + quick_check +
  /// hadith count, and — when a hash was recorded for this copy — a
  /// streaming SHA-256 comparison. A migrated build-52 copy has no
  /// recorded hash, and the message says so instead of inventing one.
  Future<void> _verifyLibrary() async {
    final dir = await getApplicationSupportDirectory();
    final file = SunnatiDatabase.installedLibraryFile(dir);
    final valid = await SunnatiDatabase.verifyLibraryFile(file);
    if (!valid) {
      _snack('المكتبة المثبّتة غير سليمة — أعد تشغيل التطبيق لإصلاحها '
          'من النسخة المضمّنة.');
      return;
    }
    final row = _libraryRow;
    if (row == null || row.sha256.isEmpty) {
      _snack('المكتبة سليمة وفق فحص قاعدة البيانات — لا توجد بصمة '
          'SHA-256 محفوظة لهذه النسخة (مهاجَرة من تثبيت سابق).');
      return;
    }
    final matches = await verifyFileSha256(file, row.sha256);
    if (!mounted) return;
    _snack(
      matches
          ? 'المكتبة سليمة — تطابق SHA-256 المنشور.'
          : 'المكتبة لا تطابق SHA-256 المنشور — أعد تشغيل التطبيق '
              'لإصلاحها من النسخة المضمّنة.',
    );
  }

  Future<void> _onLibraryInstalled() async {
    final fresh = await SunnatiDatabase.open();
    if (!mounted) return;
    setState(() {
      _db = fresh;
      _notice = 'تم تثبيت المكتبة الأساسية بعد التحقق من سلامتها. '
          'أعد تشغيل التطبيق لتحديث الشاشة الرئيسية.';
    });
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final books = _db.books();
    final installed = _db.totalHadiths();
    final libraryInstalled = _db.isAvailable;
    final libraryRow = _libraryRow;
    final available = _packages
        .where((p) => p.status == 'available' && p.libraryId != 'library')
        .toList();
    final installedPkgs = _packages
        .where((p) => p.status == 'installed' && p.libraryId != 'library')
        .toList();
    final activeId = _activeProgress?.libraryId;
    return Scaffold(
      appBar: AppBar(title: const Text('التنزيلات')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_notice != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_notice!),
              ),
            ),
          _SectionCard(
            title: 'المكتبة المثبّتة',
            child: Text(
              installed > 0
                  ? '$installed حديثاً مثبّتاً وتعمل دون إنترنت.'
                  : 'لا توجد أحاديث مثبّتة بعد — نزّل المكتبة الأساسية من الأسفل.',
              style: const TextStyle(color: SunnatiColors.inkMuted),
            ),
          ),
          const _SectionTitle('المكتبة الأساسية — الكتب التسعة'),
          if (libraryInstalled)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kLibraryPackage.displayName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${libraryRow?.version ?? '1.0.0'} — '
                      '${libraryRow != null && libraryRow.sizeBytes > 0 ? formatBytes(libraryRow.sizeBytes) : '$installed حديثاً'}'
                      '${libraryRow != null && libraryRow.sha256.isEmpty ? '\nبصمة SHA-256 غير محفوظة لهذه النسخة (مهاجَرة من تثبيت سابق)' : ''}',
                      style:
                          const TextStyle(color: SunnatiColors.inkMuted),
                    ),
                    const SizedBox(height: 8),
                    // No delete button: the core library is embedded in
                    // the APK (owner decision 2026-11-26 16:54) and a
                    // corrupt copy is repaired from the embedded asset
                    // on the next boot — it must never be deletable.
                    OutlinedButton.icon(
                      onPressed: _verifyLibrary,
                      icon: const Icon(Icons.verified_outlined),
                      label: const Text('التحقق من السلامة (SHA-256)'),
                    ),
                  ],
                ),
              ),
            )
          else
            LibraryDownloadCard(onInstalled: _onLibraryInstalled),
          const _SectionTitle('حزمة الرواة'),
          _db.narratorsAvailable
              ? Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _db.downloadedLibraryById('narrators')?.source ==
                                  'embedded-asset'
                              ? '${kNarratorsPackage.displayName} — مضمّنة في التطبيق'
                              : '${kNarratorsPackage.displayName} — مثبّتة من نسخة سابقة',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _db.downloadedLibraryById('narrators')?.source ==
                                  'embedded-asset'
                              ? '${_db.narratorCount()} راوٍ موثّق — مضمّنة في التطبيق بأمر مالك التطبيق بتاريخ 2026-11-26 (تقريب التهذيب، CC BY-NC-SA 4.0). لا تُنشر كملف مستقل.'
                              : '${_db.narratorCount()} راوٍ موثّق — نسخة محلية '
                                  'من تثبيت سابق على هذا الجهاز. هذه النسخة ليست '
                                  'منزّلة من هذا الإصدار ولا تُوزَّع منه؛ تبقى '
                                  'للقراءة فقط.',
                          style: const TextStyle(
                            color: SunnatiColors.inkMuted,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Chip(
                          label: Text(
                            _db.downloadedLibraryById('narrators')?.source ==
                                    'embedded-asset'
                                ? 'مضمّنة في التطبيق'
                                : 'نسخة محلية قديمة',
                          ),
                          backgroundColor: SunnatiColors.goldSoft,
                        ),
                      ],
                    ),
                  ),
                )
              : Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          kNarratorsPackage.displayName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_db.narratorsUnavailableReason.isNotEmpty ? _db.narratorsUnavailableReason : 'تعذّر تثبيت حزمة الرواة المضمّنة — أعد تثبيت التطبيق.'} — حزمة الرواة مضمّنة في التطبيق ولا تُنزَّل من هنا.',
                          style: const TextStyle(
                            color: SunnatiColors.inkMuted,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Chip(
                          label: Text('غير مثبّتة'),
                          backgroundColor: SunnatiColors.goldSoft,
                        ),
                      ],
                    ),
                  ),
                ),
          _SectionCard(
            title: 'المساحة',
            child: Text(
              _storage == null
                  ? 'جارٍ حساب المساحة…'
                  : 'الحزم الموسعة على الجهاز: '
                      '${formatBytes(_storage!.totalBytes)} '
                      '(${_storage!.perPackage.length} حزمة). '
                      'المكتبة الأساسية مضمّنة في التطبيق وتُحفظ في '
                      'مساحة التطبيق.',
              style: const TextStyle(color: SunnatiColors.inkMuted),
            ),
          ),
          const _SectionTitle('الكتب التسعة — ضمن المكتبة'),
          ...books.map(
            (b) => Card(
              child: ListTile(
                leading: const Icon(Icons.book_outlined),
                title: Text(b.name),
                subtitle: Text(
                  b.hasData
                      ? '${b.count} حديثاً — مثبّت ضمن المكتبة'
                      : 'قيد الاستيراد',
                ),
              ),
            ),
          ),
          if (available.isNotEmpty) ...[
            const _SectionTitle('حزم متاحة للتنزيل'),
            ...available.map((pkg) => _AvailablePackageCard(
                  pkg: pkg,
                  activeProgress: activeId == pkg.libraryId
                      ? _activeProgress
                      : null,
                  onDownload: () => _download(pkg),
                  onPause: () => _activeTask?.cancel(),
                )),
          ],
          if (installedPkgs.isNotEmpty) ...[
            const _SectionTitle('حزم موسعة مثبّتة'),
            ...installedPkgs.map(
              (pkg) => Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle),
                  title: Text(pkg.name),
                  subtitle: Text(
                    '${pkg.version} — ${pkg.sizeLabel}'
                    '${pkg.license.isNotEmpty ? ' — ${pkg.license}' : ''}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.verified_outlined),
                        tooltip: 'التحقق من السلامة (SHA-256)',
                        onPressed: () => _verifyInstalled(pkg),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'حذف',
                        onPressed: () => _delete(pkg),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const _SectionTitle('المكتبة الموسعة — تجهيز فقط'),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'الكتب التالية قيد التجهيز: لم تُستورد بياناتها ولم تُتحقق '
                'بعد، فلا تظهر مكتملة ولا يوجد لها زر تنزيل. تُضاف حزمة '
                'منها هنا فقط بعد استيراد موثّق وبيان حزمة صالح '
                '(ملف قاعدة + manifest + SHA-256 + ترخيص المصدر).',
                style: TextStyle(color: SunnatiColors.inkMuted),
              ),
            ),
          ),
          ...extendedLibraries.map(
            (entry) => Card(
              child: ListTile(
                leading: Icon(
                  entry.isBook ? Icons.book_outlined : Icons.folder_outlined,
                ),
                title: Text(entry.name),
                subtitle: Text(
                  entry.author.isNotEmpty
                      ? '${entry.author}\n$extendedLibraryPreparingLabel'
                      : extendedLibraryPreparingLabel,
                ),
                isThreeLine: entry.author.isNotEmpty,
                trailing: const Chip(
                  label: Text('قيد التجهيز'),
                  backgroundColor: SunnatiColors.goldSoft,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'التنزيل اختياري للمكتبات الموسعة فقط. المكتبة الأساسية '
            'مضمّنة في التطبيق وتعمل دون إنترنت.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SunnatiColors.inkMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

/// Card for a real, available package: size, source, licence, progress,
/// download / pause / resume. Shown only when a verified manifest
/// exists — never for a "preparing" library.
class _AvailablePackageCard extends StatelessWidget {
  const _AvailablePackageCard({
    required this.pkg,
    required this.activeProgress,
    required this.onDownload,
    required this.onPause,
  });

  final DownloadedLibrary pkg;
  final DownloadProgress? activeProgress;
  final VoidCallback onDownload;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    final progress = activeProgress;
    final downloading =
        progress != null && progress.status == DownloadStatus.downloading;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pkg.name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '${pkg.version} — ${pkg.sizeLabel}'
              '${pkg.source.isNotEmpty ? '\nالمصدر: ${pkg.source}' : ''}'
              '${pkg.license.isNotEmpty ? '\nالترخيص: ${pkg.license}' : ''}',
              style: const TextStyle(color: SunnatiColors.inkMuted),
            ),
            if (progress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress.fraction),
              const SizedBox(height: 4),
              Text(
                '${formatBytes(progress.receivedBytes)} من '
                '${formatBytes(progress.totalBytes)}',
                style: const TextStyle(color: SunnatiColors.inkMuted),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: downloading ? null : onDownload,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(
                    pkg.downloadedBytes > 0 ? 'استكمال التنزيل' : 'تنزيل',
                  ),
                ),
                if (downloading) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: onPause,
                    icon: const Icon(Icons.pause_outlined),
                    label: const Text('إيقاف مؤقت'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
