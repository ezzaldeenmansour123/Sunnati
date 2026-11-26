/// Interactive isnad text — Phase 5.
///
/// Renders a hadith text as a [RichText] in which only names linked to
/// verified narrators (from the `chains` table, via
/// [SunnatiDatabase.narratorsForHadith]) are tappable. Tappable names are
/// shown in petrol with a light gold underline; every other name stays
/// plain text. Tapping a name opens the narrator card as a bottom sheet
/// over the current page, so the reader never loses its place.
///
/// The text itself is never altered: matching is done on a normalised
/// copy (see `lib/core/narrator_logic.dart`) and the displayed slices
/// come from the original text with its diacritics intact.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/narrator_logic.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../models/narrator.dart';
import 'narrator_card.dart';

class InteractiveIsnadText extends StatefulWidget {
  const InteractiveIsnadText({
    super.key,
    required this.db,
    required this.text,
    required this.confirmedNarrators,
    this.style,
  });

  final SunnatiDatabase db;

  /// Full hadith text (isnad + matn) exactly as stored.
  final String text;

  /// Verified narrators of this hadith, in chain order.
  final List<Narrator> confirmedNarrators;

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
        oldWidget.confirmedNarrators != widget.confirmedNarrators) {
      _buildSpan();
    }
  }

  void _buildSpan() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final baseStyle = widget.style ??
        const TextStyle(fontSize: 20, height: 1.9);
    final matches = widget.confirmedNarrators
        .map(
          (n) => IsnadNameMatch(name: n.displayName, narratorId: n.id),
        )
        .toList();
    final spans = buildIsnadSpans(widget.text, matches);
    _span = TextSpan(
      style: baseStyle,
      children: spans.map((s) {
        if (!s.isNarrator) return TextSpan(text: s.text);
        final recognizer = TapGestureRecognizer()
          ..onTap = () {
            showNarratorSheetById(context, widget.db, s.narratorId!);
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
