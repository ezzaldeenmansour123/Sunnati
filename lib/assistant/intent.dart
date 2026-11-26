/// Assistant intent detection — Phase 6.
///
/// Pure Dart, no Flutter dependency. Mirrors `tools/assistant_engine.py`
/// exactly: the same 15 categories (master prompt §9), the same 7
/// narrator sub-intents (§10), the same keyword sets, the same priority
/// order, and the same guards:
///
///  * "أحاديث في الصلاة" is a TOPIC search, not a narrator question;
///    "ما أحاديث الزهري؟" is. The guard is [topicWords] (+ grade words).
///  * "أحاديث صحيح" is a grade search, not a narrator question.
///  * "ما معنى مصطلح صحيح؟" is terminology about a grade word.
///  * Bare "ما معنى" is NOT a terminology keyword on its own — otherwise
///    "ما معنى حديث الصلاة؟" would never reach the explain branch.
///
/// Keyword matching is done on normalised text ([normalizeArabic]), so
/// hamza/alef/ta-marbuta/diacritic variants all match. Nothing here
/// generates content: it only classifies the question so the retrieval
/// engine ([RagEngine]) knows which tables to query.
library;

import '../core/normalize.dart';

/// The 15 question categories (master prompt §9).
enum AssistantIntent {
  search,
  explain,
  vocabulary,
  narrator,
  grade,
  takhrij,
  variantDiff,
  shawahid,
  isnad,
  rijal,
  jarhTadil,
  ilal,
  terminology,
  fiqhBenefits,
  compare,
}

/// Arabic label of each category, shown next to the answer.
extension AssistantIntentLabel on AssistantIntent {
  String get labelAr => switch (this) {
        AssistantIntent.search => 'بحث',
        AssistantIntent.explain => 'شرح',
        AssistantIntent.vocabulary => 'مفردات',
        AssistantIntent.narrator => 'راوٍ',
        AssistantIntent.grade => 'أحكام',
        AssistantIntent.takhrij => 'تخريج',
        AssistantIntent.variantDiff => 'اختلاف روايات',
        AssistantIntent.shawahid => 'شواهد',
        AssistantIntent.isnad => 'أسانيد',
        AssistantIntent.rijal => 'رجال',
        AssistantIntent.jarhTadil => 'جرح وتعديل',
        AssistantIntent.ilal => 'علل',
        AssistantIntent.terminology => 'مصطلح',
        AssistantIntent.fiqhBenefits => 'فوائد فقهية',
        AssistantIntent.compare => 'مقارنة',
      };
}

/// The seven narrator questions (master prompt §10).
enum NarratorQuestion {
  whoIs,
  sayings,
  teachers,
  students,
  disputed,
  hadiths,
  ways,
}

/// Arabic wording of each narrator question, as shown in the UI chips.
extension NarratorQuestionLabel on NarratorQuestion {
  String get labelAr => switch (this) {
        NarratorQuestion.whoIs => 'من هو هذا الراوي؟',
        NarratorQuestion.sayings => 'ما أقوال العلماء فيه؟',
        NarratorQuestion.teachers => 'من أشهر شيوخه؟',
        NarratorQuestion.students => 'من أشهر تلاميذه؟',
        NarratorQuestion.disputed => 'هل اختلف العلماء فيه؟',
        NarratorQuestion.hadiths => 'ما الأحاديث التي ورد فيها؟',
        NarratorQuestion.ways => 'ما الطرق الأخرى للحديث؟',
      };
}

/// Result of intent detection.
class DetectedIntent {
  const DetectedIntent(this.intent, [this.narratorQuestion]);

  final AssistantIntent intent;

  /// Non-null only when [intent] is [AssistantIntent.narrator].
  final NarratorQuestion? narratorQuestion;
}

/// Topic words (normalised, prefix-stripped) that mark a question as a
/// TOPIC search, never a narrator question. Mirrors `TOPIC_WORDS` in
/// `tools/assistant_engine.py`.
const Set<String> topicWords = <String>{
  'صلاه', 'صيام', 'زكاه', 'حج', 'وضوء', 'طهار', 'علم', 'ايمان',
  'صدق', 'كذب', 'غيبه', 'والدين', 'رحم', 'جهاد', 'دعاء', 'ذكر',
  'توبه', 'صبر', 'شكر', 'حياء', 'امانه', 'عدل', 'رحمه', 'جار',
  'يتيم', 'مرض', 'جناز', 'نكاح', 'طلاق', 'بيوع', 'ربا', 'نيه', 'نيات',
};

/// Grade words (normalised) — also excluded from the narrator guard.
const Set<String> gradeWords = <String>{
  'صحيح', 'حسن', 'ضعيف', 'موضوع', 'منكر', 'شاذ', 'غريب', 'موقوف',
  'مرسل', 'مقطوع', 'معلول', 'متواتر',
};

/// Keyword sets per category, in priority order. Written in natural
/// Arabic; matched after [normalizeArabic], exactly like the Python side.
const Map<AssistantIntent, List<String>> _intentKeywords =
    <AssistantIntent, List<String>>{
  AssistantIntent.narrator: <String>['راوي', 'رواه', 'ترجمه', 'ترجمة'],
  AssistantIntent.takhrij: <String>[
    'تخريج', 'خرج', 'اخرج', 'اين ورد', 'مواضع ورود',
  ],
  AssistantIntent.variantDiff: <String>[
    'اختلاف الروايات', 'اختلاف روايات', 'اختلاف الفاظ',
    'روايه اخري', 'رواية أخري', 'روايه اخرى', 'فرق بين روايتي',
  ],
  AssistantIntent.shawahid: <String>[
    'شواهد', 'شاهد', 'متابعات', 'متابعه', 'طرق الحديث', 'طرق حديث',
  ],
  AssistantIntent.vocabulary: <String>[
    'مفردات', 'غريب الحديث', 'غريب', 'معني كلمه', 'معنى كلمة',
    'معني لفظ', 'ما معني كلمه',
  ],
  AssistantIntent.terminology: <String>[
    'عرف مصطلح', 'تعريف مصطلح', 'مصطلح', 'ما هو الحديث', 'ما الحديث',
  ],
  AssistantIntent.grade: <String>[
    'درجه', 'درجة', 'حكم الحديث', 'ما حكم', 'صحيح ام ضعيف',
    'صحيح او ضعيف', 'هل الحديث صحيح', 'هل هذا الحديث صحيح',
  ],
  AssistantIntent.explain: <String>[
    'اشرح', 'شرح', 'فسر', 'ما معني الحديث', 'ما معنى الحديث',
    'بين معني', 'وضح',
  ],
  AssistantIntent.fiqhBenefits: <String>[
    'فوايد فقهيه', 'فوائد فقهية', 'مسايل فقهيه', 'مسائل فقهية',
    'الاحكام الفقهيه', 'الأحكام الفقهية', 'يستفاد', 'فوايد الحديث',
    'فوائد الحديث',
  ],
  AssistantIntent.compare: <String>[
    'قارن', 'مقارنه', 'مقارنة', 'الفرق بين', 'ما الفرق', 'ايهما اصح',
    'أيهما أصح',
  ],
  AssistantIntent.isnad: <String>[
    'اسناد', 'إسناد', 'سند الحديث', 'سلسله الرواه', 'سلسلة الرواة',
  ],
  AssistantIntent.rijal: <String>['رجال', 'الرجال', 'علم الرجال'],
  AssistantIntent.jarhTadil: <String>[
    'جرح وتعديل', 'جرح', 'تعديل', 'توثيق', 'تضعيف', 'ثقه', 'صدوق',
    'ضعيف الراوي', 'حاله الراوي', 'حال الراوي',
  ],
  AssistantIntent.ilal: <String>[
    'علل', 'عله', 'علة الحديث', 'معلول', 'العلل',
  ],
  AssistantIntent.search: <String>[
    'ابحث', 'احاديث في', 'أحاديث في', 'احاديث عن', 'اورد احاديث',
    'اعرض احاديث',
  ],
};

const List<AssistantIntent> _intentPriority = <AssistantIntent>[
  AssistantIntent.narrator,
  AssistantIntent.takhrij,
  AssistantIntent.variantDiff,
  AssistantIntent.shawahid,
  AssistantIntent.vocabulary,
  AssistantIntent.terminology,
  AssistantIntent.grade,
  AssistantIntent.explain,
  AssistantIntent.fiqhBenefits,
  AssistantIntent.compare,
  AssistantIntent.isnad,
  AssistantIntent.rijal,
  AssistantIntent.jarhTadil,
  AssistantIntent.ilal,
  AssistantIntent.search,
];

/// Which narrator sub-intent [normalizedQuery] matches, or null.
/// The "hadiths" branch fires only when the remainder after stripping
/// "ما أحاديث" is a narrator name, not a topic or a grade word.
NarratorQuestion? detectNarratorQuestion(String normalizedQuery) {
  final norm = normalizedQuery;
  if (norm.contains('طرق') && norm.contains('حديث')) {
    return NarratorQuestion.ways;
  }
  if (norm.contains('اقوال العلماء') ||
      norm.contains('ماذا قال') ||
      norm.contains('قال فيه')) {
    return NarratorQuestion.sayings;
  }
  if (norm.contains('شيوخ') ||
      norm.contains('روي عن') ||
      norm.contains('روى عن')) {
    return NarratorQuestion.teachers;
  }
  if (norm.contains('تلاميذ') ||
      norm.contains('روي عنه') ||
      norm.contains('روى عنه')) {
    return NarratorQuestion.students;
  }
  if (norm.contains('اختلف') || norm.contains('مختلف')) {
    return NarratorQuestion.disputed;
  }
  if (norm.contains('احاديث') ||
      norm.contains('ما روي') ||
      norm.contains('ما روى')) {
    var rest = norm;
    for (final p in <String>[
      'ما احاديث', 'احاديث', 'ما روي', 'ما روى',
    ]) {
      rest = rest.replaceAll(p, ' ');
    }
    rest = rest.replaceAll(RegExp(r'\s+'), ' ').trim();
    final restWords = rest
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map(stripPrefixes)
        .toList();
    if (restWords.isNotEmpty &&
        !restWords.any(
          (w) => topicWords.contains(w) || gradeWords.contains(w),
        )) {
      return NarratorQuestion.hadiths;
    }
    return null;
  }
  if (norm.contains('من هو') ||
      norm.contains('من هذا الراوي') ||
      norm.contains('من الراوي') ||
      norm.contains('عرف بالراوي') ||
      norm.contains('ترجمه') ||
      norm.contains('ترجمة')) {
    return NarratorQuestion.whoIs;
  }
  return null;
}

/// Classify [query] into one of the 15 categories (+ narrator sub-intent).
DetectedIntent detectAssistantIntent(String query) {
  final norm = normalizeArabic(query);
  final narrator = detectNarratorQuestion(norm);
  if (narrator != null) {
    return DetectedIntent(AssistantIntent.narrator, narrator);
  }
  final words = norm.split(' ').where((w) => w.isNotEmpty).toSet();
  final hasGradeWord = words.intersection(gradeWords).isNotEmpty;
  if (norm.contains('احاديث') && hasGradeWord) {
    return const DetectedIntent(AssistantIntent.grade);
  }
  if (hasGradeWord &&
      (words.contains('معني') ||
          norm.contains('مصطلح') ||
          norm.contains('تعريف'))) {
    return const DetectedIntent(AssistantIntent.terminology);
  }
  for (final intent in _intentPriority) {
    for (final kw in _intentKeywords[intent]!) {
      if (norm.contains(normalizeArabic(kw))) {
        return DetectedIntent(intent);
      }
    }
  }
  return const DetectedIntent(AssistantIntent.search);
}

/// Retrieval stopwords: question/task nouns, book names, grade words and
/// jarh verdict words. They describe the QUESTION, not the evidence, so
/// they must never become FTS terms. Checked against the raw normalised
/// token, its article-stripped form and its fully prefix-stripped form —
/// the stripper turns "الفقهية" into "قهيه", so checking only the final
/// form would miss it. Mirrors `RETRIEVAL_STOPWORDS` in Python.
const Set<String> retrievalStopwords = <String>{
  'ما', 'من', 'هل', 'كيف', 'اين', 'متي', 'لماذا', 'اشرح', 'شرح', 'عرف',
  'اذكر', 'اعطني', 'اريد', 'ابحث', 'اورد', 'هات', 'حدثني', 'اخبرني',
  'هو', 'هي', 'هذا', 'هذه', 'ذلك', 'في', 'عن', 'الي', 'او', 'ام',
  '؟', 'سوال', 'سؤال',
  'حديث', 'احاديث', 'حديثا', 'روايه', 'روايات', 'روايتي', 'كتاب',
  'باب', 'معني', 'كلمه', 'مه', 'لفظ', 'مفرده', 'مفردات', 'غريب',
  'فوايد', 'فوائد', 'مسايل', 'مسائل', 'احكام', 'فقهيه', 'فقهي',
  'فقه', 'تخريج', 'اسناد', 'سند', 'شواهد', 'شاهد', 'طرق', 'طريق',
  'عله', 'علل', 'مصطلح', 'راوي', 'رواه', 'رجال', 'مقارنه', 'قارن',
  'فرق', 'بين', 'ورد', 'مواضع', 'ورود', 'اخرج', 'خرج', 'وضح',
  'فسر', 'شيوخ', 'تلاميذ', 'ترجمه', 'ترجمة', 'اقوال',
  'العلماء', 'علماء', 'حال', 'حاله',
  'بخاري', 'خاري', 'مسلم', 'داود', 'ترمذي', 'نسايي', 'ماجه',
  'احمد', 'مالك', 'دارمي', 'موطا', 'ابو', 'ابن',
  'صحيح', 'حسن', 'ضعيف', 'موضوع', 'منكر', 'شاذ', 'موقوف', 'مرسل',
  'مقطوع', 'معلول', 'متواتر', 'متفق', 'عليه', 'جدا',
  'ثقه', 'صدوق', 'حافظ', 'مدلس', 'متروك', 'مجهول', 'مختلف', 'فيه',
  'باس', 'به', 'لا',
};

/// Content terms of [query] for FTS: normalised tokens minus retrieval
/// stopwords (checked in all three forms, see above), prefix-stripped.
/// Empty when the query carries no retrievable content.
List<String> assistantContentTerms(String query) {
  final out = <String>[];
  for (final w in normalizeArabic(query).split(' ')) {
    if (w.isEmpty) continue;
    final stripped = stripPrefixes(w);
    final noArticle =
        w.startsWith('ال') && w.length > 3 ? w.substring(2) : w;
    if (retrievalStopwords.contains(w) ||
        retrievalStopwords.contains(noArticle) ||
        retrievalStopwords.contains(stripped)) {
      continue;
    }
    if (stripped.length > 1) out.add(stripped);
  }
  return out;
}

/// Parse "البخاري رقم 1" / "حديث رقم 5 في مسلم" into (bookId, number).
/// Returns nulls when no book + number pair is present. The book keywords
/// are matched on normalised text.
({String? bookId, int? num}) extractBookNumber(String query) {
  const bookKeywords = <String, String>{
    'البخاري': 'bukhari', 'بخاري': 'bukhari',
    'مسلم': 'muslim',
    'ابي داود': 'abudawud', 'أبي داود': 'abudawud', 'ابو داود': 'abudawud',
    'الترمذي': 'tirmidhi', 'ترمذي': 'tirmidhi',
    'النسائي': 'nasai', 'النسايي': 'nasai', 'نسايي': 'nasai',
    'ابن ماجه': 'ibnmajah',
    'احمد': 'ahmad', 'أحمد': 'ahmad',
    'مالك': 'malik', 'الموطا': 'malik', 'موطا': 'malik',
    'الدارمي': 'darimi', 'دارمي': 'darimi',
  };
  final norm = normalizeArabic(query);
  String? bookId;
  for (final entry in bookKeywords.entries) {
    if (norm.contains(normalizeArabic(entry.key))) {
      bookId = entry.value;
      break;
    }
  }
  final m = RegExp(r'رقم\s+(\d+)').firstMatch(norm);
  final num = m == null ? null : int.tryParse(m.group(1)!);
  return (bookId: bookId, num: num);
}
