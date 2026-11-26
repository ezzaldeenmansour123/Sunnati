/// User data repository: favourites, tags, notes, reading history and
/// display settings, stored locally in SharedPreferences — no accounts,
/// no network. Export/import is a JSON document (see [UserData]) so the
/// user can back up before any reinstall.
///
/// Note (lesson from the Ezz-alsonah audit): no server token or secret is
/// stored here. SharedPreferences holds only the user's own reading data.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_data.dart';

/// SharedPreferences keys. Versioned key for the JSON blob so a future
/// format change can migrate instead of silently dropping data.
const String _kUserDataKey = 'sunnati_user_data_v1';
const String _kThemeModeKey = 'sunnati_theme_mode';
const String _kFontScaleKey = 'sunnati_font_scale';
const String _kWelcomeSeenKey = 'sunnati_welcome_seen';

/// Maximum backup string accepted on import (1 MiB).
const int kMaxUserBackupBytes = 1024 * 1024;

class UserRepository {
  UserRepository(this._prefs, this._data);

  final SharedPreferences _prefs;
  UserData _data;

  static Future<UserRepository> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUserDataKey);
    UserData data;
    if (raw == null) {
      data = UserData();
    } else {
      try {
        data = UserData.fromJsonString(raw);
      } catch (_) {
        // A corrupt blob must not wipe the app: start empty and keep the
        // corrupt value untouched in prefs for manual recovery.
        data = UserData();
      }
    }
    return UserRepository(prefs, data);
  }

  UserData get data => _data;

  Future<void> _save() async {
    await _prefs.setString(_kUserDataKey, _data.toJsonString());
  }

  bool isFavorite(String stableId) => _data.favorites.contains(stableId);

  Future<void> toggleFavorite(String stableId) async {
    final next = Set<String>.of(_data.favorites);
    if (next.contains(stableId)) {
      next.remove(stableId);
    } else {
      next.add(stableId);
    }
    _data = _data.copyWith(favorites: next);
    await _save();
  }

  Future<void> setNote(String stableId, String note) async {
    final notes = Map<String, String>.of(_data.notes);
    if (note.trim().isEmpty) {
      notes.remove(stableId);
    } else {
      notes[stableId] = note.trim();
    }
    _data = _data.copyWith(notes: notes);
    await _save();
  }

  Future<void> setTags(String stableId, List<String> tags) async {
    final next = Map<String, List<String>>.of(_data.tags);
    final clean = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    if (clean.isEmpty) {
      next.remove(stableId);
    } else {
      next[stableId] = clean;
    }
    _data = _data.copyWith(tags: next);
    await _save();
  }

  /// Record a read (most recent first, capped at 100 — see [UserData]).
  Future<void> touch(String stableId) async {
    _data = _data.touch(stableId);
    await _save();
  }

  /// Full JSON backup string for export (share / save to file).
  String exportJson() => _data.toJsonString();

  /// Replace local data from a backup string. Throws [FormatException]
  /// on invalid input; the existing data is left untouched in that case.
  /// A backup larger than [kMaxUserBackupBytes] is refused before any
  /// parsing — user data is small, so a huge blob is not a SUNNATI
  /// backup (Phase 8 hardening; the admin panel enforces the same cap).
  Future<void> importJson(String source) async {
    if (source.length > kMaxUserBackupBytes) {
      throw const FormatException('Backup is too large to be a SUNNATI backup');
    }
    final imported = UserData.fromJsonString(source);
    _data = imported;
    await _save();
  }

  // ---- Display settings (stored separately, also local-only) ----

  /// 'light' | 'dark' | 'system'. Defaults to 'system'.
  String get themeMode => _prefs.getString(_kThemeModeKey) ?? 'system';

  Future<void> setThemeMode(String mode) async {
    await _prefs.setString(_kThemeModeKey, mode);
  }

  /// Font scale multiplier, 0.85–1.6. Defaults to 1.0.
  double get fontScale => _prefs.getDouble(_kFontScaleKey) ?? 1.0;

  Future<void> setFontScale(double scale) async {
    final clamped = scale.clamp(0.85, 1.6).toDouble();
    await _prefs.setDouble(_kFontScaleKey, clamped);
  }

  // ---- First-run welcome (user order 2026-11-26 ~17:51) ----

  /// Whether the first-run welcome screen has been shown. Defaults to
  /// false — a fresh install shows the welcome once, then never again.
  bool get welcomeSeen => _prefs.getBool(_kWelcomeSeenKey) ?? false;

  /// Mark the welcome as seen (called when the user taps
  /// «ابدأ تصفح سُنَّتي» on [WelcomeScreen]).
  Future<void> setWelcomeSeen() async {
    await _prefs.setBool(_kWelcomeSeenKey, true);
  }
}
