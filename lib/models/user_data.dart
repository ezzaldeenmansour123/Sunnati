/// The user's own data: favourites, tags, notes and reading history.
///
/// Stored locally in SharedPreferences as JSON (see
/// `lib/data/user_repository.dart`). Export/import is a plain JSON document
/// so the user can back up before any reinstall — the lesson of the
/// Ezz-alsonah debug-signing incident, where a signature change would have
/// wiped favourites with no backup.
///
/// Pure value type: no Flutter / SharedPreferences dependency, fully
/// unit-tested (round-trip in `test/user_data_test.dart`).
library;

import 'dart:convert';

class UserData {
  UserData({
    Set<String>? favorites,
    Map<String, List<String>>? tags,
    Map<String, String>? notes,
    List<String>? history,
  })  : favorites = favorites ?? <String>{},
        tags = tags ?? <String, List<String>>{},
        notes = notes ?? <String, String>{},
        history = history ?? <String>[];

  factory UserData.fromJson(Map<String, Object?> json) {
    final favs = json['favorites'];
    final tagsJson = json['tags'];
    final notesJson = json['notes'];
    final historyJson = json['history'];
    return UserData(
      favorites: favs is List
          ? favs.whereType<String>().toSet()
          : <String>{},
      tags: tagsJson is Map
          ? tagsJson.map(
              (k, v) => MapEntry(
                k.toString(),
                v is List ? v.whereType<String>().toList() : <String>[],
              ),
            )
          : <String, List<String>>{},
      notes: notesJson is Map
          ? notesJson.map((k, v) => MapEntry(k.toString(), v.toString()))
          : <String, String>{},
      history: historyJson is List
          ? historyJson.whereType<String>().toList()
          : <String>[],
    );
  }

  /// Hadith stable ids (`<book>:<num>`), e.g. `bukhari:1`.
  final Set<String> favorites;

  /// Hadith stable id → list of user tags.
  final Map<String, List<String>> tags;

  /// Hadith stable id → free-text note.
  final Map<String, String> notes;

  /// Hadith stable ids, most recent first, capped at 100 entries.
  final List<String> history;

  Map<String, Object?> toJson() => <String, Object?>{
        'format': 'sunnati-user-data',
        'version': 1,
        'favorites': favorites.toList()..sort(),
        'tags': tags,
        'notes': notes,
        'history': history,
      };

  String toJsonString() => jsonEncode(toJson());

  static UserData fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('SUNNATI user-data backup is not a JSON object');
    }
    if (decoded['format'] != 'sunnati-user-data') {
      throw const FormatException('Not a SUNNATI user-data backup');
    }
    return UserData.fromJson(decoded);
  }

  UserData copyWith({
    Set<String>? favorites,
    Map<String, List<String>>? tags,
    Map<String, String>? notes,
    List<String>? history,
  }) {
    return UserData(
      favorites: favorites ?? Set<String>.of(this.favorites),
      tags: tags ?? Map<String, List<String>>.of(this.tags),
      notes: notes ?? Map<String, String>.of(this.notes),
      history: history ?? List<String>.of(this.history),
    );
  }

  /// Record a read: most recent first, de-duplicated, capped at 100.
  UserData touch(String stableId) {
    final next = <String>[stableId, ...history.where((h) => h != stableId)];
    return copyWith(history: next.take(100).toList());
  }
}
