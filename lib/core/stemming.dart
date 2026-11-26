/// Light Arabic stemming / root keys for lexical semantic search.
///
/// Pure functions — no Flutter dependency. This is the Dart mirror of
/// `tools/arabic_text.py` (`light_stem`, `root_key`, `spelling_variants`):
/// the two MUST stay in sync (same rules, same edge cases).
///
/// A root key is a HEURISTIC grouping key, not a real morphological
/// analysis. It groups regular derivations (صلاة/صلوات/يصلي → «صلي»)
/// but does NOT unify broken plurals or different patterns
/// (كتاب/كتب/كاتب stay apart). Deliberately conservative (precision
/// over recall):
///  - only the article prefixes, ONE verb prefix (يـ), regular nominal
///    suffixes, and a weak-letter ending unification (ا/و → ي);
///  - تـ/نـ/أ verb prefixes are NOT stripped — they collapse unrelated
///    nouns (نيات «intentions» with فتيات «girls»);
///  - trailing ي/و are NOT stripped — they collapse 2-letter roots
///    across unrelated words (شر «evil» with شريك «partner»);
///  - a final ن is NOT a suffix — stripping it collapses أيمن
///    «right-hand» into إيمان «faith».
library;

/// Suffixes tried longest-first. A strip is kept only if >= 3 letters
/// remain — except ه and ات, which may leave >= 2 (نيه/نيات → «ني»).
const List<String> _suffixes = <String>[
  'ات',
  'ون',
  'ين',
  'ان',
  'وا',
  'ية',
  'ها',
  'هم',
  'هن',
  'كم',
  'نا',
  'ه',
  'ي',
  'ك',
  'ة',
  'ت',
];

/// Compound article prefixes stripped first (stricter than
/// [stripPrefixes]: a bare و/ف/ب/ل/ك is stripped only when >= 4 letters
/// remain, so «وصل» does NOT collapse into the «صل» root group).
const List<String> _compoundPrefixes = <String>[
  'وال',
  'فال',
  'بال',
  'كال',
  'لل',
  'ال',
];

String _stripRootPrefixes(String word) {
  var w = word;
  var changed = true;
  while (changed) {
    changed = false;
    for (final p in _compoundPrefixes) {
      if (w.startsWith(p) && w.length - p.length >= 3) {
        w = w.substring(p.length);
        changed = true;
        break;
      }
    }
    if (!changed && w.length >= 5 && 'وفبلك'.contains(w[0])) {
      w = w.substring(1);
      changed = true;
    }
  }
  return w;
}

/// Heuristic stem of one normalised word (see file docstring).
String lightStem(String word) {
  var w = _stripRootPrefixes(word);
  // Verb prefix يـ only, when >= 3 letters remain (يصلي → صلي).
  if (w.length >= 4 && w.startsWith('ي')) {
    w = w.substring(1);
  }
  // Up to two suffix strips, longest first.
  for (var i = 0; i < 2; i++) {
    var stripped = false;
    for (final suf in _suffixes) {
      final minRemain = (suf == 'ه' || suf == 'ات') ? 2 : 3;
      if (w.endsWith(suf) && w.length - suf.length >= minRemain) {
        w = w.substring(0, w.length - suf.length);
        stripped = true;
        break;
      }
    }
    if (!stripped) break;
  }
  // Weak-letter ending unification: final ا/و → ي (صلا/صلو → صلي).
  if (w.length >= 3 && (w.endsWith('ا') || w.endsWith('و'))) {
    w = '${w.substring(0, w.length - 1)}ي';
  }
  return w;
}

/// Root-group key for one normalised word.
///
/// Returns '' when the word is too short to group safely (<= 1 letter
/// after prefix stripping) — such words are never root-expanded.
String rootKey(String word) {
  final base = _stripRootPrefixes(word);
  if (base.length <= 1) return '';
  final stem = lightStem(word);
  return stem.length >= 2 ? stem : '';
}

/// ابن <-> بن inside isnads: the same person is written both ways.
const Map<String, String> ibnVariants = <String, String>{
  'ابن': 'بن',
  'بن': 'ابن',
};

/// Extra query forms for one normalised term.
///
/// * «ابن» <-> «بن».
/// * Joined «عبدX» (عبدالله، عبدالرحمن…) also searches the split form
///   «عبد X» — returned as the two-word variant `'عبد X'`.
List<String> spellingVariants(String term) {
  final out = <String>[];
  final ibn = ibnVariants[term];
  if (ibn != null) out.add(ibn);
  if (term.startsWith('عبد') && term.length > 3) {
    out.add('عبد ${term.substring(3)}');
  }
  return out;
}

/// Common words dropped from similarity (not from search): they occur in
/// almost every hadith and carry no discriminating meaning.
/// Mirror of `STOPWORDS` in `tools/arabic_text.py`.
const Set<String> kStopwords = <String>{
  'في',
  'من',
  'الي',
  'عن',
  'ان',
  'ما',
  'لا',
  'قد',
  'ثم',
  'قال',
  'رسول',
  'الله',
  'عليه',
  'وسلم',
  'صلي',
  'الذي',
  'التي',
  'كان',
  'يكون',
  'هذا',
  'هذه',
  'ذلك',
  'كل',
  'لم',
  'لن',
  'هو',
  'هي',
  'هم',
  'اذا',
  'او',
  'ام',
  'بل',
  'لكن',
  'علي',
  'مع',
  'بعد',
  'قبل',
  'عند',
  'بين',
  'غير',
  'حتي',
  'كما',
  'لما',
  'انما',
  'انه',
  'انها',
  'يا',
  'ايها',
  'بن',
  'ابن',
  'ابي',
  'ابو',
  'رضي',
  'عنه',
  'عنها',
  'عنهم',
  'قالوا',
  'قالت',
  'حدثنا',
  'حدثني',
  'اخبرنا',
  'اخبرني',
  'سمعت',
  'انبأنا',
  'يعني',
  'ح',
  'ثنا',
  'انا',
  'ومن',
};
