/// Isnad analysis — mockup screen 8 (تحليل الإسناد), HONEST VERSION.
///
/// Layout follows the mockup exactly: the checks list beside a summary
/// box, then the «معلومات إضافية» section, then a bottom verdict-style
/// card. CONTENT is only what can be verified from the chain rows passed
/// in — the mockup's 92% donut and its final «صحيح» verdict are NOT
/// reproduced: there is NO percentage score and NO final sahih/daif
/// ruling anywhere on this screen (the spec forbids an automated final
/// ruling). Checks with no data show an honest «لا توجد بيانات موثقة»
/// state, never a green check. The turuq/takhrij tables are empty, so
/// the routes section says so plainly. The bottom card states the honest
/// rule and the disclaimer that this is automated analysis, not a
/// scholarly ruling.
///
/// NOTE: this screen receives only [hadithId], [chainLinks] and an
/// optional [bookName] — it has no database handle, so recorded grades
/// cannot be shown here; «مصادر الحديث» lists the book name when given
/// plus the real sources recorded on the chain links themselves, and
/// says so honestly when none are recorded.
library;

import 'package:material_ui/material_ui.dart';

import '../core/narrator_logic.dart';
import '../core/theme.dart';
import '../models/chain.dart';
import 'widgets/empty_library.dart';
import 'widgets/sunnati_bottom_nav.dart';

class IsnadAnalysisScreen extends StatelessWidget {
  const IsnadAnalysisScreen({
    required this.hadithId,
    required this.chainLinks,
    this.bookName,
    super.key,
  });

  /// Database id of the analysed hadith (identifies it; the chain rows
  /// carry the analysable data).
  final int hadithId;

  /// Chain links in position order (0 = closest to the compiler).
  final List<ChainLink> chainLinks;

  /// Name of the book the hadith is in, when the caller knows it.
  final String? bookName;

  int get _total => chainLinks.length;

  int get _verifiedCount =>
      chainLinks.where((l) => l.isConfirmed).length;

  int get _heldBackCount =>
      chainLinks.where((l) => !l.isConfirmed && l.isVerifiedLink).length;

  int get _needsReviewCount =>
      chainLinks.where((l) => l.matchStatus == 'needs_review').length;

  int get _unlinkedCount =>
      chainLinks.where((l) => l.matchStatus == 'unlinked').length;

  int get _withoutReviewStateCount =>
      _total -
      _verifiedCount -
      _heldBackCount -
      _needsReviewCount -
      _unlinkedCount;

  /// Verified narrators grouped by their recorded status wording.
  Map<String, int> get _statusCounts {
    final counts = <String, int>{};
    for (final link in chainLinks) {
      final narrator = link.narrator;
      if (narrator == null || !narrator.hasStatus) continue;
      final label = canonicalGradeLabel(narrator.status);
      counts[label] = (counts[label] ?? 0) + 1;
    }
    return counts;
  }

  int get _verifiedWithoutStatusCount => chainLinks
      .where((l) => l.narrator != null && !l.narrator!.hasStatus)
      .length;

  int get _withoutBiographyCount => _total - _verifiedCount;

  /// Real sources recorded on the chain links themselves.
  List<String> get _linkSources {
    final sources = <String>{};
    for (final link in chainLinks) {
      if (link.source.isNotEmpty) sources.add(link.source);
    }
    return sources.toList();
  }

  String _linkStatusLine() {
    final parts = <String>[
      'عدد الروابط: $_total',
      'موثقة: $_verifiedCount',
    ];
    if (_heldBackCount > 0) {
      parts.add('موثقة بانتظار حزمة الرواة: $_heldBackCount');
    }
    if (_needsReviewCount > 0) parts.add('قيد المراجعة: $_needsReviewCount');
    if (_unlinkedCount > 0) parts.add('غير مرتبطة: $_unlinkedCount');
    if (_withoutReviewStateCount > 0) {
      parts.add('بلا حالة مراجعة مسجلة: $_withoutReviewStateCount');
    }
    return parts.join(' — ');
  }

  String _narratorsJusticeLine() {
    if (_verifiedCount == 0) {
      return 'لا توجد تراجم موثقة لرواة هذا السند بعد.';
    }
    final parts = <String>[];
    _statusCounts.forEach((status, count) {
      parts.add('$status: $count');
    });
    if (_verifiedWithoutStatusCount > 0) {
      parts.add('موثقون بلا حالة مسجلة: $_verifiedWithoutStatusCount');
    }
    if (_withoutBiographyCount > 0) {
      parts.add('بلا ترجمة موثقة بعد: $_withoutBiographyCount');
    }
    return parts.join(' — ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تحليل الإسناد')),
      // Shared bottom nav (mockup screen 8: الرئيسية active). Tapping a
      // tab replaces the stack with a fresh shell on that tab — see
      // `sunnatiGoToTab`.
      bottomNavigationBar: SunnatiBottomNav(
        currentIndex: 2,
        onTap: (index) => sunnatiGoToTab(context, index),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (chainLinks.isEmpty)
            const EmptyLibraryCard(
              title: 'لا توجد بيانات سلسلة موثّقة',
              detail:
                  'سلسلة هذا الحديث غير مستوردة بعد — لا يمكن تحليل إسناد بلا روابط موثّقة.',
              icon: Icons.account_tree_outlined,
            )
          else
            // Top area, as in the mockup: checks on one side, a summary
            // box on the other — but the box holds REAL counts, never an
            // invented percentage score.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _CheckRow(
                            icon: Icons.link_outlined,
                            title: 'اتصال السند',
                            detail: _linkStatusLine(),
                            hasData: true,
                          ),
                          _CheckRow(
                            icon: Icons.people_outline,
                            title: 'عدالة الرواة',
                            detail: _narratorsJusticeLine(),
                            hasData: _verifiedCount > 0,
                          ),
                          const _CheckRow(
                            icon: Icons.help_outline,
                            title: 'عدم الشذوذ',
                            detail: 'لا توجد بيانات موثقة.',
                            hasData: false,
                          ),
                          const _CheckRow(
                            icon: Icons.help_outline,
                            title: 'عدم العلة',
                            detail: 'لا توجد بيانات موثقة.',
                            hasData: false,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      width: 110,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: SunnatiColors.goldSoft,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: SunnatiColors.gold),
                      ),
                      child: Column(
                        children: [
                          Text(
                            '$_verifiedCount',
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: SunnatiColors.petrol,
                            ),
                          ),
                          Text(
                            'من $_total رواة موثقون',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: SunnatiColors.inkMuted,
                              fontSize: 12,
                            ),
                          ),
                          if (_heldBackCount > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '$_heldBackCount بانتظار حزمة الرواة',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: SunnatiColors.inkMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const _SectionTitle('معلومات إضافية', Icons.balance_outlined),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              child: Column(
                children: [
                  const _InfoRow(
                    'عدد طرق الحديث',
                    'لا توجد بيانات طرق موثقة بعد.',
                  ),
                  const _InfoRow(
                    'أشهر الطرق',
                    'لا توجد بيانات طرق موثقة بعد.',
                  ),
                  if (bookName != null && bookName!.isNotEmpty)
                    _InfoRow('الكتاب', bookName!),
                  _InfoRow(
                    'مصادر الحديث',
                    _linkSources.isEmpty
                        ? 'لا توجد مصادر مسجلة لروابط هذا السند بعد.'
                        : _linkSources.join('، '),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Replaces the mockup's green final-verdict card: a neutral
          // honest line + disclaimer. No verdict, no percentage.
          const Card(
            color: SunnatiColors.goldSoft,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'التحليل الآلي يعرض ما هو موثق فقط؛ لا يصدر حكماً نهائياً.',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: SunnatiColors.petrol,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'هذا تحليل آلي لمحتويات قاعدة البيانات الموثقة، وليس حكماً علمياً على صحة الحديث أو ضعفه.',
                    style: TextStyle(color: SunnatiColors.inkMuted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.hasData,
  });

  final IconData icon;
  final String title;
  final String detail;

  /// False for checks with no data: shown with a muted icon and an
  /// honest empty line, never a check mark.
  final bool hasData;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: hasData ? SunnatiColors.petrol : SunnatiColors.inkMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: SunnatiColors.petrol,
                  ),
                ),
                Text(
                  detail,
                  style: const TextStyle(color: SunnatiColors.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

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
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(color: SunnatiColors.inkMuted),
            ),
          ),
        ],
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
