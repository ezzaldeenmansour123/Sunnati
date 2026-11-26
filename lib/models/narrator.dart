/// A narrator (راوٍ) — Phase 5 model.
///
/// Rows come only from the database: the Phase 5 core reads them from the
/// derived `narrators.db` (OpenITI Taqrib al-Tahdhib, CC BY-NC-SA 4.0)
/// when it is installed, else from the local (empty) `narrators` table —
/// screens then report honestly that no verified narrators are installed.
/// Never construct a [Narrator] with invented facts; rows come only from
/// the database.
///
/// New Phase-5 fields ([laqab], [lineage], [country], [birthYearHijri],
/// [teachersIds], [studentsIds], [sayings]) are optional and default to
/// empty: [Narrator.fromRow] reads them only when the row actually carries
/// them, so rows from the current schema — which has no such columns yet —
/// keep parsing exactly as before. [teachersIds]/[studentsIds] are filled
/// by [SunnatiDatabase.narratorById] from verified `chains` adjacency
/// (see the database docs for the position convention); [sayings] are
/// loaded separately via [SunnatiDatabase.narratorSayings].
library;

import '../core/narrator_logic.dart';

export '../core/narrator_logic.dart'
    show gradeRank, isDisputedStatus, canonicalGradeLabel;

/// One critic's saying about a narrator, always with its source.
///
/// Rows come from `narrators_db.narrator_grades` (Phase 5 core: the grade
/// wording verbatim with its speaker and the exact source reference);
/// until the narrators database is installed the list is empty and the
/// UI says so. When sayings conflict, the UI shows them side by side as
/// `مختلف فيه` — it never collapses them into a single verdict.
class NarratorSaying {
  const NarratorSaying({
    required this.scholar,
    required this.text,
    required this.source,
  });

  factory NarratorSaying.fromRow(Map<String, Object?> row) {
    return NarratorSaying(
      scholar: (row['scholar'] as String?) ?? '',
      text: (row['saying'] as String?) ?? '',
      source: (row['source'] as String?) ?? '',
    );
  }

  /// The critic, e.g. `ابن حجر`.
  final String scholar;

  /// The saying exactly as recorded.
  final String text;

  /// Source of the saying, e.g. `تقريب التهذيب`. Empty means unrecorded.
  final String source;

  bool get hasSource => source.isNotEmpty;
}

class Narrator {
  const Narrator({
    required this.id,
    required this.name,
    required this.kunya,
    required this.tier,
    required this.deathYearHijri,
    required this.status,
    required this.statusSource,
    required this.biographySource,
    this.laqab = '',
    this.lineage = '',
    this.country = '',
    this.birthYearHijri = 0,
    this.teachersIds = const <int>[],
    this.studentsIds = const <int>[],
    this.sayings = const <NarratorSaying>[],
  });

  factory Narrator.fromRow(Map<String, Object?> row) {
    return Narrator(
      id: (row['id'] as int?) ?? 0,
      name: (row['name'] as String?) ?? '',
      kunya: (row['kunya'] as String?) ?? '',
      tier: (row['tier'] as String?) ?? '',
      deathYearHijri: (row['death_hijri'] as int?) ?? 0,
      status: (row['status'] as String?) ?? '',
      statusSource: (row['status_src'] as String?) ?? '',
      biographySource: (row['bio_src'] as String?) ?? '',
      laqab: (row['laqab'] as String?) ?? '',
      lineage: (row['lineage'] as String?) ?? '',
      country: (row['country'] as String?) ?? '',
      birthYearHijri: (row['birth_hijri'] as int?) ?? 0,
      teachersIds: _intList(row['teachers_ids']),
      studentsIds: _intList(row['students_ids']),
    );
  }

  static List<int> _intList(Object? value) {
    if (value is List) {
      return value.whereType<int>().toList();
    }
    return const <int>[];
  }

  final int id;

  /// Full name, e.g. `أبو هريرة عبد الرحمن بن صخر الدوسي`.
  final String name;

  /// Kunya, e.g. `أبو هريرة`.
  final String kunya;

  /// Generation / tabaqa as recorded by the source (empty if unknown).
  final String tier;

  /// Hijri year of death (0 if unknown — never guessed).
  final int deathYearHijri;

  /// Critics' status, e.g. `ثقة` — always with [statusSource]; empty if
  /// no critic's verdict is recorded for this narrator.
  final String status;

  /// Source of [status], e.g. `تقريب التهذيب`. Shown next to the status.
  final String statusSource;

  /// Source of the biography itself. Shown on the narrator page.
  final String biographySource;

  /// Laqab (لقب), e.g. `الحافظ`. Empty when the import records none.
  final String laqab;

  /// Lineage / nasab (نسب), e.g. `الدوسي`. Empty when unrecorded.
  final String lineage;

  /// Country / homeland (بلد), e.g. `المدينة`. Empty when unrecorded.
  final String country;

  /// Hijri year of birth (0 if unknown — never guessed).
  final int birthYearHijri;

  /// Ids of his teachers (شيوخ), derived from verified chains.
  final List<int> teachersIds;

  /// Ids of his students (تلاميذ), derived from verified chains.
  final List<int> studentsIds;

  /// Critics' sayings about him, each with its source. Loaded separately;
  /// empty until the Phase-5 import provides the sayings table.
  final List<NarratorSaying> sayings;

  bool get hasStatus => status.isNotEmpty;

  bool get hasLaqab => laqab.isNotEmpty;

  bool get hasLineage => lineage.isNotEmpty;

  bool get hasCountry => country.isNotEmpty;

  bool get hasBirth => birthYearHijri > 0;

  bool get hasDeath => deathYearHijri > 0;

  /// True when the recorded verdicts about him conflict.
  bool get isDisputed => isDisputedStatus(status);

  /// Rank of [status] (1 strongest … 7 weakest), null if disputed/unknown.
  int? get statusRank => gradeRank(status);

  /// True when at least one biographical fact beyond the name is recorded.
  bool get hasBiographyData =>
      kunya.isNotEmpty ||
      laqab.isNotEmpty ||
      lineage.isNotEmpty ||
      country.isNotEmpty ||
      tier.isNotEmpty ||
      hasBirth ||
      hasDeath ||
      hasStatus ||
      sayings.isNotEmpty;

  /// Name to show in lists: full name, falling back to the kunya.
  String get displayName => name.isNotEmpty ? name : kunya;
}
