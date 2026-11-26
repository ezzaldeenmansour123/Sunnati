/// «غير مترجم» chapter-title tag tests (user follow-up 2026-11-26 16:51).
///
/// Until a verified Arabic باب title exists for a chapter, the
/// book/chapter UI shows the current title WITH a clear visible
/// «غير مترجم» tag — never presenting an English title as if it were
/// the Arabic باب, and never inventing an Arabic title. Pure tests
/// cover the detection; widget tests cover the book screen chapter
/// list and the hadith page header.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunnati/data/user_repository.dart';
import 'package:sunnati/models/book.dart';
import 'package:sunnati/models/hadith.dart';
import 'package:sunnati/ui/book_screen.dart';
import 'package:sunnati/ui/hadith_reader_screen.dart';

import 'synthetic_db.dart';

void main() {
  group('isUntranslatedChapterTitle (pure)', () {
    test('English verbatim titles are untranslated', () {
      expect(isUntranslatedChapterTitle('Revelation'), isTrue);
      expect(isUntranslatedChapterTitle('Belief'), isTrue);
      expect(isUntranslatedChapterTitle('Book 1: Revelation'), isTrue);
    });

    test('Arabic titles are not untranslated', () {
      expect(isUntranslatedChapterTitle('الإيمان'), isFalse);
      expect(isUntranslatedChapterTitle('باب بدء نزول الوحي'), isFalse);
      expect(isUntranslatedChapterTitle('غير مصنّف'), isFalse);
    });

    test('empty titles are not tagged', () {
      expect(isUntranslatedChapterTitle(''), isFalse);
    });

    test('a mixed title still carries Latin letters, so it is tagged', () {
      expect(isUntranslatedChapterTitle('Revelation (الوحي)'), isTrue);
    });
  });

  group('BookScreen chapter list — the tag', () {
    testWidgets(
        'English chapter shows «غير مترجم», Arabic chapter does '
        'not', (tester) async {
      final supportDir = Directory.systemTemp.createTempSync('sunnati_tag_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final userRepo = (await tester.runAsync(() => UserRepository.load()))!;
      final book = db.books().first;
      await tester.pumpWidget(
        MaterialApp(
          home: BookScreen(db: db, userRepo: userRepo, book: book),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Revelation'), findsOneWidget);
      expect(find.text('الإيمان'), findsOneWidget);
      // Exactly one tag: the English chapter only.
      expect(find.text('غير مترجم'), findsOneWidget);
    });
  });

  group('HadithReaderScreen header — the tag', () {
    testWidgets(
        'untranslated chapter title carries «غير مترجم» in the '
        'header', (tester) async {
      final supportDir =
          Directory.systemTemp.createTempSync('sunnati_tag_hdr_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final userRepo = (await tester.runAsync(() => UserRepository.load()))!;
      await tester.pumpWidget(
        MaterialApp(
          home: HadithReaderScreen(
            db: db,
            userRepo: userRepo,
            hadith: syntheticHadith,
            chapterHadiths: <Hadith>[syntheticHadith],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('صحيح البخاري — Revelation'),
        findsOneWidget,
      );
      expect(find.text('غير مترجم'), findsOneWidget);
    });
  });
}
