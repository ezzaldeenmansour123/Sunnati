/// جامع الكتب التسعة layout tests (user decision 2026-11-26 17:26 —
/// keep the petrol identity, adopt layout/structure/features only):
/// the Nine Books as a grid of cover cards, and the advanced search as
/// four tabs (الحديث / الرواة / الأبواب / الموضوع — NO المشكاة tab,
/// topics show an honest empty state). Private folders and the thematic
/// tree are FUTURE scope and are NOT tested here.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunnati/data/database.dart';
import 'package:sunnati/data/user_repository.dart';
import 'package:sunnati/ui/book_screen.dart';
import 'package:sunnati/ui/library_screen.dart';
import 'package:sunnati/ui/search_screen.dart';

import 'synthetic_db.dart';

void main() {
  group('LibraryScreen — Nine Books as cover cards', () {
    testWidgets('books show as a 2-column cover grid with real counts',
        (tester) async {
      final supportDir = Directory.systemTemp.createTempSync('sunnati_lib_');
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
        MaterialApp(home: LibraryScreen(db: db, userRepo: userRepo)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('صحيح البخاري'), findsOneWidget);
      expect(find.text('محمد بن إسماعيل البخاري'), findsOneWidget);
      // Real imported count (1 hadith in the fixture), not invented.
      expect(find.text('حديث واحد'), findsOneWidget);
      // Tapping a cover card opens the book.
      await tester.tap(find.text('صحيح البخاري'));
      await tester.pumpAndSettle();
      expect(find.byType(BookScreen), findsOneWidget);
    });
  });

  group('SearchScreen — four tabs, no المشكاة', () {
    Future<void> pumpSearch(
      WidgetTester tester,
      SunnatiDatabase db,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: SearchScreen(db: db)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('tab row is الحديث / الرواة / الأبواب / الموضوع',
        (tester) async {
      final supportDir = Directory.systemTemp.createTempSync('sunnati_search_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      await pumpSearch(tester, db);
      for (final label in <String>[
        'الحديث',
        'الرواة',
        'الأبواب',
        'الموضوع',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('المشكاة'), findsNothing);
      // Default tab: الحديث — the mockup advanced search.
      expect(find.text('خيارات البحث'), findsOneWidget);
    });

    testWidgets(
        'الرواة tab without the package shows the honest gate '
        'message; with it, a tap shows the inline line', (tester) async {
      final supportDir =
          Directory.systemTemp.createTempSync('sunnati_search2_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      await pumpSearch(tester, db);
      await tester.tap(find.text('الرواة'));
      await tester.pumpAndSettle();
      expect(find.text('البحث في الرواة غير متوفر بعد'), findsOneWidget);
      // (With the package installed the same tab lists the verified
      // narrators; that path is covered by the next test and by the
      // reader رواة tab test.)
    });

    testWidgets(
        'الرواة tab with the package lists narrators and shows '
        'the inline line on tap', (tester) async {
      final supportDir =
          Directory.systemTemp.createTempSync('sunnati_search3_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir, withNarrators: true),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      await pumpSearch(tester, db);
      await tester.tap(find.text('الرواة'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'سفيان',
      );
      // Plain pump, NOT pumpAndSettle: the focused field's blinking
      // cursor schedules frames forever, so pumpAndSettle would run
      // until its timeout. One pump rebuilds the filtered list.
      await tester.pump();
      expect(find.text('سفيان بن عيينة'), findsOneWidget);
      await tester.tap(find.text('سفيان بن عيينة'));
      await tester.pump();
      expect(
        find.text('ثقة — مصدر الحكم: تقريب التهذيب'),
        findsOneWidget,
      );
    });

    testWidgets(
        'الأبواب tab finds chapters and tags untranslated '
        'titles', (tester) async {
      final supportDir =
          Directory.systemTemp.createTempSync('sunnati_search4_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      await pumpSearch(tester, db);
      await tester.tap(find.text('الأبواب'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Rev');
      // Plain pump, NOT pumpAndSettle (focused field's blinking cursor
      // never settles — see the الرواة test above).
      await tester.pump();
      expect(find.text('Revelation'), findsOneWidget);
      expect(find.text('غير مترجم'), findsOneWidget);
      expect(find.text('الإيمان'), findsNothing);
    });

    testWidgets('الموضوع tab shows the honest empty state', (tester) async {
      final supportDir =
          Directory.systemTemp.createTempSync('sunnati_search5_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      await pumpSearch(tester, db);
      await tester.tap(find.text('الموضوع'));
      await tester.pumpAndSettle();
      expect(find.text('لا توجد مواضيع مستوردة بعد'), findsOneWidget);
    });
  });
}
