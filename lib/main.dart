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
    // Register the fresh-shell factory for pushed screens: tapping a
    // tab on a pushed page replaces the stack with a new shell on that
    // tab (see `sunnatiGoToTab` in `sunnati_bottom_nav.dart`). Only
    // registered once a library is open — pushed screens exist solely
    // under a booted shell.
    if (db != null && repo != null) {
      sunnatiShellBuilder = (index) => _SunnatiShell(
            db: db,
            userRepo: repo,
            initialIndex: index,
            onThemeModeChanged: (mode) {
              setState(() => _themeMode = mode);
            },
            onFontScaleChanged: (scale) {
              setState(() => _fontScale = scale);
            },
          );
    }
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
              // External-download decision (rebuild 2026-11-26): no
              // valid library installed → blocking first-run download.
              // A migrated build-52 copy opens normally and never lands
              // here (see SunnatiDatabase.open).
              : db.libraryNeedsDownload
                  ? FirstRunDownloadScreen(
                      onInstalled: _onLibraryInstalled,
                    )
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
/// The body builds only the active tab (no IndexedStack): the reader
/// tab marks its hadith as read in initState, so building it eagerly
/// would pollute the reading history on every launch. Tab state (e.g.
/// a typed search) is therefore not preserved across tab switches —
/// a known limitation, not a silent behaviour.
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
    this.initialIndex = 2,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final ValueChanged<String> onThemeModeChanged;
  final ValueChanged<double> onFontScaleChanged;

  /// Tab the fresh shell opens on (0 المزيد، 1 المكتبة، 2 الرئيسية،
  /// 3 البحث، 4 الحديث). Default 2 = الرئيسية, the landing tab. Used
  /// by [sunnatiGoToTab] so a tab tap on a pushed screen can open a
  /// fresh shell on that tab.
  final int initialIndex;

  @override
  State<_SunnatiShell> createState() => _SunnatiShellState();
}

class _SunnatiShellState extends State<_SunnatiShell> {
  /// Active tab — the landing tab, unless [initialIndex] says otherwise.
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
  }

  void _select(int index) {
    if (index != _index) setState(() => _index = index);
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
      body: _page(_index),
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
