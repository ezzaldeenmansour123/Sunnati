import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/book.dart';
import 'book_screen.dart';
import 'widgets/empty_library.dart';

/// Library screen: the Nine Books with gold covers (design reference),
/// each showing its actually-imported count. A book with no imported data
/// is shown as "being imported" and is NOT openable — tapping it would
/// show an empty list, so it is not a button at all.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.db, required this.userRepo});

  final SunnatiDatabase db;
  final UserRepository userRepo;

  @override
  Widget build(BuildContext context) {
    final books = db.books();
    return Scaffold(
      appBar: AppBar(title: const Text('المكتبة')),
      body: !db.isAvailable
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                EmptyLibraryCard(
                  title: 'المكتبة تُبنى',
                  detail: db.unavailableReason.isNotEmpty
                      ? db.unavailableReason
                      : 'الكتب التسعة قيد الاستيراد (المرحلتان 2 و3). ستظهر هنا فور اكتمال الاستيراد والتحقق.',
                ),
                const SizedBox(height: 4),
                _BooksGrid(books: books, db: db, userRepo: userRepo, embedded: true),
              ],
            )
          : _BooksGrid(books: books, db: db, userRepo: userRepo),
    );
  }
}

/// The Nine Books as a 3-column grid of gold covers (design reference:
/// the mockup's library is a grid of gold book covers with the name
/// under each cover, not a vertical list). A book with no imported data
/// is shown dimmed as "being imported" and is NOT openable.
class _BooksGrid extends StatelessWidget {
  const _BooksGrid({required this.books, required this.db, required this.userRepo, this.embedded = false});

  final List<Book> books;
  final SunnatiDatabase db;
  final UserRepository userRepo;

  /// True when the grid sits inside another scrollable (the
  /// "library is being built" list) — then it must shrink-wrap and
  /// not scroll itself.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        // Cover (taller than wide) + book name + count line.
        childAspectRatio: 0.62,
      ),
      itemCount: books.length,
      itemBuilder: (context, i) => _BookTile(
        book: books[i],
        db: db,
        userRepo: userRepo,
      ),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book, required this.db, required this.userRepo});

  final Book book;
  final SunnatiDatabase db;
  final UserRepository userRepo;

  @override
  Widget build(BuildContext context) {
    final cover = Column(
      children: [
        Expanded(
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: SunnatiColors.gold,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: SunnatiColors.petrol, width: 1.5),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    book.shortName,
                    style: const TextStyle(
                      color: SunnatiColors.petrol,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: 24,
                    height: 2,
                    color: SunnatiColors.petrol,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          book.name,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          book.hasData
              ? '${book.count} حديثاً'
              : 'قيد الاستيراد',
          style: const TextStyle(color: SunnatiColors.inkMuted, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
    final tile = Opacity(
      opacity: book.hasData ? 1.0 : 0.55,
      child: cover,
    );
    if (!book.hasData) return tile;
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
      borderRadius: BorderRadius.circular(4),
      child: tile,
    );
  }
}
