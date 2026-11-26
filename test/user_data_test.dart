import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/models/user_data.dart';

void main() {
  group('UserData JSON round-trip', () {
    test('exports and re-imports identically', () {
      final original = UserData(
        favorites: <String>{'bukhari:1', 'muslim:42'},
        tags: <String, List<String>>{
          'bukhari:1': <String>['نية', 'مهم'],
        },
        notes: <String, String>{'bukhari:1': 'أول حديث في الصحيح'},
        history: <String>['bukhari:1', 'muslim:42'],
      );
      final restored = UserData.fromJsonString(original.toJsonString());
      expect(restored.favorites, original.favorites);
      expect(restored.tags, original.tags);
      expect(restored.notes, original.notes);
      expect(restored.history, original.history);
    });

    test('empty data round-trips', () {
      final restored = UserData.fromJsonString(UserData().toJsonString());
      expect(restored.favorites, isEmpty);
      expect(restored.tags, isEmpty);
      expect(restored.notes, isEmpty);
      expect(restored.history, isEmpty);
    });

    test('rejects a non-SUNNATI document', () {
      expect(
        () => UserData.fromJsonString('{"format":"other-app","version":1}'),
        throwsFormatException,
      );
      expect(() => UserData.fromJsonString('not json'), throwsFormatException);
    });

    test('tolerates missing keys in older backups', () {
      final restored = UserData.fromJson(<String, Object?>{
        'format': 'sunnati-user-data',
        'version': 1,
        'favorites': <String>['bukhari:1'],
      });
      expect(restored.favorites, <String>{'bukhari:1'});
      expect(restored.notes, isEmpty);
    });
  });

  group('UserData.touch', () {
    test('most recent first, de-duplicated, capped at 100', () {
      var data = UserData();
      for (var i = 0; i < 105; i++) {
        data = data.touch('bukhari:$i');
      }
      expect(data.history.length, 100);
      expect(data.history.first, 'bukhari:104');
      data = data.touch('bukhari:104');
      expect(data.history.length, 100);
      expect(data.history.first, 'bukhari:104');
    });
  });
}
