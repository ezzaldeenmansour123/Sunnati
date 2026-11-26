/// Narrator card page — mockup screen 6 (بطاقة الراوي).
///
/// Layout follows the mockup exactly: silhouette avatar, pink name pill,
/// then the fields card (الكنية / النسب / الطبقة / الوفاة / الحالة),
/// then شيوخه / تلاميذه / أقوال العلماء فيه / المصادر, then his linked
/// hadiths. CONTENT stays strictly the verified database rows: a field
/// with no recorded value shows an honest muted
/// «لا توجد بيانات موثقة بعد» line — the mockup's example teachers,
/// students and nisba are illustrative only and are never copied as data.
/// Teachers/students shown here are derived ONLY from verified chains
/// (see [SunnatiDatabase.teachersOfNarrator]); when the derivation
/// returns nothing the honest line is shown instead.
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/hadith.dart';
import '../models/narrator.dart';
import 'hadith_reader_screen.dart';
import 'widgets/empty_library.dart';
import 'widgets/sunnati_bottom_nav.dart';

class NarratorDetailScreen extends StatefulWidget {
  const NarratorDetailScreen({
    super.key,
    required this.db,
    required this.narratorId,
  });

  final SunnatiDatabase db;
  final int narratorId;

  @override
  State<NarratorDetailScreen> createState() => _NarratorDetailScreenState();
}

class _NarratorDetailScreenState extends State<NarratorDetailScreen> {
  late final Narrator? _narrator;
  late final List<NarratorSaying> _sayings;
  late final List<Narrator> _teachers;
  late final List<Narrator> _students;
  late final List<Hadith> _hadiths;

  @override
  void initState() {
    super.initState();
    _narrator = widget.db.narratorById(widget.narratorId);
    _sayings = widget.db.narratorSayings(widget.narratorId);
    _teachers = widget.db.teachersOfNarrator(widget.narratorId);
    _students = widget.db.studentsOfNarrator(widget.narratorId);
    _hadiths = widget.db.hadithsForNarrator(widget.narratorId);
  }

  Future<void> _openHadith(Hadith hadith) async {
    final repo = await UserRepository.load();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HadithReaderScreen(
          db: widget.db,
          userRepo: repo,
          hadith: hadith,
        ),
      ),
    );
  }

  void _openNarrator(int id) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NarratorDetailScreen(db: widget.db, narratorId: id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = _narrator;
    if (n == null) {
      // When the narrators package is held back pending approval, the
      // empty state names that reason instead of looking like a bug.
      final heldBack = !widget.db.narratorsAvailable;
      return Scaffold(
        appBar: AppBar(title: const Text('بطاقة الراوي')),
        // Shared bottom nav (mockup screen 6: الرئيسية active).
        bottomNavigationBar: SunnatiBottomNav(
          currentIndex: 2,
          onTap: (index) => sunnatiGoToTab(context, index),
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            EmptyLibraryCard(
              title: heldBack
                  ? 'حزمة الرواة قيد انتظار الموافقة'
                  : 'لم تتوفر ترجمة موثّقة',
              detail: heldBack
                  ? 'حالة هذا الراوي غير متاحة بعد — حزمة الرواة قيد انتظار الموافقة ولم تُثبَّت بعد.'
                  : 'لا يوجد راوٍ بهذا المعرف في المكتبة المثبّتة — تراجم الرواة قيد الاستيراد في المرحلة 5.',
              icon: Icons.person_outline,
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('بطاقة الراوي')),
      // Shared bottom nav (mockup screen 6: الرئيسية active). Tapping a
      // tab replaces the stack with a fresh shell on that tab — see
      // `sunnatiGoToTab`.
      bottomNavigationBar: SunnatiBottomNav(
        currentIndex: 2,
        onTap: (index) => sunnatiGoToTab(context, index),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Silhouette avatar (no photo exists) + pink name pill,
          // exactly as the mockup's narrator card header.
          Center(
            child: Column(
              children: [
                const SizedBox(height: 8),
                const CircleAvatar(
                  radius: 46,
                  backgroundColor: SunnatiColors.blush,
                  child: Icon(
                    Icons.person,
                    size: 58,
                    color: SunnatiColors.petrol,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: SunnatiColors.blush,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    n.displayName,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: SunnatiColors.petrol,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Fields card — only values the database actually records.
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              child: Column(
                children: [
                  _FieldRow(
                    'الكنية',
                    n.kunya.isNotEmpty ? n.kunya : null,
                  ),
                  _FieldRow(
                    'النسب',
                    n.lineage.isNotEmpty ? n.lineage : null,
                  ),
                  _FieldRow(
                    'الطبقة',
                    n.tier.isNotEmpty ? n.tier : null,
                  ),
                  _FieldRow(
                    'الوفاة',
                    n.hasDeath ? '${n.deathYearHijri} هـ' : null,
                  ),
                  _FieldRow(
                    'الحالة',
                    n.hasStatus
                        ? canonicalGradeLabel(n.status)
                        : null,
                    valueSuffix: n.hasStatus && n.statusSource.isNotEmpty
                        ? '(${n.statusSource})'
                        : null,
                  ),
                ],
              ),
            ),
          ),
          const _SectionTitle('شيوخه', Icons.people_outline),
          if (_teachers.isEmpty)
            const _HonestEmpty('لا توجد بيانات موثقة بعد.')
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _teachers
                  .map(
                    (t) => ActionChip(
                      label: Text(t.displayName),
                      onPressed: () => _openNarrator(t.id),
                    ),
                  )
                  .toList(),
            ),
          const _SectionTitle('تلاميذه', Icons.people_outline),
          if (_students.isEmpty)
            const _HonestEmpty('لا توجد بيانات موثقة بعد.')
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _students
                  .map(
                    (t) => ActionChip(
                      label: Text(t.displayName),
                      onPressed: () => _openNarrator(t.id),
                    ),
                  )
                  .toList(),
            ),
          const _SectionTitle('أقوال العلماء فيه', Icons.menu_book_outlined),
          if (n.isDisputed)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'مختلف فيه — الأقوال أدناه متعارضة وتُعرض كما وردت دون ترجيح حكم واحد.',
                style: TextStyle(color: SunnatiColors.inkMuted),
              ),
            ),
          if (_sayings.isEmpty)
            const _HonestEmpty('لا توجد أقوال موثقة بعد.')
          else
            ..._sayings.map(
              (s) => Card(
                child: ListTile(
                  title: Text('${s.scholar}: ${s.text}'),
                  subtitle: s.hasSource
                      ? Text('المصدر: ${s.source}')
                      : const Text('المصدر غير مسجّل'),
                ),
              ),
            ),
          const _SectionTitle('المصادر', Icons.source_outlined),
          if (n.statusSource.isEmpty && n.biographySource.isEmpty)
            const _HonestEmpty('لا توجد بيانات موثقة بعد.')
          else ...[
            if (n.statusSource.isNotEmpty)
              _FieldRow('مصدر الحكم', n.statusSource),
            if (n.biographySource.isNotEmpty)
              _FieldRow('مصدر الترجمة', n.biographySource),
          ],
          _SectionTitle(
            'أحاديثه المرتبطة (${_hadiths.length})',
            Icons.library_books_outlined,
          ),
          if (_hadiths.isEmpty)
            const _HonestEmpty(
              'لا توجد أحاديث مرتبطة به بعد — تُربط الأحاديث بالرواة من الأسانيد الموثّقة فقط.',
            )
          else
            ..._hadiths.map(
              (h) => Card(
                child: ListTile(
                  title: Text(
                    h.text.length > 120
                        ? '${h.text.substring(0, 120)}…'
                        : h.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('حديث ${h.num} — ${h.chapterTitle}'),
                  onTap: () => _openHadith(h),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One field row of the card: label on the right, value on the left.
/// A null [value] renders the honest muted line instead of an invention.
class _FieldRow extends StatelessWidget {
  const _FieldRow(this.label, this.value, {this.valueSuffix});

  final String label;
  final String? value;
  final String? valueSuffix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label:',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: SunnatiColors.petrol,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: value == null
                ? const Text(
                    'لا توجد بيانات موثقة بعد.',
                    style: TextStyle(color: SunnatiColors.inkMuted),
                    textAlign: TextAlign.end,
                  )
                : Text(
                    valueSuffix == null
                        ? value!
                        : '$value $valueSuffix',
                    textAlign: TextAlign.end,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Honest muted line for a section with no verified data.
class _HonestEmpty extends StatelessWidget {
  const _HonestEmpty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: const TextStyle(color: SunnatiColors.inkMuted),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, this.icon);

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: SunnatiColors.gold),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
