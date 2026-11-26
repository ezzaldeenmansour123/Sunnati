/// Takhrij entries and hadith variants — Phase 5 models.
///
/// Rows come only from the `takhrij` and `hadith_variants` tables. Both
/// tables are empty until the Phase-5 import; the takhrij lab therefore
/// shows an honest empty state instead of a fabricated comparison. A
/// variant's [diffNote] is shown exactly as recorded — no defect (`علة`)
/// or legal effect is ever inferred from a wording difference.
library;

import 'hadith.dart';

/// One takhrij record: where else the hadith is reported.
class TakhrijEntry {
  const TakhrijEntry({
    required this.sourceBook,
    required this.sourceRef,
    required this.grade,
    required this.notes,
    required this.source,
  });

  factory TakhrijEntry.fromRow(Map<String, Object?> row) {
    return TakhrijEntry(
      sourceBook: (row['source_book'] as String?) ?? '',
      sourceRef: (row['source_ref'] as String?) ?? '',
      grade: (row['grade'] as String?) ?? '',
      notes: (row['notes'] as String?) ?? '',
      source: (row['source'] as String?) ?? '',
    );
  }

  /// Book the hadith is also reported in, e.g. `صحيح مسلم`.
  final String sourceBook;

  /// Reference inside that book, e.g. `حديث 123`.
  final String sourceRef;

  /// Grade recorded for that occurrence. Empty when unrecorded.
  final String grade;

  /// Notes recorded with the entry. Empty when none.
  final String notes;

  /// Source of this takhrij record. Empty when unrecorded.
  final String source;
}

/// One recorded route (طريق) of a hadith: another hadith row reporting
/// the same matn, with the kind of variation and the recorded note.
class HadithVariant {
  const HadithVariant({
    required this.variantHadithId,
    required this.variant,
    required this.variantType,
    required this.diffNote,
    required this.source,
  });

  factory HadithVariant.fromRow(
    Map<String, Object?> row, {
    Hadith? variant,
  }) {
    return HadithVariant(
      variantHadithId: (row['variant_hadith_id'] as int?) ?? 0,
      variant: variant,
      variantType: (row['variant_type'] as String?) ?? '',
      diffNote: (row['diff_note'] as String?) ?? '',
      source: (row['source'] as String?) ?? '',
    );
  }

  /// Id of the variant hadith row (0 when the variant is a bare reference).
  final int variantHadithId;

  /// The variant hadith itself, or null when only a reference is recorded.
  final Hadith? variant;

  /// Kind of variation as recorded, e.g. `لفظ آخر`.
  final String variantType;

  /// Recorded note on the difference. Empty when unrecorded.
  final String diffNote;

  /// Source of this variant record. Empty when unrecorded.
  final String source;
}
