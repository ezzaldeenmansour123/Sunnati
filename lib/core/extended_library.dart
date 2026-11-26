/// Extended-library catalogue (master prompt §6, Phase 7).
///
/// The extended library is PREPARATION ONLY: these books and collections
/// have no imported, verified data yet, so they are listed honestly as
/// "preparing — not available yet", with NO download button, NO size and
/// NO download URL. A size or a URL shown here would be invented data.
///
/// An entry graduates from this catalogue to a real downloadable package
/// only when: its data has been imported, verified and licensed, a
/// package has been built with `tools/build_package.py`, and its manifest
/// (see `lib/core/package_manifest.dart`) validates. Until then the
/// downloads screen shows exactly what this file says — nothing more.
library;

/// One extended-library entry: a book, or a whole collection category
/// (commentaries, gharib, rijal, ...). Categories deliberately carry no
/// author and no book list — naming individual titles before their data
/// exists would be inventing content.
class ExtendedLibrary {
  const ExtendedLibrary({
    required this.id,
    required this.name,
    required this.author,
    required this.kind,
  });

  /// Stable id, e.g. `darqutni`. Matches the future package library_id.
  final String id;

  /// Arabic display name.
  final String name;

  /// Author as recorded by the heritage tradition, or '' for a category.
  final String author;

  /// 'book' for a single book, 'collection' for a category of books.
  final String kind;

  /// True only for a single book (categories group many books).
  bool get isBook => kind == 'book';
}

/// The eight extended books named in the master prompt §6, in the order
/// they are listed there, plus the six collection categories — all
/// preparation-only. No sizes, no URLs, no licences are recorded here:
/// a licence is only known once a concrete source edition is verified.
const List<ExtendedLibrary> extendedLibraries = <ExtendedLibrary>[
  // --- Books (master prompt §6) ---
  ExtendedLibrary(
    id: 'muwatta_muhammad',
    name: 'موطأ محمد',
    author: 'محمد بن الحسن الشيباني',
    kind: 'book',
  ),
  ExtendedLibrary(
    id: 'musannaf_abd_alrazzaq',
    name: 'مصنف عبد الرزاق',
    author: 'عبد الرزاق بن همام الصنعاني',
    kind: 'book',
  ),
  ExtendedLibrary(
    id: 'musannaf_ibn_abi_shayba',
    name: 'مصنف ابن أبي شيبة',
    author: 'عبد الله بن محمد ابن أبي شيبة',
    kind: 'book',
  ),
  ExtendedLibrary(
    id: 'musnad_abi_yala',
    name: 'مسند أبي يعلى',
    author: 'أحمد بن علي أبو يعلى الموصلي',
    kind: 'book',
  ),
  ExtendedLibrary(
    id: 'musnad_albazzar',
    name: 'مسند البزار',
    author: 'أحمد بن عمرو البزار',
    kind: 'book',
  ),
  ExtendedLibrary(
    id: 'sunan_darqutni',
    name: 'سنن الدارقطني',
    author: 'علي بن عمر الدارقطني',
    kind: 'book',
  ),
  ExtendedLibrary(
    id: 'sunan_kubra_bayhaqi',
    name: 'السنن الكبرى للبيهقي',
    author: 'أحمد بن الحسين البيهقي',
    kind: 'book',
  ),
  ExtendedLibrary(
    id: 'mustadrak_hakim',
    name: 'المستدرك على الصحيحين للحاكم',
    author: 'محمد بن عبد الله الحاكم النيسابوري',
    kind: 'book',
  ),
  // --- Collection categories (master prompt §6): preparation only.
  // No individual titles are named — the data does not exist yet.
  ExtendedLibrary(
    id: 'collection_commentaries',
    name: 'كتب الشروح',
    author: '',
    kind: 'collection',
  ),
  ExtendedLibrary(
    id: 'collection_gharib',
    name: 'كتب غريب الحديث',
    author: '',
    kind: 'collection',
  ),
  ExtendedLibrary(
    id: 'collection_rijal',
    name: 'كتب الرجال',
    author: '',
    kind: 'collection',
  ),
  ExtendedLibrary(
    id: 'collection_ilal',
    name: 'كتب العلل',
    author: '',
    kind: 'collection',
  ),
  ExtendedLibrary(
    id: 'collection_takhrij',
    name: 'كتب التخريج',
    author: '',
    kind: 'collection',
  ),
  ExtendedLibrary(
    id: 'collection_mustalah',
    name: 'كتب المصطلح',
    author: '',
    kind: 'collection',
  ),
];

/// Arabic status label shown for every catalogue entry until real data
/// exists. One label, shared by the downloads screen and the admin panel,
/// so the two can never disagree about availability.
const String extendedLibraryPreparingLabel = 'قيد التجهيز — غير متاحة بعد';
