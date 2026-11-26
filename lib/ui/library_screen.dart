import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/book.dart';
import 'book_screen.dart';
import 'widgets/empty_library.dart';

/// Library screen — the Nine Books as a grid of book-cover cards
/// (جامع الكتب التسعة layout, user decision 2026-11-26 17:26).
///
/// Each book is a cover card: a coloured cover block (identity-family
/// tints — petrol blues, violet-gray, muted gold, rose; NEVER the
/// reference's brown/green/purple covers, and never a green primary —
/// palette decision 2026-11-26 17:26 «أبقِ البترولي وخذ التخطيط بس»)
/// with the short name + a gold divider, then the book name, author
/// and the REAL imported hadith count. Tapping opens the book.
///
/// Only the DESIGN is copied from the reference: names, authors and
/// counts come from the `books` table — never hard-coded here. A book
/// with no imported data is shown dimmed as "قيد الاستيراد" and is NOT
/// openable: tapping it would show an empty list, so it is not a button
/// at all.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.db, required this.userRepo});

  final SunnatiDatabase db;
  final UserRepository userRepo;

  @override
  Widget build(BuildContext context) {
    final books = db.books();
    return Scaffold(
      appBar: AppBar(title: const Text('الكتب التسعة')),
      body: Column(
        children: [
          if (!db.isAvailable)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: EmptyLibraryCard(
                title: 'المكتبة تُبنى',
                detail: db.unavailableReason.isNotEmpty
                    ? db.unavailableReason
                    : 'الكتب التسعة قيد الاستيراد (المرحلتان 2 و3). ستظهر هنا فور اكتمال الاستيراد والتحقق.',
              ),
            ),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              // Tall cover cards: cover block on top, name/author/count
              // below — the reference's 2-column cover grid.
              childAspectRatio: 0.68,
              padding: const EdgeInsets.all(12),
              children: [
                for (final book in books)
                  _BookCard(book: book, db: db, userRepo: userRepo),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Cover colours, one per book in canonical order (index = sort − 1).
/// Identity-family tints only: petrol blues, violet-gray, muted gold,
/// rose — the petrol/ivory/matte-gold identity, no brown, no green.
const List<Color> kBookCoverColors = <Color>[
  Color(0xFF0F3B4D), // petrol
  Color(0xFF14606E), // petrol-teal
  Color(0xFF2E7A96), // petrolLight
  Color(0xFF0A2A38), // deepPetrol
  Color(0xFF2F4A6B), // slate petrol-blue
  Color(0xFF5E5670), // violet-gray
  Color(0xFF6E5A7A), // violet-gray, lighter
  Color(0xFF9A7B3F), // muted dark gold
  Color(0xFFB84A5E), // roseDark (rose accent family)
];

/// Correct Arabic count label for [count] imported hadiths.
String bookCountLabel(int count) {
  if (count == 1) return 'حديث واحد';
  if (count == 2) return 'حديثان';
  if (count >= 3 && count <= 10) return '$count أحاديث';
  return '$count حديثاً';
}

/// One book-cover card: coloured cover block (short name + gold
/// divider) on top, name + author + real count below.
class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.db,
    required this.userRepo,
  });

  final Book book;
  final SunnatiDatabase db;
  final UserRepository userRepo;

  @override
  Widget build(BuildContext context) {
    final color = kBookCoverColors[
        (book.sort - 1) % kBookCoverColors.length];
    final card = Card(
      margin: const EdgeInsets.all(6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              color: color,
              alignment: Alignment.center,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      book.shortName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: 24,
                      height: 2,
                      color: SunnatiColors.gold,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(
              children: [
                Text(
                  book.name,
                  style: SunnatiText.bookTitle,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 2),
                Text(
                  book.author,
                  style: SunnatiText.bookAuthor,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  book.hasData
                      ? bookCountLabel(book.count)
                      : 'قيد الاستيراد',
                  style: const TextStyle(
                    color: SunnatiColors.inkMuted,
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final dimmed = Opacity(
      opacity: book.hasData ? 1.0 : 0.55,
      child: card,
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
