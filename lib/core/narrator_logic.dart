/// Pure narrator logic — no Flutter dependency.
///
/// Used by the interactive isnad, the isnad tree, the encyclopedia and
/// the "men assistant". Everything here is deterministic and unit-tested;
/// no data is invented: a name is rendered as a narrator name whenever a
/// parser row names it (one-color rule, user decision 2026-11-26 15:03 —
/// every parsed name in one style, all tappable; the colour is the
/// single distinctive RED of user decision 2026-11-26 17:23), and a
/// status is shown only when a verified chain row links it to a
/// narrator id, ranked only when its wording matches one of the eight
/// documented verdicts below.
library;

import 'normalize.dart';

/// Exact honest-ladder copy — single source of truth.
///
/// The UI shows one of these strings and never invents a status or a
/// source. Keep the wording identical everywhere (widgets import these
/// constants; tests assert them verbatim).

/// (b) A verified link exists but the narrators package is held back.
const String kNarratorsPendingApprovalMessage =
    'حزمة الرواة قيد انتظار الموافقة — الحالة غير متاحة بعد';

/// (c) No verified biography exists for this narrator (yet).
const String kNoVerifiedBiographyMessage =
    'لا توجد ترجمة موثّقة لهذا الراوي بعد.';

/// Parser rows exist for this hadith but none of them is verified.
const String kNoVerifiedChainMessage =
    'أسماء الرواة غير مرتبطة بعد — لا توجد بيانات سلسلة موثّقة لهذا الحديث.';

/// This hadith has no parser rows at all: its isnad was never parsed.
const String kIsnadNotParsedMessage =
    'إسناد هذا الحديث لم يُحلَّل بعد — لا توجد أسماء رواة موثّقة لهذا الحديث.';

/// What tapping a narrator name must show, decided from facts only.
///
/// * [showStatus] — a verified link and the narrators package is
///   installed: show the status + source as an INLINE LINE embedded in
///   the hadith text itself, right under the tapped name (user decision
///   2026-11-26 17:23, superseding the 16:49 small-card design and the
///   build-81 details sheet). Never a popup card/sheet, never the full
///   details page, never a navigation.
/// * [pendingApproval] — a verified link but the narrators package is
///   held back: show [kNarratorsPendingApprovalMessage] as an inline
///   line and NO status.
/// * [noVerifiedBiography] — no verified link: show
///   [kNoVerifiedBiographyMessage] as an inline line and nothing else.
enum NarratorTapOutcome { showStatus, pendingApproval, noVerifiedBiography }

/// Pure decision for the honest ladder (unit-tested, no widgets).
NarratorTapOutcome narratorTapOutcome({
  required bool verifiedLink,
  required bool narratorsAvailable,
}) {
  if (!verifiedLink) return NarratorTapOutcome.noVerifiedBiography;
  if (!narratorsAvailable) return NarratorTapOutcome.pendingApproval;
  return NarratorTapOutcome.showStatus;
}

/// A verified narrator row exists but records no status wording.
const String kNoRecordedStatusMessage =
    'لا توجد حالة مسجّلة لهذا الراوي بعد.';

/// Data for the INLINE status line embedded in the hadith text itself,
/// right under the tapped narrator name (user decision 2026-11-26
/// 17:23): status + source only, never a popup card/sheet, never the
/// full details page, never a navigation. The full narrator page stays
/// available ONLY from the narrators encyclopedia.
class InlineNarratorStatus {
  const InlineNarratorStatus({
    required this.name,
    this.status = '',
    this.statusSource = '',
    this.message = '',
  });

  /// Name exactly as tapped in the hadith text (empty for a
  /// message-only line, e.g. from the reader's coverage line).
  final String name;

  /// The recorded status wording (e.g. `ثقة`), empty when no status
  /// is recorded or the rung shows a message instead.
  final String status;

  /// Source of [status] (e.g. `تقريب التهذيب`), empty when unknown.
  final String statusSource;

  /// Honest message shown instead of a status (pending-approval /
  /// no-verified-biography / no-recorded-status rungs).
  final String message;

  /// True when a status is available to show.
  bool get hasStatus => status.isNotEmpty;
}

/// Display text of the inline status line for [status]: the status
/// with its source (`ثقة — مصدر الحكم: تقريب التهذيب`) when a status
/// exists, otherwise the honest [InlineNarratorStatus.message]. Pure
/// and unit-tested — the same wording is used by the isnad text, the
/// isnad tree and the reader's narrators list, so the line always
/// reads the same everywhere.
String inlineStatusLineText(InlineNarratorStatus status) {
  if (status.hasStatus) {
    if (status.statusSource.isEmpty) return status.status;
    return '${status.status} — مصدر الحكم: ${status.statusSource}';
  }
  return status.message;
}

/// Build the inline status line's data from a tap outcome
/// (pure, unit-tested). [status] / [statusSource] come from the
/// verified narrator row and are only used on the showStatus rung;
/// every other rung shows its honest message and no status.
InlineNarratorStatus inlineStatusForTap({
  required String name,
  required NarratorTapOutcome outcome,
  String status = '',
  String statusSource = '',
}) {
  switch (outcome) {
    case NarratorTapOutcome.showStatus:
      if (status.isEmpty) {
        return InlineNarratorStatus(
          name: name,
          message: kNoRecordedStatusMessage,
        );
      }
      return InlineNarratorStatus(
        name: name,
        status: status,
        statusSource: statusSource,
      );
    case NarratorTapOutcome.pendingApproval:
      return InlineNarratorStatus(
        name: name,
        message: kNarratorsPendingApprovalMessage,
      );
    case NarratorTapOutcome.noVerifiedBiography:
      return InlineNarratorStatus(
        name: name,
        message: kNoVerifiedBiographyMessage,
      );
  }
}

/// Coverage state of one hadith's isnad, for the reader's honest line.
///
/// * [verifiedAvailable] — at least one verified narrator is attached
///   (package installed).
/// * [verifiedHeldBack] — verified links exist in `hadith_narrators`
///   but the narrators package is not installed.
/// * [parserRowsNoVerified] — parser rows exist but none is verified.
/// * [notParsed] — no parser rows at all for this hadith.
enum HadithCoverageState {
  verifiedAvailable,
  verifiedHeldBack,
  parserRowsNoVerified,
  notParsed,
}

/// Pure decision for the reader's coverage line (unit-tested).
HadithCoverageState hadithCoverageState({
  required bool hasVerifiedNarrators,
  required bool hasVerifiedLinks,
  required bool hasParserRows,
}) {
  if (hasVerifiedNarrators) return HadithCoverageState.verifiedAvailable;
  if (hasVerifiedLinks) return HadithCoverageState.verifiedHeldBack;
  if (hasParserRows) return HadithCoverageState.parserRowsNoVerified;
  return HadithCoverageState.notParsed;
}

/// One confirmed narrator name as it appears in a hadith text.
class IsnadNameMatch {
  const IsnadNameMatch({
    required this.name,
    required this.narratorId,
    this.startChar,
    this.endChar,
    this.verified = true,
  });

  /// Name exactly as stored for the narrator (e.g. `الزهري`), or the
  /// parser's verbatim slice (`narrator_text`) for an unverified name.
  final String name;

  /// Verified narrator id from the `chains` table, or null for an
  /// unverified parser name (tappable under the one-color rule; the tap
  /// shows the honest no-biography inline line, never a status).
  final int? narratorId;

  /// Exact character offsets of this name inside the hadith text, from
  /// `hadith_narrators.start_char` / `end_char` (the parser's verbatim
  /// slice). Null when the row carries no offsets — the name-search
  /// fallback is then used, and is lower-confidence (see
  /// [buildIsnadSpans]).
  final int? startChar;

  /// Exclusive end offset (see [startChar]).
  final int? endChar;

  /// True only for a `linked_verified` row. Unverified parser names
  /// (`needs_review` / `unlinked`) are false: they carry no verified id,
  /// so a tap on them shows the honest no-biography inline line and never
  /// a status — but under the one-color rule they are still rendered in
  /// the single narrator-name style and remain tappable.
  final bool verified;

  /// True when both offsets are present (validity is checked again
  /// against the text length by the span builder).
  bool get hasOffsets => startChar != null && endChar != null;
}

/// One slice of a hadith text: plain text, or a parsed narrator name.
///
/// ONE-COLOR RULE (user decision 2026-11-26 15:03): every parsed
/// narrator name — verified or not — is a narrator-name span
/// ([isNarratorName] true) and the widget renders all of them in the
/// single narrator-name style (one distinctive red) and makes them
/// all tappable. Verified and unverified names differ ONLY in what the
/// tap shows (see [narratorTapOutcome]): a verified name shows its
/// status in the inline line (or the pending-approval message
/// when the package is held);
/// an unverified name shows the honest «لا توجد ترجمة موثّقة بعد»
/// inline line and never a status.
///
/// [isNarrator] keeps its old meaning (verified only: a non-null
/// [narratorId]) so existing callers/tests that count verified links
/// keep working; use [isNarratorName] for styling and tappability.
class IsnadSpan {
  const IsnadSpan({
    required this.text,
    this.narratorId,
    this.isNarratorName = false,
  });

  final String text;

  /// Non-null only for a confirmed (verified) narrator name.
  final int? narratorId;

  /// True for every parsed narrator name in this slice, verified or
  /// unverified. Plain text is false.
  final bool isNarratorName;

  /// True only for a verified narrator name.
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
/// Offset-first: entries carrying `start_char`/`end_char` from
/// `hadith_narrators` are placed at their exact stored positions — the
/// parser's verbatim slice, diacritics intact — so a name repeated in
/// one hadith gets one span per parser row, at its own occurrence.
/// Entries without (usable) offsets fall back to normalised name search
/// ([_buildIsnadSpansByName]); that path is LOWER-CONFIDENCE — it
/// re-derives a position instead of using the stored one, and must never
/// be treated as verified positioning.
///
/// Only verified entries ([IsnadNameMatch.verified] with a non-null
/// [IsnadNameMatch.narratorId]) carry a narrator id. EVERY parsed entry
/// — verified or unverified — becomes a narrator-name span
/// ([IsnadSpan.isNarratorName] true) at its exact offsets, in the single
/// narrator-name style, tappable under the one-color rule; what the tap
/// shows is decided by [narratorTapOutcome], never by the style. Names
/// not in [confirmed] are never made narrator names — no linking by
/// mere similarity.
List<IsnadSpan> buildIsnadSpans(String text, List<IsnadNameMatch> confirmed) {
  if (text.isEmpty || confirmed.isEmpty) {
    return <IsnadSpan>[IsnadSpan(text: text)];
  }
  if (confirmed.every((m) => !m.hasOffsets)) {
    return _buildIsnadSpansByName(text, confirmed);
  }
  return buildIsnadSpansWithOffsets(text, confirmed);
}

/// Offset-based span building (see [buildIsnadSpans]).
///
/// An offset entry is usable only when `0 <= start < end <=
/// text.length`; an unusable entry (null, reversed, or out of range)
/// falls back to name search instead of being placed blindly. Entries
/// overlapping an already-placed span are skipped (the earliest start
/// wins; chain order breaks ties), so the result never double-covers
/// any character. Name-only verified entries are placed by normalised
/// search into the gaps left by the offset spans, never over them.
List<IsnadSpan> buildIsnadSpansWithOffsets(
  String text,
  List<IsnadNameMatch> confirmed,
) {
  if (text.isEmpty || confirmed.isEmpty) {
    return <IsnadSpan>[IsnadSpan(text: text)];
  }
  // Placed ranges: (start, end, narratorId or null, narrator-name?).
  // Every placed parser row is a narrator name (one-color rule);
  // only verified rows carry a narrator id.
  final placed = <({
    int start,
    int end,
    int? narratorId,
    bool isNarratorName,
  })>[];

  bool overlaps(int start, int end) {
    for (final p in placed) {
      if (start < p.end && p.start < end) return true;
    }
    return false;
  }

  // 1. Offset entries first, in stored position order.
  final offsetEntries = confirmed
      .where(
        (m) =>
            m.hasOffsets &&
            m.startChar! >= 0 &&
            m.startChar! < m.endChar! &&
            m.endChar! <= text.length,
      )
      .toList()
    ..sort((a, b) => a.startChar!.compareTo(b.startChar!));
  // Entries already resolved by their offsets (placed, or skipped
  // because they overlap a placed span) must NOT be re-searched by
  // name: name search could link a different occurrence. Entries
  // whose offsets are unusable (null, reversed, out of range) are NOT
  // in either set, so step 2 falls back to name search for them.
  final offsetResolved = <IsnadNameMatch>{};
  for (final entry in offsetEntries) {
    final start = entry.startChar!;
    final end = entry.endChar!;
    offsetResolved.add(entry);
    if (overlaps(start, end)) continue;
    placed.add(
      (
        start: start,
        end: end,
        narratorId: entry.verified ? entry.narratorId : null,
        // One-color rule: an unverified parser name is still a
        // narrator name (same style, tappable); it just has no id,
        // so its tap shows the honest no-biography inline line.
        isNarratorName: true,
      ),
    );
  }

  // 2. Name-only entries, by normalised search into the gaps.
  // LOWER-CONFIDENCE fallback (see [buildIsnadSpans]): only for rows
  // without usable stored offsets. Verified rows carry their id;
  // unverified rows are placed as narrator names with no id.
  final normalized = normalizeForMatching(text);
  for (final entry in confirmed) {
    if (offsetResolved.contains(entry)) continue;
    final needle = normalizeArabic(entry.name);
    if (needle.isEmpty) continue;
    var at = normalized.text.indexOf(needle);
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
        if (!overlaps(start, end)) {
          placed.add(
            (
              start: start,
              end: end,
              narratorId: entry.verified ? entry.narratorId : null,
              isNarratorName: true,
            ),
          );
          break;
        }
      }
      at = normalized.text.indexOf(needle, at + 1);
    }
  }

  if (placed.isEmpty) return <IsnadSpan>[IsnadSpan(text: text)];
  placed.sort((a, b) => a.start.compareTo(b.start));
  final spans = <IsnadSpan>[];
  var cursor = 0;
  for (final p in placed) {
    if (p.start > cursor) {
      spans.add(IsnadSpan(text: text.substring(cursor, p.start)));
    }
    spans.add(
      IsnadSpan(
        text: text.substring(p.start, p.end),
        narratorId: p.narratorId,
        isNarratorName: p.isNarratorName,
      ),
    );
    cursor = p.end;
  }
  if (cursor < text.length) {
    spans.add(IsnadSpan(text: text.substring(cursor)));
  }
  if (spans.isEmpty) return <IsnadSpan>[IsnadSpan(text: text)];
  return spans;
}

/// Normalised name-search span building.
///
/// LOWER-CONFIDENCE fallback: used only when no entry carries stored
/// offsets. Every name in [confirmed] becomes a narrator-name span, in
/// chain order; each name is matched once, scanning forward from the
/// previous match, so the same name appearing twice links only its first
/// occurrence in isnad order and a name that does not occur in the text
/// yields no span at all. Verified names carry their id; unverified
/// names are narrator-name spans with no id (one-color rule: same
/// style, tappable, honest no-biography inline line on tap). Names not in
/// [confirmed] are never made narrator names — no linking by mere
/// similarity.
List<IsnadSpan> _buildIsnadSpansByName(
  String text,
  List<IsnadNameMatch> confirmed,
) {
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
        narratorId: entry.verified ? entry.narratorId : null,
        isNarratorName: true,
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
