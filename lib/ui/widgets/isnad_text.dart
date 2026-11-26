/// Interactive isnad text — Phase 5.
///
/// Renders a hadith text as a [RichText] in which only names linked to
/// verified narrators (from the `chains` table, via
/// [SunnatiDatabase.narratorsForHadith]) are tappable. Tappable names are
/// shown in petrol with a light gold underline; every other name stays
/// plain text. Tapping a name opens the narrator card as a bottom sheet
/// over the current page, so the reader never loses its place.
///
/// Span positions come from the stored `hadith_narrators.start_char` /
/// `end_char` offsets when the chain rows carry them (see
/// [buildIsnadSpans]); only rows without usable offsets fall back to
/// normalised name search, which is lower-confidence and is never
/// treated as verified positioning. Unverified parser names
/// (`needs_review` / `unlinked`) are rendered as plain ink with no
/// underline and no tap handler — they must never look tappable.
///
/// The text itself is never altered: matching is done on a normalised
/// copy (see `lib/core/narrator_logic.dart`) and the displayed slices
/// come from the original text with its diacritics intact.
library;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/narrator_logic.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../models/chain.dart';
import '../../models/narrator.dart';
import 'narrator_card.dart';

class InteractiveIsnadText extends StatefulWidget {
  const InteractiveIsnadText({
    super.key,
    required this.db,
    required this.text,
    required this.confirmedNarrators,
    this.chainLinks = const <ChainLink>[],
    this.narratorsAvailable = true,
    this.style,
  });

  final SunnatiDatabase db;

  /// Full hadith text (isnad + matn) exactly as stored.
  final String text;

  /// Verified narrators of this hadith, in chain order. Fallback source
  /// for span building when [chainLinks] carries no offsets.
  final List<Narrator> confirmedNarrators;

  /// Full chain rows of this hadith, in position order, including
  /// unconfirmed links (from [SunnatiDatabase.chainForHadith]). When
  /// the rows carry `narrator_text` / `start_char` / `end_char` /
  /// `match_status`, spans are built from those stored offsets;
  /// otherwise [confirmedNarrators] is used as before.
  final List<ChainLink> chainLinks;

  /// Whether the verified narrators package is installed. When false,
  /// tapping a verified name shows the pending-approval sheet
  /// ([showNarratorPendingSheet]) and NO status.
  final bool narratorsAvailable;

  final TextStyle? style;

  @override
  State<InteractiveIsnadText> createState() => _InteractiveIsnadTextState();
}

class _InteractiveIsnadTextState extends State<InteractiveIsnadText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];
  late TextSpan _span;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _buildSpan();
  }

  @override
  void didUpdateWidget(InteractiveIsnadText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.confirmedNarrators != widget.confirmedNarrators ||
        oldWidget.chainLinks != widget.chainLinks ||
        oldWidget.narratorsAvailable != widget.narratorsAvailable) {
      _buildSpan();
    }
  }

  /// Matches for the span builder, offset-first.
  ///
  /// Chain rows are the primary source: a verified row contributes its
  /// narrator id + stored offsets, an unverified parser row contributes
  /// its verbatim name + stored offsets with `verified: false` (plain
  /// span, never tappable). Rows carrying neither an id nor a name
  /// contribute nothing. When the chain rows carry no usable names at
  /// all (e.g. a query that does not select the parser columns), the
  /// verified narrators fall back to normalised name search.
  List<IsnadNameMatch> _matches() {
    final fromLinks = <IsnadNameMatch>[];
    for (final link in widget.chainLinks) {
      if (link.isVerifiedLink) {
        fromLinks.add(
          IsnadNameMatch(
            name: link.narrator?.displayName ?? link.narratorText,
            narratorId: link.narratorId,
            startChar: link.startChar,
            endChar: link.endChar,
            verified: true,
          ),
        );
      } else if (link.isUnverifiedParserName) {
        fromLinks.add(
          IsnadNameMatch(
            name: link.narratorText,
            narratorId: null,
            startChar: link.startChar,
            endChar: link.endChar,
            verified: false,
          ),
        );
      }
    }
    if (fromLinks.isNotEmpty) return fromLinks;
    return widget.confirmedNarrators
        .map(
          (n) => IsnadNameMatch(name: n.displayName, narratorId: n.id),
        )
        .toList();
  }

  void _buildSpan() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final baseStyle = widget.style ??
        const TextStyle(fontSize: 20, height: 1.9);
    final spans = buildIsnadSpans(widget.text, _matches());
    _span = TextSpan(
      style: baseStyle,
      children: spans.map((s) {
        if (!s.isNarrator) return TextSpan(text: s.text);
        final recognizer = TapGestureRecognizer()
          ..onTap = () {
            // Honest ladder (pure decision in narrator_logic.dart):
            // a verified name with the package held back shows the
            // pending-approval sheet and NO status.
            final outcome = narratorTapOutcome(
              verifiedLink: true,
              narratorsAvailable: widget.narratorsAvailable,
            );
            if (outcome == NarratorTapOutcome.pendingApproval) {
              showNarratorPendingSheet(
                context,
                narratorName: s.text,
                verifiedLinkKnown: true,
              );
            } else if (outcome == NarratorTapOutcome.showStatus) {
              showNarratorSheetById(context, widget.db, s.narratorId!);
            } else {
              // Unreachable: unverified names never get a recognizer.
              showUnverifiedNarratorSheet(
                context,
                narratorName: s.text,
              );
            }
          };
        _recognizers.add(recognizer);
        return TextSpan(
          text: s.text,
          recognizer: recognizer,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
            decoration: TextDecoration.underline,
            decorationColor: SunnatiColors.gold,
            decorationThickness: 1.5,
          ),
        );
      }).toList(),
    );
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: _span,
      textAlign: TextAlign.justify,
      textDirection: TextDirection.rtl,
    );
  }
}
