/// Visible «غير مترجم» tag for chapter titles.
///
/// Shown next to a chapter title that is still the English verbatim
/// title from the source (see [isUntranslatedChapterTitle] in
/// `lib/models/book.dart`) — never present an English title as if it
/// were the Arabic باب, and never invent an Arabic title. The real
/// Arabic titles come later from the per-book pilots.
library;

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';

class UntranslatedChapterTag extends StatelessWidget {
  const UntranslatedChapterTag({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: SunnatiColors.goldSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SunnatiColors.gold),
      ),
      child: const Text(
        'غير مترجم',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: SunnatiColors.petrol,
        ),
      ),
    );
  }
}
