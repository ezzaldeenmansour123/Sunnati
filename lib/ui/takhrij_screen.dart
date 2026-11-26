import 'package:material_ui/material_ui.dart';

import '../core/text_compare.dart';
import '../core/theme.dart';
import '../data/database.dart';
import '../models/hadith.dart';
import '../models/takhrij.dart';
import 'widgets/empty_library.dart';

/// Takhrij lab (master prompt §11) — Phase 5.
///
/// Shows what the installed data actually supports for [hadith]: its book,
/// number, chapter and recorded gradings; its recorded routes (طرق) from
/// `hadith_variants` with the shared/differing wording shown side by side;
/// and its takhrij records from `takhrij` (other books reporting it).
///
/// The wording comparison is a mechanical token comparison of the stored
/// texts only. It never claims a defect (`علة`) or a legal effect — those
/// need a sourced note in the database, and the screen says so when none
/// is recorded. When the variant/takhrij tables are empty (Phase 5 import
/// pending) the screen says so and offers no fabricated comparison. When
/// opened without a hadith (from Home) it explains the same and asks the
/// user to pick a hadith first.
class TakhrijScreen extends StatelessWidget {
  const TakhrijScreen({super.key, required this.db, this.hadith});

  final SunnatiDatabase db;
  final Hadith? hadith;

  @override
  Widget build(BuildContext context) {
    final h = hadith;
    final variants =
        h == null ? const <HadithVariant>[] : db.variantsForHadith(h.id);
    final entries =
        h == null ? const <TakhrijEntry>[] : db.takhrijForHadith(h.id);
    return Scaffold(
      appBar: AppBar(title: const Text('مختبر التخريج')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (h == null)
            const EmptyLibraryCard(
              title: 'اختر حديثاً أولاً',
              detail:
                  'مختبر التخريج يعمل على حديث محدد: افتح أي حديث من المكتبة ثم اختر «التخريج».',
              icon: Icons.account_tree_outlined,
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'حديث ${h.num} — ${h.chapterTitle}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(h.text, style: const TextStyle(height: 1.8)),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'أحكام المحدثين المسجّلة',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (h.hasGrades)
                      ...h.grades.map(
                        (g) => Text('${g.scholar}: ${g.grade}'),
                      )
                    else
                      const Text('لم يرد حكم مسجّل لهذا الحديث في المصدر.'),
                  ],
                ),
              ),
            ),
            _sectionTitle(context, 'طرق الحديث (${variants.length})'),
            if (variants.isEmpty)
              const EmptyLibraryCard(
                title: 'لا توجد طرق مسجّلة بعد',
                detail:
                    'طرق الحديث واختلاف ألفاظها تتطلب جدول الطرق (المرحلة 5) — غير مستورد بعد. لا تُعرض هنا أي مقارنة غير موثقة.',
                icon: Icons.account_tree_outlined,
              )
            else ...[
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'المقارنة أدناه لفظية آلية على النصوص المستوردة فقط — المشترك والمختلف من الألفاظ. لا يُستنتج منها علة أو أثر إلا بنص موثّق مسجّل.',
                  style: TextStyle(color: SunnatiColors.inkMuted, fontSize: 12),
                ),
              ),
              ...variants.map((v) => _VariantCard(base: h, variant: v)),
            ],
            _sectionTitle(context, 'مصادر التخريج (${entries.length})'),
            if (entries.isEmpty)
              const Text(
                'لا توجد مصادر تخريج مسجّلة لهذا الحديث بعد.',
                style: TextStyle(color: SunnatiColors.inkMuted),
              )
            else
              ...entries.map(
                (e) => Card(
                  child: ListTile(
                    title: Text(
                      [
                        if (e.sourceBook.isNotEmpty) e.sourceBook,
                        if (e.sourceRef.isNotEmpty) e.sourceRef,
                      ].join(' — '),
                    ),
                    subtitle: Text(
                      [
                        if (e.grade.isNotEmpty) 'الحكم: ${e.grade}',
                        if (e.notes.isNotEmpty) e.notes,
                        if (e.source.isNotEmpty) 'المصدر: ${e.source}',
                      ].join('\n'),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

Widget _sectionTitle(BuildContext context, String text) {
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

class _VariantCard extends StatelessWidget {
  const _VariantCard({required this.base, required this.variant});

  final Hadith base;
  final HadithVariant variant;

  @override
  Widget build(BuildContext context) {
    final v = variant.variant;
    final comparison = v == null
        ? null
        : compareVariantTexts(base.text, v.text);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                if (v != null) 'حديث ${v.num} — ${v.chapterTitle}',
                if (variant.variantType.isNotEmpty) variant.variantType,
              ].join(' — '),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            if (v != null) ...[
              const SizedBox(height: 8),
              Text(v.text, style: const TextStyle(height: 1.8)),
            ] else
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'الطريق مسجّل كمرجع فقط دون نص مستورد.',
                  style: TextStyle(color: SunnatiColors.inkMuted),
                ),
              ),
            if (variant.diffNote.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('ملاحظة مسجّلة: ${variant.diffNote}'),
              ),
            if (variant.source.isNotEmpty)
              Text(
                'المصدر: ${variant.source}',
                style: const TextStyle(
                  color: SunnatiColors.inkMuted,
                  fontSize: 12,
                ),
              ),
            if (comparison != null) ...[
              const Divider(),
              if (comparison.identical)
                const Text('الألفاظ مطابقة لنص الحديث الأصل.')
              else ...[
                _WordRow(
                  label: 'مشترك',
                  words: comparison.common,
                ),
                _WordRow(
                  label: 'في الأصل فقط',
                  words: comparison.onlyInBase,
                ),
                _WordRow(
                  label: 'في الطريق فقط',
                  words: comparison.onlyInVariant,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _WordRow extends StatelessWidget {
  const _WordRow({required this.label, required this.words});

  final String label;
  final List<String> words;

  @override
  Widget build(BuildContext context) {
    if (words.isEmpty) return const SizedBox.shrink();
    final shown = words.length > 12 ? words.sublist(0, 12) : words;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label (${words.length})',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: shown
                .map((w) => Chip(label: Text(w), visualDensity: VisualDensity.compact))
                .toList(),
          ),
          if (words.length > 12)
            Text(
              '… و${words.length - 12} كلمة أخرى',
              style: const TextStyle(
                color: SunnatiColors.inkMuted,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }
}
