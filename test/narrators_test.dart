import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/core/narrator_logic.dart';
import 'package:sunnati/models/chain.dart';
import 'package:sunnati/models/narrator.dart';

void main() {
  group('gradeRank — the eight jarh-wa-ta\'dil verdicts', () {
    test('ranks the seven graded verdicts strongest to weakest', () {
      expect(gradeRank('ثقة ثبت'), 1);
      expect(gradeRank('ثقة'), 2);
      expect(gradeRank('صدوق'), 3);
      expect(gradeRank('لا بأس به'), 4);
      expect(gradeRank('ضعيف'), 5);
      expect(gradeRank('متروك'), 6);
      expect(gradeRank('مجهول'), 7);
    });

    test('matches despite diacritics and hamza forms', () {
      expect(gradeRank('ثِقَةٌ'), 2);
      expect(gradeRank('لَا بَأْسَ بِهِ'), 4);
    });

    test('مختلف فيه has no rank — it is a conflict, not a grade', () {
      expect(gradeRank('مختلف فيه'), isNull);
      expect(isDisputedStatus('مختلف فيه'), isTrue);
      expect(isDisputedStatus('ثقة'), isFalse);
    });

    test('unrecognised wording has no rank and is never forced into one', () {
      expect(gradeRank('إمام حافظ'), isNull);
      expect(gradeRank(''), isNull);
    });

    test('compareGradeRanks orders verdicts, null when either is unranked', () {
      expect(compareGradeRanks('ثقة', 'ضعيف'), lessThan(0));
      expect(compareGradeRanks('ضعيف', 'ثقة'), greaterThan(0));
      expect(compareGradeRanks('ثقة', 'ثقة'), 0);
      expect(compareGradeRanks('مختلف فيه', 'ثقة'), isNull);
    });

    test('canonicalGradeLabel keeps the eight labels, passes the rest through', () {
      expect(canonicalGradeLabel('ثقه'), 'ثقة');
      expect(canonicalGradeLabel('مختلف فيه'), 'مختلف فيه');
      expect(canonicalGradeLabel('إمام حافظ'), 'إمام حافظ');
      expect(gradeVerdicts, hasLength(8));
    });
  });

  group('Narrator.fromRow — backward compatible with the current schema', () {
    test('old rows without the new columns parse exactly as before', () {
      final n = Narrator.fromRow(<String, Object?>{
        'id': 1,
        'name': 'الزهري',
        'kunya': 'أبو بكر',
        'tier': 'الطبقة الرابعة',
        'death_hijri': 124,
        'status': 'ثقة',
        'status_src': 'تقريب التهذيب',
        'bio_src': 'تهذيب التهذيب',
      });
      expect(n.id, 1);
      expect(n.name, 'الزهري');
      expect(n.hasStatus, isTrue);
      expect(n.statusRank, 2);
      expect(n.isDisputed, isFalse);
      expect(n.laqab, '');
      expect(n.lineage, '');
      expect(n.country, '');
      expect(n.birthYearHijri, 0);
      expect(n.teachersIds, isEmpty);
      expect(n.studentsIds, isEmpty);
      expect(n.sayings, isEmpty);
      expect(n.hasBiographyData, isTrue);
    });

    test('rows carrying the new Phase-5 columns parse them', () {
      final n = Narrator.fromRow(<String, Object?>{
        'id': 2,
        'name': 'شعبة بن الحجاج',
        'kunya': 'أبو بسطام',
        'tier': 'الطبقة السابعة',
        'death_hijri': 160,
        'status': 'ثقة ثبت',
        'status_src': 'تقريب التهذيب',
        'bio_src': 'تهذيب التهذيب',
        'laqab': 'الحافظ',
        'lineage': 'العتكي',
        'country': 'البصرة',
        'birth_hijri': 82,
        'teachers_ids': <int>[3, 4],
        'students_ids': <int>[5],
      });
      expect(n.laqab, 'الحافظ');
      expect(n.lineage, 'العتكي');
      expect(n.country, 'البصرة');
      expect(n.birthYearHijri, 82);
      expect(n.teachersIds, <int>[3, 4]);
      expect(n.studentsIds, <int>[5]);
      expect(n.statusRank, 1);
      expect(n.hasBirth, isTrue);
      expect(n.hasDeath, isTrue);
    });

    test('a bare name with nothing recorded reports no biography data', () {
      final n = Narrator.fromRow(<String, Object?>{
        'id': 3,
        'name': 'راوٍ مجهول الاسم',
        'kunya': '',
        'tier': '',
        'death_hijri': 0,
        'status': '',
        'status_src': '',
        'bio_src': '',
      });
      expect(n.hasBiographyData, isFalse);
      expect(n.displayName, 'راوٍ مجهول الاسم');
      expect(n.hasStatus, isFalse);
    });

    test('NarratorSaying keeps scholar, text and source together', () {
      final s = NarratorSaying.fromRow(<String, Object?>{
        'scholar': 'ابن حجر',
        'saying': 'ثقة ثبت',
        'source': 'تقريب التهذيب',
      });
      expect(s.scholar, 'ابن حجر');
      expect(s.hasSource, isTrue);
      final noSource = NarratorSaying.fromRow(<String, Object?>{
        'scholar': 'الذهبي',
        'saying': 'ثقة',
        'source': '',
      });
      expect(noSource.hasSource, isFalse);
    });
  });

  group('ChainLink', () {
    test('a link with a narrator is confirmed; without one it is not', () {
      final narrator = Narrator.fromRow(<String, Object?>{
        'id': 1,
        'name': 'الزهري',
        'kunya': '',
        'tier': '',
        'death_hijri': 0,
        'status': '',
        'status_src': '',
        'bio_src': '',
      });
      final confirmed = ChainLink.fromRow(
        <String, Object?>{
          'position': 1,
          'narrator_id': 1,
          'link_type': '',
          'source': '',
          'notes': '',
        },
        narrator: narrator,
      );
      expect(confirmed.isConfirmed, isTrue);
      expect(confirmed.displayName, 'الزهري');
      expect(confirmed.isCompanion, isFalse);

      final open = ChainLink.fromRow(<String, Object?>{
        'position': 0,
        'narrator_id': null,
        'link_type': 'صحابي',
        'source': '',
        'notes': '',
      });
      expect(open.isConfirmed, isFalse);
      expect(open.isCompanion, isTrue);
      expect(open.displayName, 'راوٍ غير محدد في المصدر');
    });
  });
}
