/// Isnad tree — mockup screen 7 (شجرة الإسناد).
///
/// Layout follows the mockup exactly: a vertical chain of rounded nodes
/// connected by lines, top = first link of the chain list down to a final
/// «الحديث» node. A node shows the narrator name and, underneath it in
/// parentheses, the tier label ONLY when the tier is actually known from
/// the database (verified narrator with a recorded tier); unverified nodes
/// show the name only, never an invented tier. Tapping a node shows the
/// status + source as an INLINE LINE inside that same node, right under
/// the name (user decision 2026-11-26 17:23, superseding the 16:49
/// small-card design); a verified link whose narrators package is held
/// back shows the pending message, and anything else shows the honest
/// «no verified biography» message — never a navigation, never a sheet,
/// never a popup card. The whole tree zooms/pans through
/// [InteractiveViewer]. With no chain rows the widget shows an honest
/// empty state instead of a fabricated chain.
library;

import 'package:material_ui/material_ui.dart';

import '../../core/narrator_logic.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../models/chain.dart';
import 'empty_library.dart';
import 'isnad_text.dart';

class IsnadTree extends StatefulWidget {
  const IsnadTree({super.key, required this.db, required this.links});

  final SunnatiDatabase db;

  /// Chain links in position order (0 = closest to the compiler).
  final List<ChainLink> links;

  @override
  State<IsnadTree> createState() => _IsnadTreeState();
}

class _IsnadTreeState extends State<IsnadTree> {
  /// Index of the tapped node (null: none tapped) + its inline-line data.
  int? _selectedIndex;
  InlineNarratorStatus? _selected;

  @override
  void didUpdateWidget(IsnadTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.links != widget.links) {
      _selectedIndex = null;
      _selected = null;
    }
  }

  /// Tap a node: compute the honest-ladder outcome and show the status
  /// + source as an inline line inside that same node — never a sheet,
  /// never a navigation, never a popup card (user decision 2026-11-26
  /// 17:23). Tapping the same node again hides the line.
  void _select(int index) {
    final link = widget.links[index];
    final outcome = narratorTapOutcome(
      verifiedLink: link.isVerifiedLink,
      narratorsAvailable: widget.db.narratorsAvailable,
    );
    final narrator =
        outcome == NarratorTapOutcome.showStatus ? link.narrator : null;
    // Same name the node shows (see [_ChainNode._name]).
    final name = link.isConfirmed
        ? link.displayName
        : (link.narratorText.isNotEmpty
            ? link.narratorText
            : link.displayName);
    setState(() {
      if (_selectedIndex == index) {
        _selectedIndex = null;
        _selected = null;
      } else {
        _selectedIndex = index;
        _selected = inlineStatusForTap(
          name: name,
          outcome: outcome,
          status: narrator?.status ?? '',
          statusSource: narrator?.statusSource ?? '',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final links = widget.links;
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
      nodes.add(
        _ChainNode(
          db: widget.db,
          link: links[i],
          onTap: () => _select(i),
          statusLine: i == _selectedIndex && _selected != null
              ? inlineStatusLineText(_selected!)
              : null,
        ),
      );
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
  const _ChainNode({
    required this.db,
    required this.link,
    required this.onTap,
    this.statusLine,
  });

  final SunnatiDatabase db;
  final ChainLink link;

  /// Called when the node is tapped; the tree shows the status + source
  /// as an inline line inside this same node (never a sheet, never a
  /// navigation, never a popup card).
  final VoidCallback onTap;

  /// Inline status line to show under the name (null: this node is not
  /// the tapped one). Rendered in the same red as the narrator names.
  final String? statusLine;

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
        onTap: onTap,
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
              if (statusLine != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    statusLine!,
                    style: isnadInlineStatusStyle(context),
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
