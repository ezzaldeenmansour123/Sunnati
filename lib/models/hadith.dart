/// A single hadith row.
///
/// The stored `text` keeps its diacritics exactly as the source gives them;
/// search uses the separate normalised `norm` column (see
/// `lib/core/normalize.dart`). The isnad is part of `text` in Phase 1 —
/// it is NOT split out or paraphrased until Phase 5 has a verified source
/// for narrator/chain data.
library;

import 'grade.dart';

class Hadith {
  const Hadith({
    required this.id,
    required this.bookId,
    required this.num,
    required this.chapterId,
    required this.chapterTitle,
    required this.text,
    required this.grades,
    required this.explanation,
    required this.explanationSource,
  });

  factory Hadith.fromRow(Map<String, Object?> row) {
    return Hadith(
      id: (row['id'] as int?) ?? 0,
      bookId: row['book'] as String,
      num: (row['num'] as int?) ?? 0,
      chapterId: (row['chapter_id'] as int?) ?? 0,
      chapterTitle: (row['chapter_title'] as String?) ?? '',
      text: (row['text'] as String?) ?? '',
      grades: parseGrades(row['grades'] as String?),
      explanation: (row['expl'] as String?) ?? '',
      explanationSource: (row['expl_src'] as String?) ?? '',
    );
  }

  /// Stable id of the form `<book>:<num>`, e.g. `bukhari:1`.
  /// Used for favourites, notes, tags and history.
  String get stableId => '$bookId:$num';

  final int id;
  final String bookId;
  final int num;
  final int chapterId;
  final String chapterTitle;

  /// Full text (isnad + matn) exactly as the source provides it.
  final String text;

  /// Gradings supplied by the source; empty means "no grading recorded".
  final List<HadithGrade> grades;

  /// Transmitted commentary (HadeethEnc only in Phase 1); empty if none.
  final String explanation;

  /// Source of [explanation], shown next to it; empty if none.
  final String explanationSource;

  bool get hasExplanation => explanation.isNotEmpty;
  bool get hasGrades => grades.isNotEmpty;
}
