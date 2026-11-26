/// Welcome screen + first-run flag + home assistant-entry tests
/// (user order 2026-11-26 ~17:51):
///  - WelcomeScreen shows the name and the start button; tapping the
///    button invokes the onStart callback (navigation lives in main.dart).
///  - The `welcomeSeen` flag defaults to false and persists true once
///    set (SharedPreferences mock).
///  - HomeScreen shows a prominent «المساعد الذكي سُنَّتي» entry and
///    tapping it opens AssistantScreen.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunnati/core/theme.dart';
import 'package:sunnati/data/user_repository.dart';
import 'package:sunnati/ui/assistant_screen.dart';
import 'package:sunnati/ui/home_screen.dart';
import 'package:sunnati/ui/welcome_screen.dart';

import 'synthetic_db.dart';

void main() {
  group('WelcomeScreen', () {
    testWidgets('shows the name and the start button; tapping calls '
        'onStart', (tester) async {
      var started = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: SunnatiTheme.light(),
          home: WelcomeScreen(onStart: () => started = true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('سُنَّتي'), findsOneWidget);
      expect(find.text('ابدأ تصفح سُنَّتي'), findsOneWidget);
      await tester.tap(find.text('ابدأ تصفح سُنَّتي'));
      await tester.pump();
      expect(started, isTrue);
    });
  });

  group('welcomeSeen flag', () {
    test('defaults to false and persists true once set', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final repo = await UserRepository.load();
      expect(repo.welcomeSeen, isFalse);
      await repo.setWelcomeSeen();
      expect(repo.welcomeSeen, isTrue);
      // A fresh load reads the persisted value back.
      final reloaded = await UserRepository.load();
      expect(reloaded.welcomeSeen, isTrue);
    });
  });

  group('HomeScreen — assistant entry', () {
    testWidgets('shows «المساعد الذكي سُنَّتي» prominently; tap opens '
        'the assistant', (tester) async {
      // Real async file IO (temp dir + synthetic DB install) must run
      // in runAsync: testWidgets runs in a fake-async zone where real
      // IO futures never complete — without this the test hangs
      // forever (diagnosed by bisection 2026-11-26: every DB-backed
      // widget test without runAsync hangs; with it, ~5s).
      final supportDir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('sunnati_welcome_'),
      );
      final db = await tester.runAsync(() => openSyntheticDb(supportDir!));
      addTearDown(() async {
        await tester.runAsync(() async {
          db!.close();
          await supportDir!.delete(recursive: true);
        });
      });
      final userRepo = await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        return UserRepository.load();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            db: db!,
            userRepo: userRepo!,
            onThemeModeChanged: (_) {},
            onFontScaleChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('المساعد الذكي سُنَّتي'), findsOneWidget);
      await tester.tap(find.text('المساعد الذكي سُنَّتي'));
      await tester.pumpAndSettle();
      expect(find.byType(AssistantScreen), findsOneWidget);
      expect(find.text('المساعد — استرجاع من المكتبة'), findsOneWidget);
    });
  });
}
