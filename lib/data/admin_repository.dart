/// Admin repository (Phase 8) — PIN store + staging/audit data layer.
///
/// Separation of duties:
///   * [AdminPinStore] keeps the PIN hash + lockout in SharedPreferences
///     only (never in the database, never in plain text).
///   * [AdminRepository] stages validated submissions, reviews them, and
///     writes the append-only audit log — all through [SunnatiDatabase].
///     It NEVER writes a staged record straight into a production table.
///     The one exception is a *book definition* (metadata row in `books`
///     with cnt=0): it is inserted only when its staged record is
///     approved in review, and it carries no hadith/narrator/grade
///     content. Merging approved commentaries / narrators / grades into
///     the library tables is a separate verified import pipeline
///     (Phase 9) — the panel marks them approved and stops there.
///   * Backup/restore of the user's own data goes through here so the
///     size/format guards and the audit row are never skipped.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/admin_pin.dart';
import '../models/admin_record.dart';
import 'database.dart';
import 'import_validator.dart';
import 'user_repository.dart';

/// Maximum backup file accepted on restore (1 MiB — user data is small;
/// anything bigger is not a SUNNATI backup).
const int kMaxBackupBytes = 1024 * 1024;

const String _kAdminPinKey = 'sunnati_admin_pin_v1';
const String _kAdminPinFailuresKey = 'sunnati_admin_pin_failures';
const String _kAdminPinLockedUntilKey = 'sunnati_admin_pin_locked_until';

/// PIN hash + lockout persistence (SharedPreferences only).
class AdminPinStore {
  AdminPinStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<AdminPinStore> load() async {
    return AdminPinStore(await SharedPreferences.getInstance());
  }

  bool get isPinSet => _prefs.getString(_kAdminPinKey) != null;

  PinLockout get lockout => PinLockout(
        failures: _prefs.getInt(_kAdminPinFailuresKey) ?? 0,
        lockedUntilMs: _prefs.getInt(_kAdminPinLockedUntilKey) ?? 0,
      );

  Future<void> _saveLockout(PinLockout state) async {
    await _prefs.setInt(_kAdminPinFailuresKey, state.failures);
    await _prefs.setInt(_kAdminPinLockedUntilKey, state.lockedUntilMs);
  }

  /// Set the PIN for the first time. Throws [ArgumentError] for a weak
  /// PIN (see [pinSetupError]); refuses when a PIN already exists —
  /// use [changePin] instead.
  Future<void> setPin(String pin) async {
    if (isPinSet) {
      throw StateError('Admin PIN is already set — use changePin.');
    }
    await _prefs.setString(_kAdminPinKey, createAdminPinHash(pin));
    await _saveLockout(const PinLockout());
  }

  /// Verify a PIN attempt, honouring the lockout. Returns true only on
  /// a correct PIN while unlocked; records failures and locks after
  /// [kAdminPinMaxAttempts].
  Future<bool> verifyPin(String pin, {int? nowMsOverride}) async {
    final nowMs =
        nowMsOverride ?? DateTime.now().millisecondsSinceEpoch;
    final stored = _prefs.getString(_kAdminPinKey);
    if (stored == null) return false;
    final state = lockout;
    if (state.isLockedAt(nowMs)) return false;
    if (verifyAdminPin(pin, stored)) {
      await _saveLockout(state.cleared);
      return true;
    }
    await _saveLockout(state.recordFailure(nowMs));
    return false;
  }

  /// Change the PIN (requires the current PIN). Returns false when the
  /// current PIN is wrong or the panel is locked.
  Future<bool> changePin(String currentPin, String newPin) async {
    final ok = await verifyPin(currentPin);
    if (!ok) return false;
    await _prefs.setString(_kAdminPinKey, createAdminPinHash(newPin));
    await _saveLockout(const PinLockout());
    return true;
  }
}

/// Admin data operations over the library database.
class AdminRepository {
  AdminRepository(this.db, this.userRepo);

  final SunnatiDatabase db;
  final UserRepository userRepo;

  /// Stage one validated record (JSON object) of [kind]. The record is
  /// validated first; on failure nothing is stored and the errors are
  /// returned. On success the record is stored as `pending_review` and
  /// an audit row is written. Returns the staged row id, or -1 + errors.
  Future<(int, ImportValidationResult)> stageRecord(
    String kind,
    Map<String, Object?> record,
    String source,
  ) async {
    final validation = validateImportDocument(kind, <Map<String, Object?>>[
      record,
    ]);
    if (!validation.ok) return (-1, validation);
    final payloadJson = jsonEncode(record);
    final sha = sha256.convert(utf8.encode(payloadJson)).toString();
    final id = db.stageInsert(
      kind: kind,
      payloadJson: payloadJson,
      source: source.isEmpty
          ? (record['source'] ?? '').toString()
          : source,
      sha256: sha,
      validationErrorsJson: '[]',
    );
    db.auditInsert(
      action: 'import_staged',
      entityType: kind,
      entityId: id.toString(),
      source: source,
      detail: 'staged ${importIdentityKey(kind, record)} as pending_review',
    );
    return (id, validation);
  }

  /// Stage a whole validated document (JSON string or CSV text).
  /// Returns (staged ids, validation). A document that fails validation
  /// stages nothing.
  Future<(List<int>, ImportValidationResult)> stageDocument(
    String text, {
    required bool isCsv,
    String csvKind = '',
  }) async {
    final validation = isCsv
        ? validateImportCsvString(text, csvKind)
        : validateImportJsonString(text);
    if (!validation.ok) return (<int>[], validation);
    final records = isCsv
        ? importRecordsFromCsv(text)
        : (jsonDecode(text)['records'] as List)
            .cast<Map<String, Object?>>();
    final ids = <int>[];
    for (final record in records) {
      final (id, _) =
          await stageRecord(validation.kind, record, '');
      if (id < 0) return (<int>[], validation);
      ids.add(id);
    }
    return (ids, validation);
  }

  /// Review a staged record. Approving a *book definition* inserts its
  /// metadata row into `books` (cnt=0 — definition only, no content).
  /// Approving any other kind only flips the review status: the merge
  /// into production tables belongs to the verified import pipeline
  /// (Phase 9) and is NOT done here. Every review writes an audit row.
  Future<bool> reviewStaged(
    int stagedId, {
    required bool approve,
    String note = '',
    String reviewedBy = 'admin',
  }) async {
    final record = db.stagingById(stagedId);
    if (record == null || !record.isPending) return false;
    final now = DateTime.now().toUtc().toIso8601String();
    final status =
        approve ? ReviewStatus.approved : ReviewStatus.rejected;
    db.stagingReview(
      id: stagedId,
      status: status,
      reviewedBy: reviewedBy,
      reviewedAt: now,
      note: note,
    );
    if (approve && record.kind == 'book') {
      final payload = record.payload;
      final id = (payload['id'] ?? '').toString();
      final name = (payload['name'] ?? '').toString();
      if (id.isNotEmpty && name.isNotEmpty && db.bookById(id) == null) {
        db.defineBook(
          id: id,
          name: name,
          shortName: (payload['short'] ?? id).toString(),
          author: (payload['author'] ?? '').toString(),
          source: record.source,
          license: (payload['license'] ?? '').toString(),
        );
      }
    }
    db.auditInsert(
      action: approve ? 'import_approved' : 'import_rejected',
      entityType: record.kind,
      entityId: stagedId.toString(),
      source: record.source,
      detail: approve
          ? 'approved ${record.identityLabel}'
              '${record.kind == 'book' ? ' — book definition added (cnt=0)' : ' — merge pending the verified import pipeline'}'
          : 'rejected ${record.identityLabel}: $note',
    );
    return true;
  }

  /// Counts for the panel overview: pending/approved/rejected staged
  /// records, audit rows, installed packages, narrator rows.
  Map<String, int> stats() => db.adminStats();

  /// Duplicate identity keys among staged records of [kind].
  Map<String, List<int>> duplicateCheck(String kind) {
    final records = db.stagingList(kind: kind, limit: 10000);
    final payloads =
        records.map((r) => r.payload).toList();
    return findDuplicateIdentities(kind, payloads);
  }

  /// Staged pending records whose payload is missing a required field
  /// (defence in depth — validation should already have refused them).
  List<(int, List<String>)> missingFieldsReport() {
    final out = <(int, List<String>)>[];
    for (final record
        in db.stagingList(status: ReviewStatus.pending, limit: 10000)) {
      final missing = findMissingFields(record.kind, record.payload);
      if (missing.isNotEmpty) out.add((record.id, missing));
    }
    return out;
  }

  /// Rebuild the FTS5 search index (after a verified import). Audited.
  Future<void> rebuildSearchIndex() async {
    db.rebuildSearchIndex();
    db.auditInsert(
      action: 'reindex',
      detail: 'FTS5 index rebuilt by admin',
    );
  }

  /// Export the user's own data as a backup string (audited).
  String exportBackup() {
    final json = userRepo.exportJson();
    db.auditInsert(action: 'backup_exported', detail: 'user data backup');
    return json;
  }

  /// Restore user data from a backup string. The backup is size- and
  /// format-checked BEFORE anything is replaced; on failure the
  /// existing data is untouched.
  Future<void> restoreBackup(String source) async {
    if (source.length > kMaxBackupBytes) {
      throw const FormatException('Backup is too large to be a SUNNATI backup');
    }
    await userRepo.importJson(source);
    db.auditInsert(action: 'backup_restored', detail: 'user data restored');
  }
}
