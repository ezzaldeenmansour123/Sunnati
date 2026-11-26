import 'package:material_ui/material_ui.dart';

import 'core/theme.dart';
import 'data/database.dart';
import 'data/user_repository.dart';
import 'models/hadith.dart';
import 'ui/first_run_download_screen.dart';
import 'ui/hadith_reader_screen.dart';
import 'ui/home_screen.dart';
import 'ui/library_screen.dart';
import 'ui/more_screen.dart';
import 'ui/search_screen.dart';
import 'ui/welcome_screen.dart';
import 'ui/widgets/empty_library.dart';
import 'ui/widgets/sunnati_bottom_nav.dart';

/// SUNNATI — entry point (thin by design).
///
/// main() only initialises the library database + user data, then hands
/// over to [_SunnatiShell]. All screens live in `lib/ui/`; all logic in
/// `lib/data/`, `lib/search/` and `lib/assistant/`. This file must stay
/// small — the Ezz-alsonah lesson was a 1,593-line main.dart.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SunnatiApp());
}

class SunnatiApp extends StatefulWidget {
  const SunnatiApp({super.key});

  @override
  State<SunnatiApp> createState() => _SunnatiAppState();
}

class _SunnatiAppState extends State<SunnatiApp> {
  SunnatiDatabase? _db;
  UserRepository? _userRepo;
  String? _error;

  String _themeMode = 'system';
  double _fontScale = 1.0;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final repo = await UserRepository.load();
      final db = await SunnatiDatabase.open();
      if (!mounted) return;
      setState(() {
        _userRepo = repo;
        _db = db;
        _themeMode = repo.themeMode;
        _fontScale = repo.fontScale;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر تهيئة التطبيق: $e');
    }
  }

  /// Re-run boot after the first-run download completes: re-open the
  /// database (now installed + verified) and show the home screen.
  void _onLibraryInstalled() {
    setState(() {
      _db = null;
      _userRepo = null;
    });
    _boot();
  }

  /// Welcome done: persist the flag and rebuild — the live
  /// [UserRepository.welcomeSeen] getter then reads true and the shell
  /// (جامع الكتب التسعة) shows. First launch only, by design; showing
  /// the welcome on every launch would be a one-line change here.
  Future<void> _onWelcomeStart() async {
    final repo = _userRepo;
    if (repo == null) return;
    await repo.setWelcomeSeen();
    if (!mounted) return;
    setState(() {});
  }

  ThemeMode get _effectiveThemeMode {
    switch (_themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = _db;
    final repo = _userRepo;
    return MaterialApp(
      title: 'سُنَّتي',
      debugShowCheckedModeBanner: false,
      // Full RTL: the whole app is Arabic-first.
      locale: const Locale('ar'),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),
      theme: SunnatiTheme.light(fontScale: _fontScale),
      darkTheme: SunnatiTheme.dark(fontScale: _fontScale),
      themeMode: _effectiveThemeMode,
      home: _error != null
          ? _BootError(message: _error!)
          : db == null || repo == null
              ? const _BootLoading()
              // Embedded library (owner decision 2026-11-26 16:54):
              // the library ships inside the APK and open() installs
              // it from the asset on first run, so this screen is
              // only a recovery path when the embedded install failed.
              // A migrated build-52/75/81 copy opens normally and
              // never lands here (see SunnatiDatabase.open).
              : db.libraryNeedsDownload
                  ? FirstRunDownloadScreen(
                      onInstalled: _onLibraryInstalled,
                    )
                  // First-run welcome (owner order 2026-11-26 17:51):
                  // shown ONCE, before the shell, after the library
                  // is confirmed available. NOT a login/account
                  // screen — SUNNATI has no accounts by design.
                  : !repo.welcomeSeen
                      ? WelcomeScreen(onStart: _onWelcomeStart)
                      : _SunnatiShell(
                          db: db,
                          userRepo: repo,
                          onThemeModeChanged: (mode) {
                            setState(() => _themeMode = mode);
                          },
                          onFontScaleChanged: (scale) {
                            setState(() => _fontScale = scale);
                          },
                        ),
    );
  }
}

class _BootLoading extends StatelessWidget {
  const _BootLoading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('جارٍ تجهيز المكتبة…'),
          ],
        ),
      ),
    );
  }
}

class _BootError extends StatelessWidget {
  const _BootError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message, textAlign: TextAlign.center),
        ),
      ),
    );
  }
}

/// App shell — the shared bottom navigation (mockup screens 1–8).
///
/// Five tabs, indices per [SunnatiBottomNav]:
///   0 المزيد → settings · 1 المكتبة → books list · 2 الرئيسية → home ·
///   3 البحث → advanced search · 4 الحديث → hadith reader.
/// الرئيسية is the landing tab, as in the mockup (its الرئيسية item is
/// the active one on the home screen).
///
/// Smoothness (2026-11-26 fix 1): the body is an [IndexedStack] — each
/// tab's page is built ONCE, on first visit, and kept alive afterwards,
/// so scroll positions, typed searches and the reader's place survive
/// tab switches. Tabs are built LAZILY on first visit (not eagerly):
/// the reader tab marks its hadith as read in initState, so building it
/// eagerly would pollute the reading history on every launch. A tab tap
/// on a pushed screen pops back to this live shell and selects the tab
/// (see `sunnatiGoToTab`) instead of building a fresh shell.
///
/// First-run download routing and admin routes are untouched: this
/// shell is only reached when a library file exists (see
/// [_SunnatiAppState.build]); admin is reached from Settings as before.
class _SunnatiShell extends StatefulWidget {
  const _SunnatiShell({
    required this.db,
    required this.userRepo,
    required this.onThemeModeChanged,
    required this.onFontScaleChanged,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final ValueChanged<String> onThemeModeChanged;
  final ValueChanged<double> onFontScaleChanged;

  @override
  State<_SunnatiShell> createState() => _SunnatiShellState();
}

class _SunnatiShellState extends State<_SunnatiShell> {
  /// Active tab — the landing tab (2 = الرئيسية).
  late int _index;

  /// One built page per visited tab (built once, on first visit, and
  /// kept alive by the IndexedStack). Unvisited tabs render an empty
  /// placeholder and cost nothing — the reader tab in particular must
  /// NOT build before its first visit (it marks its hadith as read in
  /// initState).
  final Map<int, Widget> _pages = <int, Widget>{};

  @override
  void initState() {
    super.initState();
    _index = 2; // الرئيسية, the landing tab.
    _pages[_index] = _page(_index);
    // Pushed screens switch tabs through this callback (see
    // `sunnatiGoToTab`): pop back to this live shell, then select.
    sunnatiSelectTab = _select;
  }

  @override
  void dispose() {
    if (sunnatiSelectTab == _select) sunnatiSelectTab = null;
    super.dispose();
  }

  void _select(int index) {
    if (index == _index && _pages.containsKey(index)) return;
    setState(() {
      _index = index;
      _pages.putIfAbsent(index, () => _page(index));
    });
  }

  Widget _page(int index) {
    final db = widget.db;
    final repo = widget.userRepo;
    return switch (index) {
      0 => MoreScreen(
          db: db,
          userRepo: repo,
          onThemeModeChanged: widget.onThemeModeChanged,
          onFontScaleChanged: widget.onFontScaleChanged,
        ),
      1 => LibraryScreen(db: db, userRepo: repo),
      3 => SearchScreen(db: db),
      4 => _HadithTab(db: db, userRepo: repo),
      _ => HomeScreen(
          db: db,
          userRepo: repo,
          onThemeModeChanged: widget.onThemeModeChanged,
          onFontScaleChanged: widget.onFontScaleChanged,
          onSelectTab: _select,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < 5; i++) _pages[i] ?? const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: SunnatiBottomNav(
        currentIndex: _index,
        onTap: _select,
      ),
    );
  }
}

/// The الحديث tab: the last-read hadith, else the first hadith of the
/// first book that has data (Bukhari 1 when present) — all real rows,
/// resolved by [_resolveDefaultHadith]. When the library holds no
/// hadith at all the tab says so honestly instead of opening a reader.
class _HadithTab extends StatelessWidget {
  const _HadithTab({required this.db, required this.userRepo});

  final SunnatiDatabase db;
  final UserRepository userRepo;

  @override
  Widget build(BuildContext context) {
    final hadith = _resolveDefaultHadith(db, userRepo);
    if (hadith == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('الحديث')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            EmptyLibraryCard(
              title: 'لا يوجد حديث بعد',
              detail: db.unavailableReason.isNotEmpty
                  ? db.unavailableReason
                  : 'الكتب التسعة قيد الاستيراد — لا توجد أحاديث بعد.',
            ),
          ],
        ),
      );
    }
    // The reader is the body of this shell Scaffold, so the shell's
    // own bottom nav is the reader's nav here — the reader must NOT
    // draw a second one (see `showBottomNav`). Pushed readers (from
    // home, book, search, …) keep the default `true` and draw their own.
    return HadithReaderScreen(
      db: db,
      userRepo: userRepo,
      hadith: hadith,
      showBottomNav: false,
    );
  }
}

/// Last-read hadith from history, else Bukhari 1, else the first hadith
/// of the first book with data. Null only when the library is empty.
/// (The database layer has no "recent hadiths" query, so recency here
/// means reading history — never an invented order.)
Hadith? _resolveDefaultHadith(SunnatiDatabase db, UserRepository repo) {
  for (final id in repo.data.history) {
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
