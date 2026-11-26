/// Isnad tree — Phase 5.
///
/// A vertical chain (narrator ↓ … ↓ Companion ↓ the Prophet ﷺ) built
/// from verified `chains` rows. Tapping a confirmed narrator opens his
/// card; tapping an unconfirmed link explains that no verified narrator
/// is recorded for it. Confirmed and incomplete links are styled
/// differently, and the whole tree zooms/pans through [InteractiveViewer].
/// With no chain rows the widget shows an honest empty state instead of
/// a fabricated chain.
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
      if (i < links.length - 1) {
        nodes.add(const _Connector());
      }
    }
    nodes.add(const _Connector());
    nodes.add(const _ProphetNode());
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
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 2),
        child: Icon(Icons.arrow_downward, color: SunnatiColors.gold),
      ),
    );
  }
}

class _ChainNode extends StatelessWidget {
  const _ChainNode({required this.db, required this.link});

  final SunnatiDatabase db;
  final ChainLink link;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final confirmed = link.isConfirmed;
    // Verified link whose narrator row cannot load because the
    // narrators package is held back (KITAB gate): NOT an unconfirmed
    // link — say so explicitly and show no status (integrator fix
    // 2026-11-26; Worker C §4). isVerifiedLink is true only for
    // match_status 'linked_verified' with a narrator id.
    final verifiedHeld = !confirmed && link.isVerifiedLink;
    return Card(
      color: confirmed ? null : SunnatiColors.goldSoft,
      child: ListTile(
        leading: Icon(
          link.isCompanion ? Icons.star_outline : Icons.person_outline,
          color: confirmed ? SunnatiColors.petrol : SunnatiColors.inkMuted,
        ),
        title: Text(
          link.displayName,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: confirmed ? colors.primary : SunnatiColors.inkMuted,
            decoration: confirmed ? TextDecoration.underline : null,
            decorationColor: SunnatiColors.gold,
          ),
        ),
        subtitle: Text(
          [
            if (link.isCompanion) 'صحابي',
            if (confirmed && link.narrator!.hasStatus)
              link.narrator!.status,
            if (verifiedHeld)
              'رابط موثّق — حزمة الرواة قيد انتظار الموافقة',
            if (!confirmed && !verifiedHeld)
              'رابط غير مكتمل — لا يوجد راوٍ موثّق',
            if (link.source.isNotEmpty) 'المصدر: ${link.source}',
          ].join(' — '),
        ),
        trailing: confirmed
            ? const Icon(Icons.open_in_new, size: 18)
            : const Icon(Icons.help_outline, size: 18),
        onTap: () {
          if (confirmed) {
            showNarratorSheetById(context, db, link.narratorId!);
          } else if (verifiedHeld) {
            // Honest-ladder rung (b): verified link, package held back.
            // No status, no scholar, no source is shown.
            showNarratorPendingSheet(context, verifiedLinkKnown: true);
          } else {
            showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('رابط غير مكتمل'),
                content: const Text(
                  'هذا الموضع من السلسلة مسجّل دون راوٍ موثّق في المصدر المستورد — لا يُعرض فيه اسم غير مؤكد.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('حسناً'),
                  ),
                ],
              ),
            );
          }
        },
      ),
    );
  }
}

class _ProphetNode extends StatelessWidget {
  const _ProphetNode();

  @override
  Widget build(BuildContext context) {
    return const Card(
      color: SunnatiColors.petrol,
      child: ListTile(
        leading: Icon(Icons.menu_book, color: Colors.white),
        title: Text(
          'النبي ﷺ',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        subtitle: Text(
          'نهاية السند',
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }
}
