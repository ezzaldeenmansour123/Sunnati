import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'data/database.dart';
import 'data/user_repository.dart';
import 'ui/home_screen.dart';

/// SUNNATI — entry point (thin by design).
///
/// main() only initialises the library database + user data, then hands
/// over to [HomeScreen]. All screens live in `lib/ui/`; all logic in
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
              : HomeScreen(
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
