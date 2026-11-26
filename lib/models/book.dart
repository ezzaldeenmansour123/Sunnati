/// A hadith book (one of the Nine Books, plus later extended-library books).
///
/// Metadata only — no hadith text lives here. `count` is the number of
/// hadiths actually imported for this book (0 until Phase 2/3 imports it);
/// a book with `count == 0` is shown as "being imported", never as complete.
library;

class Book {
  const Book({
    required this.id,
    required this.name,
    required this.shortName,
    required this.author,
    required this.sort,
    required this.count,
  });

  factory Book.fromRow(Map<String, Object?> row) {
    return Book(
      id: row['id'] as String,
      name: row['name'] as String,
      shortName: (row['short'] as String?) ?? row['id'] as String,
      author: (row['author'] as String?) ?? '',
      sort: (row['sort'] as int?) ?? 0,
      count: (row['cnt'] as int?) ?? 0,
    );
  }

  /// Stable id, e.g. `bukhari`. Matches `quranlab/hadith` collection names.
  final String id;

  /// Arabic display name, e.g. `صحيح البخاري`.
  final String name;

  /// Short label used on book covers / chips.
  final String shortName;

  /// Author as recorded by the source, e.g. `محمد بن إسماعيل البخاري`.
  final String author;

  /// Display order in the library (1..9 for the Nine Books).
  final int sort;

  /// Hadiths actually present in the installed database.
  final int count;

  /// True only when real hadith rows have been imported for this book.
  bool get hasData => count > 0;
}

/// The Nine Books in canonical order. Used by the library screen and by
/// `tools/build_db.py` (same order, same ids) as the import checklist.
/// No counts are hard-coded here: counts come from the database.
const List<Book> nineBooks = <Book>[
  Book(id: 'bukhari', name: 'صحيح البخاري', shortName: 'البخاري', author: 'محمد بن إسماعيل البخاري', sort: 1, count: 0),
  Book(id: 'muslim', name: 'صحيح مسلم', shortName: 'مسلم', author: 'مسلم بن الحجاج النيسابوري', sort: 2, count: 0),
  Book(id: 'abudawud', name: 'سنن أبي داود', shortName: 'أبو داود', author: 'سليمان بن الأشعث السجستاني', sort: 3, count: 0),
  Book(id: 'tirmidhi', name: 'جامع الترمذي', shortName: 'الترمذي', author: 'محمد بن عيسى الترمذي', sort: 4, count: 0),
  Book(id: 'nasai', name: 'سنن النسائي', shortName: 'النسائي', author: 'أحمد بن شعيب النسائي', sort: 5, count: 0),
  Book(id: 'ibnmajah', name: 'سنن ابن ماجه', shortName: 'ابن ماجه', author: 'محمد بن يزيد ابن ماجه', sort: 6, count: 0),
  Book(id: 'ahmad', name: 'مسند أحمد', shortName: 'أحمد', author: 'أحمد بن حنبل', sort: 7, count: 0),
  Book(id: 'malik', name: 'موطأ مالك', shortName: 'مالك', author: 'مالك بن أنس', sort: 8, count: 0),
  Book(id: 'darimi', name: 'سنن الدارمي', shortName: 'الدارمي', author: 'عبد الله بن عبد الرحمن الدارمي', sort: 9, count: 0),
];

/// A chapter (book / باب) inside a book.
class Chapter {
  const Chapter({
    required this.id,
    required this.bookId,
    required this.num,
    required this.title,
    required this.count,
  });

  factory Chapter.fromRow(Map<String, Object?> row) {
    return Chapter(
      id: (row['id'] as int?) ?? 0,
      bookId: row['book'] as String,
      num: (row['num'] as int?) ?? 0,
      title: (row['title'] as String?) ?? '',
      count: (row['cnt'] as int?) ?? 0,
    );
  }

  final int id;
  final String bookId;
  final int num;
  final String title;
  final int count;
}
