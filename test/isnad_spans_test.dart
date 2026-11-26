import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/core/narrator_logic.dart';
import 'package:sunnati/core/text_compare.dart';

// NOTE: the chains below are test-only fixtures invented for the tests —
// they are never shipped in the app, which links names only from verified
// database rows.
void main() {
  group('normalizeForMatching', () {
    test('maps every normalised character back to its original index', () {
      const text = 'حَدَّثَنَا شُعْبَةُ عَنِ الزُّهْرِيِّ';
      final norm = normalizeForMatching(text);
      expect(norm.text, 'حدثنا شعبه عن الزهري');
      // The normalised slice for "الزهري" comes from the original text
      // with its diacritics intact.
      final found = findNameInText(text, 'الزهري');
      expect(found, isNotNull);
      expect(text.substring(found!.start, found.end), 'الزُّهْرِيِّ');
    });

    test('does not collapse whitespace, so origins stay aligned', () {
      final norm = normalizeForMatching('قال  رسول  الله');
      expect(norm.text, 'قال  رسول  الله');
      expect(norm.origins.length, norm.text.length);
    });
  });

  group('findNameInText', () {
    test('finds a name despite diacritics and hamza forms', () {
      const text = 'حدثنا أَحْمَدُ بن حَنْبَلٍ قال';
      final found = findNameInText(text, 'أحمد بن حنبل');
      expect(found, isNotNull);
      expect(text.substring(found!.start, found.end), 'أَحْمَدُ بن حَنْبَلٍ');
    });

    test('does not match inside another word', () {
      const text = 'حدثنا الشعبي عن رجل';
      expect(findNameInText(text, 'شعبة'), isNull);
    });

    test('returns null when the name is absent', () {
      expect(findNameInText('حدثنا مالك عن نافع', 'الزهري'), isNull);
    });
  });

  group('buildIsnadSpans', () {
    const text = 'حدثنا شعبة عن الزهري عن أنس بن مالك قال: قال رسول الله ﷺ';

    test('links only confirmed names, in chain order', () {
      final spans = buildIsnadSpans(text, const <IsnadNameMatch>[
        IsnadNameMatch(name: 'شعبة', narratorId: 1),
        IsnadNameMatch(name: 'الزهري', narratorId: 2),
        IsnadNameMatch(name: 'أنس بن مالك', narratorId: 3),
      ]);
      final linked = spans.where((s) => s.isNarrator).toList();
      expect(linked.map((s) => s.narratorId).toList(), <int>[1, 2, 3]);
      expect(linked.map((s) => s.text).toList(),
          <String>['شعبة', 'الزهري', 'أنس بن مالك']);
      expect(spans.map((s) => s.text).join(), text);
    });

    test('unconfirmed names stay plain text', () {
      final spans = buildIsnadSpans(text, const <IsnadNameMatch>[
        IsnadNameMatch(name: 'الزهري', narratorId: 2),
      ]);
      expect(spans.where((s) => s.isNarrator).toList(), hasLength(1));
      expect(spans.firstWhere((s) => s.isNarrator).text, 'الزهري');
      expect(spans.any((s) => s.text.contains('شعبة') && s.isNarrator),
          isFalse);
    });

    test('a confirmed name absent from the text yields no span', () {
      final spans = buildIsnadSpans(text, const <IsnadNameMatch>[
        IsnadNameMatch(name: 'مالك بن أنس', narratorId: 9),
      ]);
      expect(spans.where((s) => s.isNarrator).toList(), isEmpty);
      expect(spans.map((s) => s.text).join(), text);
    });

    test('empty chain list returns the whole text as one plain span', () {
      final spans = buildIsnadSpans(text, const <IsnadNameMatch>[]);
      expect(spans, hasLength(1));
      expect(spans.first.isNarrator, isFalse);
      expect(spans.first.text, text);
    });

    test('matches a name with diacritics in the text', () {
      const vocalised =
          'حَدَّثَنَا شُعْبَةُ عَنِ الزُّهْرِيِّ عَنْ أَنَسٍ قَالَ';
      final spans = buildIsnadSpans(vocalised, const <IsnadNameMatch>[
        IsnadNameMatch(name: 'شعبة', narratorId: 1),
        IsnadNameMatch(name: 'الزهري', narratorId: 2),
      ]);
      final linked = spans.where((s) => s.isNarrator).toList();
      expect(linked.map((s) => s.text).toList(),
          <String>['شُعْبَةُ', 'الزُّهْرِيِّ']);
      expect(spans.map((s) => s.text).join(), vocalised);
    });
  });

  group('buildIsnadSpans — offset-based (stored start_char/end_char)', () {
    // NOTE: offsets below are computed with indexOf inside each test so
    // the test itself never hard-codes a hand-counted position; what the
    // tests assert is that the builder honours the GIVEN offsets (not a
    // re-derived name search) and slices the original text exactly.
    const text = 'حدثنا شعبة عن شعبة عن الزهري قال';

    test('repeated name: each occurrence gets its own span from its row', () {
      final first = text.indexOf('شعبة');
      final second = text.indexOf('شعبة', first + 1);
      final zuhri = text.indexOf('الزهري');
      final spans = buildIsnadSpans(text, <IsnadNameMatch>[
        IsnadNameMatch(
            name: 'شعبة', narratorId: 1, startChar: first, endChar: first + 'شعبة'.length),
        IsnadNameMatch(
            name: 'شعبة',
            narratorId: 7,
            startChar: second,
            endChar: second + 'شعبة'.length),
        IsnadNameMatch(
            name: 'الزهري',
            narratorId: 2,
            startChar: zuhri,
            endChar: zuhri + 6),
      ]);
      final linked = spans.where((s) => s.isNarrator).toList();
      expect(linked.map((s) => s.narratorId).toList(), <int>[1, 7, 2]);
      expect(linked.map((s) => s.text).toList(),
          <String>['شعبة', 'شعبة', 'الزهري']);
      expect(spans.map((s) => s.text).join(), text);
    });

    test('offsets win over name search: a later occurrence is linked', () {
      // The name occurs twice; the offset points at the SECOND one, so
      // only the second occurrence may be tappable — a name search
      // would have linked the first.
      final first = text.indexOf('شعبة');
      final second = text.indexOf('شعبة', first + 1);
      final spans = buildIsnadSpans(text, <IsnadNameMatch>[
        IsnadNameMatch(
            name: 'شعبة',
            narratorId: 1,
            startChar: second,
            endChar: second + 'شعبة'.length),
      ]);
      final linked = spans.where((s) => s.isNarrator).toList();
      expect(linked, hasLength(1));
      expect(linked.first.text, 'شعبة');
      // The plain span before it still contains the first occurrence.
      expect(spans.first.text, contains('حدثنا شعبة عن '));
      expect(spans.map((s) => s.text).join(), text);
    });

    test('diacritics: offset slices keep the vocalised text intact', () {
      const vocalised =
          'حَدَّثَنَا شُعْبَةُ عَنِ الزُّهْرِيِّ عَنْ أَنَسٍ قَالَ';
      final shuba = vocalised.indexOf('شُعْبَةُ');
      final zuhri = vocalised.indexOf('الزُّهْرِيِّ');
      final spans = buildIsnadSpans(vocalised, <IsnadNameMatch>[
        IsnadNameMatch(
          name: 'شعبة',
          narratorId: 1,
          startChar: shuba,
          endChar: shuba + 'شُعْبَةُ'.length,
        ),
        IsnadNameMatch(
          name: 'الزهري',
          narratorId: 2,
          startChar: zuhri,
          endChar: zuhri + 'الزُّهْرِيِّ'.length,
        ),
      ]);
      final linked = spans.where((s) => s.isNarrator).toList();
      expect(linked.map((s) => s.text).toList(),
          <String>['شُعْبَةُ', 'الزُّهْرِيِّ']);
      expect(spans.map((s) => s.text).join(), vocalised);
    });

    test('boundary cases: name at offset 0 and name ending at text end', () {
      const edge = 'شعبة عن الزهري';
      final spans = buildIsnadSpans(edge, <IsnadNameMatch>[
        const IsnadNameMatch(
            name: 'شعبة',
            narratorId: 1,
            startChar: 0,
            endChar: 'شعبة'.length),
        const IsnadNameMatch(
            name: 'الزهري',
            narratorId: 2,
            startChar: 8,
            endChar: edge.length),
      ]);
      final linked = spans.where((s) => s.isNarrator).toList();
      expect(linked.map((s) => s.narratorId).toList(), <int>[1, 2]);
      expect(spans.map((s) => s.text).join(), edge);
    });

    test('unverified offset names stay plain text, never tappable', () {
      final first = text.indexOf('شعبة');
      final zuhri = text.indexOf('الزهري');
      final spans = buildIsnadSpans(text, <IsnadNameMatch>[
        IsnadNameMatch(
          name: 'شعبة',
          narratorId: null,
          startChar: first,
          endChar: first + 'شعبة'.length,
          verified: false,
        ),
        IsnadNameMatch(
            name: 'الزهري',
            narratorId: 2,
            startChar: zuhri,
            endChar: zuhri + 6),
      ]);
      final linked = spans.where((s) => s.isNarrator).toList();
      expect(linked.map((s) => s.narratorId).toList(), <int>[2]);
      expect(spans.any((s) => s.text == 'شعبة' && s.isNarrator), isFalse);
      expect(spans.map((s) => s.text).join(), text);
    });

    test('unusable offsets fall back to name search, never placed blindly',
        () {
      final spans = buildIsnadSpans(text, <IsnadNameMatch>[
        // Reversed offsets.
        const IsnadNameMatch(
            name: 'الزهري', narratorId: 2, startChar: 10, endChar: 5),
        // End beyond the text.
        const IsnadNameMatch(
            name: 'شعبة',
            narratorId: 1,
            startChar: 0,
            endChar: text.length + 99),
      ]);
      final linked = spans.where((s) => s.isNarrator).toList();
      expect(linked.map((s) => s.narratorId).toList(), <int>[1, 2]);
      expect(linked.map((s) => s.text).toList(),
          <String>['شعبة', 'الزهري']);
      expect(spans.map((s) => s.text).join(), text);
    });

    test('overlapping offset rows: earliest start wins, no double cover',
        () {
      final first = text.indexOf('شعبة');
      final spans = buildIsnadSpans(text, <IsnadNameMatch>[
        IsnadNameMatch(
            name: 'شعبة', narratorId: 1, startChar: first, endChar: first + 'شعبة'.length),
        // Same span claimed again by another row.
        IsnadNameMatch(
            name: 'شعبة', narratorId: 7, startChar: first, endChar: first + 'شعبة'.length),
      ]);
      final linked = spans.where((s) => s.isNarrator).toList();
      expect(linked, hasLength(1));
      expect(linked.first.narratorId, 1);
      expect(spans.map((s) => s.text).join(), text);
    });

    test('mixed rows: offset rows placed first, name-only rows fill gaps',
        () {
      final zuhri = text.indexOf('الزهري');
      final spans = buildIsnadSpans(text, <IsnadNameMatch>[
        IsnadNameMatch(
            name: 'الزهري',
            narratorId: 2,
            startChar: zuhri,
            endChar: zuhri + 6),
        // No offsets: lower-confidence name search.
        const IsnadNameMatch(name: 'شعبة', narratorId: 1),
      ]);
      final linked = spans.where((s) => s.isNarrator).toList();
      expect(linked.map((s) => s.narratorId).toList(), <int>[1, 2]);
      expect(spans.map((s) => s.text).join(), text);
    });
  });

  group('compareVariantTexts', () {
    test('separates shared words from words only in one wording', () {
      final c = compareVariantTexts(
        'إنما الأعمال بالنيات وإنما لكل امرئ ما نوى',
        'إنما الأعمال بالنيات فمن كانت هجرته إلى الله',
      );
      expect(c.common, containsAll(<String>['انما', 'الاعمال', 'بالنيات']));
      expect(c.onlyInBase, contains('نوي'));
      expect(c.onlyInVariant, contains('هجرته'));
      expect(c.identical, isFalse);
    });

    test('identical wordings compare identical despite diacritics', () {
      final c = compareVariantTexts(
        'إنما الأعمال بالنيات',
        'إِنَّمَا الْأَعْمَالُ بِالنِّيَّاتِ',
      );
      expect(c.identical, isTrue);
      expect(c.common, <String>['انما', 'الاعمال', 'بالنيات']);
    });
  });
}
