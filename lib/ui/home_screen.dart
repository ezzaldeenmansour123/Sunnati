import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/hadith.dart';
import 'hadith_reader_screen.dart';
import 'library_screen.dart';
import 'narrators_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'widgets/empty_library.dart';
import 'widgets/isnad_tree.dart';
import 'widgets/sunnati_bottom_nav.dart';

/// Home screen — mockup screen 1, reproduced faithfully in structure:
/// top row (settings gear one side, search icon the other), brand header
/// (launcher icon + «سُنّتي» + «موسوعة السنة النبوية»), the verse quote
/// card, a 2×2 grid of rose shortcut cards (موسوعة الرواة، شجرة الإسناد،
/// الكتب التسعة، البحث المتقدم), then «آخر الأحاديث» with «عرض الكل».
///
/// Only the DESIGN is copied from the mockup: every hadith shown comes
/// from the installed database — «آخر الأحاديث» is the last-read hadiths
/// (reading history) topped up, when history is short, with the opening
/// hadiths of the first book that has data. There is no "recent hadiths"
/// query in the database layer, and no text here is invented.
///
/// When embedded in the app shell ([onSelectTab] set) the الكتب التسعة
/// and البحث المتقدم cards switch tabs instead of pushing a route, so
/// the bottom nav stays visible. When used standalone they push routes.
/// The bottom nav itself lives in the shell (`lib/main.dart`); detail
/// pages pushed from here carry the same bar (active tab الرئيسية),
/// and a tab tap on a pushed page replaces the stack with a fresh
/// shell on that tab — see `sunnatiGoToTab`.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.db,
    required this.userRepo,
    required this.onThemeModeChanged,
    required this.onFontScaleChanged,
    this.onSelectTab,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final ValueChanged<String> onThemeModeChanged;
  final ValueChanged<double> onFontScaleChanged;

  /// Switches the shell to a tab: 0 المزيد، 1 المكتبة، 2 الرئيسية،
  /// 3 البحث، 4 الحديث. Null when this screen is used standalone.
  final ValueChanged<int>? onSelectTab;

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  void _openSettings(BuildContext context) {
    _push(
      context,
      SettingsScreen(
        db: db,
        userRepo: userRepo,
        onThemeModeChanged: onThemeModeChanged,
        onFontScaleChanged: onFontScaleChanged,
      ),
    );
  }

  void _openSearch(BuildContext context) {
    final select = onSelectTab;
    if (select != null) {
      select(3);
    } else {
      _push(context, SearchScreen(db: db));
    }
  }

  void _openBooks(BuildContext context) {
    final select = onSelectTab;
    if (select != null) {
      select(1);
    } else {
      _push(context, LibraryScreen(db: db, userRepo: userRepo));
    }
  }

  void _openNarrators(BuildContext context) {
    _push(context, NarratorsScreen(db: db));
  }

  /// The hadith the isnad-tree card shows: the last-read hadith, else
  /// the first hadith of the first book that has data. Null when the
  /// library holds no hadith at all.
  Hadith? _targetHadith() {
    for (final id in userRepo.data.history) {
      final parts = id.split(':');
      if (parts.length != 2) continue;
      final num = int.tryParse(parts[1]);
      if (num == null) continue;
      final hadith = db.hadithByNumber(parts[0], num);
      if (hadith != null) return hadith;
    }
    final first = db.hadithByNumber('bukhari', 1);
    if (first != null) return first;
    for (final book in db.books()) {
      if (!book.hasData) continue;
      for (final chapter in db.chapters(book.id)) {
        if (chapter.count == 0) continue;
        final page = db.hadithsForChapterPaged(chapter.id, limit: 1);
        if (page.isNotEmpty) return page.first;
      }
    }
    return null;
  }

  void _openIsnadTree(BuildContext context) {
    final hadith = _targetHadith();
    if (hadith == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يوجد حديث بعد لعرض شجرته.')),
      );
      return;
    }
    _push(
      context,
      _IsnadTreePage(db: db, hadith: hadith),
    );
  }

  void _openHadith(BuildContext context, Hadith hadith) {
    _push(
      context,
      HadithReaderScreen(db: db, userRepo: userRepo, hadith: hadith),
    );
  }

  /// «آخر الأحاديث»: the last-read hadiths, in history order — real
  /// rows from the installed database, never invented. With no reading
  /// history yet the list is empty (the section then says so honestly);
  /// opening hadiths of a book are NOT presented as "latest".
  List<Hadith> _latestHadiths() {
    final out = <Hadith>[];
    final seen = <String>{};
    for (final id in userRepo.data.history) {
      if (out.length >= 3) break;
      final parts = id.split(':');
      if (parts.length != 2) continue;
      final num = int.tryParse(parts[1]);
      if (num == null) continue;
      final hadith = db.hadithByNumber(parts[0], num);
      if (hadith != null && seen.add(hadith.stableId)) out.add(hadith);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final latest = db.isAvailable ? _latestHadiths() : const <Hadith>[];
    final bookNames = <String, String>{
      for (final book in db.books()) book.id: book.name,
    };
    return Scaffold(
      backgroundColor: SunnatiColors.ivory,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          children: [
            // Top row — mockup screen 1: search icon at the RTL start
            // (right), settings gear at the RTL end (left).
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.search, color: SunnatiColors.petrol),
                  tooltip: 'البحث',
                  onPressed: db.isAvailable
                      ? () => _openSearch(context)
                      : null,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(
                    Icons.settings_outlined,
                    color: SunnatiColors.petrol,
                  ),
                  tooltip: 'الإعدادات',
                  onPressed: () => _openSettings(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Brand header: the launcher icon itself, then the wordmark.
            Column(
              children: [
                Image.asset('assets/app_icon.png', width: 112, height: 112),
                const SizedBox(height: 8),
                const Text(
                  'سُنّتي',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                    color: SunnatiColors.petrol,
                  ),
                ),
                const Text(
                  'موسوعة السنة النبوية',
                  style: TextStyle(
                    fontSize: 15,
                    color: SunnatiColors.inkMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Verse quote card (mockup wording, Qur'an 59:7).
            Container(
              decoration: BoxDecoration(
                color: SunnatiColors.roseSoft,
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 16,
              ),
              child: const Text(
                '{ وما آتاكم الرسول فخذوه وما نهاكم عنه فانتهوا }',
                style: TextStyle(
                  fontSize: 16,
                  height: 1.8,
                  color: SunnatiColors.ink,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            if (!db.isAvailable)
              EmptyLibraryCard(
                title: 'المكتبة تُبنى',
                detail: db.unavailableReason.isNotEmpty
                    ? db.unavailableReason
                    : 'الكتب التسعة قيد الاستيراد — لا توجد أحاديث بعد.',
                icon: Icons.hourglass_empty,
              )
            else ...[
              // 2×2 shortcut grid — RTL order: first row موسوعة الرواة
              // (right) then شجرة الإسناد (left); second row الكتب
              // التسعة (right) then البحث المتقدم (left), as the mockup.
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.9,
                children: [
                  _ShortcutCard(
                    icon: Icons.people_outline,
                    label: 'موسوعة الرواة',
                    onTap: () => _openNarrators(context),
                  ),
                  _ShortcutCard(
                    icon: Icons.account_tree_outlined,
                    label: 'شجرة الإسناد',
                    onTap: () => _openIsnadTree(context),
                  ),
                  _ShortcutCard(
                    icon: Icons.library_books_outlined,
                    label: 'الكتب التسعة',
                    onTap: () => _openBooks(context),
                  ),
                  _ShortcutCard(
                    icon: Icons.search,
                    label: 'البحث المتقدم',
                    onTap: () => _openSearch(context),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // «آخر الأحاديث» + «عرض الكل».
              Row(
                children: [
                  const Text(
                    'آخر الأحاديث',
                    style: SunnatiText.sectionTitle,
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: latest.isEmpty
                        ? null
                        : () => _push(
                              context,
                              _LatestHadithsPage(
                                db: db,
                                userRepo: userRepo,
                                hadiths: latest,
                                bookNames: bookNames,
                              ),
                            ),
                    borderRadius: BorderRadius.circular(8),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('عرض الكل', style: SunnatiText.sectionAction),
                        Icon(
                          Icons.chevron_left,
                          size: 18,
                          color: SunnatiColors.roseDark,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (latest.isEmpty)
                const Text(
                  'لا توجد أحاديث مقروءة بعد — ابدأ القراءة من الكتب التسعة.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: SunnatiColors.inkMuted),
                )
              else
                for (final hadith in latest)
                  _HadithPreviewCard(
                    hadith: hadith,
                    bookName: bookNames[hadith.bookId] ?? hadith.bookId,
                    onTap: () => _openHadith(context, hadith),
                  ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

/// One rose shortcut card of the home 2×2 grid (mockup screen 1).
class _ShortcutCard extends StatelessWidget {
  const _ShortcutCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: SunnatiColors.roseSurface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 28, color: SunnatiColors.petrol),
            const SizedBox(height: 6),
            Text(label, style: SunnatiText.cardLabel),
          ],
        ),
      ),
    );
  }
}

/// A real hadith from the database shown under «آخر الأحاديث»:
/// opening lines of the text, then book + number. Tapping opens the
/// reader. No text is invented or shortened without the ellipsis.
class _HadithPreviewCard extends StatelessWidget {
  const _HadithPreviewCard({
    required this.hadith,
    required this.bookName,
    required this.onTap,
  });

  final Hadith hadith;
  final String bookName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hadith.text,
                style: const TextStyle(fontSize: 15, height: 1.8),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                '$bookName • حديث رقم ${hadith.num}',
                style: const TextStyle(
                  fontSize: 12,
                  color: SunnatiColors.inkMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «عرض الكل» for «آخر الأحاديث»: the same real list, fuller text.
class _LatestHadithsPage extends StatelessWidget {
  const _LatestHadithsPage({
    required this.db,
    required this.userRepo,
    required this.hadiths,
    required this.bookNames,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final List<Hadith> hadiths;
  final Map<String, String> bookNames;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('آخر الأحاديث')),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: hadiths.length,
        itemBuilder: (context, i) {
          final hadith = hadiths[i];
          return _HadithPreviewCard(
            hadith: hadith,
            bookName: bookNames[hadith.bookId] ?? hadith.bookId,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HadithReaderScreen(
                  db: db,
                  userRepo: userRepo,
                  hadith: hadith,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The isnad tree of the last-read (else first) hadith, as a page.
/// [IsnadTree] itself shows the honest empty state when no verified
/// chain is recorded for the hadith — no chain is fabricated here.
class _IsnadTreePage extends StatelessWidget {
  const _IsnadTreePage({required this.db, required this.hadith});

  final SunnatiDatabase db;
  final Hadith hadith;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('شجرة الإسناد')),
      bottomNavigationBar: SunnatiBottomNav(
        currentIndex: 2,
        onTap: (index) => sunnatiGoToTab(context, index),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: IsnadTree(
          db: db,
          links: db.chainForHadith(hadith.id),
        ),
      ),
    );
  }
}
