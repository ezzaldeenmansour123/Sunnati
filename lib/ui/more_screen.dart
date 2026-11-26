/// «المزيد» tab — the overflow menu for the sections the mockup's
/// 4-card home does not link directly: favorites, downloads, the
/// assistant, the takhrij lab, and settings. Every entry pushes a real
/// screen; nothing here is a dead button.
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import 'assistant_screen.dart';
import 'downloads_screen.dart';
import 'favorites_screen.dart';
import 'settings_screen.dart';
import 'takhrij_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({
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
    return Scaffold(
      appBar: AppBar(title: const Text('المزيد')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _Entry(
            icon: Icons.favorite_outline,
            title: 'المفضلة',
            subtitle: 'أحاديثك المحفوظة وملاحظاتك عليها',
            onTap: () => _push(
              context,
              FavoritesScreen(db: db, userRepo: userRepo),
            ),
          ),
          _Entry(
            icon: Icons.download_outlined,
            title: 'التنزيلات',
            subtitle: 'مكتبات التطبيق وحالة التنزيل',
            onTap: () => _push(context, DownloadsScreen(db: db)),
          ),
          _Entry(
            icon: Icons.smart_toy_outlined,
            title: 'المساعد الذكي',
            subtitle: 'اسأل سُنَّتي — يسترجع من المكتبة فقط',
            onTap: () => _push(context, AssistantScreen(db: db)),
          ),
          _Entry(
            icon: Icons.science_outlined,
            title: 'مختبر التخريج',
            subtitle: 'تخريج الأحاديث وطرقها',
            onTap: () => _push(context, TakhrijScreen(db: db)),
          ),
          _Entry(
            icon: Icons.settings_outlined,
            title: 'الإعدادات',
            subtitle: 'المظهر والخط والتخزين والمصادر',
            onTap: () => _push(
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
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: SunnatiColors.petrol),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_left),
        onTap: onTap,
      ),
    );
  }
}
