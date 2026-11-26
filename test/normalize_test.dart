import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/core/normalize.dart';

void main() {
  group('normalizeArabic', () {
    test('strips tashkeel and tatweel', () {
      expect(normalizeArabic('إِنَّمَا الْأَعْمَالُ بِالنِّيَّاتِ'),
          'انما الاعمال بالنيات');
      expect(normalizeArabic('سُـنَّـتِي'), 'سنتي');
    });

    test('unifies hamzas', () {
      expect(normalizeArabic('أحمد إبراهيم آمنة'), 'احمد ابراهيم امنه');
      expect(normalizeArabic('مؤمن'), 'مومن');
      expect(normalizeArabic('قارئ'), 'قاري');
    });

    test('alef maksura becomes yeh, teh marbuta becomes heh', () {
      expect(normalizeArabic('موسى رضى'), 'موسي رضي');
      expect(normalizeArabic('الصلاة الزكاة'), 'الصلاه الزكاه');
    });

    test('strips punctuation and collapses whitespace', () {
      expect(normalizeArabic('قال رسولُ الله ﷺ: «إنما الأعمال…»'),
          'قال رسول الله انما الاعمال');
    });

    test('empty input stays empty', () {
      expect(normalizeArabic(''), '');
      expect(normalizeArabic('   '), '');
    });
  });

  group('stripPrefixes', () {
    test('strips the article and single-letter prefixes', () {
      expect(stripPrefixes('النيات'), 'نيات');
      expect(stripPrefixes('بالنيات'), 'نيات');
      expect(stripPrefixes('وبالنيات'), 'نيات');
      expect(stripPrefixes('فالصلاه'), 'صلاه');
    });

    test('does not mangle short words', () {
      expect(stripPrefixes('لا'), 'لا');
      expect(stripPrefixes('من'), 'من');
      expect(stripPrefixes('في'), 'في');
    });
  });

  group('queryTerms', () {
    test('normalises a full query into stripped terms', () {
      expect(queryTerms('إِنَّمَا الأعمالُ بالنيات'), <String>['انما', 'اعمال', 'نيات']);
    });

    test('empty query yields no terms', () {
      expect(queryTerms(''), isEmpty);
    });
  });

  group('indexVariants', () {
    test('yields word plus stripped form', () {
      expect(indexVariants('بالنيات'), <String>['بالنيات', 'نيات']);
      expect(indexVariants('نيات'), <String>['نيات']);
    });
  });
}
