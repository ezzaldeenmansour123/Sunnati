/// Design-smoothness regression tests (review
/// SUNNATI_DESIGN_SMOOTHNESS_REVIEW_2026-11-26, fixes 2/3/4).
///
/// NO timing / fps assertions — fps cannot be measured in a widget
/// test. Instead each fix is pinned by a structural fact:
///
/// (a) fix 2 — tab switches in the reader must NOT rebuild the isnad
///     spans: the [RichText] under [InteractiveIsnadText] keeps the
///     IDENTICAL [TextSpan] object across tab switches, and a tap on
///     a red name still expands the inline line afterwards;
/// (b) fix 4 — only the SELECTED tab's content is built: the other
///     tabs' distinctive content is absent from the tree;
/// (c) fix 3 — the lists still render their rows and still work after
///     `scrollCacheExtent` was added (no `itemExtent` anywhere: every
///     row here is variable-height, see the comments at each list).
///     (The task names this `cacheExtent`; in the project's pinned
///     Flutter 3.50.1 that parameter is deprecated in favour of
///     `scrollCacheExtent`, which is what the code uses.)
///
/// Real async file IO (temp dir + synthetic DB install + user repo)
/// MUST run in [WidgetTester.runAsync]: testWidgets runs in a
/// fake-async zone where real IO futures never complete — without
/// this the test hangs forever (same diagnosis as
/// welcome_screen_test.dart, 2026-11-26).
///
/// Finders here use `skipOffstage: false`, and the reader tests run
/// on a 4000px-tall viewport (see [pumpReader]): the reader is one
/// long ListView whose sliver builds children lazily, so at the
/// default 800x600 size the tabs and tab content below the fold are
/// not in the element tree at all. What test (b) asserts is
/// built-vs-not-built, not visible-vs-hidden, so off-viewport
/// matching is exactly right.
library;

import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunnati/data/database.dart';
import 'package:sunnati/data/user_repository.dart';
import 'package:sunnati/models/hadith.dart';
import 'package:sunnati/ui/book_screen.dart';
import 'package:sunnati/ui/hadith_reader_screen.dart';
import 'package:sunnati/ui/narrator_detail_screen.dart';
import 'package:sunnati/ui/narrators_screen.dart';
import 'package:sunnati/ui/search_screen.dart';
import 'package:sunnati/ui/widgets/isnad_text.dart';

import 'synthetic_db.dart';

/// The isnad widget, including when it is below the fold.
Finder get isnadFinder =>
    find.byType(InteractiveIsnadText, skipOffstage: false);

/// The isnad [RichText] under test.
RichText isnadRichText(WidgetTester tester) {
  return tester.widget<RichText>(
    find.descendant(
      of: isnadFinder,
      matching: find.byType(RichText, skipOffstage: false),
    ),
  );
}

/// Plain text of the isnad paragraph (names + any inline line).
String isnadPlainText(WidgetTester tester) {
  return (isnadRichText(tester).text as TextSpan).toPlainText();
}

/// Tap the span covering [start, end) inside the isnad [RichText].
/// Two pumps: the tap rebuilds the spans in a post-frame callback
/// (the tap's own recognizer must not be disposed mid-gesture).
Future<void> tapIsnadRange(
  WidgetTester tester, {
  required int start,
  required int end,
}) async {
  await tester.pumpAndSettle();
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(
      of: isnadFinder,
      matching: find.byType(RichText, skipOffstage: false),
    ),
  );
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  expect(boxes, isNotEmpty, reason: 'no laid-out box for the span');
  // getBoxesForSelection returns boxes in the paragraph's LOCAL
  // coordinates — convert to global with the widget's top-left, or
  // the tap lands at the top of the screen instead of on the name
  // (the isnad sits deep inside the reader page).
  final topLeft = tester.getTopLeft(
    find.descendant(
      of: isnadFinder,
      matching: find.byType(RichText, skipOffstage: false),
    ),
  );
  await tester.tapAt(topLeft + boxes.first.toRect().center);
  await tester.pump();
  await tester.pump();
}

/// Scroll a reader tab pill into view and tap it.
Future<void> tapReaderTab(WidgetTester tester, String label) async {
  // No scrolling: the reader tests run on a tall viewport (see
  // [pumpReader]), so every pill is already in view and its element
  // stays mounted — scrolling would unmount the isnad above the fold
  // and defeat the identity check in the fix-2 test.
  final pill = find.text(label, skipOffstage: false);
  await tester.tap(pill);
  await tester.pumpAndSettle();
}

/// Open the synthetic DB (with the narrators package when asked) in
/// real async — see the file doc comment for why [runAsync] is
/// mandatory here. Returns the (supportDir, db) pair; the caller
/// registers the tearDown.
Future<(Directory, SunnatiDatabase)> openTestDb(
  WidgetTester tester, {
  required String tag,
  bool withNarrators = false,
}) async {
  final supportDir = await tester.runAsync(
    () => Directory.systemTemp.createTemp('sunnati_smooth_$tag'),
  );
  final db = await tester.runAsync(
    () => openSyntheticDb(supportDir!, withNarrators: withNarrators),
  );
  addTearDown(() async {
    await tester.runAsync(() async {
      db!.close();
      await supportDir!.delete(recursive: true);
    });
  });
  return (supportDir!, db!);
}

Future<UserRepository> freshUserRepo(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    return UserRepository.load();
  }))!;
}

Future<void> pumpReader(
  WidgetTester tester,
  SunnatiDatabase db,
  UserRepository userRepo,
) async {
  // Tall viewport: the reader is one long ListView and its sliver
  // builds children lazily — at the default 800x600 size the tabs and
  // tab content below the fold are NOT in the element tree at all
  // (they are built only when scrolled into view), and scrolling far
  // enough would unmount the isnad above the fold. A 4000px-tall
  // surface keeps the whole page — matn, isnad, tabs, tab content —
  // built and mounted, so tab switches exercise exactly the rebuild
  // behaviour under test (and the fix-2 identity check is meaningful).
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
}

void main() {
  group('fix 2 — isnad spans are cached across reader rebuilds', () {
    testWidgets('switching tabs does not rebuild the isnad TextSpan; '
        'a tap afterwards still shows the inline line', (tester) async {
      final (_, db) = await openTestDb(
        tester,
        tag: 'a',
        withNarrators: true,
      );
      final userRepo = await freshUserRepo(tester);
      await pumpReader(tester, db, userRepo);

      final before = isnadRichText(tester).text;
      final plainBefore = isnadPlainText(tester);
      expect(plainBefore, contains('سفيان'));

      // Every tab switch rebuilds the whole reader page (setState).
      // Before the fix the reader handed this widget a fresh
      // `chainLinks` list object on each build, so didUpdateWidget
      // re-parsed and rebuilt the spans every time.
      for (final tab in <String>['تخريج', 'الحكم', 'رواة', 'شرح']) {
        await tapReaderTab(tester, tab);
        expect(
          identical(isnadRichText(tester).text, before),
          isTrue,
          reason: 'tab "$tab" rebuilt the isnad TextSpan',
        );
        expect(isnadPlainText(tester), plainBefore);
      }

      // The isnad is still alive: a tap on the verified red name
      // expands the inline status line in place (recognisers were
      // not broken by the caching).
      await tapIsnadRange(
        tester,
        start: kSyntheticVerifiedStart,
        end: kSyntheticVerifiedEnd,
      );
      expect(
        isnadPlainText(tester),
        contains('ثقة — مصدر الحكم: تقريب التهذيب'),
      );
      expect(find.byType(NarratorDetailScreen), findsNothing);
    });
  });

  group('fix 4 — only the selected tab is built (lazy tabs)', () {
    testWidgets('unselected tabs contribute nothing to the tree',
        (tester) async {
      final (_, db) = await openTestDb(
        tester,
        tag: 'b',
        withNarrators: true,
      );
      final userRepo = await freshUserRepo(tester);
      await pumpReader(tester, db, userRepo);

      // Default tab is شرح: the تخريج empty state and its button are
      // not built, and the matn/isnad stay in the tree.
      expect(isnadFinder, findsOneWidget);
      expect(
        find.text(
          'لا توجد مصادر تخريج مسجّلة لهذا الحديث بعد',
          skipOffstage: false,
        ),
        findsNothing,
      );
      expect(
        find.text('فتح مختبر التخريج', skipOffstage: false),
        findsNothing,
      );
      expect(
        find.text(
          'لا يوجد شرح مرتبط بهذا الحديث بعد',
          skipOffstage: false,
        ),
        findsOneWidget,
      );

      // Switch to الحكم: the شرح content disappears, the الحكم
      // content appears — only one tab at a time.
      await tapReaderTab(tester, 'الحكم');
      expect(
        find.text(
          'لم يرد حكم مسجّل لهذا الحديث في المصدر.',
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'لا يوجد شرح مرتبط بهذا الحديث بعد',
          skipOffstage: false,
        ),
        findsNothing,
      );
      expect(isnadFinder, findsOneWidget);

      // Switch to رواة: the verified narrator row is built now.
      await tapReaderTab(tester, 'رواة');
      expect(
        find.text('سفيان بن عيينة', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text(
          'لم يرد حكم مسجّل لهذا الحديث في المصدر.',
          skipOffstage: false,
        ),
        findsNothing,
      );

      // Switch to تعليقات: only the comments content is present.
      await tapReaderTab(tester, 'تعليقات');
      expect(
        find.text(
          'لا توجد تعليقات لهذا الحديث بعد — أضف تعليقك الخاص.',
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.text('سفيان بن عيينة', skipOffstage: false),
        findsNothing,
      );
    });
  });

  group('fix 3 — lists still render and work with cacheExtent', () {
    testWidgets('BookScreen chapters list renders and opens the reader',
        (tester) async {
      final (_, db) = await openTestDb(tester, tag: 'c1');
      final userRepo = await freshUserRepo(tester);
      final book = db.books().firstWhere((b) => b.id == 'bukhari');
      await tester.pumpWidget(
        MaterialApp(
          home: BookScreen(db: db, userRepo: userRepo, book: book),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Revelation'), findsOneWidget);
      expect(find.text('الإيمان'), findsOneWidget);
      expect(find.text('1 حديثاً'), findsOneWidget);
      expect(find.text('غير مترجم'), findsOneWidget);
      await tester.tap(find.text('Revelation'));
      await tester.pumpAndSettle();
      expect(find.byType(HadithReaderScreen), findsOneWidget);
    });

    testWidgets('NarratorsScreen list renders, filters and opens the '
        'full page', (tester) async {
      final (_, db) = await openTestDb(
        tester,
        tag: 'c2',
        withNarrators: true,
      );
      await tester.pumpWidget(
        MaterialApp(home: NarratorsScreen(db: db)),
      );
      await tester.pumpAndSettle();
      expect(find.text('سفيان بن عيينة'), findsOneWidget);
      // The list still works: searching filters it.
      await tester.enterText(find.byType(TextField).first, 'zzz');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.text('سفيان بن عيينة'), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'سفيان');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.text('سفيان بن عيينة'), findsOneWidget);
      // Tapping a row opens the full narrator page.
      await tester.tap(find.text('سفيان بن عيينة'));
      await tester.pumpAndSettle();
      expect(find.byType(NarratorDetailScreen), findsOneWidget);
    });

    testWidgets('SearchScreen chapter-tab list renders and finds rows',
        (tester) async {
      final (_, db) = await openTestDb(tester, tag: 'c3');
      await tester.pumpWidget(
        MaterialApp(home: SearchScreen(db: db)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('الأبواب'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Rev');
      // Plain pump, NOT pumpAndSettle: the focused field's blinking
      // cursor schedules frames forever.
      await tester.pump();
      expect(find.text('Revelation'), findsOneWidget);
      expect(find.text('غير مترجم'), findsOneWidget);
      expect(find.text('الإيمان'), findsNothing);
    });
  });
}
