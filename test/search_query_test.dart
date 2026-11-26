import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/core/stemming.dart';
import 'package:sunnati/search/search_history.dart';
import 'package:sunnati/search/search_service.dart';
import 'package:sunnati/search/semantic.dart';

void main() {
  group('buildFtsQuery', () {
    test('single term becomes a quoted prefix term', () {
      expect(buildFtsQuery(<String>['نيات']), '"نيات"*');
    });

    test('multiple terms are joined with AND', () {
      expect(
        buildFtsQuery(<String>['انما', 'اعمال', 'نيات']),
        '"انما"* AND "اعمال"* AND "نيات"*',
      );
    });

    test('empty terms yield an empty query', () {
      expect(buildFtsQuery(<String>[]), '');
      expect(buildFtsQuery(<String>['  ', '']), '');
    });

    test('quotes inside terms are stripped, never injected', () {
      // The builder normalises first: Latin letters and FTS operators
      // are stripped entirely, so a hostile query can never inject
      // FTS5 syntax — nothing of it survives into the MATCH string.
      expect(buildFtsQuery(<String>['a"b']), '');
      // An Arabic term with an embedded quote loses the quote, not
      // the term.
      expect(buildFtsQuery(<String>['النيات"']), '"النيات"*');
      expect(
        buildFtsQueryFromText('النيات" OR 1=1'),
        '"نيات"* AND "1"* AND "1"*',
      );
    });

    test('spelling variants become OR alternatives', () {
      expect(buildFtsQuery(<String>['ابن']), '("ابن"* OR "بن"*)');
      expect(
        buildFtsQuery(<String>['عبدالله']),
        '("عبدالله"* OR "عبد"* "الله"*)',
      );
    });
  });

  group('buildFtsQueryScoped', () {
    test('matn scope prefixes every term with the column', () {
      expect(
        buildFtsQueryScoped(<String>['نيات'], 'matn_norm'),
        '{matn_norm} : "نيات"*',
      );
      expect(
        buildFtsQueryScoped(<String>['انما', 'نيات'], 'isnad_norm'),
        '{isnad_norm} : "انما"* AND {isnad_norm} : "نيات"*',
      );
    });
  });

  group('buildFtsOrQuery', () {
    test('OR of quoted prefix terms', () {
      expect(buildFtsOrQuery(<String>['صلاه', 'صلوات']), '"صلاه"* OR "صلوات"*');
      expect(buildFtsOrQuery(<String>[]), '');
    });
  });

  group('buildFtsQueryFromText', () {
    test('normalises Arabic input end to end', () {
      expect(
        buildFtsQueryFromText('إِنَّمَا الأعمالُ بالنيات'),
        '"انما"* AND "اعمال"* AND "نيات"*',
      );
    });
  });

  group('phraseMatches', () {
    test('finds the phrase after per-word prefix stripping', () {
      expect(
        phraseMatches(<String>[
          'انما',
          'اعمال',
          'نيات',
        ], 'سمعت رسول الله يقول انما الاعمال بالنيات وانما لكل امري ما نوي'),
        isTrue,
      );
    });

    test('rejects a non-contiguous term order', () {
      expect(
        phraseMatches(<String>['نيات', 'اعمال'], 'انما الاعمال بالنيات'),
        isFalse,
      );
    });

    test('single-term queries have no phrase tier', () {
      expect(phraseMatches(<String>['نيات'], 'بالنيات'), isFalse);
    });
  });

  group('lightStem / rootKey', () {
    test('صلاه/صلوات/يصلي share one root', () {
      expect(
        <String>{rootKey('صلاه'), rootKey('صلوات'), rootKey('يصلي')}.length,
        1,
      );
      expect(rootKey('صلاه'), 'صلي');
    });

    test('نيات/نيه share one root', () {
      expect(rootKey('نيات'), rootKey('نيه'));
      expect(rootKey('نيات'), isNot(''));
    });

    test('وصل does NOT join صلاه (over-stemming guard)', () {
      expect(rootKey('وصل'), isNot(rootKey('صلاه')));
    });

    test('فتيات does NOT join نيات (ت/ن prefix guard)', () {
      expect(rootKey('فتيات'), isNot(rootKey('نيات')));
    });

    test('ايمان is separated from ايمن', () {
      expect(rootKey('ايمان'), isNot(rootKey('ايمن')));
    });

    test('كتاب/كتب stay apart (documented: no broken-plural analysis)', () {
      expect(rootKey('كتاب'), isNot(rootKey('كتب')));
    });

    test('one-letter words have no root key', () {
      expect(rootKey('و'), '');
      expect(rootKey('ب'), '');
    });
  });

  group('spellingVariants', () {
    test('ابن <-> بن', () {
      expect(spellingVariants('ابن'), <String>['بن']);
      expect(spellingVariants('بن'), <String>['ابن']);
    });

    test('عبدالله splits to عبد الله', () {
      expect(spellingVariants('عبدالله'), <String>['عبد الله']);
    });

    test('ordinary words have no variants', () {
      expect(spellingVariants('صلاه'), isEmpty);
    });
  });

  group('SemanticExpander.bundled', () {
    test('صوم expands to صيام (curated synonym)', () {
      final expansion = SemanticExpander.bundled().expand(<String>['صوم']);
      expect(expansion.synonyms, contains('صيام'));
      expect(expansion.note, contains('معجمي'));
    });

    test('short terms are never expanded', () {
      final expansion = SemanticExpander.bundled().expand(<String>['حج']);
      expect(expansion.isEmpty, isTrue);
    });

    test('unknown terms expand to nothing', () {
      final expansion = SemanticExpander.bundled().expand(<String>['كتاب']);
      expect(expansion.isEmpty, isTrue);
      expect(expansion.note, isEmpty);
    });

    test('root expansions come from the injected lookup', () {
      final expander = SemanticExpander(
        rootExpansions: (term) =>
            term == 'صلاه' ? <String>['صلوات', 'يصلي'] : const <String>[],
        synonymExpansions: (_) => const <String>[],
      );
      final expansion = expander.expand(<String>['صلاه']);
      expect(expansion.roots, <String>['صلوات', 'يصلي']);
    });
  });

  group('SearchQuery', () {
    test('detects numeric-only input', () {
      expect(const SearchQuery(text: '42').isNumericOnly, isTrue);
      expect(const SearchQuery(text: ' 7 ').isNumericOnly, isTrue);
      expect(const SearchQuery(text: 'النية').isNumericOnly, isFalse);
      expect(const SearchQuery(text: '42 حديث').isNumericOnly, isFalse);
    });

    test('detects empty input', () {
      expect(const SearchQuery(text: '   ').isEmpty, isTrue);
      expect(const SearchQuery(text: 'صلاة').isEmpty, isFalse);
      expect(const SearchQuery(text: '', narrator: 'الزهري').isEmpty, isFalse);
    });

    test('page offset is (page-1)*pageSize, page clamped at 1', () {
      expect(const SearchQuery(text: 'x', page: 1).offset, 0);
      expect(const SearchQuery(text: 'x', page: 3).offset, 40);
      expect(const SearchQuery(text: 'x', page: 2, pageSize: 10).offset, 10);
    });

    test('scope defaults to all, semantic defaults to off', () {
      const q = SearchQuery(text: 'صلاة');
      expect(q.scope, SearchScope.all);
      expect(q.semantic, isFalse);
      expect(q.pageSize, kDefaultPageSize);
    });
  });

  group('SearchPage', () {
    test('totalPages rounds up; hasMore follows the page', () {
      const page = SearchPage<String>(
        items: <String>[],
        total: 41,
        page: 2,
        pageSize: 20,
      );
      expect(page.totalPages, 3);
      expect(page.hasMore, isTrue);
      const last = SearchPage<String>(
        items: <String>[],
        total: 41,
        page: 3,
        pageSize: 20,
      );
      expect(last.hasMore, isFalse);
    });

    test('zero results is one empty page', () {
      const page = SearchPage<String>(
        items: <String>[],
        total: 0,
        page: 1,
        pageSize: 20,
      );
      expect(page.totalPages, 1);
      expect(page.hasMore, isFalse);
    });
  });

  group('SearchHistoryEntry', () {
    test('JSON round-trip preserves the query', () {
      final entry = SearchHistoryEntry(
        text: 'النيات',
        scope: SearchScope.matn,
        bookId: 'bukhari',
        grade: 'صحيح',
        narrator: '',
        companion: '',
        semantic: true,
        savedAt: DateTime.utc(2026, 11, 26),
      );
      final restored = SearchHistoryEntry.fromJson(entry.toJson());
      expect(restored.text, 'النيات');
      expect(restored.scope, SearchScope.matn);
      expect(restored.bookId, 'bukhari');
      expect(restored.grade, 'صحيح');
      expect(restored.semantic, isTrue);
      expect(restored.sameAs(entry), isTrue);
    });

    test('label joins text + narrator + companion', () {
      final entry = SearchHistoryEntry(
        text: '',
        scope: SearchScope.all,
        narrator: 'الزهري',
        companion: '',
        savedAt: DateTime.utc(2026, 11, 26),
      );
      expect(entry.label, 'راوٍ: الزهري');
    });

    test('sameAs ignores the timestamp', () {
      final a = SearchHistoryEntry(
        text: 'صلاة',
        scope: SearchScope.all,
        savedAt: DateTime.utc(2026, 11, 26),
      );
      final b = SearchHistoryEntry(
        text: 'صلاة',
        scope: SearchScope.all,
        savedAt: DateTime.utc(2026, 11, 25),
      );
      expect(a.sameAs(b), isTrue);
      expect(
        a.sameAs(
          SearchHistoryEntry(
            text: 'صوم',
            scope: SearchScope.all,
            savedAt: DateTime.utc(2026, 11, 26),
          ),
        ),
        isFalse,
      );
    });
  });
}
