/// First-run welcome screen (user order 2026-11-26 ~17:51).
///
/// Shown ONCE, on the first launch only: the app icon, the «سُنَّتي»
/// wordmark, one short welcome line, and the «ابدأ تصفح سُنَّتي»
/// button. This is NOT a login or an account screen — SUNNATI has no
/// accounts by design. Navigation lives entirely in the caller: the
/// button only invokes [onStart] (the shell in `lib/main.dart` marks
/// the welcome as seen and shows the home screen). No navigation
/// logic lives here, so the screen is testable on its own.
///
/// Identity: warm ivory background, deep petrol headings, one matte
/// gold divider — simple and elegant, no exaggerated ornamentation.
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.onStart});

  /// Called when the user taps «ابدأ تصفح سُنَّتي». The caller
  /// (main.dart) persists `welcomeSeen` and navigates to the home
  /// screen (جامع الكتب التسعة).
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SunnatiColors.ivory,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Image.asset('assets/app_icon.png', width: 160, height: 160),
              const SizedBox(height: 24),
              const Text(
                'سُنَّتي',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                  color: SunnatiColors.petrol,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'موسوعة السنة النبوية',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  color: SunnatiColors.inkMuted,
                ),
              ),
              const SizedBox(height: 24),
              Container(height: 1, color: SunnatiColors.gold),
              const SizedBox(height: 24),
              const Text(
                'الكتب التسعة بين يديك — اقرأ وابحث واسأل المساعد، دون إنترنت.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.8,
                  color: SunnatiColors.ink,
                ),
              ),
              const SizedBox(height: 40),
              FilledButton(
                onPressed: onStart,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'ابدأ تصفح سُنَّتي',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
