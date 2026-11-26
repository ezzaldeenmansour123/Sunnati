import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import 'hadith_reader_screen.dart';
import 'widgets/empty_library.dart';

/// Favourites, notes and tags (master prompt §13).
///
/// Works even before the library is complete: favourites are stored by
/// stable id, so the list is never lost. Entries whose text is not yet
/// installed are shown by id with an honest note instead of fake text.
/// Export/import (JSON backup) lives here and in Settings.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key, required this.db, required this.userRepo});

  final SunnatiDatabase db;
  final UserRepository userRepo;

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  @override
  Widget build(BuildContext context) {
    final data = widget.userRepo.data;
    final favs = data.favorites.toList()..sort();
    return Scaffold(
      appBar: AppBar(
        title: const Text('المفضلة والملاحظات'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'تصدير نسخة احتياطية (JSON)',
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: widget.userRepo.exportJson()),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('تم نسخ النسخة الاحتياطية (JSON) إلى الحافظة'),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: favs.isEmpty && data.notes.isEmpty
          ? ListView(
              padding: const EdgeInsets.all(12),
              children: const [
                EmptyLibraryCard(
                  title: 'لا توجد مفضلة بعد',
                  detail:
                      'احفظ أي حديث من شاشة القراءة بالقلب، وستظهر مفضلتك وملاحظاتك هنا — وتُحفظ على جهازك دون حساب.',
                  icon: Icons.favorite_outline,
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (favs.isNotEmpty) ...[
                  Text(
                    'الأحاديث المفضلة (${favs.length})',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...favs.map((id) => _FavTile(
                        db: widget.db,
                        userRepo: widget.userRepo,
                        stableId: id,
                        onChanged: () => setState(() {}),
                      )),
                ],
                if (data.notes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'الملاحظات (${data.notes.length})',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...data.notes.entries.map(
                    (e) => Card(
                      child: ListTile(
                        title: Text(e.value),
                        subtitle: Text(e.key),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _FavTile extends StatelessWidget {
  const _FavTile({
    required this.db,
    required this.userRepo,
    required this.stableId,
    required this.onChanged,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final String stableId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final parts = stableId.split(':');
    final hadith = parts.length == 2
        ? db.hadithByNumber(parts[0], int.tryParse(parts[1]) ?? -1)
        : null;
    final tags = userRepo.data.tags[stableId] ?? const <String>[];
    return Card(
      child: ListTile(
        leading: const Icon(Icons.star, color: SunnatiColors.gold),
        title: Text(
          hadith?.text ?? stableId,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          hadith == null
              ? 'النص غير مثبّت بعد — يُعرض فور اكتمال المكتبة'
              : 'حديث ${hadith.num} — ${hadith.chapterTitle}'
                  '${tags.isEmpty ? '' : ' — وسوم: ${tags.join('، ')}'}',
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'إزالة من المفضلة',
          onPressed: () async {
            await userRepo.toggleFavorite(stableId);
            onChanged();
          },
        ),
        onTap: hadith == null
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => HadithReaderScreen(
                      db: db,
                      userRepo: userRepo,
                      hadith: hadith,
                    ),
                  ),
                ),
      ),
    );
  }
}
