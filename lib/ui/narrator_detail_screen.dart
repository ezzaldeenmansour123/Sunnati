/// Narrator detail page — Phase 5.
///
/// Full page for one narrator, built only from what the database records:
/// identity (name, kunya, laqab, lineage, generation, birth/death,
/// country), the jarh-wa-ta'dil verdict with its source, critics' sayings
/// each with its source (conflicting sayings shown as `مختلف فيه` without
/// a single imposed verdict), his teachers and students (derived from
/// verified chains), and his recorded hadiths. Every section that has no
/// data says so plainly.
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/hadith.dart';
import '../models/narrator.dart';
import 'hadith_reader_screen.dart';
import 'widgets/empty_library.dart';
import 'widgets/narrator_card.dart';

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
        appBar: AppBar(title: const Text('الراوي')),
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
      appBar: AppBar(title: Text(n.displayName)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          NarratorCard(
            db: widget.db,
            narrator: n,
            expanded: true,
            showOpenFullPage: false,
          ),
          const _SectionTitle('أقوال العلماء فيه'),
          if (_sayings.isEmpty)
            const Text(
              'لا توجد أقوال مسجّلة للعلماء فيه بعد.',
              style: TextStyle(color: SunnatiColors.inkMuted),
            )
          else ...[
            if (n.isDisputed)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'مختلف فيه — الأقوال أدناه متعارضة وتُعرض كما وردت دون ترجيح حكم واحد.',
                  style: TextStyle(color: SunnatiColors.inkMuted),
                ),
              ),
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
          ],
          const _SectionTitle('شيوخه'),
          if (_teachers.isEmpty)
            const Text(
              'لا يوجد شيوخ مسجّلون له بعد — تُستنتج الشيوخ من الأسانيد الموثّقة فقط.',
              style: TextStyle(color: SunnatiColors.inkMuted),
            )
          else
            Wrap(
              spacing: 8,
              children: _teachers
                  .map(
                    (t) => ActionChip(
                      label: Text(t.displayName),
                      onPressed: () => _openNarrator(t.id),
                    ),
                  )
                  .toList(),
            ),
          const _SectionTitle('تلاميذه'),
          if (_students.isEmpty)
            const Text(
              'لا يوجد تلاميذ مسجّلون له بعد — تُستنتج التلاميذ من الأسانيد الموثّقة فقط.',
              style: TextStyle(color: SunnatiColors.inkMuted),
            )
          else
            Wrap(
              spacing: 8,
              children: _students
                  .map(
                    (t) => ActionChip(
                      label: Text(t.displayName),
                      onPressed: () => _openNarrator(t.id),
                    ),
                  )
                  .toList(),
            ),
          _SectionTitle('أحاديثه المرتبطة (${_hadiths.length})'),
          if (_hadiths.isEmpty)
            const Text(
              'لا توجد أحاديث مرتبطة به بعد — تُربط الأحاديث بالرواة من الأسانيد الموثّقة فقط.',
              style: TextStyle(color: SunnatiColors.inkMuted),
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
          if (n.biographySource.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'مصدر الترجمة: ${n.biographySource}',
                style: const TextStyle(
                  color: SunnatiColors.inkMuted,
                  fontSize: 12,
                ),
              ),
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
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
