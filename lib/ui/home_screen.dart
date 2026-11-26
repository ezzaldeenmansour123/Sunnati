import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import 'assistant_screen.dart';
import 'downloads_screen.dart';
import 'favorites_screen.dart';
import 'hadith_reader_screen.dart';
import 'library_screen.dart';
import 'narrators_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'takhrij_screen.dart';
import 'widgets/empty_library.dart';

/// Home screen — the app's front door (master prompt §13).
///
/// Shows the logo/title, search entry, assistant entry, continue-reading
/// (only when history exists), quick access, and the installed-library
/// status. Actions that need library data are HIDDEN while the library is
/// unavailable — never shown as dead buttons. Settings and Downloads are
/// always reachable (they work without hadith data).
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.db,
    required this.userRepo,
    required this.onThemeModeChanged,
    required this.onFontScaleChanged,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final ValueChanged<String> onThemeModeChanged;
  final ValueChanged<double> onFontScaleChanged;

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final history = userRepo.data.history;
    return Scaffold(
      appBar: AppBar(
        title: const Text('سُنَّتي'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'الإعدادات',
            onPressed: () => _push(
              context,
              SettingsScreen(
                db: db,
                userRepo: userRepo,
                onThemeModeChanged: onThemeModeChanged,
                onFontScaleChanged: onFontScaleChanged,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Brand header: open-book + dome mark is the launcher icon; here
          // the wordmark + tagline carry the identity in petrol + matte gold.
          const Card(
            color: SunnatiColors.petrol,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Column(
                children: [
                  Icon(Icons.menu_book, size: 44, color: Colors.white),
                  SizedBox(height: 8),
                  Text(
                    'سُنَّتي',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    'SUNNATI',
                    style: TextStyle(
                      fontSize: 13,
                      letterSpacing: 4,
                      color: SunnatiColors.goldSoft,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'السنة النبوية بين يديك، بفهم موثّق وذكاء متقدم',
                    style: TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (!db.isAvailable)
            EmptyLibraryCard(
              title: 'المكتبة تُبنى',
              detail: db.unavailableReason.isNotEmpty
                  ? db.unavailableReason
                  : 'الكتب التسعة قيد الاستيراد — لا توجد أحاديث بعد.',
              icon: Icons.hourglass_empty,
            )
          else
            Card(
              child: ListTile(
                leading: const Icon(Icons.check_circle, color: SunnatiColors.petrol),
                title: Text('المكتبة مثبّتة — ${db.totalHadiths()} حديثاً'),
                subtitle: const Text('تعمل دون إنترنت'),
              ),
            ),
          const SizedBox(height: 8),
          // Quick access — only the actions that can actually run now.
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              if (db.isAvailable)
                _QuickTile(
                  icon: Icons.search,
                  label: 'البحث',
                  onTap: () => _push(context, SearchScreen(db: db)),
                ),
              if (db.isAvailable)
                _QuickTile(
                  icon: Icons.smart_toy_outlined,
                  label: 'المساعد',
                  onTap: () => _push(context, AssistantScreen(db: db)),
                ),
              _QuickTile(
                icon: Icons.library_books_outlined,
                label: 'المكتبة',
                onTap: () => _push(context, LibraryScreen(db: db, userRepo: userRepo)),
              ),
              _QuickTile(
                icon: Icons.download_outlined,
                label: 'التنزيلات',
                onTap: () => _push(context, DownloadsScreen(db: db)),
              ),
              _QuickTile(
                icon: Icons.favorite_outline,
                label: 'المفضلة',
                onTap: () => _push(
                  context,
                  FavoritesScreen(db: db, userRepo: userRepo),
                ),
              ),
              if (db.isAvailable)
                _QuickTile(
                  icon: Icons.people_outline,
                  label: 'الرواة',
                  onTap: () => _push(context, NarratorsScreen(db: db)),
                ),
              if (db.isAvailable)
                _QuickTile(
                  icon: Icons.account_tree_outlined,
                  label: 'التخريج',
                  onTap: () => _push(context, TakhrijScreen(db: db)),
                ),
            ],
          ),
          if (history.isNotEmpty && db.isAvailable) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.history, color: SunnatiColors.gold),
                title: const Text('متابعة القراءة'),
                subtitle: Text('آخر حديث قرأته: ${history.first}'),
                trailing: const Icon(Icons.chevron_left),
                onTap: () {
                  final parts = history.first.split(':');
                  if (parts.length == 2) {
                    final num = int.tryParse(parts[1]);
                    final hadith = num == null
                        ? null
                        : db.hadithByNumber(parts[0], num);
                    if (hadith != null && context.mounted) {
                      _push(
                        context,
                        HadithReaderScreen(
                          db: db,
                          userRepo: userRepo,
                          hadith: hadith,
                        ),
                      );
                    }
                  }
                },
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'يعمل دون إنترنت بعد تثبيت المكتبة. المساعد يسترجع من المكتبة فقط ولا يولّد إجابات.',
            style: TextStyle(color: colors.onSurface.withValues(alpha: 0.6), fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 28, color: SunnatiColors.petrol),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
