import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/book.dart';
import 'book_screen.dart';
import 'widgets/empty_library.dart';

/// Library screen — mockup screen 2, reproduced faithfully in structure:
/// a LIST (not a grid) of the Nine Books, each row with a gold book-cover
/// thumbnail drawn in code, the book name + author from the database, and
/// a chevron; tapping opens the book.
///
/// Only the DESIGN is copied from the mockup: names, authors and counts
/// come from the `books` table — never hard-coded here. A book with no
/// imported data is shown dimmed as "قيد الاستيراد" and is NOT openable:
/// tapping it would show an empty list, so it is not a button at all.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.db, required this.userRepo});

  final SunnatiDatabase db;
  final UserRepository userRepo;

  @override
  Widget build(BuildContext context) {
    final books = db.books();
    return Scaffold(
      appBar: AppBar(title: const Text('الكتب التسعة')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          if (!db.isAvailable)
            EmptyLibraryCard(
              title: 'المكتبة تُبنى',
              detail: db.unavailableReason.isNotEmpty
                  ? db.unavailableReason
                  : 'الكتب التسعة قيد الاستيراد (المرحلتان 2 و3). ستظهر هنا فور اكتمال الاستيراد والتحقق.',
            ),
          for (final book in books)
            _BookRow(book: book, db: db, userRepo: userRepo),
        ],
      ),
    );
  }
}

/// One row of the Nine Books list: gold cover (right, RTL leading),
/// name + author centred, chevron (left, RTL trailing).
class _BookRow extends StatelessWidget {
  const _BookRow({
    required this.book,
    required this.db,
    required this.userRepo,
  });

  final Book book;
  final SunnatiDatabase db;
  final UserRepository userRepo;

  @override
  Widget build(BuildContext context) {
    final row = Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Gold cover thumbnail, drawn in code — no image asset.
            _GoldCover(shortName: book.shortName),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    book.name,
                    style: SunnatiText.bookTitle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    book.author,
                    style: SunnatiText.bookAuthor,
                    textAlign: TextAlign.center,
                  ),
                  if (!book.hasData) ...[
                    const SizedBox(height: 2),
                    const Text(
                      'قيد الاستيراد',
                      style: TextStyle(
                        color: SunnatiColors.inkMuted,
                        fontSize: 11,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_left,
              color: book.hasData
                  ? SunnatiColors.neutral
                  : SunnatiColors.neutral.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
    final dimmed = Opacity(
      opacity: book.hasData ? 1.0 : 0.55,
      child: row,
    );
    if (!book.hasData) return dimmed;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BookScreen(
            db: db,
            userRepo: userRepo,
            book: book,
          ),
        ),
      ),
      borderRadius: BorderRadius.circular(12),
      child: dimmed,
    );
  }
}

/// Gold book cover drawn in code (matte gold, petrol border, short name
/// + divider line) — the same cover style the library used before, now
/// as a small list thumbnail instead of a grid tile.
class _GoldCover extends StatelessWidget {
  const _GoldCover({required this.shortName});

  final String shortName;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 68,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: SunnatiColors.gold,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: SunnatiColors.petrol, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              shortName,
              style: const TextStyle(
                color: SunnatiColors.petrol,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Container(
              width: 20,
              height: 2,
              color: SunnatiColors.petrol,
            ),
          ],
        ),
      ),
    );
  }
}
