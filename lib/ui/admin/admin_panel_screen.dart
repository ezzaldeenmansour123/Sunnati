import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../core/admin_pin.dart';
import '../../core/theme.dart';
import '../../data/admin_repository.dart';
import '../../data/database.dart';
import '../../data/import_validator.dart';
import '../../data/user_repository.dart';
import '../../models/admin_record.dart';

/// Admin panel (master prompt §15, Phase 8).
///
/// Tabs: overview, review queue, import, quality, packages, audit log,
/// settings. Rules enforced by the panel (not just documented):
///
///   * Every submission is validated first and staged as
///     `pending_review`; nothing staged is published to a production
///     table by this panel. Approving a *book definition* inserts only
///     its metadata row (cnt=0). Approving anything else only flips the
///     review status — the merge into the library tables is the
///     verified import pipeline (Phase 9).
///   * Every action writes an audit row (who / what / source / when).
///   * The audit log is read-only here: no edit or delete action exists.
///   * No API key or secret appears anywhere in the panel or the APK.
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({
    super.key,
    required this.db,
    required this.userRepo,
    required this.pinStore,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final AdminPinStore pinStore;

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  late final AdminRepository _admin;
  Map<String, int> _stats = const <String, int>{};
  List<StagedRecord> _staging = const <StagedRecord>[];
  List<AuditEntry> _audit = const <AuditEntry>[];
  int _stagingOffset = 0;
  int _auditOffset = 0;
  bool _stagingHasMore = false;
  bool _auditHasMore = false;
  String _stagingFilter = '';

  final _importController = TextEditingController();
  String _importFormat = 'json';
  String _csvKind = 'narrator';
  String _importResult = '';

  final _bookIdController = TextEditingController();
  final _bookNameController = TextEditingController();
  final _bookAuthorController = TextEditingController();
  final _bookSourceController = TextEditingController();
  final _bookLicenseController = TextEditingController();

  String _qualityResult = '';

  @override
  void initState() {
    super.initState();
    _admin = AdminRepository(widget.db, widget.userRepo);
    _refreshAll();
  }

  @override
  void dispose() {
    _importController.dispose();
    _bookIdController.dispose();
    _bookNameController.dispose();
    _bookAuthorController.dispose();
    _bookSourceController.dispose();
    _bookLicenseController.dispose();
    super.dispose();
  }

  void _refreshAll() {
    _stagingOffset = 0;
    _auditOffset = 0;
    _loadStats();
    _loadStaging(reset: true);
    _loadAudit(reset: true);
  }

  void _loadStats() {
    setState(() => _stats = _admin.stats());
  }

  void _loadStaging({required bool reset}) {
    final offset = reset ? 0 : _stagingOffset;
    final page = widget.db.stagingList(
      status: _stagingFilter.isEmpty ? null : _stagingFilter,
      limit: 20,
      offset: offset,
    );
    setState(() {
      _staging = reset ? page : <StagedRecord>[..._staging, ...page];
      _stagingOffset = offset + page.length;
      _stagingHasMore = page.length == 20;
    });
  }

  void _loadAudit({required bool reset}) {
    final offset = reset ? 0 : _auditOffset;
    final page = widget.db.auditList(limit: 20, offset: offset);
    setState(() {
      _audit = reset ? page : <AuditEntry>[..._audit, ...page];
      _auditOffset = offset + page.length;
      _auditHasMore = page.length == 20;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _review(StagedRecord record, bool approve) async {
    var note = '';
    if (!approve) {
      note = await _askNote() ?? '';
      if (!mounted) return;
      if (note.trim().isEmpty) {
        _snack('الرفض يحتاج سبباً يُسجَّل في التدقيق.');
        return;
      }
    }
    final ok = await _admin.reviewStaged(
      record.id,
      approve: approve,
      note: note,
    );
    if (!mounted) return;
    _snack(
      ok
          ? approve
              ? 'تم الاعتماد بعد المراجعة وسُجّل في التدقيق.'
              : 'تم الرفض وسُجّل في التدقيق.'
          : 'تعذّرت المراجعة — قد يكون السجل رُوجع من قبل.',
    );
    _refreshAll();
  }

  Future<String?> _askNote() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('سبب الرفض'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'يُسجَّل في سجل التدقيق',
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('تأكيد الرفض'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _stageImport() async {
    final text = _importController.text;
    if (text.trim().isEmpty) {
      setState(() => _importResult = 'الصق ملف JSON أو CSV أولاً.');
      return;
    }
    final (ids, validation) = await _admin.stageDocument(
      text,
      isCsv: _importFormat == 'csv',
      csvKind: _csvKind,
    );
    if (!mounted) return;
    setState(() {
      _importResult = validation.ok
          ? 'تم قبول ${validation.recordCount} سجلاً وحفظها «قيد المراجعة» '
              '(أرقام: ${ids.join('، ')}). لم يُنشر شيء في المكتبة.'
          : 'رُفض الملف — لم يُحفظ شيء:\n${validation.errors.join('\n')}';
    });
    if (validation.ok) {
      _importController.clear();
      _refreshAll();
    }
  }

  Future<void> _defineBook() async {
    final record = <String, Object?>{
      'id': _bookIdController.text.trim(),
      'name': _bookNameController.text.trim(),
      'author': _bookAuthorController.text.trim(),
      'source': _bookSourceController.text.trim(),
      'license': _bookLicenseController.text.trim(),
    };
    final (id, validation) = await _admin.stageRecord(
      'book',
      record,
      record['source'].toString(),
    );
    if (!mounted) return;
    if (id < 0) {
      _snack('تعريف الكتاب مرفوض:\n${validation.errors.join('\n')}');
      return;
    }
    _snack('حُفظ تعريف الكتاب «قيد المراجعة» (رقم $id) — راجعه من تبويب المراجعة.');
    for (final c in <TextEditingController>[
      _bookIdController,
      _bookNameController,
      _bookAuthorController,
      _bookSourceController,
      _bookLicenseController,
    ]) {
      c.clear();
    }
    _refreshAll();
  }

  void _runDuplicateCheck() {
    final lines = <String>[];
    for (final kind in kImportKinds) {
      final dups = _admin.duplicateCheck(kind);
      if (dups.isEmpty) continue;
      lines.add('$kind: ${dups.length} مكرر — ${dups.keys.join('، ')}');
    }
    setState(() {
      _qualityResult = lines.isEmpty
          ? 'لا تكرار بين السجلات المرحلية.'
          : 'تكرار مكتشف:\n${lines.join('\n')}';
    });
  }

  void _runMissingFieldsCheck() {
    final report = _admin.missingFieldsReport();
    setState(() {
      _qualityResult = report.isEmpty
          ? 'لا نواقص في السجلات المرحلية قيد المراجعة.'
          : 'نواقص:\n${report.map((r) => 'سجل ${r.$1}: ${r.$2.join('، ')}').join('\n')}';
    });
  }

  Future<void> _reindex() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إعادة فهرسة البحث؟'),
        content: const Text(
          'يُعاد بناء فهرس البحث النصي من قاعدة البيانات الحالية. '
          'عملية محلية آمنة تُسجَّل في التدقيق.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('إعادة الفهرسة'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _admin.rebuildSearchIndex();
    if (!mounted) return;
    _snack('تمت إعادة الفهرسة وسُجّلت في التدقيق.');
    _refreshAll();
  }

  Future<void> _changePin() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تغيير رمز الإدارة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'الرمز الحالي'),
            ),
            TextField(
              controller: next,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'الرمز الجديد'),
            ),
            TextField(
              controller: confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'تأكيد الجديد'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (result != true) return;
    if (next.text.trim() != confirm.text.trim()) {
      _snack('الرمزان الجديدان غير متطابقين.');
      return;
    }
    final error = pinSetupError(next.text.trim());
    if (error.isNotEmpty) {
      _snack(error);
      return;
    }
    final ok = await widget.pinStore.changePin(
      current.text.trim(),
      next.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      widget.db.auditInsert(action: 'pin_changed', detail: 'admin PIN changed');
      _snack('تم تغيير الرمز.');
      _refreshAll();
    } else {
      _snack('الرمز الحالي غير صحيح أو اللوحة مقفلة.');
    }
  }

  Future<void> _exportBackup() async {
    final json = _admin.exportBackup();
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    _snack('تم نسخ النسخة الاحتياطية إلى الحافظة.');
  }

  Future<void> _restoreBackup() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      _snack('الحافظة فارغة — انسخ نسخة احتياطية JSON أولاً.');
      return;
    }
    try {
      await _admin.restoreBackup(text);
      if (!mounted) return;
      _snack('تمت استعادة النسخة الاحتياطية.');
    } on FormatException catch (e) {
      _snack('تعذّرت الاستعادة: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('لوحة الإدارة'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'نظرة عامة'),
              Tab(text: 'المراجعة'),
              Tab(text: 'استيراد'),
              Tab(text: 'الجودة'),
              Tab(text: 'الحزم'),
              Tab(text: 'سجل التدقيق'),
              Tab(text: 'الإعدادات'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _overviewTab(),
            _reviewTab(),
            _importTab(),
            _qualityTab(),
            _packagesTab(),
            _auditTab(),
            _settingsTab(),
          ],
        ),
      ),
    );
  }

  Widget _overviewTab() {
    final stats = _stats;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'لوحة منفصلة عن واجهة المستخدم العادية. كل إدخال يبقى '
              '«قيد المراجعة» حتى يُراجَع — ولا يُنشر شيء غير مراجَع '
              'كمحتوى معتمد في المكتبة.',
              style: TextStyle(color: SunnatiColors.inkMuted),
            ),
          ),
        ),
        _statTile('سجلات قيد المراجعة', stats['staging_pending'] ?? 0),
        _statTile('سجلات معتمدة', stats['staging_approved'] ?? 0),
        _statTile('سجلات مرفوضة', stats['staging_rejected'] ?? 0),
        _statTile('صفوف سجل التدقيق', stats['audit_rows'] ?? 0),
        _statTile('حزم موسعة مثبّتة', stats['packages_installed'] ?? 0),
        _statTile('رواة في المكتبة', stats['narrators'] ?? 0),
        _statTile('أحاديث في المكتبة', stats['hadiths'] ?? 0),
      ],
    );
  }

  Widget _statTile(String label, int value) {
    return Card(
      child: ListTile(
        title: Text(label),
        trailing: Text(
          '$value',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
    );
  }

  Widget _reviewTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: DropdownButton<String>(
            value: _stagingFilter,
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: '', child: Text('كل الحالات')),
              DropdownMenuItem(
                value: ReviewStatus.pending,
                child: Text('قيد المراجعة فقط'),
              ),
              DropdownMenuItem(
                value: ReviewStatus.approved,
                child: Text('معتمدة'),
              ),
              DropdownMenuItem(
                value: ReviewStatus.rejected,
                child: Text('مرفوضة'),
              ),
            ],
            onChanged: (v) {
              setState(() => _stagingFilter = v ?? '');
              _loadStaging(reset: true);
            },
          ),
        ),
        Expanded(
          child: _staging.isEmpty
              ? const Center(child: Text('لا توجد سجلات مرحلية.'))
              : ListView.builder(
                  itemCount: _staging.length + (_stagingHasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _staging.length) {
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: ElevatedButton(
                          onPressed: () => _loadStaging(reset: false),
                          child: const Text('عرض المزيد'),
                        ),
                      );
                    }
                    final record = _staging[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${record.kind} — ${record.identityLabel}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'الحالة: ${ReviewStatus.label(record.reviewStatus)}'
                              ' — المصدر: ${record.source}'
                              ' — ${record.submittedAt}',
                              style: const TextStyle(
                                color: SunnatiColors.inkMuted,
                              ),
                            ),
                            if (record.reviewNote.isNotEmpty)
                              Text('ملاحظة المراجعة: ${record.reviewNote}'),
                            if (record.isPending)
                              Row(
                                children: [
                                  ElevatedButton(
                                    onPressed: () => _review(record, true),
                                    child: const Text('اعتماد'),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: () => _review(record, false),
                                    child: const Text('رفض'),
                                  ),
                                ],
                              ),
                            if (record.kind != 'book' &&
                                record.reviewStatus ==
                                    ReviewStatus.approved)
                              const Text(
                                'معتمدة بعد المراجعة — الدمج في جداول '
                                'المكتبة يتم عبر خط الاستيراد الموثّق '
                                '(المرحلة 9)، وليس من هذه اللوحة.',
                                style: TextStyle(
                                  color: SunnatiColors.inkMuted,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _importTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text(
          'استيراد JSON/CSV — يُتحقق من الملف أولاً (بنية + حجم + محتوى '
          'مشبوه)، والمقبول منه يُحفظ «قيد المراجعة» فقط.',
          style: TextStyle(color: SunnatiColors.inkMuted),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButton<String>(
                value: _importFormat,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'json', child: Text('JSON')),
                  DropdownMenuItem(value: 'csv', child: Text('CSV')),
                ],
                onChanged: (v) => setState(() => _importFormat = v ?? 'json'),
              ),
            ),
            if (_importFormat == 'csv') ...[
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  value: _csvKind,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'book', child: Text('كتاب')),
                    DropdownMenuItem(
                      value: 'commentary',
                      child: Text('شرح'),
                    ),
                    DropdownMenuItem(value: 'narrator', child: Text('راوٍ')),
                    DropdownMenuItem(value: 'grade', child: Text('حكم')),
                    DropdownMenuItem(value: 'source', child: Text('مصدر')),
                  ],
                  onChanged: (v) => setState(() => _csvKind = v ?? 'narrator'),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _importController,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText: 'الصق محتوى ملف JSON أو CSV هنا…',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: _stageImport,
          child: const Text('تحقق واحفظ للمراجعة'),
        ),
        if (_importResult.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_importResult),
            ),
          ),
        ],
        const SizedBox(height: 20),
        const Text(
          'تعريف كتاب (بيانات وصفية فقط — بلا محتوى حديثي)',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _bookIdController,
          decoration: const InputDecoration(labelText: 'المعرف (a-z, 0-9, _ , -)'),
        ),
        TextField(
          controller: _bookNameController,
          decoration: const InputDecoration(labelText: 'اسم الكتاب'),
        ),
        TextField(
          controller: _bookAuthorController,
          decoration: const InputDecoration(labelText: 'المؤلف'),
        ),
        TextField(
          controller: _bookSourceController,
          decoration: const InputDecoration(labelText: 'المصدر'),
        ),
        TextField(
          controller: _bookLicenseController,
          decoration: const InputDecoration(labelText: 'الترخيص'),
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: _defineBook,
          child: const Text('حفظ التعريف للمراجعة'),
        ),
      ],
    );
  }

  Widget _qualityTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text(
          'اختبارات جودة على السجلات المرحلية وقاعدة البيانات — النتائج '
          'تظهر هنا وتُسجَّل إعادة الفهرسة في التدقيق.',
          style: TextStyle(color: SunnatiColors.inkMuted),
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: _runDuplicateCheck,
          child: const Text('كشف التكرار في السجلات المرحلية'),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _runMissingFieldsCheck,
          child: const Text('فحص النواقص (حقول مطلوبة مفقودة)'),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _reindex,
          child: const Text('إعادة فهرسة البحث (FTS5)'),
        ),
        if (_qualityResult.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_qualityResult),
            ),
          ),
        ],
      ],
    );
  }

  Widget _packagesTab() {
    final packages = widget.db.downloadedLibraries();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'إصدار حزمة جديدة يتم بأداة سطح المكتب '
              'tools/build_package.py من ملف قاعدة موثّق — وليس من داخل '
              'التطبيق. هنا: عرض الحزم المعروفة وإعادة إصدار بيانها بعد '
              'التحقق من سلامتها.',
              style: TextStyle(color: SunnatiColors.inkMuted),
            ),
          ),
        ),
        if (packages.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('لا توجد حزم موسعة معروفة بعد — المكتبة الموسعة قيد التجهيز.'),
            ),
          ),
        ...packages.map(
          (pkg) => Card(
            child: ListTile(
              title: Text(pkg.name),
              subtitle: Text(
                '${pkg.libraryId} ${pkg.version} — ${pkg.status}'
                ' — ${pkg.sizeLabel}',
              ),
              trailing: pkg.manifestJson.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.copy_outlined),
                      tooltip: 'نسخ البيان (manifest)',
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: pkg.manifestJson),
                        );
                        widget.db.auditInsert(
                          action: 'package_exported',
                          entityType: 'package',
                          entityId: pkg.libraryId,
                          detail: 'manifest re-exported for '
                              '${pkg.libraryId} ${pkg.version}',
                        );
                        _snack('تم نسخ بيان الحزمة.');
                        _refreshAll();
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _auditTab() {
    return _audit.isEmpty
        ? const Center(child: Text('سجل التدقيق فارغ بعد.'))
        : ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _audit.length + (_auditHasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _audit.length) {
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: ElevatedButton(
                    onPressed: () => _loadAudit(reset: false),
                    child: const Text('عرض المزيد'),
                  ),
                );
              }
              final entry = _audit[index];
              return Card(
                child: ListTile(
                  title: Text(AuditEntry.actionLabel(entry.action)),
                  subtitle: Text(
                    '${entry.createdAt}'
                    '${entry.entityType.isNotEmpty ? ' — ${entry.entityType} ${entry.entityId}' : ''}'
                    '${entry.source.isNotEmpty ? ' — المصدر: ${entry.source}' : ''}'
                    '${entry.detail.isNotEmpty ? '\n${entry.detail}' : ''}',
                  ),
                ),
              );
            },
          );
  }

  Widget _settingsTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Column(
            children: [
              ListTile(
                title: const Text('تغيير رمز الإدارة'),
                trailing: const Icon(Icons.chevron_left),
                onTap: _changePin,
              ),
              ListTile(
                title: const Text('تصدير نسخة احتياطية (بيانات المستخدم)'),
                subtitle: const Text('تُنسخ إلى الحافظة وتُسجَّل في التدقيق'),
                trailing: const Icon(Icons.ios_share),
                onTap: _exportBackup,
              ),
              ListTile(
                title: const Text('استعادة نسخة احتياطية'),
                subtitle: const Text('من نص منسوخ في الحافظة — تُفحص قبل الاستبدال'),
                trailing: const Icon(Icons.file_download_outlined),
                onTap: _restoreBackup,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'النسخ الاحتياطي يخص بيانات المستخدم (مفضلة وملاحظات وسجل '
          'قراءة) فقط — لا يشمل قاعدة المكتبة ولا سجل التدقيق.',
          textAlign: TextAlign.center,
          style: TextStyle(color: SunnatiColors.inkMuted, fontSize: 12),
        ),
      ],
    );
  }
}
