/// A scholar's grading of a hadith (e.g. الألباني: صحيح).
///
/// Grades are stored in the DB as a JSON list of `{scholar, grade}` objects
/// and are shown only where the source provides them. Bukhari and Muslim
/// carry no per-hadith grade (their authenticity is at collection level);
/// Musnad Ahmad and Sunan al-Darimi carry no grades in the source — the UI
/// must say "لم يرد حكم" rather than invent one.
library;

import 'dart:convert';

class HadithGrade {
  const HadithGrade({required this.scholar, required this.grade});

  factory HadithGrade.fromJson(Map<String, Object?> json) {
    return HadithGrade(
      scholar: (json['scholar'] as String?) ?? '',
      grade: (json['grade'] as String?) ?? '',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'scholar': scholar,
        'grade': grade,
      };

  /// Name of the grading scholar, e.g. `الألباني`.
  final String scholar;

  /// Grade text as given by the source, e.g. `صحيح`.
  final String grade;
}

/// Parse the JSON `grades` column; returns an empty list on bad/missing data
/// instead of throwing — a missing grade is a fact, not a crash.
List<HadithGrade> parseGrades(String? gradesJson) {
  if (gradesJson == null || gradesJson.trim().isEmpty) {
    return const <HadithGrade>[];
  }
  try {
    final decoded = jsonDecode(gradesJson);
    if (decoded is! List) return const <HadithGrade>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(HadithGrade.fromJson)
        .where((g) => g.scholar.isNotEmpty && g.grade.isNotEmpty)
        .toList();
  } catch (_) {
    return const <HadithGrade>[];
  }
}

/// Grades offered as a search filter. The list is a UI vocabulary only;
/// filtering matches the grade text stored in the DB.
const List<String> gradeFilterOptions = <String>[
  'صحيح',
  'حسن',
  'ضعيف',
  'موضوع',
];

/// One row of `hadith_grades`: a single grader's opinion on one hadith,
/// kept verbatim (`gradeAr`) with its normalised kind and source.
/// The assistant's الدرجة / أقوال العلماء sections are built from these
/// rows only — never from a paraphrase.
class HadithGradeDetail {
  const HadithGradeDetail({
    required this.grader,
    required this.gradeAr,
    required this.gradeKind,
    required this.source,
  });

  factory HadithGradeDetail.fromRow(Map<String, Object?> row) {
    return HadithGradeDetail(
      grader: (row['grader'] as String?) ?? '',
      gradeAr: (row['grade_ar'] as String?) ?? '',
      gradeKind: (row['grade_kind'] as String?) ?? '',
      source: (row['source'] as String?) ?? '',
    );
  }

  /// Grader name in Arabic, e.g. `الألباني`.
  final String grader;

  /// Grade text, e.g. `حسن صحيح`.
  final String gradeAr;

  /// Normalised kind, e.g. `صحيح` / `حسن` / `ضعيف`.
  final String gradeKind;

  /// Provenance of the row, e.g. `fawazahmed0/hadith-api`.
  final String source;
}
