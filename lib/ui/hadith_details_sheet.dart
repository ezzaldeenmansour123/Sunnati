import 'package:material_ui/material_ui.dart';

import '../core/narrator_logic.dart';
import '../core/theme.dart';
import '../data/database.dart';
import '../models/chain.dart';
import '../models/hadith.dart';
import '../models/narrator.dart';
import 'widgets/isnad_text.dart';
import 'widgets/narrator_card.dart';

/// Hadith details sheet — mockup screen 5 (the «جامع الكتب التسعة»
/// layout, copied as DESIGN only; every word of content comes from the
/// installed DB).
///
/// Layout, top to bottom, exactly as the mockup:
/// * Title «تفاصيل الحديث».
/// * «سند الحديث» section (pink pill header) with the isnad rendered
///   through [InteractiveIsnadText].
/// * «معلومات الراوي» card for the tapped narrator: name in a pink pill,
///   then ONLY fields the DB actually has — kunya, tier, death year, and
///   the critics' sayings each with speaker + source. No nisba, no
///   teachers, no students: the verified narrator rows carry none of
///   those, and nothing is invented here.
/// * An «إغلاق» button.
///
/// When the narrator has no verified biography data at all, the card
/// shows the honest «لا توجد ترجمة موثّقة بعد» state and nothing else.
///
/// The sheet is opened for the verified/status tap outcome only — see
/// [showHadithDetailsSheetById] and the reader's narrator list, which
/// use the existing [narratorTapOutcome] decision; the other outcomes
/// keep their existing sheets.
Future<void> showHadithDetailsSheet(
  BuildContext context, {
  required SunnatiDatabase db,
  required Hadith hadith,
  required Narrator narrator,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: HadithDetailsSheet(
          db: db,
          hadith: hadith,
          narrator: narrator,
          scrollController: scrollController,
        ),
      ),
    ),
  );
}

/// Same as [showHadithDetailsSheet], loading the narrator by id first.
///
/// Call only for a tapped name known to carry a verified link: when the
/// narrators package is held back the pending-approval sheet is shown
/// and NO status; when the id has no verified row the honest
/// no-verified-biography sheet is shown.
Future<void> showHadithDetailsSheetById(
  BuildContext context,
  SunnatiDatabase db,
  Hadith hadith,
  int narratorId,
) {
  final outcome = narratorTapOutcome(
    verifiedLink: true,
    narratorsAvailable: db.narratorsAvailable,
  );
  if (outcome == NarratorTapOutcome.pendingApproval) {
    return showNarratorPendingSheet(
      context,
      verifiedLinkKnown: true,
    );
  }
  final narrator = db.narratorById(narratorId);
  if (narrator == null) {
    return showUnverifiedNarratorSheet(context);
  }
  return showHadithDetailsSheet(
    context,
    db: db,
    hadith: hadith,
    narrator: narrator,
  );
}

class HadithDetailsSheet extends StatefulWidget {
  const HadithDetailsSheet({
    super.key,
    required this.db,
    required this.hadith,
    required this.narrator,
    required this.scrollController,
  });

  final SunnatiDatabase db;
  final Hadith hadith;
  final Narrator narrator;
  final ScrollController scrollController;

  @override
  State<HadithDetailsSheet> createState() => _HadithDetailsSheetState();
}

class _HadithDetailsSheetState extends State<HadithDetailsSheet> {
  late final List<ChainLink> _chainLinks;
  late final List<NarratorSaying> _sayings;

  @override
  void initState() {
    super.initState();
    _chainLinks = widget.db.chainForHadith(widget.hadith.id);
    _sayings = widget.db.narratorSayings(widget.narrator.id);
  }

  /// End of the last parsed narrator name in the hadith text (parser
  /// offsets from `hadith_narrators`), or null when no parser row
  /// carries usable offsets. Same split as the reader: the isnad is the
  /// text up to that point, verbatim.
  int? get _isnadEnd {
    int? end;
    for (final link in _chainLinks) {
      if (link.hasOffsets && link.endChar != null) {
        end = end == null || link.endChar! > end ? link.endChar! : end;
      }
    }
    if (end == null ||
        end <= 0 ||
        end > widget.hadith.text.length) {
      return null;
    }
    return end;
  }

  String get _isnadText {
    final end = _isnadEnd;
    if (end == null) return widget.hadith.text;
    return widget.hadith.text.substring(0, end);
  }

  List<ChainLink> get _isnadLinks {
    final end = _isnadEnd;
    if (end == null) return _chainLinks;
    return _chainLinks
        .where((l) => l.hasOffsets && l.endChar! <= end)
        .toList();
  }

  List<Narrator> get _chainNarrators =>
      _chainLinks.where((l) => l.narrator != null).map((l) => l.narrator!).toList();

  @override
  Widget build(BuildContext context) {
    final n = widget.narrator;
    final colors = Theme.of(context).colorScheme;
    final hasAnyBiographyData =
        n.kunya.isNotEmpty ||
            n.tier.isNotEmpty ||
            n.hasDeath ||
            n.hasStatus ||
            n.biographySource.isNotEmpty ||
            _sayings.isNotEmpty;
    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: SunnatiColors.neutral,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'تفاصيل الحديث',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colors.primary,
            ),
          ),
          const SizedBox(height: 16),
          // «سند الحديث» (mockup's pill header) + isnad via IsnadText.
          const Center(child: _PinkPill('سند الحديث')),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _chainLinks.isEmpty
                  ? const Text(
                      kIsnadNotParsedMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: SunnatiColors.inkMuted),
                    )
                  : InteractiveIsnadText(
                      db: widget.db,
                      text: _isnadText,
                      confirmedNarrators: _chainNarrators,
                      chainLinks: _isnadLinks,
                      narratorsAvailable: widget.db.narratorsAvailable,
                    ),
            ),
          ),
          const SizedBox(height: 16),
          // «معلومات الراوي» card (mockup screen 5, lower card).
          Row(
            children: [
              const Icon(Icons.person_outline, color: SunnatiColors.gold),
              const SizedBox(width: 8),
              Text(
                'معلومات الراوي',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: colors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: _PinkPill(n.displayName)),
                  const SizedBox(height: 12),
                  if (!hasAnyBiographyData)
                    const Text(
                      kNoVerifiedBiographyMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: SunnatiColors.inkMuted),
                    )
                  else ...[
                    if (n.hasStatus) ...[
                      Center(
                        child: Container(
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
                      ),
                      if (n.statusSource.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'مصدر الحكم: ${n.statusSource}',
                            style: const TextStyle(
                              color: SunnatiColors.inkMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                    if (n.isDisputed)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          'مختلف فيه — وردت فيه أقوال متعارضة، وتُعرض كما وردت دون ترجيح حكم واحد.',
                          style: TextStyle(color: SunnatiColors.inkMuted),
                        ),
                      ),
                    if (n.kunya.isNotEmpty) _FactRow('الكنية', n.kunya),
                    if (n.tier.isNotEmpty) _FactRow('الطبقة', n.tier),
                    if (n.hasDeath)
                      _FactRow('الوفاة', '${n.deathYearHijri} هـ'),
                    if (n.biographySource.isNotEmpty)
                      _FactRow('مصدر الترجمة', n.biographySource),
                    if (_sayings.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'أقوال النقاد',
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
                          subtitle: s.hasSource
                              ? Text('المصدر: ${s.source}')
                              : null,
                        ),
                      ),
                    ] else if (n.hasStatus)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'لا توجد أقوال مسجّلة للعلماء فيه بعد.',
                          style: TextStyle(color: SunnatiColors.inkMuted),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }
}

/// Pink pill exactly as the mockup's: pale pink fill, petrol bold text.
class _PinkPill extends StatelessWidget {
  const _PinkPill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: SunnatiColors.blush,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: SunnatiColors.petrol,
          fontWeight: FontWeight.bold,
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
