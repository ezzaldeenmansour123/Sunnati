/// Pure narrator logic — no Flutter dependency.
///
/// Used by the interactive isnad, the narrator card, the encyclopedia and
/// the "men assistant". Everything here is deterministic and unit-tested;
/// no data is invented: a name becomes tappable only when a verified chain
/// row links it to a narrator id, and a status is ranked only when its
/// wording matches one of the eight documented verdicts below.
library;

import 'normalize.dart';

/// One confirmed narrator name as it appears in a hadith text.
class IsnadNameMatch {
  const IsnadNameMatch({required this.name, required this.narratorId});

  /// Name exactly as stored for the narrator (e.g. `الزهري`).
  final String name;

  /// Verified narrator id from the `chains` table.
  final int narratorId;
}

/// One slice of a hadith text: plain text, or a tappable narrator name.
class IsnadSpan {
  const IsnadSpan({required this.text, this.narratorId});

  final String text;

  /// Non-null only for a confirmed narrator name.
  final int? narratorId;

  bool get isNarrator => narratorId != null;
}

/// Normalised text together with the origin of every normalised character.
///
/// Normalisation here is strictly 1:1 per character (diacritics dropped,
/// hamzas unified, punctuation turned into a space) and whitespace is NOT
/// collapsed, so every normalised index maps back to exactly one original
/// index. That is what lets a name found in the normalised text be sliced
/// out of the original text with its diacritics intact.
class NormalizedText {
  const NormalizedText({required this.text, required this.origins});

  /// Normalised characters.
  final String text;

  /// `origins[i]` is the index in the original string of `text[i]`.
  final List<int> origins;

  /// Original-text slice covered by normalised range [start, end).
  String sliceOriginal(String original, int start, int end) {
    if (start >= end || origins.isEmpty) return '';
    final from = origins[start];
    final to = end < origins.length ? origins[end] : original.length;
    return original.substring(from, to);
  }
}

/// Normalise [input] for matching, keeping the origin map.
NormalizedText normalizeForMatching(String input) {
  const diacritics = 'ًٌٍَُِّْٰٓـ';
  final buffer = StringBuffer();
  final origins = <int>[];
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (diacritics.contains(ch)) continue;
    final mapped = switch (ch) {
      'أ' || 'إ' || 'آ' => 'ا',
      'ؤ' => 'و',
      'ئ' => 'ي',
      'ى' => 'ي',
      'ة' => 'ه',
      _ => RegExp(r'[\u0621-\u064A0-9]').hasMatch(ch) ? ch : ' ',
    };
    buffer.write(mapped);
    origins.add(i);
  }
  return NormalizedText(text: buffer.toString(), origins: origins);
}

/// Find [name] in [text] (both normalised for matching) starting at
/// [from]. Returns the original-text range, or null when the name does not
/// occur there. A match must start and end on word boundaries so `شعبة`
/// never matches inside another word.
({int start, int end})? findNameInText(
  String text,
  String name, {
  int from = 0,
}) {
  final haystack = normalizeForMatching(text);
  final needle = normalizeArabic(name);
  if (needle.isEmpty) return null;
  var at = haystack.text.indexOf(needle, from);
  while (at >= 0) {
    final beforeOk =
        at == 0 || haystack.text[at - 1] == ' ';
    final after = at + needle.length;
    final afterOk =
        after >= haystack.text.length || haystack.text[after] == ' ';
    if (beforeOk && afterOk) {
      return (
        start: haystack.origins[at],
        end: after < haystack.origins.length
            ? haystack.origins[after]
            : text.length,
      );
    }
    at = haystack.text.indexOf(needle, at + 1);
  }
  return null;
}

/// Split [text] into plain and tappable slices.
///
/// Only names in [confirmed] become tappable, in chain order; each name is
/// matched once, scanning forward from the previous match, so the same
/// name appearing twice links only its first occurrence in isnad order and
/// a name that does not occur in the text yields no span at all. Names not
/// in [confirmed] are never made tappable — no linking by mere similarity.
List<IsnadSpan> buildIsnadSpans(String text, List<IsnadNameMatch> confirmed) {
  if (text.isEmpty || confirmed.isEmpty) {
    return <IsnadSpan>[IsnadSpan(text: text)];
  }
  final spans = <IsnadSpan>[];
  var cursor = 0;
  var searchFrom = 0;
  final normalized = normalizeForMatching(text);
  for (final entry in confirmed) {
    final needle = normalizeArabic(entry.name);
    if (needle.isEmpty) continue;
    var at = normalized.text.indexOf(needle, searchFrom);
    ({int start, int end})? found;
    var foundAfterNorm = -1;
    while (at >= 0) {
      final beforeOk = at == 0 || normalized.text[at - 1] == ' ';
      final after = at + needle.length;
      final afterOk =
          after >= normalized.text.length || normalized.text[after] == ' ';
      if (beforeOk && afterOk) {
        final start = normalized.origins[at];
        final end = after < normalized.origins.length
            ? normalized.origins[after]
            : text.length;
        found = (start: start, end: end);
        foundAfterNorm = after;
        break;
      }
      at = normalized.text.indexOf(needle, at + 1);
    }
    if (found == null) continue;
    if (found.start > cursor) {
      spans.add(IsnadSpan(text: text.substring(cursor, found.start)));
    }
    spans.add(
      IsnadSpan(
        text: text.substring(found.start, found.end),
        narratorId: entry.narratorId,
      ),
    );
    cursor = found.end;
    searchFrom = foundAfterNorm;
  }
  if (cursor < text.length) {
    spans.add(IsnadSpan(text: text.substring(cursor)));
  }
  if (spans.isEmpty) return <IsnadSpan>[IsnadSpan(text: text)];
  return spans;
}

/// The eight documented jarh-wa-ta'dil verdicts, in order of strength.
///
/// `مختلف فيه` is not a rank — it marks conflicting verdicts, so it has
/// no rank and [isDisputedStatus] is true instead. Anything else returns
/// a null rank: an unrecognised wording is never forced into a rank.
const Map<String, int> _gradeRanks = <String, int>{
  'ثقه ثبت': 1,
  'ثقه': 2,
  'صدوق': 3,
  'لا باس به': 4,
  'ضعيف': 5,
  'متروك': 6,
  'مجهول': 7,
};

/// Canonical display labels for the eight verdicts.
const List<String> gradeVerdicts = <String>[
  'ثقة',
  'ثقة ثبت',
  'صدوق',
  'لا بأس به',
  'ضعيف',
  'متروك',
  'مجهول',
  'مختلف فيه',
];

/// Rank of [status] (1 strongest … 7 weakest), or null when the wording
/// is `مختلف فيه` or unrecognised.
int? gradeRank(String status) {
  final norm = normalizeArabic(status.trim());
  if (norm.isEmpty || isDisputedStatus(status)) return null;
  return _gradeRanks[norm];
}

/// True when [status] records conflicting verdicts about the narrator.
bool isDisputedStatus(String status) {
  final norm = normalizeArabic(status);
  return norm.contains('مختلف فيه') || norm.contains('مختلف');
}

/// Canonical label for [status] when it matches a known verdict,
/// otherwise the trimmed original wording (never rewritten).
String canonicalGradeLabel(String status) {
  final norm = normalizeArabic(status.trim());
  for (final verdict in gradeVerdicts) {
    if (normalizeArabic(verdict) == norm) return verdict;
  }
  return status.trim();
}

/// Compare two verdicts by rank: negative when [a] is stronger.
/// Returns null when either side has no rank (disputed / unknown).
int? compareGradeRanks(String a, String b) {
  final ra = gradeRank(a);
  final rb = gradeRank(b);
  if (ra == null || rb == null) return null;
  return ra.compareTo(rb);
}
