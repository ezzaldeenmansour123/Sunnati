import 'package:flutter/material.dart';

import '../data/database.dart';
import '../models/hadith.dart';
import 'widgets/empty_library.dart';

/// Commentaries screen (الشروح) — Phase 1.
///
/// Shows the transmitted commentary attached to [hadith] when the source
/// provides one (HadeethEnc only in Phase 1), with its source. The classic
/// commentaries (فتح الباري، شرح النووي، عون المعبود…) are not imported
/// yet — each needs a documented, licensed digital source (Phase 5) — so
/// the screen lists them as "not imported yet" rather than showing text
/// from an unverified copy.
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
