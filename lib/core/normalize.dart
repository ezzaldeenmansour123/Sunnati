/// Arabic text normalisation for search indexing and querying.
///
/// The stored hadith text is NEVER modified: diacritics are kept in the
/// database. Normalisation produces a separate indexed form (`norm` column)
/// used only by FTS5, exactly as documented in the master prompt §7.
///
/// Rules (must match `tools/build_db.py` byte-for-byte in behaviour):
///  - strip tashkeel (diacritics) and tatweel (kashida)
///  - unify hamzas (أ إ آ ؤ ئ) to bare alef / yeh as appropriate
///  - alef maksura ى → ي, teh marbuta ة → ه
///  - strip punctuation, keep Arabic letters and digits
///  - strip the prefixes و / ف / ب / ل / ك and the definite article ال,
///    so «بالنيات» is found by «النيات»
///
/// Pure functions — no Flutter dependency, fully unit-tested.
library;

/// Arabic diacritics (tashkeel) + tatweel, removed for indexing only.
const String _diacritics = 'ًٌٍَُِّْٰٓـ';

/// Punctuation / symbols stripped from indexed text.
final RegExp _punctuation = RegExp(r'[^\u0621-\u064A\u0660-\u0669\u06F0-\u06F90-9\s]');

/// Normalise one Arabic string for indexing / querying.
///
/// Returns the normalised form; the input is never mutated.
String normalizeArabic(String input) {
  var s = input;
  for (var i = 0; i < _diacritics.length; i++) {
    s = s.replaceAll(_diacritics[i], '');
  }
  s = s
      .replaceAll('أ', 'ا')
      .replaceAll('إ', 'ا')
      .replaceAll('آ', 'ا')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ي')
      .replaceAll('ى', 'ي')
      .replaceAll('ة', 'ه');
  s = s.replaceAll(_punctuation, ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

/// Strip a single leading prefix (و / ف / ب / ل / ك) and/or the article ال.
///
/// Applied repeatedly so «وبالنيات» → «نيات». Only strips when the remainder
/// keeps at least two letters, so short words such as «لا» are untouched.
String stripPrefixes(String word) {
  var w = word;
  var changed = true;
  while (changed && w.length > 2) {
    changed = false;
    if (w.startsWith('ال') && w.length > 3) {
      w = w.substring(2);
      changed = true;
    } else if ((w.startsWith('و') ||
            w.startsWith('ف') ||
            w.startsWith('ب') ||
            w.startsWith('ل') ||
            w.startsWith('ك')) &&
        w.length > 2) {
      w = w.substring(1);
      changed = true;
    }
  }
  return w;
}

/// All indexed variants of one word: the word itself plus its
/// prefix-stripped form (when different). The DB indexer stores both, so a
/// query for either form matches.
List<String> indexVariants(String word) {
  final stripped = stripPrefixes(word);
  if (stripped == word || stripped.isEmpty) return <String>[word];
  return <String>[word, stripped];
}

/// Tokenise normalised text into words.
List<String> tokenize(String normalizedText) {
  if (normalizedText.trim().isEmpty) return const <String>[];
  return normalizedText.split(' ');
}

/// Normalise a user query and return its search terms (words, prefixes
/// stripped). Empty input yields an empty list.
List<String> queryTerms(String query) {
  final norm = normalizeArabic(query);
  return tokenize(norm)
      .map(stripPrefixes)
      .where((t) => t.isNotEmpty)
      .toList();
}
