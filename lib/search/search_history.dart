/// Saved search history, stored locally in SharedPreferences — no
/// accounts, no network. The user re-runs a previous search with one
/// tap, or clears the history. At most 20 entries; a repeat of an
/// existing search moves it to the top instead of duplicating it.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'search_service.dart';

const String _kHistoryKey = 'sunnati_search_history_v1';
const int kMaxHistoryEntries = 20;

/// One saved search: the query plus the filters it ran with.
class SearchHistoryEntry {
  const SearchHistoryEntry({
    required this.text,
    required this.scope,
    this.bookId,
    this.grade,
    this.chapterId,
    this.narrator = '',
    this.companion = '',
    this.semantic = false,
    required this.savedAt,
  });

  factory SearchHistoryEntry.fromQuery(SearchQuery query) {
    return SearchHistoryEntry(
      text: query.text,
      scope: query.scope,
      bookId: query.bookId,
      grade: query.grade,
      chapterId: query.chapterId,
      narrator: query.narrator,
      companion: query.companion,
      semantic: query.semantic,
      savedAt: DateTime.now().toUtc(),
    );
  }

  factory SearchHistoryEntry.fromJson(Map<String, Object?> json) {
    return SearchHistoryEntry(
      text: (json['text'] as String?) ?? '',
      scope: SearchScope.values[(json['scope'] as int?) ?? 0],
      bookId: json['bookId'] as String?,
      grade: json['grade'] as String?,
      chapterId: json['chapterId'] as int?,
      narrator: (json['narrator'] as String?) ?? '',
      companion: (json['companion'] as String?) ?? '',
      semantic: (json['semantic'] as bool?) ?? false,
      savedAt: DateTime.tryParse((json['savedAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'scope': scope.index,
        'bookId': bookId,
        'grade': grade,
        'chapterId': chapterId,
        'narrator': narrator,
        'companion': companion,
        'semantic': semantic,
        'savedAt': savedAt.toIso8601String(),
      };

  final String text;
  final SearchScope scope;
  final String? bookId;
  final String? grade;
  final int? chapterId;
  final String narrator;
  final String companion;
  final bool semantic;
  final DateTime savedAt;

  /// Short one-line summary for the history list.
  String get label {
    final parts = <String>[];
    if (text.trim().isNotEmpty) parts.add(text.trim());
    if (narrator.trim().isNotEmpty) parts.add('راوٍ: ${narrator.trim()}');
    if (companion.trim().isNotEmpty) {
      parts.add('صحابي: ${companion.trim()}');
    }
    return parts.join(' • ');
  }

  /// Same search (text + filters), ignoring the timestamp.
  bool sameAs(SearchHistoryEntry other) {
    return text == other.text &&
        scope == other.scope &&
        bookId == other.bookId &&
        grade == other.grade &&
        chapterId == other.chapterId &&
        narrator == other.narrator &&
        companion == other.companion &&
        semantic == other.semantic;
  }

  SearchQuery toQuery() {
    return SearchQuery(
      text: text,
      bookId: bookId,
      grade: grade,
      chapterId: chapterId,
      narrator: narrator,
      companion: companion,
      scope: scope,
      semantic: semantic,
    );
  }
}

class SearchHistory {
  SearchHistory(this._prefs, this._entries);

  final SharedPreferences _prefs;
  List<SearchHistoryEntry> _entries;

  static Future<SearchHistory> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kHistoryKey);
    var entries = <SearchHistoryEntry>[];
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          entries = decoded
              .whereType<Map<String, Object?>>()
              .map(SearchHistoryEntry.fromJson)
              .where((e) => e.label.isNotEmpty)
              .toList();
        }
      } catch (_) {
        // A corrupt blob must not wipe the app: start empty and keep
        // the corrupt value untouched in prefs for manual recovery.
        entries = <SearchHistoryEntry>[];
      }
    }
    return SearchHistory(prefs, entries);
  }

  List<SearchHistoryEntry> get entries =>
      List<SearchHistoryEntry>.unmodifiable(_entries);

  Future<void> add(SearchQuery query) async {
    final entry = SearchHistoryEntry.fromQuery(query);
    if (entry.label.isEmpty) return;
    _entries.removeWhere((e) => e.sameAs(entry));
    _entries.insert(0, entry);
    if (_entries.length > kMaxHistoryEntries) {
      _entries = _entries.sublist(0, kMaxHistoryEntries);
    }
    await _save();
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    _entries.removeAt(index);
    await _save();
  }

  Future<void> clear() async {
    _entries = <SearchHistoryEntry>[];
    await _save();
  }

  Future<void> _save() async {
    await _prefs.setString(
      _kHistoryKey,
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
  }
}
