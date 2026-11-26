/// "Men assistant" (مساعد الرجال) — retrieval from the database only.
///
/// Answers the six documented narrator-question patterns by looking the
/// narrator up in the installed database and quoting what is recorded
/// there, with its source. It never generates a biography, a verdict or a
/// ruling, and when the tables are empty (or the narrator is not found)
/// the answer is an explicit "no verified data" — never a guess.
///
/// Question patterns (matched on normalised text):
///  - من هذا الراوي؟ / من هو …؟ — who is this narrator?
///  - ما أقوال العلماء في …؟ — critics' sayings
///  - من شيوخ …؟ — his teachers
///  - من تلاميذ …؟ — his students
///  - هل اختلفوا في …؟ — was he disputed?
///  - ما أحاديث …؟ — his recorded hadiths
///  - ما طرق الحديث؟ — routes of a given hadith (needs [hadith]).
library;

import '../core/normalize.dart';
import '../data/database.dart';
import '../models/hadith.dart';
import '../models/narrator.dart';

/// Which narrator pattern a question matches.
enum NarratorIntent {
  whoIs,
  sayings,
  teachers,
  students,
  disputed,
  hadiths,
  ways,
  unknown,
}

/// One sourced line of a narrator-assistant answer.
class NarratorAnswerLine {
  const NarratorAnswerLine({required this.text, this.source = ''});

  final String text;

  /// Source of this line, shown next to it. Empty when unrecorded.
  final String source;
}

/// Answer of the men assistant. [handled] is false only when the question
/// is not a narrator question at all, so the caller falls back to the
/// general retrieval assistant.
class NarratorAssistantAnswer {
  const NarratorAssistantAnswer({
    required this.handled,
    required this.intent,
    required this.title,
    required this.lines,
    this.narrator,
    this.narrators = const <Narrator>[],
    this.hadiths = const <Hadith>[],
    this.note = '',
  });

  final bool handled;
  final NarratorIntent intent;
  final String title;
  final List<NarratorAnswerLine> lines;
  final Narrator? narrator;
  final List<Narrator> narrators;
  final List<Hadith> hadiths;

  /// Plain-language note, e.g. why no data is shown.
  final String note;

  bool get hasContent => lines.isNotEmpty || hadiths.isNotEmpty;
}

/// Suggested question patterns shown as chips. The `…` is a placeholder
/// for the narrator's name, which the user types or which the reader
/// supplies from the hadith being read.
const List<String> narratorQuestionPatterns = <String>[
  'من هو الراوي …؟',
  'ما أقوال العلماء في …؟',
  'من شيوخ …؟',
  'من تلاميذ …؟',
  'هل اختلفوا في …؟',
  'ما أحاديث …؟',
  'ما طرق هذا الحديث؟',
];

class NarratorAssistantService {
  NarratorAssistantService(this._db);

  final SunnatiDatabase _db;

  static const String noDataNote =
      'لا توجد بيانات موثّقة عن هذا الراوي في المكتبة المثبّتة بعد — '
      'تراجم الرواة وأحوالهم قيد الاستيراد في المرحلة 5.';

  /// Teachers/students are ZERO in the first verified core — the
  /// narrator tables are empty (0 rows), so the answer says so
  /// explicitly instead of inventing a teacher/student list.
  static const String coreZeroNote =
      'الشيوخ والتلاميذ غير متوفرون في النواة الأولى — '
      'جدول الرواة فارغ في القاعدة الحالية (0 راوٍ موثق).';

  /// The no-data note for [intent]: teachers/students name the
  /// first-core gap explicitly.
  static String noDataNoteFor(NarratorIntent intent) {
    return intent == NarratorIntent.teachers ||
            intent == NarratorIntent.students
        ? 'لا توجد بيانات موثّقة عن هذا الراوي في المكتبة المثبّتة بعد. '
            '$coreZeroNote'
        : noDataNote;
  }

  /// Try to answer [query] as a narrator question. Returns an unhandled
  /// answer when the question is not about narrators at all.
  NarratorAssistantAnswer ask(String query, {Hadith? hadith}) {
    final intent = detectIntent(query);
    if (intent == NarratorIntent.unknown) {
      return const NarratorAssistantAnswer(
        handled: false,
        intent: NarratorIntent.unknown,
        title: '',
        lines: <NarratorAnswerLine>[],
      );
    }
    if (intent == NarratorIntent.ways) {
      return _answerWays(query, hadith);
    }
    final name = extractNarratorName(query, intent);
    if (name.isEmpty) {
      return NarratorAssistantAnswer(
        handled: true,
        intent: intent,
        title: 'مساعد الرجال',
        lines: const <NarratorAnswerLine>[],
        note: 'اذكر اسم الراوي في سؤالك، مثل: «من هو الزهري؟».',
      );
    }
    final matches = _db.searchNarrators(name);
    if (matches.isEmpty) {
      return NarratorAssistantAnswer(
        handled: true,
        intent: intent,
        title: 'مساعد الرجال',
        lines: const <NarratorAnswerLine>[],
        note: noDataNoteFor(intent),
      );
    }
    final narrator = matches.first;
    return _answerFor(narrator, intent);
  }

  NarratorAssistantAnswer _answerWays(String query, Hadith? hadith) {
    if (hadith == null) {
      return const NarratorAssistantAnswer(
        handled: true,
        intent: NarratorIntent.ways,
        title: 'طرق الحديث',
        lines: <NarratorAnswerLine>[],
        note: 'افتح حديثاً ثم اسأل عن طرقه — الطرق تُعرض لحديث محدد.',
      );
    }
    final variants = _db.variantsForHadith(hadith.id);
    if (variants.isEmpty) {
      return NarratorAssistantAnswer(
        handled: true,
        intent: NarratorIntent.ways,
        title: 'طرق الحديث ${hadith.num}',
        lines: const <NarratorAnswerLine>[],
        note:
            'لا توجد طرق مسجّلة لهذا الحديث بعد — جدول الطرق قيد الاستيراد في المرحلة 5.',
      );
    }
    return NarratorAssistantAnswer(
      handled: true,
      intent: NarratorIntent.ways,
      title: 'طرق الحديث ${hadith.num} (${variants.length})',
      lines: variants
          .map(
            (v) => NarratorAnswerLine(
              text: [
                if (v.variant != null)
                  'حديث ${v.variant!.num} — ${v.variant!.chapterTitle}',
                if (v.variantType.isNotEmpty) v.variantType,
                if (v.diffNote.isNotEmpty) v.diffNote,
              ].join(' — '),
              source: v.source,
            ),
          )
          .toList(),
    );
  }

  NarratorAssistantAnswer _answerFor(
    Narrator narrator,
    NarratorIntent intent,
  ) {
    final full = _db.narratorById(narrator.id) ?? narrator;
    switch (intent) {
      case NarratorIntent.whoIs:
        final lines = <NarratorAnswerLine>[];
        if (full.kunya.isNotEmpty) {
          lines.add(NarratorAnswerLine(text: 'الكنية: ${full.kunya}'));
        }
        if (full.laqab.isNotEmpty) {
          lines.add(NarratorAnswerLine(text: 'اللقب: ${full.laqab}'));
        }
        if (full.lineage.isNotEmpty) {
          lines.add(NarratorAnswerLine(text: 'النسب: ${full.lineage}'));
        }
        if (full.tier.isNotEmpty) {
          lines.add(NarratorAnswerLine(text: 'الطبقة: ${full.tier}'));
        }
        if (full.hasBirth || full.hasDeath) {
          lines.add(
            NarratorAnswerLine(
              text: [
                if (full.hasBirth) 'وُلد ${full.birthYearHijri}هـ',
                if (full.hasDeath) 'توفي ${full.deathYearHijri}هـ',
              ].join(' — '),
            ),
          );
        }
        if (full.hasCountry) {
          lines.add(NarratorAnswerLine(text: 'البلد: ${full.country}'));
        }
        if (full.hasStatus) {
          lines.add(
            NarratorAnswerLine(
              text: 'الحكم: ${full.status}',
              source: full.statusSource,
            ),
          );
        }
        return NarratorAssistantAnswer(
          handled: true,
          intent: intent,
          title: full.displayName,
          lines: lines,
          narrator: full,
          note: lines.isEmpty ? noDataNote : _sourceNote(full),
        );
      case NarratorIntent.sayings:
        final sayings = _db.narratorSayings(full.id);
        return NarratorAssistantAnswer(
          handled: true,
          intent: intent,
          title: 'أقوال العلماء في ${full.displayName}',
          lines: sayings
              .map(
                (s) => NarratorAnswerLine(
                  text: '${s.scholar}: ${s.text}',
                  source: s.source,
                ),
              )
              .toList(),
          narrator: full,
          note: sayings.isEmpty
              ? noDataNote
              : full.isDisputed
                  ? 'الأقوال مختلفة — عُرضت كما وردت دون ترجيح حكم واحد.'
                  : '',
        );
      case NarratorIntent.teachers:
        final teachers = _db.teachersOfNarrator(full.id);
        return NarratorAssistantAnswer(
          handled: true,
          intent: intent,
          title: 'شيوخ ${full.displayName}',
          lines: teachers
              .map((t) => NarratorAnswerLine(text: t.displayName))
              .toList(),
          narrator: full,
          narrators: teachers,
          note: teachers.isEmpty ? noDataNoteFor(intent) : '',
        );
      case NarratorIntent.students:
        final students = _db.studentsOfNarrator(full.id);
        return NarratorAssistantAnswer(
          handled: true,
          intent: intent,
          title: 'تلاميذ ${full.displayName}',
          lines: students
              .map((t) => NarratorAnswerLine(text: t.displayName))
              .toList(),
          narrator: full,
          narrators: students,
          note: students.isEmpty ? noDataNoteFor(intent) : '',
        );
      case NarratorIntent.disputed:
        return NarratorAssistantAnswer(
          handled: true,
          intent: intent,
          title: 'هل اختلفوا في ${full.displayName}؟',
          lines: full.hasStatus
              ? <NarratorAnswerLine>[
                  NarratorAnswerLine(
                    text: full.isDisputed
                        ? 'نعم — الحكم المسجّل: ${full.status}'
                        : 'الحكم المسجّل: ${full.status} — ولم يُسجَّل اختلاف فيه.',
                    source: full.statusSource,
                  ),
                ]
              : const <NarratorAnswerLine>[],
          narrator: full,
          note: full.hasStatus ? '' : noDataNote,
        );
      case NarratorIntent.hadiths:
        final hadiths = _db.hadithsForNarrator(full.id);
        return NarratorAssistantAnswer(
          handled: true,
          intent: intent,
          title: 'أحاديث ${full.displayName}',
          lines: hadiths
              .map(
                (h) => NarratorAnswerLine(
                  text: 'حديث ${h.num} — ${h.chapterTitle}',
                ),
              )
              .toList(),
          narrator: full,
          hadiths: hadiths,
          note: hadiths.isEmpty ? noDataNote : '',
        );
      case NarratorIntent.ways:
      case NarratorIntent.unknown:
        return const NarratorAssistantAnswer(
          handled: false,
          intent: NarratorIntent.unknown,
          title: '',
          lines: <NarratorAnswerLine>[],
        );
    }
  }

  String _sourceNote(Narrator narrator) {
    return narrator.biographySource.isNotEmpty
        ? 'المصدر: ${narrator.biographySource}'
        : '';
  }

  /// Which pattern [query] matches, from its wording only.
  static NarratorIntent detectIntent(String query) {
    final norm = normalizeArabic(query);
    if (norm.contains('طرق') && norm.contains('حديث')) {
      return NarratorIntent.ways;
    }
    if (norm.contains('اقوال العلماء') ||
        norm.contains('ماذا قال') ||
        norm.contains('قال فيه')) {
      return NarratorIntent.sayings;
    }
    if (norm.contains('شيوخ') || norm.contains('روي عن') || norm.contains('روى عن')) {
      return NarratorIntent.teachers;
    }
    if (norm.contains('تلاميذ') || norm.contains('روي عنه') || norm.contains('روى عنه')) {
      return NarratorIntent.students;
    }
    if (norm.contains('اختلف') || norm.contains('مختلف')) {
      return NarratorIntent.disputed;
    }
    if (norm.contains('احاديث') || norm.contains('ما روي') || norm.contains('ما روى')) {
      return NarratorIntent.hadiths;
    }
    if (norm.contains('من هو') ||
        norm.contains('من هذا الراوي') ||
        norm.contains('من الراوي') ||
        norm.contains('عرف بالراوي') ||
        norm.contains('ترجمه')) {
      return NarratorIntent.whoIs;
    }
    return NarratorIntent.unknown;
  }

  /// The narrator name inside [query]: the question words are stripped
  /// and what remains is the name candidate.
  static String extractNarratorName(String query, NarratorIntent intent) {
    var s = query
        .replaceAll('؟', ' ')
        .replaceAll('?', ' ')
        .replaceAll('…', ' ')
        .trim();
    const phrases = <String>[
      'ما أقوال العلماء في',
      'ما اقوال العلماء في',
      'أقوال العلماء في',
      'اقوال العلماء في',
      'ماذا قال العلماء في',
      'ماذا قال فيه',
      'هل اختلفوا في',
      'هل اختلف العلماء في',
      'من شيوخ',
      'من تلاميذ',
      'ما أحاديث',
      'ما احاديث',
      'من هو الراوي',
      'من هذا الراوي',
      'من الراوي',
      'من هو',
      'عرف بالراوي',
      'ترجمة',
      'في',
      'عن',
    ];
    for (final phrase in phrases) {
      if (s.startsWith(phrase)) {
        s = s.substring(phrase.length).trim();
      }
    }
    s = s.replaceAll(RegExp(r'^(من|ما|هل)\s+'), '').trim();
    return s;
  }
}
