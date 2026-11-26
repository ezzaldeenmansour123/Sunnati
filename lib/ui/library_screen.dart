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
              padding: const EdgeInsets.all(12),
              children: [
                EmptyLibraryCard(
                  title: 'المكتبة تُبنى',
                  detail: db.unavailableReason.isNotEmpty
                      ? db.unavailableReason
                      : 'الكتب التسعة قيد الاستيراد (المرحلتان 2 و3). ستظهر هنا فور اكتمال الاستيراد والتحقق.',
                ),
                const SizedBox(height: 4),
                ...books.map((b) => _BookTile(
                      book: b,
                      db: db,
                      userRepo: userRepo,
                    )),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: books.length,
              itemBuilder: (context, i) => _BookTile(
                book: books[i],
                db: db,
                userRepo: userRepo,
              ),
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
    return Card(
      child: ListTile(
        leading: Container(
          width: 46,
          height: 60,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: SunnatiColors.petrol,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: SunnatiColors.gold, width: 1.5),
          ),
          child: Text(
            book.shortName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        title: Text(book.name),
        subtitle: Text(
          book.hasData
              ? '${book.count} حديثاً — ${book.author}'
              : 'قيد الاستيراد — ${book.author}',
          style: const TextStyle(color: SunnatiColors.inkMuted),
        ),
        trailing: book.hasData
            ? const Icon(Icons.chevron_left, color: SunnatiColors.gold)
            : null,
        onTap: book.hasData
            ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BookScreen(
                      db: db,
                      userRepo: userRepo,
                      book: book,
                    ),
                  ),
                )
            : null,
      ),
    );
  }
}
