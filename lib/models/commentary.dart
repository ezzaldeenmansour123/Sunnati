/// A HadeethEnc commentary entry (standalone passage).
///
/// The 3,574 HadeethEnc rows are NOT linked to Nine-Books hadiths (no
/// reliable key — see `tools/build_db.py`): a [Commentary] is retrieved
/// and shown only as its own passage, with its own HadeethEnc key and
/// attribution, never presented as the commentary OF a Nine-Books hadith.
/// Never construct one with invented text; rows come only from the DB.
library;

class Commentary {
  const Commentary({
    required this.id,
    required this.hadithKey,
    required this.title,
    required this.text,
    required this.explanation,
    required this.gradeAr,
    required this.grader,
    required this.attribution,
    required this.source,
  });

  factory Commentary.fromRow(Map<String, Object?> row) {
    return Commentary(
      id: (row['id'] as int?) ?? 0,
      hadithKey: (row['hadith_key'] as String?) ?? '',
      title: (row['title'] as String?) ?? '',
      text: (row['text'] as String?) ?? '',
      explanation: (row['explanation'] as String?) ?? '',
      gradeAr: (row['grade_ar'] as String?) ?? '',
      grader: (row['grader'] as String?) ?? '',
      attribution: (row['attribution_text'] as String?) ?? '',
      source: (row['source'] as String?) ?? '',
    );
  }

  final int id;

  /// HadeethEnc key, e.g. `hadeethenc:1751` — the passage's own identity.
  final String hadithKey;

  /// The hadith text as HadeethEnc titles it (not a Nine-Books number).
  final String title;

  /// The hadith text as HadeethEnc gives it (verbatim, with tashkeel).
  final String text;

  /// The transmitted explanation text, verbatim.
  final String explanation;

  /// Grade recorded by HadeethEnc, verbatim Arabic.
  final String gradeAr;

  final String grader;

  /// Attribution text, shown with the passage (HadeethEnc terms).
  final String attribution;

  final String source;

  bool get hasExplanation => explanation.isNotEmpty;
}
