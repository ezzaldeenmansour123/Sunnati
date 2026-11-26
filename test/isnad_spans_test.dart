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
