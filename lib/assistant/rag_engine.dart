/// SUNNATI retrieval engine — Phase 6 (Dart).
///
/// Local, offline, retrieval-only. Mirrors `tools/assistant_engine.py`
/// exactly: same intent detection ([detectAssistantIntent]), same
/// retrieval order, same 14-section template ([buildExplanation]), same
/// three levels, same hard guards:
///
///  * no evidence -> explicit refusal ("لا توجد أدلة موثقة في القاعدة"),
///    never an invented substitute;
///  * narrators / takhrij / variants / shawahid tables are EMPTY in the
///    shipped DB, so questions needing them refuse explicitly;
///  * HadeethEnc commentaries are retrieved only as standalone passages
///    with their own key and attribution — never auto-linked to a
///    Nine-Books hadith, never presented as its commentary;
///  * every available section carries its source next to it; every
///    unavailable section says so.
///
/// This is NOT a language model: it classifies the question (by keywords
/// + the phrasings dataset, see [phrasings.dart]) and retrieves rows that
/// already exist in the installed database. The UI says so plainly.
library;

import '../core/normalize.dart';
import '../data/database.dart';
import '../models/commentary.dart';
import '../models/hadith.dart';
import '../search/search_service.dart' show buildFtsQuery;
import 'explanation_template.dart';
import 'intent.dart';
import 'phrasings.dart';

/// The refusal wording. Part of the contract: the UI and the tests look
/// for this exact string.
const String noEvidenceText = 'لا توجد أدلة موثقة في القاعدة';

/// Shown when a section/answer has no backing data.
const String unavailableText = 'غير متوفر في المصادر المتاحة';

/// Teachers/students are ZERO in the first verified core.
const String coreZeroNote =
    'الشيوخ والتلاميذ غير متوفرين في النواة الأولى — '
    'جدول الرواة فارغ في القاعدة الحالية (0 راوٍ موثق).';

/// Honest scope note attached to every answered (non-refused) answer.
const String notAModelNote =
    'مساعد استرجاعي — مطابقة نوايا بالاسترجاع فوق صياغات الأسئلة، '
    'وليست نموذجاً لغوياً توليدياً؛ لا يولّد أحكاماً ولا شروحاً ولا تراجم.';

const String _refusalSuffix = ' — لم يُخترَع بديل.';

/// One retrieved piece of evidence, always with its citation + source.
class RagEvidence {
  const RagEvidence.hadith(this.hadith)
      : kind = 'hadith',
        commentary = null;

  const RagEvidence.commentary(this.commentary)
      : kind = 'commentary',
        hadith = null;

  final String kind;
  final Hadith? hadith;
  final Commentary? commentary;

  /// Short citation, e.g. `صحيح البخاري رقم 1 — Revelation`.
  String get citation {
    final h = hadith;
    if (h != null) {
      final name = bookDisplayNames[h.bookId] ?? h.bookId;
      return '$name رقم ${h.num}'
          '${h.chapterTitle.isNotEmpty ? ' — ${h.chapterTitle}' : ''}';
    }
    return commentary?.hadithKey ?? '';
  }

  /// Source line shown next to the evidence.
  String get source {
    final h = hadith;
    if (h != null) {
      final name = bookDisplayNames[h.bookId] ?? h.bookId;
      return 'quranlab/hadith — $name';
    }
    final c = commentary;
    if (c != null) {
      return 'HadeethEnc (${c.hadithKey}) — '
          '${c.attribution.isNotEmpty ? c.attribution : 'موسوعة الحديث HadeethEnc'}';
    }
    return '';
  }

  String get text {
    final h = hadith;
    if (h != null) return h.text;
    return commentary?.explanation ?? commentary?.title ?? '';
  }
}

/// The answer of the retrieval engine.
class RagAnswer {
  const RagAnswer({
    required this.query,
    required this.intent,
    required this.level,
    required this.evidences,
    required this.sections,
    required this.refused,
    required this.note,
    this.narratorQuestion,
    this.matchedPhrasing,
  });

  final String query;
  final AssistantIntent intent;
  final NarratorQuestion? narratorQuestion;
  final ExplanationLevel level;
  final List<RagEvidence> evidences;

  /// 14-section template (already filtered to the level), or empty when
  /// the question is not an explanation of one hadith.
  final List<ExplanationSection> sections;

  /// True when the engine refused for lack of evidence.
  final bool refused;

  /// Plain-language note: scope note, or the explicit refusal reason.
  final String note;

  /// Closest known phrasing from the dataset, if any (intent-matching
  /// hint shown to the user; it never changes the retrieved evidence).
  final String? matchedPhrasing;
}

class RagEngine {
  RagEngine(this._db);

  final SunnatiDatabase _db;

  /// FTS retrieval over the CONTENT terms only (stopwords removed),
  /// exactly like `search_hadiths` in `tools/assistant_engine.py`.
  /// Using the raw query text here would AND-match question words
  /// ("إسناد"، "حديث") that do not occur in hadith texts.
  List<Hadith> _searchTerms(List<String> terms, {int limit = 6}) {
    final fts = buildFtsQuery(terms);
    if (fts.isEmpty) return const <Hadith>[];
    return _db.searchFts(fts, limit: limit);
  }

  /// Answer [query] by retrieval only. [phrasings] (loaded from the
  /// bundled dataset) is used only to show the closest known phrasing;
  /// intent stays keyword-based, exactly like the Python mirror.
  RagAnswer ask(
    String query, {
    ExplanationLevel level = ExplanationLevel.scholarly,
    List<PhrasingEntry>? phrasings,
  }) {
    final trimmed = query.trim();
    final detected = detectAssistantIntent(trimmed);
    final intent = detected.intent;
    final narr = detected.narratorQuestion;
    final matched = phrasings == null
        ? null
        : matchPhrasing(trimmed, phrasings)?.text;

    RagAnswer refuse(String note) => RagAnswer(
          query: trimmed,
          intent: intent,
          narratorQuestion: narr,
          level: level,
          evidences: const <RagEvidence>[],
          sections: const <ExplanationSection>[],
          refused: true,
          note: note,
          matchedPhrasing: matched,
        );

    RagAnswer answer(List<RagEvidence> evidences,
        {List<ExplanationSection> sections = const <ExplanationSection>[],
        String? note}) {
      return RagAnswer(
        query: trimmed,
        intent: intent,
        narratorQuestion: narr,
        level: level,
        evidences: evidences,
        sections: sections,
        refused: false,
        note: note ?? notAModelNote,
        matchedPhrasing: matched,
      );
    }

    if (trimmed.isEmpty) {
      return refuse('اكتب سؤالاً أو كلمة للبحث في المكتبة.');
    }
    if (!_db.isAvailable) {
      return refuse('المكتبة قيد الاستيراد — لا توجد نصوص بعد لاسترجاعها.');
    }

    // --- narrator questions: answered ONLY from the narrators tables ---
    if (intent == AssistantIntent.narrator) {
      return _answerNarrator(trimmed, narr ?? NarratorQuestion.whoIs,
          level, matched);
    }

    // --- a specific hadith by book + number -----------------------------
    // Only for intents a numbered hadith can answer. Takhrij / variant /
    // shawahid questions must NOT be diverted here: their tables are
    // empty, so they refuse explicitly below.
    final ref = extractBookNumber(trimmed);
    if (ref.num != null &&
        ref.bookId != null &&
        intent != AssistantIntent.takhrij &&
        intent != AssistantIntent.variantDiff &&
        intent != AssistantIntent.shawahid) {
      final row = _db.hadithByNumber(ref.bookId!, ref.num!);
      if (row == null) {
        final name = bookDisplayNames[ref.bookId!] ?? ref.bookId!;
        return refuse(
          '$noEvidenceText: لا يوجد حديث رقم ${ref.num} في $name في القاعدة.'
          '$_refusalSuffix',
        );
      }
      return answer(
        <RagEvidence>[RagEvidence.hadith(row)],
        sections: buildExplanation(row, _db, level: level),
      );
    }

    // --- grade / terminology: real grade rows as evidence ---------------
    // Runs BEFORE the empty-terms check: these questions are answered
    // from the grade word, not from FTS terms (grade words are retrieval
    // stopwords, so content terms are legitimately empty here).
    if (intent == AssistantIntent.grade ||
        intent == AssistantIntent.terminology) {
      final gradeWord = _gradeWord(trimmed);
      if (gradeWord != null) {
        final rows = _db.hadithsWithGrade(gradeWord, limit: 6);
        if (rows.isNotEmpty) {
          var note = notAModelNote;
          if (intent == AssistantIntent.terminology) {
            note += ' تعريف المصطلح نفسه غير متوفر في القاعدة '
                '(جدول المصطلحات فارغ)؛ المعروض أمثلة موثقة '
                'من أحاديث مدرجة بهذه الدرجة فقط.';
          }
          return answer(
            rows.map(RagEvidence.hadith).toList(),
            note: note,
          );
        }
      }
      if (intent == AssistantIntent.terminology) {
        return refuse(
          '$noEvidenceText: تعريف هذا المصطلح غير متوفر في القاعدة '
          '(جدول المصطلحات فارغ).$_refusalSuffix',
        );
      }
      return refuse(
        '$noEvidenceText: لا توجد أحاديث مدرجة بهذه الدرجة في القاعدة.'
        '$_refusalSuffix',
      );
    }

    final terms = assistantContentTerms(trimmed);
    if (terms.isEmpty) {
      return refuse('اكتب سؤالاً أو كلمة للبحث في المكتبة.');
    }

    // --- takhrij / variants / shawahid / isnad / rijal / jarh / ilal ----
    if (intent == AssistantIntent.takhrij ||
        intent == AssistantIntent.variantDiff ||
        intent == AssistantIntent.shawahid ||
        intent == AssistantIntent.isnad ||
        intent == AssistantIntent.rijal ||
        intent == AssistantIntent.jarhTadil ||
        intent == AssistantIntent.ilal) {
      final rows = _searchTerms(terms);
      if (intent == AssistantIntent.takhrij ||
          intent == AssistantIntent.variantDiff ||
          intent == AssistantIntent.shawahid) {
        return refuse(
          '$noEvidenceText: جداول التخريج والروايات والطرق فارغة في '
          'القاعدة الحالية.$_refusalSuffix',
        );
      }
      if (rows.isEmpty) {
        return refuse('$noEvidenceText.$_refusalSuffix');
      }
      return answer(
        rows.map(RagEvidence.hadith).toList(),
        note: '$notAModelNote عرض نصوص مطابقة فقط؛ '
            'الأحكام والتراجم الخاصة بهذا الباب غير متوفرة.',
      );
    }

    // --- explain: 14-section template on the best hit -------------------
    if (intent == AssistantIntent.explain) {
      final rows = _searchTerms(terms);
      if (rows.isEmpty) {
        return refuse('$noEvidenceText.$_refusalSuffix');
      }
      return answer(
        rows.take(3).map(RagEvidence.hadith).toList(),
        sections: buildExplanation(rows.first, _db, level: level),
      );
    }

    // --- vocabulary / fiqh benefits: texts only; no verified gloss ------
    if (intent == AssistantIntent.vocabulary ||
        intent == AssistantIntent.fiqhBenefits) {
      final rows = _searchTerms(terms);
      if (rows.isEmpty) {
        return refuse('$noEvidenceText.$_refusalSuffix');
      }
      return answer(
        rows.map(RagEvidence.hadith).toList(),
        note: '$notAModelNote المعروض نصوص مطابقة فقط؛ '
            'المفردات/الفوائد الموثقة غير متوفرة في القاعدة.',
      );
    }

    // --- compare: retrieved texts side by side, no generated verdict ----
    if (intent == AssistantIntent.compare) {
      final rows = _searchTerms(terms);
      if (rows.isEmpty) {
        return refuse('$noEvidenceText.$_refusalSuffix');
      }
      return answer(
        rows.map(RagEvidence.hadith).toList(),
        note: '$notAModelNote مقارنة نصوص مسترجعة فقط؛ '
            'لا ترجيح ولا حكم مولّد.',
      );
    }

    // --- general search: FTS + standalone HadeethEnc passages -----------
    final rows = _searchTerms(terms);
    final evidences = rows.map(RagEvidence.hadith).toList();
    if (evidences.length < 3) {
      final commentaries = _searchCommentaries(terms, 3 - evidences.length);
      evidences.addAll(commentaries.map(RagEvidence.commentary));
    }
    if (evidences.isEmpty) {
      return refuse('$noEvidenceText.$_refusalSuffix');
    }
    return answer(evidences);
  }

  RagAnswer _answerNarrator(
    String query,
    NarratorQuestion sub,
    ExplanationLevel level,
    String? matched,
  ) {
    RagAnswer refuse(String note) => RagAnswer(
          query: query,
          intent: AssistantIntent.narrator,
          narratorQuestion: sub,
          level: level,
          evidences: const <RagEvidence>[],
          sections: const <ExplanationSection>[],
          refused: true,
          note: note,
          matchedPhrasing: matched,
        );
    // The narrators table is EMPTY (0 rows, verified). Every one of the
    // seven questions therefore refuses explicitly — no biography, no
    // verdict, no teacher/student list is ever invented.
    if (sub == NarratorQuestion.ways) {
      return refuse(
        '$noEvidenceText: الطرق تُعرض لحديث محدد من جدول الروايات، '
        'وهو فارغ في القاعدة الحالية.$_refusalSuffix',
      );
    }
    if (sub == NarratorQuestion.teachers ||
        sub == NarratorQuestion.students) {
      return refuse('$noEvidenceText: $coreZeroNote$_refusalSuffix');
    }
    return refuse(
      '$noEvidenceText: لا توجد ترجمة موثقة لهذا الراوي في القاعدة '
      '(جدول الرواة فارغ — 0 راوٍ).$_refusalSuffix',
    );
  }

  /// HadeethEnc passages whose normalised title + explanation contain
  /// every content term. Standalone passages only — never linked to a
  /// Nine-Books hadith.
  List<Commentary> _searchCommentaries(List<String> terms, int limit) {
    if (limit <= 0 || terms.isEmpty) return const <Commentary>[];
    final hits = <Commentary>[];
    for (final c in _db.allCommentaries()) {
      final norm = normalizeArabic('${c.title} ${c.explanation}');
      if (terms.every((t) => norm.contains(t))) {
        hits.add(c);
        if (hits.length >= limit) break;
      }
    }
    return hits;
  }

  /// The grade word in [query], if any, in the Python mirror's order.
  static String? _gradeWord(String query) {
    const ordered = <String>[
      'صحيح لغيره', 'ضعيف جدا', 'حسن صحيح', 'متفق عليه',
      'صحيح', 'حسن', 'ضعيف', 'موضوع', 'منكر', 'شاذ', 'غريب',
      'موقوف', 'مرسل', 'مقطوع', 'معلول', 'متواتر',
    ];
    final norm = normalizeArabic(query);
    for (final w in ordered) {
      if (norm.contains(normalizeArabic(w))) {
        return w.replaceAll('جدا', 'جداً');
      }
    }
    return null;
  }
}
