/// Isnad tree — mockup screen 7 (شجرة الإسناد).
///
/// Layout follows the mockup exactly: a vertical chain of rounded nodes
/// connected by lines, top = first link of the chain list down to a final
/// «الحديث» node. A node shows the narrator name and, underneath it in
/// parentheses, the tier label ONLY when the tier is actually known from
/// the database (verified narrator with a recorded tier); unverified nodes
/// show the name only, never an invented tier. Tapping reuses the
/// existing honest-ladder tap logic: a confirmed narrator opens his card,
/// a verified link whose narrators package is held back shows the pending
/// sheet with no status, and anything else shows the honest
/// «no verified biography» sheet. The whole tree zooms/pans through
/// [InteractiveViewer]. With no chain rows the widget shows an honest
/// empty state instead of a fabricated chain.
library;

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/database.dart';
import '../../models/chain.dart';
import 'empty_library.dart';
import 'narrator_card.dart';

class IsnadTree extends StatelessWidget {
  const IsnadTree({super.key, required this.db, required this.links});

  final SunnatiDatabase db;

  /// Chain links in position order (0 = closest to the compiler).
  final List<ChainLink> links;

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) {
      return const EmptyLibraryCard(
        title: 'لا توجد بيانات سلسلة موثّقة',
        detail:
            'سلسلة هذا الحديث غير مستوردة بعد — جدول الأسانيد قيد الاستيراد في المرحلة 5. لا تُعرض هنا سلسلة غير موثّقة.',
        icon: Icons.account_tree_outlined,
      );
    }
    final nodes = <Widget>[];
    for (var i = 0; i < links.length; i++) {
      nodes.add(_ChainNode(db: db, link: links[i]));
      nodes.add(const _Connector());
    }
    nodes.add(const _HadithNode());
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 2.5,
      boundaryMargin: const EdgeInsets.all(40),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: nodes,
        ),
      ),
    );
  }
}

class _Connector extends StatelessWidget {
  const _Connector();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 2,
        height: 20,
        color: SunnatiColors.gold,
      ),
    );
  }
}

class _ChainNode extends StatelessWidget {
  const _ChainNode({required this.db, required this.link});

  final SunnatiDatabase db;
  final ChainLink link;

  /// Name to show: the verified narrator's name, else the name exactly
  /// as printed in the hadith text, else the honest placeholder.
  String get _name {
    if (link.isConfirmed) return link.displayName;
    if (link.narratorText.isNotEmpty) return link.narratorText;
    return link.displayName;
  }

  /// Tier label, only when actually known from the database: a verified
  /// narrator's recorded tier, else the recorded link type (e.g. صحابي).
  /// Null means: show the name only.
  String? get _tierLabel {
    if (link.isConfirmed) {
      final narrator = link.narrator!;
      if (narrator.tier.isNotEmpty) return narrator.tier;
      if (link.linkType.isNotEmpty) return link.linkType;
      return null;
    }
    return null;
  }

  void _onTap(BuildContext context) {
    if (link.isConfirmed) {
      showNarratorSheetById(context, db, link.narratorId!);
    } else if (link.isVerifiedLink) {
      // Honest-ladder rung (b): verified link, package held back.
      // No status, no scholar, no source is shown.
      showNarratorPendingSheet(
        context,
        narratorName: _name,
        verifiedLinkKnown: true,
      );
    } else {
      // Honest-ladder rung (c): no verified biography (yet).
      showUnverifiedNarratorSheet(context, narratorName: _name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final confirmed = link.isConfirmed;
    // Verified link whose narrator row cannot load because the
    // narrators package is held back (KITAB gate): NOT an unconfirmed
    // link — say so explicitly and show no status. isVerifiedLink is
    // true only for match_status 'linked_verified' with a narrator id.
    final verifiedHeld = !confirmed && link.isVerifiedLink;
    final tierLabel = _tierLabel;
    return Card(
      color: confirmed ? SunnatiColors.blush : SunnatiColors.goldSoft,
      child: InkWell(
        onTap: () => _onTap(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    link.isCompanion
                        ? Icons.star_outline
                        : Icons.person_outline,
                    color: confirmed
                        ? SunnatiColors.petrol
                        : SunnatiColors.inkMuted,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _name,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: confirmed
                            ? SunnatiColors.petrol
                            : SunnatiColors.inkMuted,
                      ),
                    ),
                  ),
                ],
              ),
              if (tierLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '($tierLabel)',
                    style: const TextStyle(color: SunnatiColors.inkMuted),
                  ),
                ),
              if (verifiedHeld)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'رابط موثّق — حزمة الرواة قيد انتظار الموافقة',
                    style: TextStyle(
                      color: SunnatiColors.inkMuted,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              if (!confirmed && !verifiedHeld)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'رابط غير مكتمل — لا يوجد راوٍ موثّق',
                    style: TextStyle(
                      color: SunnatiColors.inkMuted,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Final node of the tree, as in the mockup: the hadith itself.
class _HadithNode extends StatelessWidget {
  const _HadithNode();

  @override
  Widget build(BuildContext context) {
    return const Card(
      color: SunnatiColors.petrol,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.menu_book, color: Colors.white),
            SizedBox(width: 8),
            Text(
              'الحديث',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
