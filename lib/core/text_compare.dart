/// Pure word-level comparison of two hadith wordings.
///
/// Used by the takhrij lab to show what two recorded routes share and
/// where their wording differs. It is a mechanical token comparison only:
/// it never infers a defect (`علة`) or a legal effect — those need a
/// sourced note in the database, and the UI says so when none exists.
library;

import 'normalize.dart';

/// Result of comparing a base wording with one variant wording.
class VariantComparison {
  const VariantComparison({
    required this.common,
    required this.onlyInBase,
    required this.onlyInVariant,
  });

  /// Normalised words present in both wordings, in base order, deduplicated.
  final List<String> common;

  /// Normalised words present only in the base wording.
  final List<String> onlyInBase;

  /// Normalised words present only in the variant wording.
  final List<String> onlyInVariant;

  bool get identical => onlyInBase.isEmpty && onlyInVariant.isEmpty;
}

/// Compare [base] and [variant] word by word (normalised tokens).
VariantComparison compareVariantTexts(String base, String variant) {
  List<String> tokens(String s) {
    final seen = <String>{};
    return tokenize(normalizeArabic(s))
        .where((t) => seen.add(t))
        .toList();
  }

  final baseTokens = tokens(base);
  final variantTokens = tokens(variant);
  final variantSet = variantTokens.toSet();
  final baseSet = baseTokens.toSet();
  return VariantComparison(
    common: baseTokens.where(variantSet.contains).toList(),
    onlyInBase: baseTokens.where((t) => !variantSet.contains(t)).toList(),
    onlyInVariant:
        variantTokens.where((t) => !baseSet.contains(t)).toList(),
  );
}
