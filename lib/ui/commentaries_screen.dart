import 'package:material_ui/material_ui.dart';

import '../data/database.dart';
import '../models/hadith.dart';
import 'search_screen.dart';
import 'widgets/empty_library.dart';

/// Commentaries screen (الشروح) — Phase 1.
///
/// Shows the transmitted commentary attached to [hadith] when the source
/// provides one (HadeethEnc only in Phase 1), with its source. The classic
/// commentaries (فتح الباري، شرح النووي، عون المعبود…) are not imported
/// yet — each needs a documented, licensed digital source (Phase 5) — so
/// the screen lists them as "not imported yet" rather than showing text
/// from an unverified copy.
///
/// VERIFIED 2026-11-26 (Worker D, read-only SQLite on assets/sunnati.db):
/// the 3,574 HadeethEnc rows in the `commentaries` table are NOT attached
/// to any hadith on this screen — and that is by design, not a broken
/// query. `hadiths.expl` is empty on all 65,712 rows, and every
/// `commentaries.hadith_key` is `hadeethenc:<id>` (0 of 3,574 match any
/// `book:num` stable id), so no reliable key exists to present one of
/// those rows as THE commentary of this hadith. They ARE reachable
/// elsewhere with their own identity: advanced search, scope «الشروح»
/// (`SunnatiDatabase.searchCommentariesFts`, via `commentaries_fts`),
/// and the assistant's RAG (`allCommentaries()`). This screen therefore
/// shows the live count and the real path to them instead of implying
/// that no commentary exists. A verified text-match link table is a
/// data decision for a later phase — it must never be improvised here
/// by matching similar titles.
class CommentariesScreen extends StatelessWidget {
  const CommentariesScreen({super.key, required this.db, required this.hadith});

  final SunnatiDatabase db;
  final Hadith hadith;

  static const List<String> _plannedCommentaries = <String>[
    'فتح الباري — صحيح البخاري',
    'شرح النووي — صحيح مسلم',
    'عون المعبود — سنن أبي داود',
    'تحفة الأحوذي — جامع الترمذي',
    'حاشية السندي — النسائي وابن ماجه والدارمي وأحمد',
    'المنتقى — موطأ مالك',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('شروح الحديث')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'حديث ${hadith.num} — ${hadith.chapterTitle}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (hadith.hasExplanation) ...[
                    Text(hadith.explanation, style: const TextStyle(height: 1.8)),
                    const SizedBox(height: 6),
                    Text(
                      'المصدر: ${hadith.explanationSource}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ] else
                    const Text('لا يوجد شرح منقول لهذا الحديث بعد.'),
                ],
              ),
            ),
          ),
          // HadeethEnc commentaries: real rows exist (live count), but
          // they are standalone passages keyed hadeethenc:<id> and are
          // deliberately NOT presented as the commentary of this
          // hadith — no reliable link key exists (see class doc).
          // They are searchable from البحث, scope «الشروح», and quoted
          // by the assistant with their own attribution.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'شروح موسوعة الحديث (HadeethEnc): ${db.commentaryCount()} شرحاً',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'هذه الشروح مقاطع مستقلة بمفاتيحها الخاصة، وليست مربوطة بهذا الحديث '
                    'بعينها، لذلك لا تظهر هنا كشرحٍ له. ابحث فيها من شاشة البحث '
                    '(نطاق «الشروح») أو اسأل عنها المساعد.',
                    style: TextStyle(height: 1.7),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SearchScreen(db: db),
                      ),
                    ),
                    child: const Text('ابحث في الشروح'),
                  ),
                ],
              ),
            ),
          ),
          const EmptyLibraryCard(
            title: 'الشروح الكلاسيكية غير مستوردة بعد',
            detail:
                'الشروح الكلاسيكية تحتاج مصدراً رقمياً موثقاً ومرخّصاً لكل شرح (المرحلة 5). القائمة أدناه هي خطة الاستيراد — وليست محتوى متوفراً.',
            icon: Icons.menu_book_outlined,
          ),
          ..._plannedCommentaries.map(
            (name) => Card(
              child: ListTile(
                leading: const Icon(Icons.book_outlined),
                title: Text(name),
                subtitle: const Text('قيد التخطيط — غير مستورد بعد'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
