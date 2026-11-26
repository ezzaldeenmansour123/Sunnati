/// Admin records (Phase 8) — pure Dart models for `admin_staging` and
/// `admin_audit_log` (schema v4).
///
/// The review rule is structural: every staged record starts as
/// `pending_review`; only an explicit review action in the admin panel
/// flips it to `approved` or `rejected`, and every flip writes an audit
/// row. Nothing staged is ever published to a production table by the
/// panel itself.
library;

import 'dart:convert';

/// Review states for a staged record.
class ReviewStatus {
  static const String pending = 'pending_review';
  static const String approved = 'approved';
  static const String rejected = 'rejected';

  static const List<String> all = <String>[pending, approved, rejected];

  /// Arabic label for the panel.
  static String label(String status) {
    switch (status) {
      case pending:
        return 'قيد المراجعة';
      case approved:
        return 'معتمدة بعد المراجعة';
      case rejected:
        return 'مرفوضة';
      default:
        return status;
    }
  }
}

/// One staged admin submission (table `admin_staging`).
class StagedRecord {
  const StagedRecord({
    required this.id,
    required this.kind,
    required this.payloadJson,
    required this.source,
    required this.sha256,
    required this.submittedBy,
    required this.submittedAt,
    required this.reviewStatus,
    this.reviewedBy = '',
    this.reviewedAt = '',
    this.reviewNote = '',
    this.validationErrorsJson = '[]',
  });

  factory StagedRecord.fromRow(Map<String, Object?> row) {
    return StagedRecord(
      id: (row['id'] as int?) ?? 0,
      kind: (row['kind'] as String?) ?? '',
      payloadJson: (row['payload_json'] as String?) ?? '',
      source: (row['source'] as String?) ?? '',
      sha256: (row['sha256'] as String?) ?? '',
      submittedBy: (row['submitted_by'] as String?) ?? '',
      submittedAt: (row['submitted_at'] as String?) ?? '',
      reviewStatus: (row['review_status'] as String?) ?? ReviewStatus.pending,
      reviewedBy: (row['reviewed_by'] as String?) ?? '',
      reviewedAt: (row['reviewed_at'] as String?) ?? '',
      reviewNote: (row['review_note'] as String?) ?? '',
      validationErrorsJson: (row['validation_errors'] as String?) ?? '[]',
    );
  }

  final int id;

  /// book | commentary | narrator | grade | source.
  final String kind;

  /// The validated record JSON (never the raw file).
  final String payloadJson;
  final String source;

  /// SHA-256 of the payload JSON (integrity of the staged record).
  final String sha256;
  final String submittedBy;
  final String submittedAt;
  final String reviewStatus;
  final String reviewedBy;
  final String reviewedAt;
  final String reviewNote;
  final String validationErrorsJson;

  bool get isPending => reviewStatus == ReviewStatus.pending;

  /// The payload as a decoded map (empty map when unparseable — a
  /// corrupt staged row is shown as such, never trusted).
  Map<String, Object?> get payload {
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is Map<String, Object?>) return decoded;
    } catch (_) {}
    return <String, Object?>{};
  }

  /// Short identity for lists (book id / hadith key / narrator name).
  String get identityLabel {
    final p = payload;
    if (p.containsKey('id')) return (p['id'] ?? '').toString();
    if (p.containsKey('hadith_key')) return (p['hadith_key'] ?? '').toString();
    if (p.containsKey('name')) return (p['name'] ?? '').toString();
    return '#$id';
  }
}

/// One audit-log row (table `admin_audit_log`, append-only).
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.createdAt,
    required this.actor,
    required this.action,
    this.entityType = '',
    this.entityId = '',
    this.source = '',
    this.detail = '',
  });

  factory AuditEntry.fromRow(Map<String, Object?> row) {
    return AuditEntry(
      id: (row['id'] as int?) ?? 0,
      createdAt: (row['created_at'] as String?) ?? '',
      actor: (row['actor'] as String?) ?? '',
      action: (row['action'] as String?) ?? '',
      entityType: (row['entity_type'] as String?) ?? '',
      entityId: (row['entity_id'] as String?) ?? '',
      source: (row['source'] as String?) ?? '',
      detail: (row['detail'] as String?) ?? '',
    );
  }

  final int id;
  final String createdAt;
  final String actor;

  /// Action key, e.g. `import_staged`, `import_approved`, `pin_changed`.
  final String action;
  final String entityType;
  final String entityId;
  final String source;
  final String detail;

  /// Arabic label for the panel's audit view.
  static String actionLabel(String action) {
    switch (action) {
      case 'book_defined':
        return 'تعريف كتاب';
      case 'import_staged':
        return 'استيراد إلى المراجعة';
      case 'import_approved':
        return 'اعتماد بعد المراجعة';
      case 'import_rejected':
        return 'رفض بعد المراجعة';
      case 'grade_updated':
        return 'تحديث حكم';
      case 'commentary_added':
        return 'إضافة شرح';
      case 'narrator_added':
        return 'إضافة ترجمة راوٍ';
      case 'source_added':
        return 'إضافة مصدر';
      case 'package_exported':
        return 'إصدار حزمة';
      case 'package_installed':
        return 'تثبيت حزمة';
      case 'package_deleted':
        return 'حذف حزمة';
      case 'reindex':
        return 'إعادة فهرسة';
      case 'pin_changed':
        return 'تغيير رمز الإدارة';
      case 'backup_exported':
        return 'تصدير نسخة احتياطية';
      case 'backup_restored':
        return 'استعادة نسخة احتياطية';
      default:
        return action;
    }
  }
}
