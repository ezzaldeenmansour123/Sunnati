import 'package:material_ui/material_ui.dart';

import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/book.dart';
import 'hadith_reader_screen.dart';
import 'widgets/empty_library.dart';
import 'widgets/sunnati_bottom_nav.dart';

/// One book: its chapters (أبواب) in order, each with its hadith count.
/// Tapping a chapter with hadiths opens the first hadith in the reader;
/// chapters with no imported hadiths are shown, not hidden, but are not
/// tappable — there is nothing to read yet.
class BookScreen extends StatelessWidget {
  const BookScreen({
    super.key,
    required this.db,
    required this.userRepo,
    required this.book,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final Book book;

  @override
  Widget build(BuildContext context) {
    final chapters = db.chapters(book.id);
    return Scaffold(
      appBar: AppBar(title: Text(book.name)),
      // Shared bottom nav (mockup screen 2, the books list: الرئيسية
      // active). Tapping a tab replaces the stack with a fresh shell on
      // that tab — see `sunnatiGoToTab`.
      bottomNavigationBar: SunnatiBottomNav(
        currentIndex: 2,
        onTap: (index) => sunnatiGoToTab(context, index),
      ),
      body: chapters.isEmpty
          ? ListView(
              padding: const EdgeInsets.all(12),
              children: const [
                EmptyLibraryCard(
                  title: 'لا توجد أبواب بعد',
                  detail:
                      'لم تُستورد أبواب هذا الكتاب بعد (المرحلتان 2 و3). لا تُعرض عناوين مخترعة.',
                ),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: chapters.length,
              itemBuilder: (context, i) {
                final chapter = chapters[i];
                return Card(
                  child: ListTile(
                    title: Text(chapter.title),
                    subtitle: Text('${chapter.count} حديثاً'),
                    trailing: chapter.count > 0
                        ? const Icon(Icons.chevron_left)
                        : null,
                    onTap: chapter.count > 0
                        ? () {
                            final hadiths =
                                db.hadithsForChapter(chapter.id);
                            if (hadiths.isNotEmpty) {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => HadithReaderScreen(
                                    db: db,
                                    userRepo: userRepo,
                                    hadith: hadiths.first,
                                    chapterHadiths: hadiths,
                                  ),
                                ),
                              );
                            }
                          }
                        : null,
                  ),
                );
              },
            ),
    );
  }
}
