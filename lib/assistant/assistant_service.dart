/// SUNNATI assistant — local retrieval only (Phase 6).
///
/// Honest scope, per the master prompt §8 and the owner decisions: the
/// assistant RETRIEVES passages from the installed library and shows
/// them with their sources and numbers. It is a RETRIEVAL assistant —
/// intent matching over the phrasings dataset + evidence retrieval from
/// the local database — NOT a language model. It does NOT generate
/// answers, does NOT issue religious rulings, and must never be presented
/// as an AI that "understands" or "reasons". The screen is labelled
/// "استرجاع من المكتبة" and says so plainly.
///
/// Retrieval is done by [RagEngine]: intent detection, FTS retrieval over
/// content terms, the 14-section explanation template, and the hard rule
/// "no evidence -> explicit refusal, never invention".
library;

import '../data/database.dart';
import '../models/hadith.dart';
import 'explanation_template.dart'
    show ExplanationLevel, ExplanationSection;
import 'intent.dart' show AssistantIntent, NarratorQuestion;
import 'phrasings.dart';
import 'rag_engine.dart';

export 'explanation_template.dart' show ExplanationLevel;
export 'intent.dart' show AssistantIntent, NarratorQuestion;
export 'rag_engine.dart'
    show RagAnswer, RagEngine, RagEvidence, noEvidenceText, notAModelNote;

/// An assistant answer: retrieved evidences (+ the 14-section
/// explanation when the question is about one hadith), or an explicit
/// refusal when the database has no evidence.
class AssistantAnswer {
  const AssistantAnswer({
    required this.query,
    required this.passages,
    required this.level,
    required this.note,
    this.intent,
    this.narratorQuestion,
    this.evidences = const <RagEvidence>[],
    this.sections = const <ExplanationSection>[],
    this.refused = false,
    this.matchedPhrasing,
  });

  final String query;

  /// Retrieved hadiths (kept for the existing passage cards).
  final List<Hadith> passages;

  final ExplanationLevel level;

  /// Plain-language note shown with the answer: the scope note, or the
  /// explicit refusal reason ("لا توجد أدلة موثقة في القاعدة").
  final String note;

  /// Detected question category (master prompt §9).
  final AssistantIntent? intent;

  /// Narrator sub-question, when the question is about a narrator.
  final NarratorQuestion? narratorQuestion;

  /// Retrieved evidences with their citations + sources.
  final List<RagEvidence> evidences;

  /// 14-section explanation (level-filtered), when the question is
  /// about one hadith.
  final List<ExplanationSection> sections;

  /// True when the engine refused for lack of evidence.
  final bool refused;

  /// Closest known phrasing from the dataset, if any (intent-matching
  /// hint; it never changes the retrieved evidence).
  final String? matchedPhrasing;
}

class AssistantService {
  AssistantService(SunnatiDatabase db) : _engine = RagEngine(db);

  final RagEngine _engine;

  /// Phrasings loaded from the bundled dataset (empty until [load] runs).
  List<PhrasingEntry> _phrasings = const <PhrasingEntry>[];

  /// Load the bundled phrasings dataset for intent-matching hints.
  /// Safe to call repeatedly; a missing asset leaves the list empty and
  /// keyword intent still works.
  Future<void> load() async {
    _phrasings = await loadPhrasings();
  }

  /// Retrieve an answer for [query] by local retrieval only.
  AssistantAnswer ask(
    String query, {
    ExplanationLevel level = ExplanationLevel.scholarly,
  }) {
    final rag = _engine.ask(
      query,
      level: level,
      phrasings: _phrasings,
    );
    return AssistantAnswer(
      query: rag.query,
      passages: rag.evidences
          .where((e) => e.hadith != null)
          .map((e) => e.hadith!)
          .toList(),
      level: rag.level,
      note: rag.note,
      intent: rag.intent,
      narratorQuestion: rag.narratorQuestion,
      evidences: rag.evidences,
      sections: rag.sections,
      refused: rag.refused,
      matchedPhrasing: rag.matchedPhrasing,
    );
  }
}
