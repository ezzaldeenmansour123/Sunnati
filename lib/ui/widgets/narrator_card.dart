/// Smart narrator card — Phase 5.
///
/// Shows what the database actually records about a narrator: full name,
/// kunya and laqab, lineage, generation, birth/death years when recorded,
/// country when recorded, the jarh-wa-ta'dil verdict with its source,
/// critics' sayings each with its source (conflicting sayings shown side
/// by side as `مختلف فيه`, never collapsed into one verdict), and how many
/// hadiths are linked to him. When nothing is recorded beyond the name,
/// the card says `لم تتوفر ترجمة موثقة` instead of inventing a biography.
/// The card expands to show the details, and offers the full narrator page.
library;

import 'package:flutter/material.dart';

import '../../core/narrator_logic.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../models/narrator.dart';
import '../narrator_detail_screen.dart';

/// Open a narrator card as a draggable bottom sheet over the current page
/// (the reader keeps its scroll position — nothing is navigated away from).
Future<void> showNarratorSheet(
  BuildContext context,
  SunnatiDatabase db,
  Narrator narrator,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: SunnatiColors.neutral,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              NarratorCard(db: db, narrator: narrator, expanded: true),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Same as [showNarratorSheet], loading the narrator by id first. When
/// the id has no verified row, the sheet honestly says so.
Future<void> showNarratorSheetById(
  BuildContext context,
  SunnatiDatabase db,
  int narratorId,
) async {
  final narrator = db.narratorById(narratorId);
  if (!context.mounted) return;
  if (narrator == null) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (context) => const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'لم تتوفر ترجمة موثّقة لهذا الراوي بعد.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
  return showNarratorSheet(context, db, narrator);
}

class NarratorCard extends StatefulWidget {
  const NarratorCard({
    super.key,
    required this.db,
    required this.narrator,
    this.expanded = false,
    this.showOpenFullPage = true,
  });

  final SunnatiDatabase db;
  final Narrator narrator;
  final bool expanded;

  /// Hide the "open full page" button when the card is already shown on
  /// that page.
  final bool showOpenFullPage;

  @override
  State<NarratorCard> createState() => _NarratorCardState();
}

class _NarratorCardState extends State<NarratorCard> {
  late bool _expanded;
  late final int _hadithCount;
  late final List<NarratorSaying> _sayings;

  @override
  void initState() {
    super.initState();
    _expanded = widget.expanded;
    _hadithCount = widget.db.countHadithsForNarrator(widget.narrator.id);
    _sayings = widget.db.narratorSayings(widget.narrator.id);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.narrator;
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.person_outline, color: SunnatiColors.gold),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        n.displayName,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: colors.primary,
                        ),
                      ),
                      if (n.kunya.isNotEmpty) Text(n.kunya),
                      if (n.hasLaqab) Text('اللقب: ${n.laqab}'),
                    ],
                  ),
                ),
                if (n.hasStatus)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: SunnatiColors.goldSoft,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: SunnatiColors.gold),
                    ),
                    child: Text(
                      canonicalGradeLabel(n.status),
                      style: const TextStyle(
                        color: SunnatiColors.petrol,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            if (n.isDisputed)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'مختلف فيه — وردت فيه أقوال متعارضة، وتُعرض كما وردت دون ترجيح حكم واحد.',
                  style: TextStyle(color: SunnatiColors.inkMuted),
                ),
              ),
            if (n.hasStatus && n.statusSource.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'مصدر الحكم: ${n.statusSource}',
                  style: const TextStyle(
                    color: SunnatiColors.inkMuted,
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                if (n.tier.isNotEmpty) Text('الطبقة: ${n.tier}'),
                if (n.hasBirth) Text('وُلد ${n.birthYearHijri}هـ'),
                if (n.hasDeath) Text('توفي ${n.deathYearHijri}هـ'),
                if (n.hasCountry) Text('البلد: ${n.country}'),
                Text('الأحاديث المرتبطة: $_hadithCount'),
              ],
            ),
            if (!n.hasBiographyData)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'لم تتوفر ترجمة موثّقة لهذا الراوي بعد.',
                  style: TextStyle(color: SunnatiColors.inkMuted),
                ),
              ),
            if (_expanded) ...[
              const Divider(),
              if (n.hasLineage) _FactRow('النسب', n.lineage),
              if (n.biographySource.isNotEmpty)
                _FactRow('مصدر الترجمة', n.biographySource),
              if (_sayings.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'أقوال العلماء',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: colors.primary,
                  ),
                ),
                ..._sayings.map(
                  (s) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${s.scholar}: ${s.text}'),
                    subtitle: s.hasSource ? Text('المصدر: ${s.source}') : null,
                  ),
                ),
              ],
              if (_sayings.isEmpty && n.hasStatus)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'لا توجد أقوال مسجّلة للعلماء فيه بعد.',
                    style: TextStyle(color: SunnatiColors.inkMuted),
                  ),
                ),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? 'عرض أقل' : 'عرض التفاصيل'),
                ),
                if (widget.showOpenFullPage)
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NarratorDetailScreen(
                          db: widget.db,
                          narratorId: n.id,
                        ),
                      ),
                    ),
                    child: const Text('فتح صفحة الراوي الكاملة'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text('$label: $value'),
    );
  }
}
