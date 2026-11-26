/// One link of a hadith chain (سند) — Phase 5 model.
///
/// A row of the `chains` table: [position] orders the narrators of one
/// hadith, [narratorId] links to a verified narrator, and [linkType]
/// records the kind of link when the source states it (e.g. `صحابي` for
/// the Companion at the end of the chain). A link whose [narrator] is null
/// is an *unconfirmed* link: the chain row exists but no verified narrator
/// row is attached to it, so the UI shows it as incomplete instead of
/// guessing who it is.
///
/// Position convention (the Phase-5 import must follow it): position 0 is
/// the narrator closest to the book's compiler, and positions increase
/// towards the Prophet ﷺ. Teachers/students derivation in the database
/// relies on this convention.
library;

import 'narrator.dart';

class ChainLink {
  const ChainLink({
    required this.position,
    required this.narratorId,
    required this.narrator,
    required this.linkType,
    required this.source,
    required this.notes,
  });

  factory ChainLink.fromRow(Map<String, Object?> row, {Narrator? narrator}) {
    return ChainLink(
      position: (row['position'] as int?) ?? 0,
      narratorId: row['narrator_id'] as int?,
      narrator: narrator,
      linkType: (row['link_type'] as String?) ?? '',
      source: (row['source'] as String?) ?? '',
      notes: (row['notes'] as String?) ?? '',
    );
  }

  /// Position in the chain (0 = closest to the compiler).
  final int position;

  /// Verified narrator id, or null when the row names no narrator.
  final int? narratorId;

  /// The verified narrator, or null when the link is unconfirmed.
  final Narrator? narrator;

  /// Kind of link as recorded by the source, e.g. `صحابي`.
  final String linkType;

  /// Source of this chain row. Empty when unrecorded.
  final String source;

  /// Notes recorded with the row. Empty when none.
  final String notes;

  /// True only when a verified narrator row is attached.
  bool get isConfirmed => narrator != null && narratorId != null;

  /// True when the source marks this link as a Companion.
  bool get isCompanion => linkType == 'صحابي';

  /// Name to display: the narrator's name, or an honest placeholder.
  String get displayName =>
      narrator != null && narrator!.displayName.isNotEmpty
          ? narrator!.displayName
          : 'راوٍ غير محدد في المصدر';
}
