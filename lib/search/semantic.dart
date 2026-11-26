/// Lexical semantic search («بحث دلالي معجمي») — query expansion by
/// roots and synonyms from dictionaries built from the app's own data.
///
/// Pure logic — no Flutter dependency. Mirror of the expansion half of
/// `tools/search_engine.py` (which reads the same tables).
///
/// What this is, stated plainly (the UI and the Phase 4 report say the
/// same): expansion of a query with (a) other vocabulary words sharing
/// its root key (`search_roots`, derived from the corpus vocabulary by
/// `tools/phase4_search_index.py`) and (b) near-synonyms / related
/// terms from a small HAND-CURATED list below (identical content in
/// `search_synonyms` when the index tables exist, and bundled here as
/// the fallback when they do not — e.g. on a database built before
/// Phase 4). It is NOT vector embeddings and NOT a language model:
/// no meaning is computed, only shared roots and listed words.
/// No pair here asserts a religious ruling or an equivalence of meaning
/// beyond ordinary usage; `related` pairs are associations a searcher
/// usually also wants (ركوع with سجود), not synonyms.
///
/// Expansion applies to TEXT search only — never to narrator or
/// Companion name search (names are proper nouns; expanding them would
/// merge different people). Terms shorter than 3 letters are never
/// expanded.
library;

/// Curated near-synonyms (hand-written, Phase 4). Keys and values are
/// NORMALISED forms (hamzas unified, ة→ه, ى→ي). Mirror of `SYNONYMS`
/// in `tools/arabic_text.py` — keep the two in sync.
const Map<String, List<String>> kBundledSynonyms = <String, List<String>>{
  'صوم': <String>['صيام'],
  'صيام': <String>['صوم'],
  'زكاه': <String>['صدقه'],
  'صدقه': <String>['زكاه'],
  'طهاره': <String>['وضوء'],
  'وضوء': <String>['طهاره'],
  'نكاح': <String>['زواج'],
  'زواج': <String>['نكاح'],
  'جهاد': <String>['قتال'],
  'قتال': <String>['جهاد'],
  'علم': <String>['معرفه'],
  'معرفه': <String>['علم'],
  'دعاء': <String>['ذكر'],
  'ذكر': <String>['دعاء'],
  'توبه': <String>['استغفار'],
  'استغفار': <String>['توبه'],
  'بر': <String>['احسان'],
  'احسان': <String>['بر'],
  'غسل': <String>['اغتسال'],
  'اغتسال': <String>['غسل'],
  'نبي': <String>['رسول'],
  'رسول': <String>['نبي'],
  'موت': <String>['وفاه'],
  'وفاه': <String>['موت'],
  'نار': <String>['جهنم'],
  'جهنم': <String>['نار'],
  'شيطان': <String>['ابليس'],
  'ابليس': <String>['شيطان'],
  'ملائكه': <String>['ملك'],
  'ملك': <String>['ملائكه'],
  'جنه': <String>['فردوس'],
  'فردوس': <String>['جنه'],
  'طلاق': <String>['خلع'],
  'خلع': <String>['طلاق'],
};

/// Curated related terms (associations, not synonyms). Mirror of
/// `RELATED` in `tools/arabic_text.py`.
const Map<String, List<String>> kBundledRelated = <String, List<String>>{
  'سجود': <String>['ركوع'],
  'ركوع': <String>['سجود'],
  'حج': <String>['عمره'],
  'عمره': <String>['حج'],
};

/// Result of expanding one query's literal terms.
class Expansion {
  const Expansion({
    required this.roots,
    required this.synonyms,
    required this.note,
  });

  /// Root-group expansions (other vocabulary words, same root key).
  final List<String> roots;

  /// Synonym / related expansions (curated list).
  final List<String> synonyms;

  /// Honest label shown in the UI when anything was expanded; empty
  /// when nothing expanded.
  final String note;

  bool get isEmpty => roots.isEmpty && synonyms.isEmpty;

  List<String> get all => <String>[...roots, ...synonyms];
}

/// Expands query terms using lexicon lookups supplied by the caller
/// (the database when the Phase 4 tables exist, the bundled maps as
/// fallback). Pure — the lookups are injected so this class stays
/// unit-testable without a database.
class SemanticExpander {
  const SemanticExpander({
    required this.rootExpansions,
    required this.synonymExpansions,
  });

  /// Other vocabulary terms sharing [term]'s root key (empty when the
  /// lexicon is absent, the term is too short, or it has no group).
  final List<String> Function(String term) rootExpansions;

  /// Curated synonym / related expansions for [term].
  final List<String> Function(String term) synonymExpansions;

  /// Bundled-only expander (no database): the fallback used when the
  /// installed library has no Phase 4 lexicon tables.
  factory SemanticExpander.bundled() {
    return SemanticExpander(
      rootExpansions: (_) => const <String>[],
      synonymExpansions: (term) {
        if (term.length < 3) return const <String>[];
        return <String>[...?kBundledSynonyms[term], ...?kBundledRelated[term]];
      },
    );
  }

  Expansion expand(List<String> terms) {
    final roots = <String>[];
    final synonyms = <String>[];
    for (final term in terms) {
      if (term.length < 3) continue;
      for (final e in rootExpansions(term)) {
        if (e != term && !terms.contains(e) && !roots.contains(e)) {
          roots.add(e);
        }
      }
      for (final e in synonymExpansions(term)) {
        if (e != term &&
            !terms.contains(e) &&
            !roots.contains(e) &&
            !synonyms.contains(e)) {
          synonyms.add(e);
        }
      }
    }
    return Expansion(
      roots: roots,
      synonyms: synonyms,
      note: roots.isEmpty && synonyms.isEmpty
          ? ''
          : 'بحث دلالي معجمي: وُسّع الاستعلام بجذور الكلمات والمرادفات '
              'من قواميس التطبيق (ليس تضمينات متجهية ولا نموذجاً لغوياً).',
    );
  }
}
