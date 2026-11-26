/// The 14-section hadith-explanation template — Phase 6 (master prompt §8).
///
/// Order (fixed): نص / مصدر / راوٍ / تخريج / درجة / شرح إجمالي / مفردات /
/// جمل / أقوال علماء / فوائد / مسائل فقهية / روايات أخرى / شواهد وطرق /
/// مصادر. Every section is built ONLY from rows that exist in the
/// installed database:
///
///  * النص، المصدر، المصادر — always available (the hadith row itself).
///  * الدرجة — from `hadith_grades`; Bukhari/Muslim are collection-level
///    sahih (no per-hadith grade in the source); Ahmad/Darimi have no
///    grade in the source — both are stated, never invented.
///  * أقوال العلماء — the recorded graders' opinions on this hadith
///    (same rows as الدرجة); nothing else is presented as a scholar's word.
///  * الراوي، التخريج، الروايات الأخرى، الشواهد والطرق — the narrators /
///    takhrij / variants tables are EMPTY in the shipped DB (0 rows), so
///    these sections are always UNAVAILABLE for now.
///  * الشرح الإجمالي، المفردات، الجمل، الفوائد، المسائل الفقهية — no
///    transmitted commentary/glossary/benefit rows are stored on the
///    hadith row (`expl` is empty for every Nine-Books row) and HadeethEnc
///    commentaries are NOT auto-linked to Nine-Books hadiths, so these
///    sections are UNAVAILABLE too — never filled with generated text.
///
/// A section that has no backing row is returned with [available] false
/// and content [unavailableText]; the UI shows exactly that. Levels only
/// change WHICH sections are shown, never their content:
/// simplified {1, 2, 5} (text shortened to 160 chars), scholarly
/// {1, 2, 5, 9, 14}, specialist all 14.
library;

import '../data/database.dart';
import '../models/hadith.dart';

/// Explanation level (master prompt §8). The level only changes how much
/// of each retrieved passage / how many of the 14 sections are shown
/// (short excerpt vs full text vs full text + grades + commentary); it
/// never changes the content into generated text.
enum ExplanationLevel {
  /// مبسّط — short excerpt; sections {1, 2, 5}.
  simplified,

  /// علمي — full text + grades; sections {1, 2, 5, 9, 14}.
  scholarly,

  /// متخصص — full text + grades + transmitted commentary when available;
  /// all 14 sections, unavailable ones stated explicitly.
  specialist,
}

/// Text shown for a section with no backing data. The exact wording is
/// part of the contract (the tests look for it).
const String unavailableSectionText = 'غير متوفر في المصادر المتاحة';

/// One section of the 14-section template.
class ExplanationSection {
  const ExplanationSection({
    required this.index,
    required this.title,
    required this.content,
    required this.source,
    required this.available,
  });

  /// 1..14, in the master prompt's order.
  final int index;

  final String title;

  /// The section body, or [unavailableSectionText] + reason when empty.
  final String content;

  /// Source shown next to the section. Empty when unavailable.
  final String source;

  /// False when no backing row exists — the section must then be shown
  /// as unavailable, never filled.
  final bool available;
}

/// Fixed titles in order.
const List<String> explanationSectionTitles = <String>[
  'النص', 'المصدر', 'الراوي', 'التخريج', 'الدرجة', 'الشرح الإجمالي',
  'المفردات', 'الجمل', 'أقوال العلماء', 'الفوائد', 'المسائل الفقهية',
  'الروايات الأخرى', 'الشواهد والطرق', 'المصادر',
];

/// Book id -> Arabic display name (the nine books).
const Map<String, String> bookDisplayNames = <String, String>{
  'bukhari': 'صحيح البخاري',
  'muslim': 'صحيح مسلم',
  'abudawud': 'سنن أبي داود',
  'tirmidhi': 'جامع الترمذي',
  'nasai': 'سنن النسائي',
  'ibnmajah': 'سنن ابن ماجه',
  'ahmad': 'مسند أحمد',
  'malik': 'موطأ مالك',
  'darimi': 'سنن الدارمي',
};

/// Build all 14 sections for [hadith] from the database only.
List<ExplanationSection> buildExplanation(
  Hadith hadith,
  SunnatiDatabase db, {
  ExplanationLevel level = ExplanationLevel.scholarly,
}) {
  final book = hadith.bookId;
  final bookName = bookDisplayNames[book] ?? book;
  final chapter = hadith.chapterTitle;
  final gradeRecords = db.gradeRecordsForHadith(hadith.id);

  late final String gradeContent;
  late final String gradeSource;
  late final bool gradeAvailable;
  if (book == 'bukhari' || book == 'muslim') {
    gradeContent =
        'صحيح على مستوى المجموعة — لا درجة لكل حديث في المصدر '
        '(إجماع أهل السنة على صحة الصحيحين).';
    gradeSource = 'quranlab/hadith — سياسة الدرجات في المصدر';
    gradeAvailable = true;
  } else if (book == 'ahmad' || book == 'darimi') {
    gradeContent = 'لا توجد درجة في المصدر — لم تُخترَع درجة.';
    gradeSource = 'quranlab/hadith — سياسة الدرجات في المصدر';
    gradeAvailable = true;
  } else if (gradeRecords.isNotEmpty) {
    gradeContent = gradeRecords
        .map((g) => '${g.grader}: ${g.gradeAr}')
        .join('؛ ');
    gradeSource =
        'hadith_grades — ${gradeRecords.map((g) => g.source).toSet().join('; ')}';
    gradeAvailable = true;
  } else {
    gradeContent = unavailableSectionText;
    gradeSource = '';
    gradeAvailable = false;
  }

  final sayingsAvailable =
      gradeRecords.isNotEmpty || book == 'bukhari' || book == 'muslim' ||
          book == 'ahmad' || book == 'darimi';
  final String sayingsContent;
  if (gradeRecords.isNotEmpty) {
    sayingsContent = gradeContent;
  } else if (book == 'ahmad' || book == 'darimi') {
    sayingsContent =
        'لا توجد درجة في المصدر، فلا أقوال محدثين مسجلة لهذا الحديث.';
  } else if (book == 'bukhari' || book == 'muslim') {
    sayingsContent = gradeContent;
  } else {
    sayingsContent = unavailableSectionText;
  }

  final text = level == ExplanationLevel.simplified && hadith.text.length > 160
      ? '${hadith.text.substring(0, 160)}…'
      : hadith.text;

  final sections = <ExplanationSection>[
    ExplanationSection(
      index: 1,
      title: 'النص',
      content: text,
      source: '$bookName رقم ${hadith.num}',
      available: true,
    ),
    ExplanationSection(
      index: 2,
      title: 'المصدر',
      content: '$bookName — حديث رقم ${hadith.num}'
          '${chapter.isNotEmpty ? ' — باب/كتاب: $chapter' : ''}',
      source: 'quranlab/hadith (مراجعة مثبّتة 9e5d61d8)',
      available: true,
    ),
    const ExplanationSection(
      index: 3,
      title: 'الراوي',
      content: '$unavailableSectionText — جدول الرواة فارغ (0 راوٍ موثق).',
      source: '',
      available: false,
    ),
    const ExplanationSection(
      index: 4,
      title: 'التخريج',
      content: '$unavailableSectionText — جدول التخريج فارغ.',
      source: '',
      available: false,
    ),
    ExplanationSection(
      index: 5,
      title: 'الدرجة',
      content: gradeContent,
      source: gradeSource,
      available: gradeAvailable,
    ),
    const ExplanationSection(
      index: 6,
      title: 'الشرح الإجمالي',
      content:
          '$unavailableSectionText — لا شرح منقول مخزّن على صف الحديث؛ '
          'وشروح HadeethEnc غير مربوطة بالأحاديث التسعة فلا تُنسب إليها.',
      source: '',
      available: false,
    ),
    const ExplanationSection(
      index: 7,
      title: 'المفردات',
      content: '$unavailableSectionText — جدول المصطلحات/الغريب فارغ.',
      source: '',
      available: false,
    ),
    const ExplanationSection(
      index: 8,
      title: 'الجمل',
      content: '$unavailableSectionText — لا شرح للجمل مخزّن في المصادر المتاحة.',
      source: '',
      available: false,
    ),
    ExplanationSection(
      index: 9,
      title: 'أقوال العلماء',
      content: sayingsContent,
      source: sayingsAvailable ? gradeSource : '',
      available: sayingsAvailable,
    ),
    const ExplanationSection(
      index: 10,
      title: 'الفوائد',
      content: '$unavailableSectionText — لا فوائد موثقة مخزّنة لهذا الحديث.',
      source: '',
      available: false,
    ),
    const ExplanationSection(
      index: 11,
      title: 'المسائل الفقهية',
      content:
          '$unavailableSectionText — لا مسائل فقهية موثقة مخزّنة لهذا الحديث.',
      source: '',
      available: false,
    ),
    const ExplanationSection(
      index: 12,
      title: 'الروايات الأخرى',
      content: '$unavailableSectionText — جدول الروايات فارغ.',
      source: '',
      available: false,
    ),
    const ExplanationSection(
      index: 13,
      title: 'الشواهد والطرق',
      content: '$unavailableSectionText — جدولا التخريج والروايات فارغان.',
      source: '',
      available: false,
    ),
    ExplanationSection(
      index: 14,
      title: 'المصادر',
      content: 'quranlab/hadith (المتن العربي، المراجعة 9e5d61d8)؛ '
          'المصدر الفرعي: $bookName؛ '
          'فهرس الأبواب: fawazahmed0/hadith-api (عناوين إنجليزية حرفية)',
      source: 'meta — قاعدة sunnati.db',
      available: true,
    ),
  ];
  return visibleSections(sections, level);
}

/// Which sections a level shows. Specialist shows all 14, unavailable
/// ones stated explicitly; lower levels show a subset only.
List<ExplanationSection> visibleSections(
  List<ExplanationSection> sections,
  ExplanationLevel level,
) {
  return switch (level) {
    ExplanationLevel.simplified =>
      sections.where((s) => <int>{1, 2, 5}.contains(s.index)).toList(),
    ExplanationLevel.scholarly =>
      sections.where((s) => <int>{1, 2, 5, 9, 14}.contains(s.index)).toList(),
    ExplanationLevel.specialist => sections,
  };
}
