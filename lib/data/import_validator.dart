/// Admin import validation (Phase 8) — pure Dart, no Flutter import.
///
/// Validates a JSON or CSV document submitted to the admin panel BEFORE
/// it is stored in `admin_staging`. A failing document is refused
/// outright (never staged, never published); a passing document is
/// staged as `pending_review` — validation is NOT approval.
///
/// This mirrors `tools/import_validator.py` rule for rule (same caps,
/// same required fields, same refusal reasons); the Python test suite
/// runs both implementations against the same fixtures.
///
/// Rules:
///   * File caps: at most 10 MiB, at most 10,000 records, one string
///     field at most 200,000 chars. A bigger file is refused, not
///     truncated.
///   * JSON shape: object with `kind` + `records` (and optional
///     `source`); CSV: header row listing exactly the allowed columns
///     for the kind. `kind` in book|commentary|narrator|grade|source.
///   * Every record must carry a non-empty `source`.
///   * Identifiers are strict: book `id` ^[a-z0-9][a-z0-9_-]{0,63}$,
///     `hadith_key` ^[a-z0-9_]+:\d+$.
///   * Duplicate identity keys inside one file are refused (compared on
///     the Arabic-normalised form, see [normalizeArabic]).
///   * Suspicious content is refused, never executed or stored raw:
///     NUL bytes; path-like fields with `/`, `..`, drive letters or
///     backslashes; shell fragments `$(`, backtick, `${`; newlines in
///     identifier fields; CSV cells starting with `=`, `+`, `-`, `@`
///     (spreadsheet-formula injection); non-string scalars where a
///     string is required; unknown fields (a typo must not silently
///     become a new column).
///   * A narrator `status` without `status_src` is refused: a verdict
///     with no speaker/source is never staged.
///   * Validation never touches production tables and never runs
///     anything from the file: it only reads and checks.
library;

import 'dart:convert';

import '../core/normalize.dart';

/// Maximum import file size (10 MiB).
const int kMaxImportBytes = 10 * 1024 * 1024;

/// Maximum records in one import file.
const int kMaxImportRecords = 10000;

/// Maximum characters in one string field.
const int kMaxImportFieldChars = 200000;

/// Import record kinds.
const Set<String> kImportKinds = <String>{
  'book',
  'commentary',
  'narrator',
  'grade',
  'source',
};

/// Required fields per kind.
const Map<String, List<String>> kImportRequiredFields =
    <String, List<String>>{
  'book': <String>['id', 'name', 'author', 'source', 'license'],
  'commentary': <String>['hadith_key', 'text', 'source'],
  'narrator': <String>['name', 'source'],
  'grade': <String>['hadith_key', 'grader', 'grade', 'source'],
  'source': <String>['name', 'license'],
};

/// Optional fields per kind.
const Map<String, List<String>> kImportOptionalFields =
    <String, List<String>>{
  'book': <String>['short', 'sort'],
  'commentary': <String>['title', 'grade', 'grader'],
  'narrator': <String>[
    'kunya',
    'tier',
    'death_hijri',
    'status',
    'status_src',
    'bio_src',
  ],
  'grade': <String>['grade_raw', 'grade_kind'],
  'source': <String>['type', 'url', 'notes'],
};

final RegExp _bookIdRegExp = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
final RegExp _hadithKeyRegExp = RegExp(r'^[a-z0-9_]+:\d+$');
final RegExp _driveRegExp = RegExp(r'^[A-Za-z]:');
const List<String> _shellFragments = <String>['\$(', '`', r'${'];

/// Validation outcome for one import document.
class ImportValidationResult {
  const ImportValidationResult({
    required this.ok,
    required this.errors,
    required this.recordCount,
    required this.kind,
  });

  final bool ok;
  final List<String> errors;
  final int recordCount;
  final String kind;
}

/// Identity key of one record, used for duplicate detection.
String importIdentityKey(String kind, Map<String, Object?> record) {
  switch (kind) {
    case 'book':
      return "book:${record['id'] ?? ''}";
    case 'commentary':
    case 'grade':
      return "$kind:${record['hadith_key'] ?? ''}";
    case 'narrator':
      return 'narrator:${normalizeArabic((record['name'] ?? '').toString())}';
    case 'source':
      return 'source:${normalizeArabic((record['name'] ?? '').toString())}';
    default:
      return '$kind:?';
  }
}

void _checkStringField(
  List<String> errors,
  String where,
  Object? value, {
  required bool allowNewlines,
}) {
  if (value is! String) {
    errors.add('$where: must be a string');
    return;
  }
  if (value.length > kMaxImportFieldChars) {
    errors.add('$where: exceeds $kMaxImportFieldChars characters');
  }
  if (value.contains('\x00')) {
    errors.add('$where: contains NUL byte');
  }
  if (!allowNewlines && (value.contains('\n') || value.contains('\r'))) {
    errors.add('$where: newlines not allowed in this field');
  }
  for (final frag in _shellFragments) {
    if (value.contains(frag)) {
      errors.add("$where: contains forbidden fragment '$frag'");
      break;
    }
  }
}

void _checkPathField(List<String> errors, String where, Object? value) {
  if (value is! String) {
    errors.add('$where: must be a string');
    return;
  }
  if (value.startsWith('/') ||
      value.startsWith(r'\') ||
      value.contains('..') ||
      value.contains(r'\') ||
      _driveRegExp.hasMatch(value)) {
    errors.add("$where: unsafe path '$value'");
  }
}

/// Validate one record. Returns its errors (empty = valid).
List<String> validateImportRecord(
  String kind,
  Map<String, Object?> record,
  int index,
) {
  final errors = <String>[];
  final where = 'records[$index]';
  final allowed = <String>{
    ...kImportRequiredFields[kind]!,
    ...kImportOptionalFields[kind]!,
  };
  for (final key in record.keys) {
    if (!allowed.contains(key)) {
      errors.add("$where: unknown field '$key'");
    }
  }
  for (final field in kImportRequiredFields[kind]!) {
    final value = record[field];
    if (value == null ||
        (value is String && value.trim().isEmpty)) {
      errors.add("$where: missing required field '$field'");
    }
  }
  for (final entry in record.entries) {
    final field = entry.key;
    final value = entry.value;
    if (field == 'text' || field == 'notes' || field == 'definition') {
      _checkStringField(errors, '$where.$field', value, allowNewlines: true);
    } else if (field == 'file' || field == 'path') {
      _checkPathField(errors, '$where.$field', value);
    } else if (field == 'url') {
      _checkStringField(errors, '$where.$field', value, allowNewlines: false);
      if (value is String &&
          value.isNotEmpty &&
          !value.startsWith('http://') &&
          !value.startsWith('https://')) {
        errors.add('$where.url: must start with http(s)://');
      }
    } else if (value is String) {
      _checkStringField(errors, '$where.$field', value, allowNewlines: false);
    } else if (value is num) {
      // Numeric fields (sort, death_hijri) are fine as-is.
    } else if (value != null) {
      errors.add('$where.$field: unsupported value type');
    }
  }
  if (kind == 'book') {
    final id = record['id'];
    if (id is String && !_bookIdRegExp.hasMatch(id)) {
      errors.add("$where.id: malformed book id '$id'");
    }
  }
  if (kind == 'commentary' || kind == 'grade') {
    final key = record['hadith_key'];
    if (key is String && !_hadithKeyRegExp.hasMatch(key)) {
      errors.add("$where.hadith_key: malformed '$key'");
    }
  }
  if (kind == 'narrator' &&
      record['status'] is String &&
      (record['status'] as String).isNotEmpty &&
      (record['status_src'] == null ||
          (record['status_src'] is String &&
              (record['status_src'] as String).trim().isEmpty))) {
    errors.add('$where: a narrator status without status_src is refused');
  }
  return errors;
}

/// Validate a parsed (kind, records) pair.
ImportValidationResult validateImportDocument(
  String kind,
  List<Map<String, Object?>> records,
) {
  final errors = <String>[];
  if (!kImportKinds.contains(kind)) {
    return ImportValidationResult(
      ok: false,
      errors: <String>['unknown kind $kind'],
      recordCount: 0,
      kind: kind,
    );
  }
  if (records.isEmpty) errors.add('records is empty');
  if (records.length > kMaxImportRecords) {
    errors.add('more than $kMaxImportRecords records');
  }
  final seen = <String>{};
  for (var i = 0; i < records.length; i++) {
    errors.addAll(validateImportRecord(kind, records[i], i));
    final key = importIdentityKey(kind, records[i]);
    if (!seen.add(key)) {
      errors.add("records[$i]: duplicate identity '$key'");
    }
  }
  return ImportValidationResult(
    ok: errors.isEmpty,
    errors: errors,
    recordCount: records.length,
    kind: kind,
  );
}

/// Validate a JSON import document given as a string.
ImportValidationResult validateImportJsonString(String source) {
  if (source.length > kMaxImportBytes) {
    return const ImportValidationResult(
      ok: false,
      errors: <String>['file exceeds $kMaxImportBytes bytes'],
      recordCount: 0,
      kind: '',
    );
  }
  if (source.contains('\x00')) {
    return const ImportValidationResult(
      ok: false,
      errors: <String>['document contains NUL byte'],
      recordCount: 0,
      kind: '',
    );
  }
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } catch (e) {
    return ImportValidationResult(
      ok: false,
      errors: <String>['not valid JSON: $e'],
      recordCount: 0,
      kind: '',
    );
  }
  if (decoded is! Map<String, Object?>) {
    return const ImportValidationResult(
      ok: false,
      errors: <String>['document must be a JSON object'],
      recordCount: 0,
      kind: '',
    );
  }
  final extra = decoded.keys.toSet()
    ..removeAll(<String>{'kind', 'records', 'source'});
  if (extra.isNotEmpty) {
    return ImportValidationResult(
      ok: false,
      errors: <String>['unknown top-level keys: ${extra.join(', ')}'],
      recordCount: 0,
      kind: '',
    );
  }
  final kind = decoded['kind'];
  final records = decoded['records'];
  if (kind is! String) {
    return const ImportValidationResult(
      ok: false,
      errors: <String>['kind is missing'],
      recordCount: 0,
      kind: '',
    );
  }
  if (records is! List) {
    return ImportValidationResult(
      ok: false,
      errors: const <String>['records must be a list'],
      recordCount: 0,
      kind: kind,
    );
  }
  final parsed = <Map<String, Object?>>[];
  for (final r in records) {
    if (r is Map<String, Object?>) {
      parsed.add(r);
    } else {
      return ImportValidationResult(
        ok: false,
        errors: const <String>['records[] entry is not an object'],
        recordCount: 0,
        kind: kind,
      );
    }
  }
  return validateImportDocument(kind, parsed);
}

/// Minimal CSV parser for import files: header row + data rows, quoted
/// cells with `""` escapes, CRLF tolerated. Returns the rows (each a list
/// of cells); a malformed quote is reported in [errors].
List<List<String>> parseImportCsv(String text, List<String> errors) {
  final rows = <List<String>>[];
  final row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      cell.write(ch);
      i++;
      continue;
    }
    if (ch == '"') {
      inQuotes = true;
      i++;
      continue;
    }
    if (ch == ',') {
      row.add(cell.toString());
      cell.clear();
      i++;
      continue;
    }
    if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      rows.add(List<String>.of(row));
      row.clear();
      i++;
      continue;
    }
    cell.write(ch);
    i++;
  }
  if (inQuotes) {
    errors.add('not valid CSV: unterminated quoted cell');
    return rows;
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(List<String>.of(row));
  }
  return rows;
}

/// Parse a CSV import document into records (header → cell maps).
/// Assumes the document already passed [validateImportCsvString].
List<Map<String, Object?>> importRecordsFromCsv(String text) {
  final errors = <String>[];
  final rows = parseImportCsv(text, errors);
  if (rows.isEmpty || errors.isNotEmpty) return <Map<String, Object?>>[];
  final header = rows.first.map((h) => h.trim()).toList();
  final records = <Map<String, Object?>>[];
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    if (row.every((c) => c.trim().isEmpty)) continue;
    if (row.length != header.length) continue;
    records.add(
      <String, Object?>{for (var c = 0; c < header.length; c++) header[c]: row[c]},
    );
  }
  return records;
}

/// Validate a CSV import document (text) for [kind].
ImportValidationResult validateImportCsvString(String text, String kind) {
  if (text.length > kMaxImportBytes) {
    return ImportValidationResult(
      ok: false,
      errors: <String>['file exceeds $kMaxImportBytes bytes'],
      recordCount: 0,
      kind: kind,
    );
  }
  if (text.contains('\x00')) {
    return ImportValidationResult(
      ok: false,
      errors: const <String>['document contains NUL byte'],
      recordCount: 0,
      kind: kind,
    );
  }
  if (!kImportKinds.contains(kind)) {
    return ImportValidationResult(
      ok: false,
      errors: <String>['unknown kind $kind'],
      recordCount: 0,
      kind: kind,
    );
  }
  final parseErrors = <String>[];
  final rows = parseImportCsv(text, parseErrors);
  if (parseErrors.isNotEmpty) {
    return ImportValidationResult(
      ok: false,
      errors: parseErrors,
      recordCount: 0,
      kind: kind,
    );
  }
  if (rows.isEmpty) {
    return const ImportValidationResult(
      ok: false,
      errors: <String>['CSV is empty'],
      recordCount: 0,
      kind: '',
    );
  }
  final header = rows.first.map((h) => h.trim()).toList();
  final allowed = <String>{
    ...kImportRequiredFields[kind]!,
    ...kImportOptionalFields[kind]!,
  };
  final unknown = header.where((h) => !allowed.contains(h)).toList();
  if (unknown.isNotEmpty) {
    return ImportValidationResult(
      ok: false,
      errors: <String>['unknown CSV columns: ${unknown.join(', ')}'],
      recordCount: 0,
      kind: kind,
    );
  }
  final missing = kImportRequiredFields[kind]!
      .where((f) => !header.contains(f))
      .toList();
  if (missing.isNotEmpty) {
    return ImportValidationResult(
      ok: false,
      errors: <String>['missing required CSV columns: ${missing.join(', ')}'],
      recordCount: 0,
      kind: kind,
    );
  }
  final errors = <String>[];
  final records = <Map<String, Object?>>[];
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    if (row.every((c) => c.trim().isEmpty)) continue; // blank line
    if (row.length != header.length) {
      errors.add(
        'line ${r + 1}: ${row.length} cells, expected ${header.length}',
      );
      continue;
    }
    for (var c = 0; c < header.length; c++) {
      final cell = row[c];
      if (cell.startsWith('=') ||
          cell.startsWith('+') ||
          cell.startsWith('-') ||
          cell.startsWith('@')) {
        errors.add(
          "line ${r + 1}, column '${header[c]}': formula-like cell "
          "refused (starts with '${cell[0]}')",
        );
      }
    }
    records.add(
      <String, Object?>{for (var c = 0; c < header.length; c++) header[c]: row[c]},
    );
  }
  if (errors.isNotEmpty) {
    return ImportValidationResult(
      ok: false,
      errors: errors,
      recordCount: records.length,
      kind: kind,
    );
  }
  return validateImportDocument(kind, records);
}

/// Find duplicate identity keys among already-staged records (or any
/// record list): returns the duplicated keys with their positions.
/// Used by the admin panel's duplicate check over `admin_staging`.
Map<String, List<int>> findDuplicateIdentities(
  String kind,
  List<Map<String, Object?>> records,
) {
  final positions = <String, List<int>>{};
  for (var i = 0; i < records.length; i++) {
    final key = importIdentityKey(kind, records[i]);
    positions.putIfAbsent(key, () => <int>[]).add(i);
  }
  positions.removeWhere((_, v) => v.length < 2);
  return positions;
}

/// Fields of a record that are required but missing/empty — the
/// "missing data" check for one staged record.
List<String> findMissingFields(
  String kind,
  Map<String, Object?> record,
) {
  final required = kImportRequiredFields[kind];
  if (required == null) return <String>['unknown kind $kind'];
  return required
      .where(
        (f) =>
            record[f] == null ||
            (record[f] is String && (record[f] as String).trim().isEmpty),
      )
      .toList();
}
