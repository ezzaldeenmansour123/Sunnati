/// Full-text + lexical semantic search over the installed library.
///
/// Search modes (master prompt §7, Phase 4):
///  - word / phrase / part of a hadith (FTS5 prefix match, AND of terms)
///  - by hadith number, optionally restricted to one book
///  - in all books or one book; by grade (via `hadith_grades`); by
///    chapter (the topic filter — chapters are the topic divisions the
///    data actually has; chapter titles are English in the source)
///  - by narrator: inside the isnad region only (`hadith_spans_fts`)
///  - by Companion: the name must be the LAST narrator candidate
///    (parser-derived, not a verified identity)
///  - in the commentaries (HadeethEnc text + explanation, FTS)
///  - takhrij scope: HONEST LIMIT — the takhrij table is EMPTY, so this
///    scope returns the literal text search grouped by book and labels
///    it as text-similarity grouping, NOT verified takhrij
///  - similar hadiths: FTS candidates over the rarest matn tokens +
///    Jaccard similarity (textual similarity alone is NOT proof of one
///    hadith — master prompt §11)
///  - lexical semantic search («بحث دلالي معجمي»): query expansion by
///    roots + curated synonyms from the app's own lexicon tables
///    (see `lib/search/semantic.dart`). NOT vector embeddings, NOT an
///    LLM — the UI and the Phase 4 report say so.
///
/// Ranking tiers: exact phrase (+100) > all literal terms (+50) >
/// semantic expansion hit (+20) > FTS5 bm25 rank as tie-breaker.
///
/// Pagination: the database is NEVER fully loaded. A page is one SQL
/// query with LIMIT/OFFSET (plus one COUNT query for the total); the
/// ranking pool is capped at 500 literal + 500 expansion candidates.
/// The stored text keeps its diacritics; only the normalised form is
/// indexed (see `lib/core/normalize.dart`).
///
/// This file is the Dart mirror of `tools/search_engine.py` (same
/// rules, same tiers, same pagination contract) — keep the two in sync.
library;

import '../core/normalize.dart';
import '../core/stemming.dart';
import '../core/text_compare.dart';
import '../data/database.dart';
import '../models/commentary.dart';
import '../models/hadith.dart';
import 'semantic.dart';

/// Ranking pool cap per tier (see file docstring).
const int kSearchPoolLimit = 500;

/// Default page size for search results.
const int kDefaultPageSize = 20;

/// Jaccard threshold for "similar hadiths".
const double kSimilarThreshold = 0.30;

/// FTS candidates examined for similar-hadith search.
const int kSimilarCandidates = 200;

/// Search scope (نطاق البحث).
enum SearchScope {
  /// Full text (isnad + matn as stored).
  all,

  /// Matn only (parser-derived split).
  matn,

  /// Isnad only (parser-derived split).
  isnad,

  /// HadeethEnc commentaries (text + explanation).
  commentary,

  /// Takhrij scope — text-similarity grouping, labelled as such (the
  /// verified takhrij table is empty; see file docstring).
  takhrij,
}

/// What the user asked for. Built by the search screen, executed by
/// [SearchService].
class SearchQuery {
  const SearchQuery({
    required this.text,
    this.bookId,
    this.grade,
    this.chapterId,
    this.narrator = '',
    this.companion = '',
    this.scope = SearchScope.all,
    this.semantic = false,
    this.page = 1,
    this.pageSize = kDefaultPageSize,
  });

  /// Raw user input (text search).
  final String text;

  /// Restrict to one book id (e.g. `bukhari`), or null for all books.
  final String? bookId;

  /// Filter by grade text (e.g. `صحيح`), or null for any grade.
  /// Matches per-hadith grades only (`hadith_grades`): Bukhari/Muslim
  /// (collection-level sahih) and Ahmad/Darimi (no grades in source)
  /// are honestly excluded by a grade filter — the UI says so.
  final String? grade;

  /// Restrict to one chapter id (the topic filter), or null.
  final int? chapterId;

  /// Narrator-name search (isnad region only); empty means "not used".
  final String narrator;

  /// Companion-name search (last narrator candidate); empty = "not used".
  final String companion;

  /// Search scope.
  final SearchScope scope;

  /// Lexical semantic expansion (roots + synonyms) on text search.
  final bool semantic;

  /// 1-based page number.
  final int page;

  /// Results per page.
  final int pageSize;

  /// True when the input is only digits (with optional book:number form).
  bool get isNumericOnly => RegExp(r'^\d+$').hasMatch(text.trim());

  bool get isEmpty =>
      text.trim().isEmpty &&
      narrator.trim().isEmpty &&
      companion.trim().isEmpty;

  /// SQL OFFSET for [page] (page clamped to >= 1).
  int get offset => (page < 1 ? 0 : page - 1) * pageSize;
}

/// One page of results. The total is the exact SQL COUNT, so it stays
/// honest even when the ranking pool is capped.
class SearchPage<T> {
  const SearchPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    this.semanticNote = '',
  });

  final List<T> items;
  final int total;
  final int page;
  final int pageSize;

  /// Honest label / limits note for this page (semantic expansion,
  /// takhrij limits, missing-index degradation); empty when none.
  final String semanticNote;

  int get totalPages => total <= 0 ? 1 : (total + pageSize - 1) ~/ pageSize;

  bool get hasMore => page < totalPages;
}

/// One ranked hadith hit.
class SearchHit {
  const SearchHit({
    required this.hadith,
    required this.score,
    required this.tier,
  });

  final Hadith hadith;

  /// Ranking score (phrase +100 / literal +50 / semantic +20 / rank).
  final double score;

  /// `phrase` | `literal` | `semantic` — drives the «دلالي» chip.
  final String tier;
}

/// One similar hadith (wording comparison, NOT a takhrij verdict).
class SimilarHadith {
  const SimilarHadith({
    required this.hadith,
    required this.jaccard,
    required this.common,
    required this.onlyInBase,
    required this.onlyInVariant,
  });

  final Hadith hadith;

  /// Jaccard similarity of the two matns' content-token sets (0..1).
  final double jaccard;

  /// Content tokens shared by both wordings.
  final int common;

  /// Content tokens only in the base wording.
  final int onlyInBase;

  /// Content tokens only in the variant wording.
  final int onlyInVariant;
}

/// Build a safe FTS5 MATCH query from normalised terms.
///
/// Each term becomes a quoted prefix term (`"term"*`) and terms are joined
/// with AND. Spelling variants become OR alternatives (`ابن` also
/// searches `بن`; joined `عبدالله` also searches the split phrase
/// `"عبد"* "الله"*`). Terms are quoted, never interpolated raw, so a
/// query can never inject FTS5 syntax. Pure function — unit-tested.
String buildFtsQuery(List<String> terms) {
  final parts = <String>[];
  for (final rawTerm in terms) {
    // Normalise first: a whitespace-only or diacritics-only term must
    // not emit empty quoted tokens (""*), which FTS5 would reject.
    final term = normalizeArabic(rawTerm);
    if (term.isEmpty) continue;
    final variants = <String>[term, ...spellingVariants(term)];
    final alts = <String>[];
    for (final v in variants) {
      if (v.contains(' ')) {
        final words = v
            .split(' ')
            .where((w) => w.isNotEmpty)
            .map((w) => '"${w.replaceAll('"', '')}"*')
            .toList();
        if (words.isNotEmpty) alts.add(words.join(' '));
      } else {
        alts.add('"${v.replaceAll('"', '')}"*');
      }
    }
    if (alts.isEmpty) continue;
    parts.add(alts.length > 1 ? '(${alts.join(' OR ')})' : alts.first);
  }
  return parts.join(' AND ');
}

/// Build a column-scoped FTS5 MATCH query: each term becomes
/// `{column} : "term"*` (for `hadith_spans_fts` matn/isnad scopes).
String buildFtsQueryScoped(List<String> terms, String column) {
  final parts = <String>[];
  for (final rawTerm in terms) {
    final term = normalizeArabic(rawTerm);
    if (term.isEmpty) continue;
    final variants = <String>[term, ...spellingVariants(term)];
    final alts = <String>[];
    for (final v in variants) {
      if (v.contains(' ')) {
        final words = v
            .split(' ')
            .where((w) => w.isNotEmpty)
            .map((w) => '{$column} : "${w.replaceAll('"', '')}"*')
            .toList();
        if (words.isNotEmpty) alts.add(words.join(' '));
      } else {
        alts.add('{$column} : "${v.replaceAll('"', '')}"*');
      }
    }
    if (alts.isEmpty) continue;
    parts.add(alts.length > 1 ? '(${alts.join(' OR ')})' : alts.first);
  }
  return parts.join(' AND ');
}

/// Build an OR of quoted prefix terms (expansion / similar candidates).
String buildFtsOrQuery(List<String> terms) {
  return terms
      .map(normalizeArabic)
      .where((t) => t.isNotEmpty)
      .map((t) => '"${t.replaceAll('"', '')}"*')
      .join(' OR ');
}

/// Build an FTS5 query directly from raw user input.
String buildFtsQueryFromText(String rawQuery) {
  return buildFtsQuery(queryTerms(rawQuery));
}

/// True when [phraseTerms] occur contiguously (after per-word prefix
/// stripping) in the plain normalised text. The stored text has
/// «الاعمال» / «بالنيات» where the query terms are «اعمال» / «نيات»,
/// so the raw plain text never contains the phrase — strip first.
/// Pure function — unit-tested.
bool phraseMatches(List<String> phraseTerms, String plainNorm) {
  if (phraseTerms.length < 2 || plainNorm.isEmpty) return false;
  final tokens = plainNorm.split(' ').map(stripPrefixes).toList();
  final n = phraseTerms.length;
  for (var i = 0; i + n <= tokens.length; i++) {
    var ok = true;
    for (var j = 0; j < n; j++) {
      if (tokens[i + j] != phraseTerms[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

class SearchService {
  SearchService(this._db)
      : _expander = SemanticExpander(
          rootExpansions: (term) => _db.rootExpansions(term),
          synonymExpansions: (term) {
            final fromDb = _db.synonymExpansions(term);
            if (fromDb.isNotEmpty) return fromDb;
            if (term.length < 3) return const <String>[];
            return <String>[
              ...?kBundledSynonyms[term],
              ...?kBundledRelated[term],
            ];
          },
        );

  final SunnatiDatabase _db;
  final SemanticExpander _expander;

  /// Execute [query]. Returns one page of ranked hits. Returns an empty
  /// page (never throws) when the library is unavailable.
  SearchPage<SearchHit> search(SearchQuery query) {
    if (!_db.isAvailable || query.isEmpty) {
      return SearchPage<SearchHit>(
        items: const <SearchHit>[],
        total: 0,
        page: query.page < 1 ? 1 : query.page,
        pageSize: query.pageSize,
      );
    }
    if (query.scope == SearchScope.commentary) {
      // Commentary scope has its own result type; the screen calls
      // searchCommentaries directly. Kept out of this method so the
      // return type stays SearchPage<SearchHit>.
      return _emptyPage(query);
    }
    if (query.companion.trim().isNotEmpty) return _searchCompanion(query);
    if (query.narrator.trim().isNotEmpty) return _searchNarrator(query);

    // Numeric search: hadith number, optionally in one book.
    if (query.isNumericOnly) return _searchNumeric(query);

    final terms = queryTerms(query.text);
    if (terms.isEmpty) return _emptyPage(query);
    final page = _searchText(query, terms);
    if (query.scope == SearchScope.takhrij) {
      return SearchPage<SearchHit>(
        items: page.items,
        total: page.total,
        page: page.page,
        pageSize: page.pageSize,
        semanticNote:
            'نطاق التخريج: جدول التخريج الموثق فارغ بعد — النتائج تجميع '
            'نصي حسب الكتاب (تشابه لفظي) وليست تخريجاً موثقاً.',
      );
    }
    return page;
  }

  SearchPage<SearchHit> _emptyPage(SearchQuery query) {
    return SearchPage<SearchHit>(
      items: const <SearchHit>[],
      total: 0,
      page: query.page < 1 ? 1 : query.page,
      pageSize: query.pageSize,
    );
  }

  SearchPage<SearchHit> _searchNumeric(SearchQuery query) {
    final num = int.parse(query.text.trim());
    final results = <Hadith>[];
    if (query.bookId != null) {
      final one = _db.hadithByNumber(query.bookId!, num);
      if (one != null) results.add(one);
    } else {
      for (final book in _db.books()) {
        final one = _db.hadithByNumber(book.id, num);
        if (one != null) results.add(one);
      }
    }
    final filtered = _applyGradeFilter(results, query.grade);
    return SearchPage<SearchHit>(
      items: filtered
          .map((h) => SearchHit(hadith: h, score: 50.0, tier: 'literal'))
          .toList(),
      total: filtered.length,
      page: 1,
      pageSize: query.pageSize,
    );
  }

  List<Hadith> _applyGradeFilter(List<Hadith> input, String? grade) {
    if (grade == null || grade.isEmpty) return input;
    return input
        .where((h) => h.grades.any((g) => g.grade.contains(grade)))
        .toList();
  }

  /// Plain normalised text (no index variants) for the phrase check.
  /// For matn/isnad scopes the text is sliced at the parser's boundary.
  String _plainNorm(FtsHitRow row, SearchScope scope) {
    final text = row.hadith.text;
    final end = row.isnadEndChar;
    if (scope == SearchScope.matn && end != null) {
      return normalizeArabic(text.substring(end));
    }
    if (scope == SearchScope.isnad) {
      return end == null ? '' : normalizeArabic(text.substring(0, end));
    }
    return normalizeArabic(text);
  }

  SearchHit _score(
    FtsHitRow row,
    List<String> terms,
    String tier,
    bool useSpans,
    SearchScope scope,
  ) {
    var score = tier == 'literal' ? 50.0 : 20.0;
    var hitTier = tier;
    final plain = terms.length >= 2 ? _plainNorm(row, scope) : '';
    if (phraseMatches(terms, plain)) {
      score += 100.0;
      hitTier = 'phrase';
    }
    score += (10.0 + row.rank).clamp(0.0, double.infinity);
    return SearchHit(
      hadith: row.hadith,
      score: double.parse(score.toStringAsFixed(2)),
      tier: hitTier,
    );
  }

  SearchPage<SearchHit> _searchText(SearchQuery query, List<String> terms) {
    final useSpans = _db.hasSearchSpans && query.scope != SearchScope.all;
    final String literal;
    if (useSpans) {
      final column =
          query.scope == SearchScope.matn ? 'matn_norm' : 'isnad_norm';
      literal = buildFtsQueryScoped(terms, column);
    } else {
      literal = buildFtsQuery(terms);
    }
    final rows = _db.ftsSearch(
      literal,
      useSpans: useSpans,
      bookId: query.bookId,
      grade: query.grade,
      chapterId: query.chapterId,
      limit: kSearchPoolLimit,
    );
    var total = _db.ftsCount(
      literal,
      useSpans: useSpans,
      bookId: query.bookId,
      grade: query.grade,
      chapterId: query.chapterId,
    );

    var note = '';
    var totalExp = 0;
    final scored = <int, SearchHit>{};
    for (final row in rows) {
      scored[row.hadith.id] = _score(
        row,
        terms,
        'literal',
        useSpans,
        query.scope,
      );
    }
    if (query.semantic) {
      final expansion = _expander.expand(terms);
      note = expansion.note;
      final expTerms = expansion.all;
      if (expTerms.isNotEmpty) {
        final String expMatch;
        if (useSpans) {
          final column =
              query.scope == SearchScope.matn ? 'matn_norm' : 'isnad_norm';
          expMatch = expTerms
              .map((t) => '{$column} : "${t.replaceAll('"', '')}"*')
              .join(' OR ');
        } else {
          expMatch = buildFtsOrQuery(expTerms);
        }
        final expRows = _db.ftsSearch(
          expMatch,
          useSpans: useSpans,
          bookId: query.bookId,
          grade: query.grade,
          chapterId: query.chapterId,
          limit: kSearchPoolLimit,
        );
        totalExp = _db.ftsCount(
          expMatch,
          useSpans: useSpans,
          bookId: query.bookId,
          grade: query.grade,
          chapterId: query.chapterId,
          antiMatch: literal,
        );
        for (final row in expRows) {
          if (scored.containsKey(row.hadith.id)) continue;
          scored[row.hadith.id] = _score(
            row,
            terms,
            'semantic',
            useSpans,
            query.scope,
          );
        }
      }
    }
    final ordered = scored.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        final byBook = a.hadith.bookId.compareTo(b.hadith.bookId);
        if (byBook != 0) return byBook;
        return a.hadith.num.compareTo(b.hadith.num);
      });
    total += totalExp;
    final page = query.page < 1 ? 1 : query.page;
    final start = (page - 1) * query.pageSize;
    final items = start >= ordered.length
        ? const <SearchHit>[]
        : ordered.skip(start).take(query.pageSize).toList();
    return SearchPage<SearchHit>(
      items: items,
      total: total,
      page: page,
      pageSize: query.pageSize,
      semanticNote: query.semantic ? note : '',
    );
  }

  /// Narrator-name search inside the isnad region only. No root/synonym
  /// expansion: names are proper nouns.
  SearchPage<SearchHit> _searchNarrator(SearchQuery query) {
    final terms = queryTerms(query.narrator);
    if (terms.isEmpty) return _emptyPage(query);
    if (!_db.hasSearchSpans) {
      return SearchPage<SearchHit>(
        items: const <SearchHit>[],
        total: 0,
        page: query.page < 1 ? 1 : query.page,
        pageSize: query.pageSize,
        semanticNote: 'فهرس السند غير متوفر في هذه النسخة من المكتبة.',
      );
    }
    final match = buildFtsQueryScoped(terms, 'isnad_norm');
    final rows = _db.ftsSearch(
      match,
      useSpans: true,
      bookId: query.bookId,
      grade: query.grade,
      chapterId: query.chapterId,
      limit: kSearchPoolLimit,
    );
    final total = _db.ftsCount(
      match,
      useSpans: true,
      bookId: query.bookId,
      grade: query.grade,
      chapterId: query.chapterId,
    );
    final hits = rows
        .map((r) => _score(r, terms, 'literal', true, SearchScope.isnad))
        .toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        final byBook = a.hadith.bookId.compareTo(b.hadith.bookId);
        if (byBook != 0) return byBook;
        return a.hadith.num.compareTo(b.hadith.num);
      });
    final page = query.page < 1 ? 1 : query.page;
    final start = (page - 1) * query.pageSize;
    return SearchPage<SearchHit>(
      items: start >= hits.length
          ? const <SearchHit>[]
          : hits.skip(start).take(query.pageSize).toList(),
      total: total,
      page: page,
      pageSize: query.pageSize,
    );
  }

  /// Companion search: the name must be the LAST narrator candidate.
  /// Parser-derived, not a verified identity.
  SearchPage<SearchHit> _searchCompanion(SearchQuery query) {
    final terms = queryTerms(query.companion);
    if (terms.isEmpty) return _emptyPage(query);
    if (!_db.hasSearchSpans) {
      return SearchPage<SearchHit>(
        items: const <SearchHit>[],
        total: 0,
        page: query.page < 1 ? 1 : query.page,
        pageSize: query.pageSize,
        semanticNote: 'فهرس السند غير متوفر في هذه النسخة من المكتبة.',
      );
    }
    final page = query.page < 1 ? 1 : query.page;
    final total = _db.countCompanion(
      terms,
      bookId: query.bookId,
      grade: query.grade,
      chapterId: query.chapterId,
    );
    final rows = _db.companionSearch(
      terms,
      bookId: query.bookId,
      grade: query.grade,
      chapterId: query.chapterId,
      limit: query.pageSize,
      offset: (page - 1) * query.pageSize,
    );
    return SearchPage<SearchHit>(
      items: rows
          .map((h) => SearchHit(hadith: h, score: 50.0, tier: 'literal'))
          .toList(),
      total: total,
      page: page,
      pageSize: query.pageSize,
    );
  }

  /// Search inside HadeethEnc commentaries (text + explanation).
  /// One page; the database is never fully loaded.
  SearchPage<Commentary> searchCommentaries(SearchQuery query) {
    final terms = queryTerms(query.text);
    final page = query.page < 1 ? 1 : query.page;
    if (terms.isEmpty) {
      return SearchPage<Commentary>(
        items: const <Commentary>[],
        total: 0,
        page: page,
        pageSize: query.pageSize,
      );
    }
    if (!_db.hasCommentariesFts) {
      return SearchPage<Commentary>(
        items: const <Commentary>[],
        total: 0,
        page: page,
        pageSize: query.pageSize,
        semanticNote: 'فهرس الشروح غير متوفر في هذه النسخة من المكتبة.',
      );
    }
    final match = buildFtsQuery(terms);
    final items = _db.searchCommentariesFts(
      match,
      limit: query.pageSize,
      offset: (page - 1) * query.pageSize,
    );
    final total = _db.countCommentariesFts(match);
    return SearchPage<Commentary>(
      items: items,
      total: total,
      page: page,
      pageSize: query.pageSize,
    );
  }

  /// Hadiths with similar wording (matn only).
  ///
  /// Candidates come from an FTS OR over the 8 rarest content tokens of
  /// the base matn; similarity is Jaccard over content-token sets
  /// ([compareVariantTexts]). Textual similarity alone is NOT proof of
  /// one hadith (master prompt §11) — the UI says so next to every
  /// result.
  List<SimilarHadith> findSimilar(Hadith base, {int limit = 10}) {
    final spans = _db.spansFor(base.id);
    final String baseNorm;
    final bool useSpans;
    if (spans != null) {
      baseNorm = spans.matnNorm;
      useSpans = true;
    } else {
      useSpans = false;
      baseNorm = _db.normFor(base.id) ?? '';
    }
    final baseTokens = _contentTokens(baseNorm);
    if (baseTokens.length < 3) return const <SimilarHadith>[];
    final rare = baseTokens.toList()
      ..sort((a, b) {
        final byFreq = _db.vocabFreq(a).compareTo(_db.vocabFreq(b));
        if (byFreq != 0) return byFreq;
        return b.length.compareTo(a.length);
      });
    final picked = rare.take(8).toList();
    final candidates = _db.similarCandidates(
      picked,
      useSpans: useSpans,
      limit: kSimilarCandidates,
    );
    final out = <SimilarHadith>[];
    for (final row in candidates) {
      if (row.hadith.id == base.id) continue;
      final candNorm = useSpans ? row.matnNorm : row.norm;
      final candTokens = _contentTokens(candNorm);
      if (candTokens.isEmpty) continue;
      final comparison = compareVariantTexts(
        baseTokens.join(' '),
        candTokens.join(' '),
      );
      final union =
          baseTokens.length + candTokens.length - comparison.common.length;
      final jaccard = union == 0 ? 0.0 : comparison.common.length / union;
      if (jaccard >= kSimilarThreshold) {
        out.add(
          SimilarHadith(
            hadith: row.hadith,
            jaccard: double.parse(jaccard.toStringAsFixed(3)),
            common: comparison.common.length,
            onlyInBase: comparison.onlyInBase.length,
            onlyInVariant: comparison.onlyInVariant.length,
          ),
        );
      }
    }
    out.sort((a, b) {
      final byJ = b.jaccard.compareTo(a.jaccard);
      if (byJ != 0) return byJ;
      final byBook = a.hadith.bookId.compareTo(b.hadith.bookId);
      if (byBook != 0) return byBook;
      return a.hadith.num.compareTo(b.hadith.num);
    });
    return out.take(limit).toList();
  }

  /// Content tokens of a normalised text: prefix-stripped (so the index
  /// variants «الاعمال»/«اعمال» collapse to one token), stopwords
  /// dropped, min length 3. Mirror of `SearchEngine.content_tokens`.
  Set<String> _contentTokens(String normText) {
    return normalizeArabic(normText)
        .split(' ')
        .map(stripPrefixes)
        .where((t) => t.isNotEmpty && !kStopwords.contains(t) && t.length >= 3)
        .toSet();
  }
}
