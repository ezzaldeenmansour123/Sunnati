import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../core/package_manifest.dart';
import '../core/theme.dart';
import '../data/database.dart';
import '../data/download_manager.dart';
import '../models/downloaded_library.dart';

/// Reusable core-library download card — recovery path only (embed
/// 2026-11-26, owner decision 16:54).
///
/// Used by the recovery first-run screen (FirstRunDownloadScreen) and
/// embedded in DownloadsScreen when the core library is missing. The
/// library is normally EMBEDDED in the APK; this card downloads the
/// library-v1 copy only when the embedded install failed. One flow,
/// one set of honest states:
///
///   * metadata: fetch the published SHA-256 (+ size via HEAD) first —
///     the download never starts on an unverified hash;
///   * downloading: progress bar + bytes, pause (partial kept) / resume
///     via HTTP Range, retry after any failure;
///   * verifying: SHA-256 (streaming, in the downloader) + SQLite
///     header / quick_check / hadith count (see
///     [SunnatiDatabase.verifyLibraryFile]) — success is reported ONLY
///     after both pass, never on download completion alone;
///   * offline: a [SocketException] is reported as "no internet" in
///     plain Arabic, never as a crash and never as a false success.
///
/// The card never navigates by itself: it reports success through
/// [onInstalled] and the caller re-opens the database.
class LibraryDownloadCard extends StatefulWidget {
  const LibraryDownloadCard({super.key, required this.onInstalled});

  /// Called after the library is downloaded, verified and recorded in
  /// the downloads registry. The caller must re-open the database
  /// (e.g. re-run boot) before showing library content.
  final VoidCallback onInstalled;

  @override
  State<LibraryDownloadCard> createState() => _LibraryDownloadCardState();
}

enum _CardPhase { checking, ready, downloading, verifying, error }

class _LibraryDownloadCardState extends State<LibraryDownloadCard> {
  _CardPhase _phase = _CardPhase.checking;
  String? _sha256;
  int? _totalBytes;
  String? _error;
  String? _notice;
  DownloadProgress? _progress;
  bool _cancelled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fetchMetadata();
  }

  Future<File> _targetFile() async {
    final dir = await getApplicationSupportDirectory();
    return SunnatiDatabase.installedLibraryFile(dir);
  }

  Future<void> _fetchMetadata() async {
    setState(() {
      _phase = _CardPhase.checking;
      _error = null;
    });
    try {
      final hash =
          await fetchRemoteSha256(Uri.parse(kLibraryPackage.sha256Url));
      final size =
          await fetchRemoteContentLength(Uri.parse(kLibraryPackage.url));
      if (!mounted) return;
      setState(() {
        _sha256 = hash;
        _totalBytes = size;
        _phase = _CardPhase.ready;
      });
    } on PackageException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _CardPhase.error;
        _error = e.message;
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _phase = _CardPhase.error;
        _error = 'لا يوجد اتصال بالإنترنت — تحقق من الاتصال ثم أعد المحاولة.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _CardPhase.error;
        _error = 'تعذّر الوصول إلى خادم التنزيل: $e';
      });
    }
  }

  Future<void> _startDownload() async {
    final hash = _sha256;
    if (hash == null || _busy) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
      _notice = null;
      _phase = _CardPhase.downloading;
    });
    try {
      final target = await _targetFile();
      final received = await downloadSingleFile(
        url: Uri.parse(kLibraryPackage.url),
        target: target,
        expectedSha256: hash,
        expectedTotalBytes: _totalBytes,
        shouldCancel: () => _cancelled,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _progress = progress;
            if (progress.status == DownloadStatus.verifying) {
              _phase = _CardPhase.verifying;
            }
          });
        },
      );
      if (!mounted) return;
      setState(() => _phase = _CardPhase.verifying);
      final valid = await SunnatiDatabase.verifyLibraryFile(target);
      if (!valid) {
        setState(() {
          _busy = false;
          _phase = _CardPhase.error;
          _error = 'نُزّلت المكتبة لكن فشل فحص سلامتها — احذف الملف '
              'وأعد التنزيل من البداية.';
        });
        return;
      }
      await _recordInstalledRow(received);
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onInstalled();
    } on DownloadPausedException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _phase = _CardPhase.ready;
        _notice = 'تم الإيقاف مؤقتاً — الاستكمال يبدأ من حيث توقفت.';
      });
    } on PackageException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _phase = _CardPhase.error;
        _error = e.message;
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _phase = _CardPhase.error;
        _error = 'انقطع الاتصال بالإنترنت أثناء التنزيل — التنزيل الجزئي '
            'محفوظ، ويمكن الاستكمال عند عودة الاتصال.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _phase = _CardPhase.error;
        _error = 'تعذّر التنزيل: $e';
      });
    }
  }

  /// Record the verified download in `downloaded_libraries` (real hash
  /// + real size + real manifest). Best-effort: a registry failure
  /// never turns a verified install into a reported failure.
  Future<void> _recordInstalledRow(int receivedBytes) async {
    try {
      final hash = _sha256;
      if (hash == null) return;
      final total = _totalBytes ?? receivedBytes;
      final manifest = buildLibraryManifest(
        package: kLibraryPackage,
        sha256: hash,
        sizeBytes: total,
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      final db = await SunnatiDatabase.open();
      final now = DateTime.now().toUtc().toIso8601String();
      db.upsertDownloadedLibrary(
        DownloadedLibrary(
          id: 0,
          libraryId: kLibraryPackage.id,
          name: kLibraryPackage.displayName,
          version: '1.0.0',
          sizeBytes: receivedBytes,
          sha256: hash,
          status: 'installed',
          installedAt: now,
          source: 'quranlab/hadith',
          license: '',
          downloadUrl: kLibraryPackage.url,
          totalBytes: total,
          downloadedBytes: receivedBytes,
          manifestJson: manifest.toJsonString(),
          updatedAt: now,
        ),
      );
      db.close();
    } catch (_) {
      // Registry bookkeeping must never fail a verified install.
    }
  }

  Future<void> _deleteLocalFiles() async {
    final target = await _targetFile();
    final partial = File('${target.path}.part');
    try {
      if (await partial.exists()) await partial.delete();
    } catch (_) {}
    try {
      if (await target.exists()) await target.delete();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final downloading = _phase == _CardPhase.downloading;
    final received = progress?.receivedBytes ?? 0;
    final total = _totalBytes ?? progress?.totalBytes ?? 0;
    final resumed = received > 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              kLibraryPackage.displayName,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'المكتبة الأساسية (الكتب التسعة) مضمّنة في التطبيق عادةً؛ '
              'هذا التنزيل للاسترداد فقط عند تعذّر التثبيت من النسخة '
              'المضمّنة. بعد التنزيل تعمل دون إنترنت. يُفضَّل الاتصال '
              'بشبكة Wi-Fi لأن حجمها كبير.',
              style: TextStyle(color: SunnatiColors.inkMuted),
            ),
            const SizedBox(height: 8),
            if (_totalBytes != null)
              Text(
                'الحجم: ${formatBytes(_totalBytes!)}',
                style: const TextStyle(color: SunnatiColors.inkMuted),
              ),
            if (_notice != null) ...[
              const SizedBox(height: 8),
              Text(_notice!),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_phase == _CardPhase.checking) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text(
                'جارٍ الاتصال بخادم التنزيل…',
                style: TextStyle(color: SunnatiColors.inkMuted),
              ),
            ],
            if (progress != null &&
                (_phase == _CardPhase.downloading ||
                    _phase == _CardPhase.verifying)) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress.fraction),
              const SizedBox(height: 4),
              Text(
                total > 0
                    ? '${formatBytes(received)} من ${formatBytes(total)}'
                    : formatBytes(received),
                style: const TextStyle(color: SunnatiColors.inkMuted),
              ),
              if (_phase == _CardPhase.verifying)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('جارٍ التحقق من سلامة المكتبة…'),
                ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_phase == _CardPhase.ready ||
                    _phase == _CardPhase.error)
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _startDownload,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(resumed ? 'استكمال التنزيل' : 'تنزيل المكتبة'),
                  ),
                if (downloading)
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _cancelled = true),
                    icon: const Icon(Icons.pause_outlined),
                    label: const Text('إيقاف مؤقت'),
                  ),
                if (_phase == _CardPhase.error) ...[
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _fetchMetadata,
                    icon: const Icon(Icons.refresh_outlined),
                    label: const Text('إعادة المحاولة'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            await _deleteLocalFiles();
                            if (!mounted) return;
                            setState(() {
                              _progress = null;
                              _notice = 'حُذفت الملفات الجزئية — '
                                  'سيبدأ التنزيل من البداية.';
                            });
                            await _fetchMetadata();
                          },
                    child: const Text('حذف الجزئي والبدء من جديد'),
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
