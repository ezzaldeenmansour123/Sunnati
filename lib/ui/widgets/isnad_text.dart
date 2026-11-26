/// Interactive isnad text — Phase 5.
///
/// ONE-COLOR RULE (user decision 2026-11-26 15:03, binding — this
/// overrides the earlier design where only verified names were
/// tappable): EVERY parsed narrator name — every [ChainLink] with
/// stored `start_char` / `end_char` offsets, verified or not — renders
/// in ONE distinctive style and is tappable. There is exactly one
/// narrator-name style ([isnadNarratorNameStyle]: petrol text + gold
/// underline, bold); no name gets its own colour. Verified and
/// unverified names differ ONLY in what the tap shows, following the
/// honest 3-rung ladder in [narratorTapOutcome] (single source of
/// truth, `lib/core/narrator_logic.dart`):
///   (a) verified link + narrators package installed → status card
///       with its source;
///   (b) verified link + package held back → pending-approval sheet,
///       NO status;
///   (c) no verified link → honest «لا توجد ترجمة موثّقة بعد» sheet,
///       NO invented grade, NO invented biography.
///
/// Tapping a name opens the sheet as a bottom sheet over the current
/// page, so the reader never loses its place.
///
/// Span positions come from the stored `hadith_narrators.start_char` /
/// `end_char` offsets when the chain rows carry them (see
/// [buildIsnadSpans]); only rows without usable offsets fall back to
/// normalised name search, which is lower-confidence and is never
/// treated as verified positioning.
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

/// The single narrator-name style (one-color rule, user decision
/// 2026-11-26 15:03): petrol text, bold, gold underline. The widget
/// builds this style ONCE per span build and applies the same
/// [TextStyle] to every parsed narrator name — verified or not — so
/// there is exactly one narrator-name colour in the whole text.
TextStyle isnadNarratorNameStyle(BuildContext context) {
  return TextStyle(
    color: Theme.of(context).colorScheme.primary,
    fontWeight: FontWeight.bold,
    decoration: TextDecoration.underline,
    decorationColor: SunnatiColors.gold,
    decorationThickness: 1.5,
  );
}

class InteractiveIsnadText extends StatefulWidget {
  const InteractiveIsnadText({
    super.key,
    required this.db,
    required this.text,
    required this.confirmedNarrators,
    this.chainLinks = const <ChainLink>[],
    this.narratorsAvailable = true,
    this.style,
    this.onVerifiedNarratorTap,
  });

  final SunnatiDatabase db;

  /// Full hadith text (isnad + matn) exactly as stored.
  final String text;

  /// Verified narrators of this hadith, in chain order. Fallback source
  /// for span building when [chainLinks] carries no offsets.
  final List<Narrator> confirmedNarrators;

  /// Optional handler for a verified-name tap. When set, the verified
  /// (showStatus) outcome calls it with the narrator id instead of
  /// opening the plain narrator card — the reader uses it to open the
  /// hadith-details sheet (mockup screen 5). When null, the default
  /// [showNarratorSheetById] card is used. The other two ladder rungs
  /// are unaffected.
  final void Function(int narratorId)? onVerifiedNarratorTap;

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
  /// its verbatim name + stored offsets with `verified: false` (a
  /// narrator-name span under the one-color rule — same style,
  /// tappable, honest no-biography sheet on tap). Rows carrying
  /// neither an id nor a name contribute nothing. When the chain rows
  /// carry no usable names at all (e.g. a query that does not select
  /// the parser columns), the verified narrators fall back to
  /// normalised name search.
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
    // One style object for every narrator name in this text — the
    // one-color rule is enforced here, not per name.
    final narratorStyle = isnadNarratorNameStyle(context);
    _span = TextSpan(
      style: baseStyle,
      children: spans.map((s) {
        if (!s.isNarratorName) return TextSpan(text: s.text);
        final recognizer = TapGestureRecognizer()
          ..onTap = () {
            // Honest ladder (pure decision in narrator_logic.dart).
            // Verified names show a status (or the pending sheet when
            // the package is held); unverified names show the honest
            // no-biography sheet and never a status.
            final outcome = narratorTapOutcome(
              verifiedLink: s.narratorId != null,
              narratorsAvailable: widget.narratorsAvailable,
            );
            if (outcome == NarratorTapOutcome.pendingApproval) {
              showNarratorPendingSheet(
                context,
                narratorName: s.text,
                verifiedLinkKnown: true,
              );
            } else if (outcome == NarratorTapOutcome.showStatus) {
              final onVerified = widget.onVerifiedNarratorTap;
              if (onVerified != null) {
                onVerified(s.narratorId!);
              } else {
                showNarratorSheetById(context, widget.db, s.narratorId!);
              }
            } else {
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
          style: narratorStyle,
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
