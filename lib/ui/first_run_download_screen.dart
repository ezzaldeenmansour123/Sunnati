import 'package:material_ui/material_ui.dart';

import 'library_download_card.dart';

/// Recovery first-run download screen (embed 2026-11-26, owner decision
/// 16:54).
///
/// The library is EMBEDDED in the APK and normally installs from the
/// asset on first run with no download at all — this screen is only a
/// recovery path, shown by `lib/main.dart` when the embedded install
/// failed (asset missing or corrupt: the libraryNeedsDownload flag).
/// The user cannot proceed into the app — and cannot dismiss the
/// screen — until the core library is downloaded and verified: the
/// library IS the app's content, and showing the home screen with an
/// empty library would be a dead shell.
/// [onInstalled] re-runs boot (re-open the database, then home).
class FirstRunDownloadScreen extends StatelessWidget {
  const FirstRunDownloadScreen({super.key, required this.onInstalled});

  final VoidCallback onInstalled;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(title: const Text('سُنَّتي')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'أهلاً بك في سُنَّتي',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'تعذّر تثبيت المكتبة الأساسية (الكتب التسعة) من النسخة '
              'المضمّنة في التطبيق. نزّلها مرة واحدة من هنا لتتصفح '
              'الأحاديث دون إنترنت. التنزيل قابل للإيقاف والاستكمال، '
              'وتُتحقق سلامته قبل التثبيت.',
            ),
            const SizedBox(height: 16),
            LibraryDownloadCard(onInstalled: onInstalled),
          ],
        ),
      ),
    );
  }
}
