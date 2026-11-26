/// Interactive isnad text — Phase 5.
///
/// ONE RED COLOUR (user decisions 2026-11-26 15:03 + 17:23, binding —
/// the 17:23 correction SUPERSEDES the build-81 petrol/bold/gold-
/// underline rule and the 16:49 small-card design): EVERY parsed
/// narrator name — every [ChainLink] with stored `start_char` /
/// `end_char` offsets, verified or not — renders in ONE distinctive
/// RED ([SunnatiColors.narratorRed], bold, no underline) and is
/// tappable. There is exactly one narrator-name colour in the whole
/// text; no name gets its own colour. Verified and unverified names
/// differ ONLY in what the tap shows, following the honest 3-rung
/// ladder in [narratorTapOutcome] (single source of truth,
/// `lib/core/narrator_logic.dart`):
///   (a) verified link + narrators package installed → the status +
///       source as an INLINE LINE embedded in the hadith text itself,
///       right under the tapped name;
///   (b) verified link + package held back → the pending-approval
///       message as an inline line, NO status;
///   (c) no verified link → the honest «لا توجد ترجمة موثّقة بعد»
///       inline line, NO invented grade, NO invented biography.
///
/// The line is a span INSIDE the same [RichText] — a new line right
/// under the name, the rest of the hadith text continuing after it —
/// never a popup card/sheet, never a navigation, never the full
/// details page. Tapping the same name again hides the line. The full
/// narrator page is reachable only from the narrators encyclopedia.
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

/// The single narrator-name style (one red colour, user decision
/// 2026-11-26 17:23): distinctive red, bold, no underline. The widget
/// builds this style ONCE per span build and applies the same
/// [TextStyle] to every parsed narrator name — verified or not — so
/// there is exactly one narrator-name colour in the whole text.
TextStyle isnadNarratorNameStyle(BuildContext context) {
  return const TextStyle(
    color: SunnatiColors.narratorRed,
    fontWeight: FontWeight.bold,
  );
}

/// Style of the inline status line embedded under a tapped name:
/// smaller red text (same distinctive red as the names, so the line
/// reads as belonging to the tapped name), normal weight.
TextStyle isnadInlineStatusStyle(BuildContext context) {
  return const TextStyle(
    color: SunnatiColors.narratorRed,
    fontSize: 13,
    height: 1.6,
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
  /// tapping a verified name shows the pending-approval message as an
  /// inline line and NO status.
  final bool narratorsAvailable;

  final TextStyle? style;

  @override
  State<InteractiveIsnadText> createState() => _InteractiveIsnadTextState();
}

class _InteractiveIsnadTextState extends State<InteractiveIsnadText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];
  late TextSpan _span;

  /// Inline status line for the last tapped name (null: none tapped).
  /// Embedded as a span right under the name, inside the hadith text.
  InlineNarratorStatus? _selected;

  /// Index (in the built span list) of the name the line belongs to.
  int? _selectedSpanIndex;

  /// Cached result of [buildIsnadSpans] for the current text + matches
  /// (smoothness fix 2026-11-26, review §2): parsing runs ONCE per
  /// hadith, not on every rebuild of the reader page (a tab switch
  /// rebuilds the page, and the reader hands this widget a fresh
  /// `chainLinks` list object on every build, so comparing list
  /// identity would re-parse every time). The cache key is the text
  /// plus a fingerprint of the matches' content — never list identity.
  /// Rebuilding the [TextSpan] tree for a tap toggle reuses these
  /// parsed spans; only the recognisers / inline line are rebuilt.
  List<IsnadSpan> _parsedSpans = const <IsnadSpan>[];
  String? _parsedSpansKey;

  /// Content fingerprint of the matches [_matches] would return:
  /// name + id + offsets + verified flag per match, in order.
  String _matchesFingerprint() {
    final buffer = StringBuffer();
    for (final m in _matches()) {
      buffer
        ..write(m.name)
        ..write('|')
        ..write(m.narratorId)
        ..write('|')
        ..write(m.startChar)
        ..write('|')
        ..write(m.endChar)
        ..write('|')
        ..write(m.verified)
        ..write('\n');
    }
    return buffer.toString();
  }

  /// Re-parse only when the text or the matches' content changed.
  /// Returns true when the cache was refreshed.
  bool _ensureParsedSpans() {
    final key = '${widget.text}\n${_matchesFingerprint()}';
    if (key == _parsedSpansKey) return false;
    _parsedSpans = buildIsnadSpans(widget.text, _matches());
    _parsedSpansKey = key;
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _buildSpan();
  }

  @override
  void didUpdateWidget(InteractiveIsnadText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      // A different hadith: the previous tap's line must not linger.
      _selected = null;
      _selectedSpanIndex = null;
    }
    // Rebuild ONLY when the parsed spans' content changed (or the
    // narrators package availability changed, which alters what a tap
    // shows for an already-selected line). The reader rebuilds this
    // widget with a fresh `chainLinks` list object on every build
    // (e.g. every tab switch), so comparing list identity here would
    // re-parse and rebuild the spans every time — the cache key in
    // [_ensureParsedSpans] compares content, not identity.
    final parsedChanged = _ensureParsedSpans();
    if (parsedChanged ||
        oldWidget.narratorsAvailable != widget.narratorsAvailable) {
      _buildSpan();
    }
  }

  /// Matches for the span builder, offset-first.
  ///
  /// Chain rows are the primary source: a verified row contributes its
  /// narrator id + stored offsets, an unverified parser row contributes
  /// its verbatim name + stored offsets with `verified: false` (a
  /// narrator-name span under the one-color rule — same red style,
  /// tappable, honest no-biography inline line on tap). Rows carrying
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
    // Cached parse (see [_ensureParsedSpans]): a tap toggle or a
    // parent rebuild reuses these spans — no re-parsing here.
    _ensureParsedSpans();
    final spans = _parsedSpans;
    // One style object for every narrator name in this text — the
    // one-color rule is enforced here, not per name.
    final narratorStyle = isnadNarratorNameStyle(context);
    final lineStyle = isnadInlineStatusStyle(context);
    final selected = _selected;
    final children = <TextSpan>[];
    for (var i = 0; i < spans.length; i++) {
      final s = spans[i];
      if (!s.isNarratorName) {
        children.add(TextSpan(text: s.text));
        continue;
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () {
          // Honest ladder (pure decision in narrator_logic.dart).
          // The tap shows ONLY the status + source as an INLINE LINE
          // embedded in the text right under the name (user decision
          // 2026-11-26 17:23): a verified name shows its status +
          // source, a held-back verified name shows the pending
          // message, an unverified name shows the honest no-biography
          // message — never a status, never a navigation, never a
          // sheet/card. Tapping the same name again hides the line.
          final outcome = narratorTapOutcome(
            verifiedLink: s.narratorId != null,
            narratorsAvailable: widget.narratorsAvailable,
          );
          final InlineNarratorStatus next;
          if (outcome == NarratorTapOutcome.showStatus) {
            final narrator = widget.db.narratorById(s.narratorId!);
            next = inlineStatusForTap(
              name: s.text,
              outcome: outcome,
              status: narrator?.status ?? '',
              statusSource: narrator?.statusSource ?? '',
            );
          } else {
            next = inlineStatusForTap(name: s.text, outcome: outcome);
          }
          // Rebuild AFTER the gesture finishes: _buildSpan disposes
          // the recognizer whose onTap is running, so the rebuild
          // must wait one frame. A post-frame callback alone does NOT
          // schedule a frame — in a widget test `tester.pump()` only
          // draws when a frame is scheduled, so without an explicit
          // [scheduleFrame] the callback would never run and the tap
          // would silently do nothing (diagnosed 2026-11-26: the
          // pre-existing tap test failed for exactly this reason).
          // Requesting the frame here is a no-op in the real app
          // (a frame is coming anyway) and unblocks the callback.
          WidgetsBinding.instance.scheduleFrame();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              if (_selectedSpanIndex == i) {
                _selected = null;
                _selectedSpanIndex = null;
              } else {
                _selected = next;
                _selectedSpanIndex = i;
              }
              _buildSpan();
            });
          });
        };
      _recognizers.add(recognizer);
      children.add(
        TextSpan(
          text: s.text,
          recognizer: recognizer,
          style: narratorStyle,
        ),
      );
      // The inline line: a new line right under this name, inside the
      // same paragraph — the rest of the text continues after it.
      if (selected != null && _selectedSpanIndex == i) {
        children.add(
          TextSpan(
            text: '\n${inlineStatusLineText(selected)}',
            style: lineStyle,
          ),
        );
      }
    }
    _span = TextSpan(style: baseStyle, children: children);
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
    // One RichText only: the status line is a span inside it, right
    // under the tapped name — never a separate card widget.
    return RichText(
      text: _span,
      textAlign: TextAlign.justify,
      textDirection: TextDirection.rtl,
    );
  }
}
