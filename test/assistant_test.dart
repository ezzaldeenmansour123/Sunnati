/// Phase 6 assistant tests — intent detection, retrieval stopwords,
/// the 14-section template shape, and phrasing matching.
///
/// These tests cover the PURE parts only (no database, no Flutter
/// widgets): the same cases are executed against the real database by
/// `tools/test_assistant.py` (59/59 passed 2026-11-26), because no
/// Dart/Flutter toolchain is installed locally — see
/// SUNNATI_PHASE6_ASSISTANT_REPORT_2026-11-26.md. Run with
/// `flutter test test/assistant_test.dart` in CI.
import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/assistant/explanation_template.dart';
import 'package:sunnati/assistant/intent.dart';
import 'package:sunnati/assistant/phrasings.dart';
import 'package:sunnati/core/normalize.dart';

void main() {
  group('detectAssistantIntent', () {
    test('topic search is not a narrator question', () {
      expect(
        detectAssistantIntent('أحاديث في الصلاة').intent,
        AssistantIntent.search,
      );
      expect(
        detectAssistantIntent('أحاديث في النية').intent,
        AssistantIntent.search,
      );
      // ...while a narrator name after "ما أحاديث" IS one.
      final narr = detectAssistantIntent('ما أحاديث الزهري؟');
      expect(narr.intent, AssistantIntent.narrator);
      expect(narr.narratorQuestion, NarratorQuestion.hadiths);
    });

    test('the seven narrator questions are detected', () {
      expect(
        detectAssistantIntent('من هو الزهري؟').narratorQuestion,
        NarratorQuestion.whoIs,
      );
      expect(
        detectAssistantIntent('ما أقوال العلماء في الزهري؟')
            .narratorQuestion,
        NarratorQuestion.sayings,
      );
      expect(
        detectAssistantIntent('من شيوخ الزهري؟').narratorQuestion,
        NarratorQuestion.teachers,
      );
      expect(
        detectAssistantIntent('من تلاميذ الزهري؟').narratorQuestion,
        NarratorQuestion.students,
      );
      expect(
        detectAssistantIntent('هل اختلف العلماء في الزهري؟')
            .narratorQuestion,
        NarratorQuestion.disputed,
      );
      expect(
        detectAssistantIntent('ما طرق هذا الحديث؟').narratorQuestion,
        NarratorQuestion.ways,
      );
    });

    test('"أحاديث صحيح" is a grade search, not a narrator question', () {
      expect(
        detectAssistantIntent('أحاديث صحيح').intent,
        AssistantIntent.grade,
      );
      expect(
        detectAssistantIntent('أحاديث موضوع').intent,
        AssistantIntent.grade,
      );
    });

    test('terminology about a grade word', () {
      expect(
        detectAssistantIntent('ما معنى مصطلح صحيح؟').intent,
        AssistantIntent.terminology,
      );
      expect(
        detectAssistantIntent('ما معنى صحيح؟').intent,
        AssistantIntent.terminology,
      );
    });

    test('explain / takhrij / shawahid / compare', () {
      expect(
        detectAssistantIntent('اشرح حديث البخاري رقم 1').intent,
        AssistantIntent.explain,
      );
      expect(
        detectAssistantIntent('ما تخريج حديث الصلاة؟').intent,
        AssistantIntent.takhrij,
      );
      expect(
        detectAssistantIntent('ما شواهد حديث العلم؟').intent,
        AssistantIntent.shawahid,
      );
      expect(
        detectAssistantIntent('قارن بين البخاري ومسلم في الصلاة').intent,
        AssistantIntent.compare,
      );
      expect(
        detectAssistantIntent('ما معنى كلمة الصلاة؟').intent,
        AssistantIntent.vocabulary,
      );
    });
  });

  group('assistantContentTerms', () {
    test('question words, book names and verdict words never become terms',
        () {
      expect(
        assistantContentTerms('ما إسناد حديث الصلاة؟'),
        <String>['صلاه'],
      );
      expect(
        assistantContentTerms('هل الزهري ثقة؟'),
        <String>['زهري'],
      );
      expect(
        assistantContentTerms('قارن بين البخاري ومسلم في الصلاة'),
        <String>['صلاه'],
      );
      expect(
        assistantContentTerms('ما فوائد حديث الصيام الفقهية؟'),
        <String>['صيام'],
      );
    });

    test('a bare grade question has no FTS terms (grade branch answers it)',
        () {
      expect(assistantContentTerms('أحاديث صحيح'), isEmpty);
    });
  });

  group('extractBookNumber', () {
    test('parses book + number', () {
      final ref = extractBookNumber('اشرح حديث البخاري رقم 1');
      expect(ref.bookId, 'bukhari');
      expect(ref.num, 1);
    });

    test('no book/number yields nulls', () {
      final ref = extractBookNumber('أحاديث في الصلاة');
      expect(ref.bookId, isNull);
      expect(ref.num, isNull);
    });
  });

  group('explanation template shape', () {
    test('14 fixed titles in order', () {
      expect(explanationSectionTitles.length, 14);
      expect(explanationSectionTitles.first, 'النص');
      expect(explanationSectionTitles[4], 'الدرجة');
      expect(explanationSectionTitles.last, 'المصادر');
    });

    test('levels filter sections without changing their content', () {
      final sections = List<ExplanationSection>.generate(
        14,
        (i) => ExplanationSection(
          index: i + 1,
          title: explanationSectionTitles[i],
          content: 'content ${i + 1}',
          source: 'source',
          available: true,
        ),
      );
      expect(
        visibleSections(sections, ExplanationLevel.simplified)
            .map((s) => s.index)
            .toList(),
        <int>[1, 2, 5],
      );
      expect(
        visibleSections(sections, ExplanationLevel.scholarly)
            .map((s) => s.index)
            .toList(),
        <int>[1, 2, 5, 9, 14],
      );
      expect(
        visibleSections(sections, ExplanationLevel.specialist).length,
        14,
      );
    });

    test('unavailable sections carry the contract wording', () {
      const section = ExplanationSection(
        index: 3,
        title: 'الراوي',
        content: '$unavailableSectionText — جدول الرواة فارغ.',
        source: '',
        available: false,
      );
      expect(section.available, isFalse);
      expect(section.content, contains(unavailableSectionText));
      expect(section.source, isEmpty);
    });
  });

  group('phrasing matching', () {
    final entries = <PhrasingEntry>[
      const PhrasingEntry(
        id: 'search-01-1',
        text: 'أحاديث في الصلاة',
        category: 'search',
        templateId: 'search-01',
        split: 'train',
        referenceStatus: 'verified',
      ),
      const PhrasingEntry(
        id: 'narrator-01-1',
        text: 'من هو الراوي الزهري؟',
        category: 'narrator',
        templateId: 'narrator-01',
        split: 'train',
        referenceStatus: 'verified',
      ),
    ];

    test('matches the closest known phrasing', () {
      final match = matchPhrasing('أحاديث في الصلاة', entries);
      expect(match?.text, 'أحاديث في الصلاة');
      final narr = matchPhrasing('من هو الزهري؟', entries);
      expect(narr?.category, 'narrator');
    });

    test('no match when only question words are shared', () {
      // "أحاديث في المريخ" shares only "أحاديث في" with the stored
      // phrasing — content tokens differ (مريخ vs صلاة) — so no match.
      expect(matchPhrasing('أحاديث في المريخ', entries), isNull);
    });

    test('a single content word can match its phrasing', () {
      expect(matchPhrasing('صلاة', entries)?.text, 'أحاديث في الصلاة');
    });

    test('overlap score is 1.0 for a covered question', () {
      expect(
        phrasingOverlapScore('أحاديث في الصلاة', 'أحاديث في الصلاة'),
        1.0,
      );
    });

    test('parsePhrasings tolerates malformed input', () {
      expect(parsePhrasings('not json'), isEmpty);
      expect(parsePhrasings('{"phrasings": []}'), isEmpty);
    });
  });

  group('normalisation agreement with the Python mirror', () {
    test('stripPrefixes over-strips the same way (documented)', () {
      // "كلمة" -> "مه": the shared stripper behaviour. Retrieval
      // stopwords are checked in all forms, so this never leaks into
      // an FTS query.
      expect(stripPrefixes(normalizeArabic('كلمة')), 'مه');
      expect(normalizeArabic('الفقهية'), 'الفقهيه');
    });
  });
}
