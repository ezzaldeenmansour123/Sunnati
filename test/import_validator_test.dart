import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/data/import_validator.dart';

void main() {
  group('validateImportJsonString', () {
    test('accepts a valid narrator document', () {
      const doc = '''
{"kind": "narrator", "records": [
  {"name": "الزهري", "source": "تقريب التهذيب", "status": "ثقة", "status_src": "تقريب التهذيب ص 1"}
]}''';
      final result = validateImportJsonString(doc);
      expect(result.ok, isTrue);
      expect(result.recordCount, 1);
    });

    test('refuses a record without a source', () {
      const doc = '''
{"kind": "narrator", "records": [{"name": "الزهري"}]}''';
      final result = validateImportJsonString(doc);
      expect(result.ok, isFalse);
      expect(result.errors.join(' '), contains('source'));
    });

    test('refuses a narrator status without status_src', () {
      const doc = '''
{"kind": "narrator", "records": [
  {"name": "الزهري", "source": "تقريب التهذيب", "status": "ثقة"}
]}''';
      final result = validateImportJsonString(doc);
      expect(result.ok, isFalse);
      expect(result.errors.join(' '), contains('status_src'));
    });

    test('refuses an unknown field', () {
      const doc = '''
{"kind": "book", "records": [
  {"id": "darqutni", "name": "سنن الدارقطني", "author": "الدارقطني",
   "source": "x", "license": "ODbL-1.0", "surprise": true}
]}''';
      final result = validateImportJsonString(doc);
      expect(result.ok, isFalse);
      expect(result.errors.join(' '), contains('surprise'));
    });

    test('refuses a malformed book id', () {
      const doc = '''
{"kind": "book", "records": [
  {"id": "Bad ID!", "name": "x", "author": "y", "source": "s", "license": "l"}
]}''';
      final result = validateImportJsonString(doc);
      expect(result.ok, isFalse);
    });

    test('refuses duplicate identities in one file', () {
      const doc = '''
{"kind": "narrator", "records": [
  {"name": "الزهري", "source": "تقريب التهذيب"},
  {"name": "الزهري", "source": "تقريب التهذيب"}
]}''';
      final result = validateImportJsonString(doc);
      expect(result.ok, isFalse);
      expect(result.errors.join(' '), contains('duplicate'));
    });

    test('refuses shell fragments', () {
      const doc = r'''
{"kind": "source", "records": [
  {"name": "x$(rm -rf /)", "license": "l"}
]}''';
      final result = validateImportJsonString(doc);
      expect(result.ok, isFalse);
    });

    test('refuses an unsafe path field', () {
      const doc = '''
{"kind": "commentary", "records": [
  {"hadith_key": "bukhari:1", "text": "شرح", "source": "s", "file": "../../etc/passwd"}
]}''';
      // 'file' is not an allowed field for commentary, so this is
      // refused either way; the point is the document is refused.
      final result = validateImportJsonString(doc);
      expect(result.ok, isFalse);
    });

    test('refuses invalid JSON and unknown kinds', () {
      expect(validateImportJsonString('not json').ok, isFalse);
      expect(
        validateImportJsonString('{"kind": "nope", "records": []}').ok,
        isFalse,
      );
    });
  });

  group('validateImportCsvString', () {
    test('accepts a valid CSV', () {
      const csv = 'name,source\nالزهري,تقريب التهذيب\n';
      final result = validateImportCsvString(csv, 'narrator');
      expect(result.ok, isTrue);
      expect(result.recordCount, 1);
    });

    test('refuses formula-like cells', () {
      const csv = 'name,source\n=1+1,تقريب التهذيب\n';
      final result = validateImportCsvString(csv, 'narrator');
      expect(result.ok, isFalse);
      expect(result.errors.join(' '), contains('formula-like'));
    });

    test('refuses a missing required column', () {
      const csv = 'name\nالزهري\n';
      final result = validateImportCsvString(csv, 'narrator');
      expect(result.ok, isFalse);
      expect(result.errors.join(' '), contains('source'));
    });

    test('refuses a row with the wrong cell count', () {
      const csv = 'name,source\nالزهري\n';
      final result = validateImportCsvString(csv, 'narrator');
      expect(result.ok, isFalse);
    });
  });

  group('findDuplicateIdentities / findMissingFields', () {
    test('finds Arabic-normalised duplicates', () {
      final dups = findDuplicateIdentities('narrator', <Map<String, Object?>>[
        <String, Object?>{'name': 'الزهري'},
        <String, Object?>{'name': 'الزهرى'},
      ]);
      expect(dups.length, 1);
    });

    test('reports missing required fields', () {
      final missing = findMissingFields('grade', <String, Object?>{
        'hadith_key': 'bukhari:1',
      });
      expect(missing, contains('grader'));
      expect(missing, contains('grade'));
      expect(missing, contains('source'));
    });
  });
}
