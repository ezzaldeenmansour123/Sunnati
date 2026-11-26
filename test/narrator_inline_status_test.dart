/// In-hadith narrator tap tests (user decisions 2026-11-26 15:03 +
/// 17:23 — the 17:23 correction SUPERSEDES the 16:49 small-card design
/// and the build-81 petrol/bold/gold-underline rule).
///
/// ALL narrator names inside a hadith are in ONE distinctive RED and
/// tappable. A tap shows the narrator's status (with its source) as an
/// INLINE LINE embedded in the hadith text itself, right under the
/// name — NOT a popup card/sheet and NOT a full details page. The full
/// narrator page stays reachable ONLY from the narrators encyclopedia.
/// Pure tests cover the line data; widget tests cover the tap itself
/// (isnad text, isnad tree, reader list) and the encyclopedia path.
library;

import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunnati/core/narrator_logic.dart';
import 'package:sunnati/core/theme.dart';
import 'package:sunnati/data/database.dart';
import 'package:sunnati/data/user_repository.dart';
import 'package:sunnati/models/chain.dart';
import 'package:sunnati/models/hadith.dart';
import 'package:sunnati/ui/hadith_reader_screen.dart';
import 'package:sunnati/ui/narrator_detail_screen.dart';
import 'package:sunnati/ui/narrators_screen.dart';
import 'package:sunnati/ui/widgets/isnad_text.dart';
import 'package:sunnati/ui/widgets/isnad_tree.dart';

import 'synthetic_db.dart';

/// Tap the span covering [start, end) inside the isnad [RichText].
/// Two pumps: the tap rebuilds the spans in a post-frame callback
/// (the tap's own recognizer must not be disposed mid-gesture), so a
/// second frame is needed before the inline line is visible.
Future<void> tapIsnadRange(
  WidgetTester tester, {
  required int start,
  required int end,
}) async {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(
      of: find.byType(InteractiveIsnadText),
      matching: find.byType(RichText),
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
      of: find.byType(InteractiveIsnadText),
      matching: find.byType(RichText),
    ),
  );
  await tester.tapAt(topLeft + boxes.first.toRect().center);
  await tester.pump();
  await tester.pump();
}

/// The isnad [RichText] under test.
RichText isnadRichText(WidgetTester tester) {
  return tester.widget<RichText>(
    find.descendant(
      of: find.byType(InteractiveIsnadText),
      matching: find.byType(RichText),
    ),
  );
}

/// Plain text of the isnad paragraph (names + any inline line).
String isnadPlainText(WidgetTester tester) {
  return (isnadRichText(tester).text as TextSpan).toPlainText();
}

/// Find the leaf span whose text is exactly [text], or null.
TextSpan? findSpanByText(TextSpan root, String text) {
  if (root.text == text) return root;
  final children = root.children;
  if (children != null) {
    for (final child in children) {
      if (child is TextSpan) {
        final found = findSpanByText(child, text);
        if (found != null) return found;
      }
    }
  }
  return null;
}

void main() {
  group(
      'inlineStatusForTap + inlineStatusLineText — the inline line '
      'data (pure)', () {
    test('showStatus carries status + source, no message', () {
      final card = inlineStatusForTap(
        name: 'سفيان',
        outcome: NarratorTapOutcome.showStatus,
        status: 'ثقة',
        statusSource: 'تقريب التهذيب',
      );
      expect(card.name, 'سفيان');
      expect(card.hasStatus, isTrue);
      expect(card.status, 'ثقة');
      expect(card.statusSource, 'تقريب التهذيب');
      expect(card.message, isEmpty);
      expect(
        inlineStatusLineText(card),
        'ثقة — مصدر الحكم: تقريب التهذيب',
      );
    });

    test('showStatus without a source shows the bare status', () {
      final card = inlineStatusForTap(
        name: 'سفيان',
        outcome: NarratorTapOutcome.showStatus,
        status: 'ثقة',
      );
      expect(inlineStatusLineText(card), 'ثقة');
    });

    test('showStatus with no recorded status says so honestly', () {
      final card = inlineStatusForTap(
        name: 'سفيان',
        outcome: NarratorTapOutcome.showStatus,
      );
      expect(card.hasStatus, isFalse);
      expect(card.message, kNoRecordedStatusMessage);
      expect(inlineStatusLineText(card), kNoRecordedStatusMessage);
    });

    test('pendingApproval shows the pending message, no status', () {
      final card = inlineStatusForTap(
        name: 'سفيان',
        outcome: NarratorTapOutcome.pendingApproval,
      );
      expect(card.hasStatus, isFalse);
      expect(card.message, kNarratorsPendingApprovalMessage);
      expect(inlineStatusLineText(card), kNarratorsPendingApprovalMessage);
    });

    test('noVerifiedBiography shows the honest message, no status', () {
      final card = inlineStatusForTap(
        name: 'يحيى بن سعيد الأنصاري',
        outcome: NarratorTapOutcome.noVerifiedBiography,
      );
      expect(card.hasStatus, isFalse);
      expect(card.message, kNoVerifiedBiographyMessage);
      expect(inlineStatusLineText(card), kNoVerifiedBiographyMessage);
    });
  });

  group(
      'InteractiveIsnadText tap — red name, inline line in place, '
      'no navigation', () {
    late Directory supportDir;

    setUp(() {
      supportDir = Directory.systemTemp.createTempSync('sunnati_tap_');
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    tearDown(() {
      if (supportDir.existsSync()) {
        supportDir.deleteSync(recursive: true);
      }
    });

    Future<void> pumpIsnad(
      WidgetTester tester,
      SunnatiDatabase db, {
      required String text,
      required List<ChainLink> links,
      required bool narratorsAvailable,
    }) async {
      final narrators = db.narratorsForHadith(1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InteractiveIsnadText(
              db: db,
              text: text,
              confirmedNarrators: narrators,
              chainLinks: links,
              narratorsAvailable: narratorsAvailable,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
        'verified name is RED and its tap expands the inline '
        'status line in place', (tester) async {
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir, withNarrators: true),
      ))!;
      addTearDown(db.close);
      expect(db.narratorsAvailable, isTrue);
      final narrator = db.narratorById(1)!;
      await pumpIsnad(
        tester,
        db,
        text: 'سفيان',
        links: <ChainLink>[
          ChainLink(
            position: 0,
            narratorId: 1,
            narrator: narrator,
            linkType: '',
            source: '',
            notes: '',
            narratorText: 'سفيان',
            startChar: 0,
            endChar: 5,
            matchStatus: 'linked_verified',
          ),
        ],
        narratorsAvailable: true,
      );
      // One distinctive RED colour for the name, bold, no underline.
      final nameSpan = findSpanByText(
        isnadRichText(tester).text as TextSpan,
        'سفيان',
      );
      expect(nameSpan, isNotNull);
      expect(nameSpan!.style?.color, SunnatiColors.narratorRed);
      expect(nameSpan.style?.fontWeight, FontWeight.bold);
      expect(nameSpan.style?.decoration, isNull);
      expect(isnadPlainText(tester), isNot(contains('ثقة')));
      await tapIsnadRange(tester, start: 0, end: 5);
      // The status + source line is now part of the hadith text
      // itself, right under the name — no card, no sheet, no page.
      expect(
        isnadPlainText(tester),
        contains('ثقة — مصدر الحكم: تقريب التهذيب'),
      );
      // No navigation: the route is still current, no full page.
      final route = ModalRoute.of(
        tester.element(find.byType(InteractiveIsnadText)),
      );
      expect(route?.isCurrent, isTrue);
      expect(find.byType(NarratorDetailScreen), findsNothing);
      // Tapping the same name again hides the line.
      await tapIsnadRange(tester, start: 0, end: 5);
      expect(isnadPlainText(tester), isNot(contains('ثقة')));
    });

    testWidgets(
        'verified tap with the package held back shows the '
        'pending message as an inline line, no status', (tester) async {
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir),
      ))!;
      addTearDown(db.close);
      expect(db.narratorsAvailable, isFalse);
      await pumpIsnad(
        tester,
        db,
        text: 'سفيان',
        links: <ChainLink>[
          const ChainLink(
            position: 0,
            narratorId: 1,
            narrator: null,
            linkType: '',
            source: '',
            notes: '',
            narratorText: 'سفيان',
            startChar: 0,
            endChar: 5,
            matchStatus: 'linked_verified',
          ),
        ],
        narratorsAvailable: false,
      );
      await tapIsnadRange(tester, start: 0, end: 5);
      expect(
          isnadPlainText(tester), contains(kNarratorsPendingApprovalMessage));
      expect(isnadPlainText(tester), isNot(contains('ثقة')));
    });

    testWidgets(
        'unverified tap shows the honest message as an inline '
        'line, no status', (tester) async {
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir),
      ))!;
      addTearDown(db.close);
      const name = 'يحيى بن سعيد الأنصاري';
      await pumpIsnad(
        tester,
        db,
        text: name,
        links: <ChainLink>[
          const ChainLink(
            position: 1,
            narratorId: null,
            narrator: null,
            linkType: '',
            source: '',
            notes: '',
            narratorText: name,
            startChar: 0,
            endChar: 21,
            matchStatus: 'unlinked',
          ),
        ],
        narratorsAvailable: false,
      );
      // The unverified name is red and tappable too.
      final nameSpan = findSpanByText(
        isnadRichText(tester).text as TextSpan,
        name,
      );
      expect(nameSpan, isNotNull);
      expect(nameSpan!.style?.color, SunnatiColors.narratorRed);
      await tapIsnadRange(tester, start: 0, end: 21);
      expect(isnadPlainText(tester), contains(kNoVerifiedBiographyMessage));
      expect(isnadPlainText(tester), isNot(contains('ثقة')));
    });
  });

  group('IsnadTree tap — inline line inside the node', () {
    testWidgets(
        'tapping a verified node shows its status line inside '
        'the node', (tester) async {
      final supportDir = Directory.systemTemp.createTempSync('sunnati_tree_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir, withNarrators: true),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      final links = db.chainForHadith(1);
      expect(links.length, 2);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: IsnadTree(db: db, links: links)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('ثقة — مصدر الحكم: تقريب التهذيب'),
        findsNothing,
      );
      await tester.tap(find.text('سفيان بن عيينة'));
      await tester.pump();
      expect(
        find.text('ثقة — مصدر الحكم: تقريب التهذيب'),
        findsOneWidget,
      );
      expect(find.byType(NarratorDetailScreen), findsNothing);
    });
  });

  group('HadithReaderScreen — in-text tap + narrators tab, no navigation', () {
    Future<HadithReaderScreen> pumpReader(
      WidgetTester tester,
      SunnatiDatabase db,
      UserRepository userRepo,
    ) async {
      final screen = HadithReaderScreen(
        db: db,
        userRepo: userRepo,
        hadith: syntheticHadith,
        chapterHadiths: <Hadith>[syntheticHadith],
      );
      // Tall viewport (same reason as design_smoothness_test): the
      // reader is one long lazily-built ListView — at 800x600 the
      // isnad and the tab pills below the fold are NOT in the tree.
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: screen));
      await tester.pumpAndSettle();
      return screen;
    }

    testWidgets(
        'tapping a red name in the isnad expands the inline '
        'line in the reader', (tester) async {
      final supportDir = Directory.systemTemp.createTempSync('sunnati_reader_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir, withNarrators: true),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final userRepo = (await tester.runAsync(() => UserRepository.load()))!;
      await pumpReader(tester, db, userRepo);
      await tester.ensureVisible(find.byType(InteractiveIsnadText));
      await tester.pumpAndSettle();
      expect(isnadPlainText(tester), isNot(contains('ثقة')));
      await tapIsnadRange(
        tester,
        start: kSyntheticVerifiedStart,
        end: kSyntheticVerifiedEnd,
      );
      expect(
        isnadPlainText(tester),
        contains('ثقة — مصدر الحكم: تقريب التهذيب'),
      );
      final route = ModalRoute.of(
        tester.element(find.byType(HadithReaderScreen)),
      );
      expect(route?.isCurrent, isTrue);
      expect(find.byType(NarratorDetailScreen), findsNothing);
    });

    testWidgets(
        'tapping a narrator in the رواة tab shows the inline '
        'line under the row', (tester) async {
      final supportDir =
          Directory.systemTemp.createTempSync('sunnati_reader2_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir, withNarrators: true),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final userRepo = (await tester.runAsync(() => UserRepository.load()))!;
      await pumpReader(tester, db, userRepo);
      await tester.tap(find.text('رواة'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('سفيان بن عيينة'));
      await tester.pumpAndSettle();
      expect(
        find.text('ثقة — مصدر الحكم: تقريب التهذيب'),
        findsNothing,
      );
      await tester.tap(find.text('سفيان بن عيينة'));
      await tester.pump();
      expect(
        find.text('ثقة — مصدر الحكم: تقريب التهذيب'),
        findsOneWidget,
      );
      expect(find.byType(NarratorDetailScreen), findsNothing);
    });
  });

  group('HadithReaderScreen tabs — جامع الكتب التسعة set', () {
    testWidgets(
        'tabs are تخريج / الحكم / رواة / شرح / تعليقات; '
        'الغريب and ملاحظات are gone', (tester) async {
      final supportDir = Directory.systemTemp.createTempSync('sunnati_tabs_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir, withNarrators: true),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final userRepo = (await tester.runAsync(() => UserRepository.load()))!;
      // Tall viewport: the tab pills live below the fold of the
      // reader's lazy ListView at 800x600 (see pumpReader above).
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
      for (final label in <String>[
        'تخريج',
        'الحكم',
        'رواة',
        'شرح',
        'تعليقات',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('الغريب'), findsNothing);
      expect(find.text('ملاحظات'), findsNothing);
      // تخريج: 0 rows — honest empty state, never invented content.
      await tester.tap(find.text('تخريج'));
      await tester.pumpAndSettle();
      expect(
        find.text('لا توجد مصادر تخريج مسجّلة لهذا الحديث بعد'),
        findsOneWidget,
      );
      // الحكم: Bukhari carries no per-hadith grade in the source.
      await tester.tap(find.text('الحكم'));
      await tester.pumpAndSettle();
      expect(
        find.text('لم يرد حكم مسجّل لهذا الحديث في المصدر.'),
        findsOneWidget,
      );
      // تعليقات: the user's own note lives here now.
      await tester.tap(find.text('تعليقات'));
      await tester.pumpAndSettle();
      expect(
        find.text('لا توجد تعليقات لهذا الحديث بعد — أضف تعليقك الخاص.'),
        findsOneWidget,
      );
      expect(find.text('إضافة تعليق'), findsOneWidget);
    });
  });

  group('Narrators encyclopedia — the full page lives here only', () {
    testWidgets(
        'tapping a narrator in the encyclopedia opens the full '
        'page', (tester) async {
      final supportDir = Directory.systemTemp.createTempSync('sunnati_encyc_');
      final db = (await tester.runAsync(
        () => openSyntheticDb(supportDir, withNarrators: true),
      ))!;
      addTearDown(() async {
        db.close();
        supportDir.deleteSync(recursive: true);
      });
      // Tall viewport: the detail page is scrollable; the status
      // field row must be mounted for the text finder to see it.
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: NarratorsScreen(db: db)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('سفيان بن عيينة'));
      await tester.pumpAndSettle();
      expect(find.byType(NarratorDetailScreen), findsOneWidget);
      // The full page shows status + source in one field row
      // ('ثقة (تقريب التهذيب)'), not a bare 'ثقة' widget.
      expect(find.text('ثقة (تقريب التهذيب)'), findsOneWidget);
    });
  });
}
