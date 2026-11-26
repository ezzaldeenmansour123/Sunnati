import 'package:material_ui/material_ui.dart';

import '../core/narrator_logic.dart';
import '../core/normalize.dart';
import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/book.dart';
import '../models/hadith.dart';
import '../models/narrator.dart';
import '../search/search_service.dart';
import 'book_screen.dart';
import 'hadith_reader_screen.dart';
import 'widgets/empty_library.dart';
import 'widgets/isnad_text.dart';
import 'widgets/untranslated_tag.dart';

/// Advanced search — layout of mockup screen 4 (2026-11-26), with the
/// «جامع الكتب التسعة» search-2.0 tab structure (user decision
/// 2026-11-26 17:26): four tabs — الحديث / الرواة / الأبواب / الموضوع.
/// There is NO المشكاة tab (that book is not in this library at all),
/// and the الموضوع tab shows an honest empty state (topics = 0 rows).
///
/// The mockup is the «جامع الكتب التسعة» search interface, and the user
/// asked (2026-11-26 15:25) for SUNNATI's screens to match those
/// interfaces exactly — same structure, same layout, same flow. The
/// الحديث tab reproduces screen 4's layout faithfully:
///   - search box «ابحث عن حديث أو راوٍ...» with a clear (×) button;
///   - «خيارات البحث» header;
///   - four filter rows: في الكتب / في الأبواب / رقم الحديث / الراوي;
///   - a pink «بحث» button;
///   - «نتائج البحث (N)» header and result cards (matn snippet + book
///     + hadith number).
///
/// ONLY the design/layout is copied. The content stays the verified
/// local database: the books and chapters come from the real installed
/// library, the narrator picker lists only the verified narrators
/// actually installed, the result count is the real SQL COUNT of the
/// query (never the mockup's illustrative number), and the search
/// itself is the existing [SearchService] (FTS5/lexical) — no new
/// search engine was written.
///
/// Honest limits, shown in the UI where they apply:
///   - chapter titles are English in the source (never translated or
///     invented in Arabic) — an untranslated title carries a visible
///     «غير مترجم» tag in the الأبواب tab;
///   - the narrator picker is available only when the verified
///     narrators package is installed; while the KITAB gate holds it
///     back the row honestly says «حزمة الرواة بانتظار الموافقة» and
///     no unlinked name is ever searched as if verified;
///   - a hadith number jumps to that hadith in the chosen book, and
///     says honestly when no such number exists in that book;
///   - tapping a narrator anywhere in search shows ONLY his status +
///     source as an inline red line under the row — never the full
///     details page (that page lives only in the narrators
///     encyclopedia, user decision 2026-11-26 17:23).
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.db});

  final SunnatiDatabase db;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// Search scope tabs, in reference order (RTL: الحديث first).
enum _SearchTab { hadith, narrators, chapters, topics }

const Map<_SearchTab, String> _searchTabLabels = <_SearchTab, String>{
  _SearchTab.hadith: 'الحديث',
  _SearchTab.narrators: 'الرواة',
  _SearchTab.chapters: 'الأبواب',
  _SearchTab.topics: 'الموضوع',
};

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _numberController = TextEditingController();
  final _narratorQueryController = TextEditingController();
  final _chapterQueryController = TextEditingController();
  String? _bookId;
  int? _chapterId;
  List<Chapter> _chapters = const <Chapter>[];

  /// Active search-scope tab (default: الحديث — the mockup screen).
  _SearchTab _tab = _SearchTab.hadith;

  /// Book filter of the الأبواب tab (null: all books).
  String? _chapterBookId;

  /// Index of the tapped narrator row in the الرواة tab (null: none).
  /// The status + source line is shown right under that row, inline.
  int? _narratorSelected;

  /// Display name of the verified narrator picked from the picker, or
  /// null when none is picked. Only a name from the verified installed
  /// list is ever searched — never a typed unlinked name.
  String? _narratorName;

  SearchPage<SearchHit>? _page;
  bool _searched = false;
  int _pageNumber = 1;

  /// Set when a number jump found no hadith in the chosen book.
  String _numberNotFound = '';

  late final SearchService _search = SearchService(widget.db);

  SearchQuery get _currentQuery {
    return SearchQuery(
      text: _controller.text,
      bookId: _bookId,
      chapterId: _chapterId,
      narrator: _narratorName ?? '',
      page: _pageNumber,
    );
  }

  void _run({int page = 1}) {
    _pageNumber = page;
    final numberText = _numberController.text.trim();
    final number = int.tryParse(numberText);
    if (number != null) {
      // Hadith number: jump to that hadith in the chosen book.
      if (_bookId != null) {
        final one = widget.db.hadithByNumber(_bookId!, number);
        if (one != null) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _ReaderOpener(db: widget.db, hadith: one),
            ),
          );
          return;
        }
        setState(() {
          _numberNotFound =
              'لا يوجد حديث رقم $number في ${_bookName(_bookId!)}.';
          _page = const SearchPage<SearchHit>(
            items: <SearchHit>[],
            total: 0,
            page: 1,
            pageSize: kDefaultPageSize,
          );
          _searched = true;
        });
        return;
      }
      // No book chosen: numeric search across all books (existing
      // SearchService numeric path).
      setState(() {
        _numberNotFound = '';
        _page = _search.search(
          SearchQuery(text: numberText, page: _pageNumber),
        );
        _searched = true;
      });
      return;
    }
    setState(() {
      _numberNotFound = '';
      _page = _search.search(_currentQuery);
      _searched = true;
    });
  }

  void _loadChapters() {
    if (_bookId == null) {
      setState(() {
        _chapters = const <Chapter>[];
        _chapterId = null;
      });
      return;
    }
    setState(() {
      _chapters = widget.db.chapters(_bookId!);
      if (_chapterId != null && !_chapters.any((c) => c.id == _chapterId)) {
        _chapterId = null;
      }
    });
  }

  String _bookName(String bookId) {
    for (final b in widget.db.books()) {
      if (b.id == bookId) return b.name;
    }
    return bookId;
  }

  /// Narrator picker: verified installed narrators only. When the
  /// narrators package is held back (KITAB gate) the picker never
  /// opens — the row explains why instead.
  Future<void> _pickNarrator() async {
    if (!widget.db.narratorsAvailable) {
      final reason = widget.db.narratorsUnavailableReason.isNotEmpty
          ? widget.db.narratorsUnavailableReason
          : kNarratorsPendingApprovalMessage;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('الراوي'),
          content: Text(reason),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
      return;
    }
    final picked = await showDialog<String?>(
      context: context,
      builder: (context) => _NarratorPickerDialog(db: widget.db),
    );
    if (picked != null && mounted) {
      setState(() => _narratorName = picked.isEmpty ? null : picked);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _numberController.dispose();
    _narratorQueryController.dispose();
    _chapterQueryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final books = widget.db.books().where((b) => b.hasData).toList();
    final page = _page;
    return Scaffold(
      appBar: AppBar(title: const Text('البحث')),
      body: Column(
        children: [
          _buildTabRow(),
          Expanded(child: _buildTabContent(books, page)),
          if (_tab == _SearchTab.hadith &&
              _searched &&
              page != null &&
              _numberNotFound.isEmpty)
            _buildPagination(page.total, page.totalPages, page.hasMore),
        ],
      ),
    );
  }

  /// The search-2.0 tab row (الحديث / الرواة / الأبواب / الموضوع).
  Widget _buildTabRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final tab in _SearchTab.values)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: _SearchTabPill(
                  label: _searchTabLabels[tab]!,
                  selected: _tab == tab,
                  onTap: () => setState(() => _tab = tab),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabContent(List<Book> books, SearchPage<SearchHit>? page) {
    switch (_tab) {
      case _SearchTab.hadith:
        return _buildHadithTab(books, page);
      case _SearchTab.narrators:
        return _buildNarratorsTab();
      case _SearchTab.chapters:
        return _buildChaptersTab(books);
      case _SearchTab.topics:
        return _buildTopicsTab();
    }
  }

  /// الحديث tab: the mockup screen-4 advanced search, unchanged.
  Widget _buildHadithTab(List<Book> books, SearchPage<SearchHit>? page) {
    return ListView(
      padding: const EdgeInsets.all(12),
      // Smoothness fix 2026-11-26 (review §3): pre-render
      // off-screen result rows. NO itemExtent: result rows are NOT
      // fixed-height — the matn snippet is up to 3 lines and the
      // subtitle wraps — so a fixed extent would break the layout.
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      children: [
        _buildSearchBox(),
        const SizedBox(height: 12),
        _buildOptionsHeader(),
        const SizedBox(height: 8),
        _buildBookRow(books),
        _buildChapterRow(),
        _buildNumberRow(),
        _buildNarratorRow(),
        const SizedBox(height: 4),
        _buildSearchButton(),
        const SizedBox(height: 12),
        if (!_searched)
          const Center(
            child: Text(
              'اكتب كلمة أو جملة، أو اختر كتاباً وباباً ورقم '
              'حديث أو راوياً، ثم اضغط «بحث».',
            ),
          )
        else if (page != null)
          _buildResults(page),
      ],
    );
  }

  /// الرواة tab: search the verified installed narrators only.
  /// Tapping a row shows ONLY his status + source as an inline red
  /// line under the row — never the full details page (that page lives
  /// only in the narrators encyclopedia).
  Widget _buildNarratorsTab() {
    if (!widget.db.narratorsAvailable) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          EmptyLibraryCard(
            title: 'البحث في الرواة غير متوفر بعد',
            detail: widget.db.narratorsUnavailableReason.isNotEmpty
                ? widget.db.narratorsUnavailableReason
                : kNarratorsPendingApprovalMessage,
          ),
        ],
      );
    }
    final query = _narratorQueryController.text.trim();
    final results = query.isEmpty
        ? widget.db.listNarrators(limit: 100)
        : widget.db.searchNarrators(query);
    return ListView(
      padding: const EdgeInsets.all(12),
      // Smoothness fix 2026-11-26 (review §3): pre-render
      // off-screen narrator rows. NO itemExtent: rows are NOT
      // fixed-height (status subtitle wraps).
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      children: [
        TextField(
          controller: _narratorQueryController,
          decoration: const InputDecoration(
            hintText: 'ابحث باسم الراوي...',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() => _narratorSelected = null),
        ),
        const SizedBox(height: 8),
        if (results.isEmpty)
          const Center(child: Text('لا يوجد راوٍ موثّق بهذا الاسم.'))
        else
          for (var i = 0; i < results.length; i++)
            Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    dense: true,
                    title: Text(results[i].displayName),
                    subtitle: results[i].hasStatus
                        ? Text(
                            '${results[i].status} — ${results[i].statusSource}',
                          )
                        : null,
                    onTap: () => setState(
                      () => _narratorSelected =
                          _narratorSelected == i ? null : i,
                    ),
                  ),
                  if (_narratorSelected == i)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: Text(
                        inlineStatusLineText(
                          inlineStatusForTap(
                            name: results[i].displayName,
                            outcome: NarratorTapOutcome.showStatus,
                            status: results[i].status,
                            statusSource: results[i].statusSource,
                          ),
                        ),
                        style: isnadInlineStatusStyle(context),
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }

  /// الأبواب tab: search chapter titles across the installed books.
  /// An untranslated (English) title carries the visible «غير مترجم»
  /// tag — never presented as an Arabic باب, never replaced by an
  /// invented Arabic title. Tapping a chapter opens its book.
  Widget _buildChaptersTab(List<Book> books) {
    final query = _chapterQueryController.text.trim();
    final matches = <({Book book, Chapter chapter})>[];
    if (query.isNotEmpty) {
      final needle = query.toLowerCase();
      final normNeedle = normalizeArabic(query);
      final bookIds = _chapterBookId == null
          ? books.map((b) => b.id)
          : <String>[_chapterBookId!];
      for (final bookId in bookIds) {
        final book =
            books.where((b) => b.id == bookId).firstOrNull;
        if (book == null) continue;
        for (final chapter in widget.db.chapters(bookId)) {
          final title = chapter.title;
          final hit = title.toLowerCase().contains(needle) ||
              (normNeedle.isNotEmpty &&
                  normalizeArabic(title).contains(normNeedle));
          if (hit) matches.add((book: book, chapter: chapter));
          if (matches.length >= 100) break;
        }
        if (matches.length >= 100) break;
      }
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      // Smoothness fix 2026-11-26 (review §3): pre-render
      // off-screen chapter rows. NO itemExtent: chapter titles wrap
      // to several lines, so rows are NOT fixed-height.
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      children: [
        DropdownButton<String?>(
          isExpanded: true,
          value: _chapterBookId,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('جميع الكتب'),
            ),
            ...books.map(
              (b) => DropdownMenuItem<String?>(
                value: b.id,
                child: Text(b.name),
              ),
            ),
          ],
          onChanged: (v) => setState(() => _chapterBookId = v),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _chapterQueryController,
          decoration: const InputDecoration(
            hintText: 'ابحث في عناوين الأبواب...',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        if (query.isEmpty)
          const Center(
            child: Text('اكتب كلمة للبحث في عناوين الأبواب.'),
          )
        else if (matches.isEmpty)
          const Center(child: Text('لا توجد أبواب مطابقة.'))
        else ...[
          Text(
            'الأبواب (${matches.length})',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          for (final m in matches)
            Card(
              child: ListTile(
                title: Row(
                  children: [
                    Expanded(child: Text(m.chapter.title)),
                    if (isUntranslatedChapterTitle(m.chapter.title))
                      const UntranslatedChapterTag(),
                  ],
                ),
                subtitle: Text(m.book.name),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _BookOpener(db: widget.db, book: m.book),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// الموضوع tab: the topics table is empty (0 rows) — honest empty
  /// state, never invented topics.
  Widget _buildTopicsTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: const [
        EmptyLibraryCard(
          title: 'لا توجد مواضيع مستوردة بعد',
          detail:
              'شجرة المواضيع قيد الإعداد — جدول المواضيع فارغ في المكتبة المثبّتة، فلا يُعرض هنا أي موضوع غير موثّق.',
          icon: Icons.account_tree_outlined,
        ),
      ],
    );
  }

  /// Search box exactly as in mockup screen 4: hint «ابحث عن حديث أو
  /// راوٍ...», magnifier icon, clear (×) button.
  Widget _buildSearchBox() {
    return TextField(
      controller: _controller,
      decoration: InputDecoration(
        hintText: 'ابحث عن حديث أو راوٍ...',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'مسح البحث',
          onPressed: () {
            _controller.clear();
            setState(() {});
          },
        ),
        border: const OutlineInputBorder(),
      ),
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _run(),
    );
  }

  Widget _buildOptionsHeader() {
    return const Row(
      children: [
        Icon(Icons.tune, color: SunnatiColors.petrol),
        SizedBox(width: 8),
        Text(
          'خيارات البحث',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ],
    );
  }

  /// One mockup filter row: label + icon on the right, control on the
  /// left (RTL row order), inside a bordered rounded container.
  Widget _filterRow({
    required IconData icon,
    required String label,
    required Widget child,
    VoidCallback? onTap,
  }) {
    final row = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: SunnatiColors.petrol),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: row,
    );
  }

  Widget _buildBookRow(List<Book> books) {
    return _filterRow(
      icon: Icons.menu_book,
      label: 'في الكتب',
      child: DropdownButton<String?>(
        isExpanded: true,
        underline: const SizedBox.shrink(),
        value: _bookId,
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('جميع الكتب'),
          ),
          ...books.map(
            (b) => DropdownMenuItem<String?>(
              value: b.id,
              child: Text(b.name),
            ),
          ),
        ],
        onChanged: (v) {
          setState(() => _bookId = v);
          _loadChapters();
        },
      ),
    );
  }

  Widget _buildChapterRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _filterRow(
          icon: Icons.list,
          label: 'في الأبواب',
          child: DropdownButton<int?>(
            isExpanded: true,
            underline: const SizedBox.shrink(),
            value: _chapterId,
            hint: Text(_bookId == null ? 'اختر كتاباً أولاً' : 'جميع الأبواب'),
            items: [
              const DropdownMenuItem<int?>(
                value: null,
                child: Text('جميع الأبواب'),
              ),
              ..._chapters.map(
                (c) => DropdownMenuItem<int?>(
                  value: c.id,
                  child: Text(c.title),
                ),
              ),
            ],
            onChanged: _bookId == null
                ? null
                : (v) => setState(() => _chapterId = v),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text(
            'عناوين الأبواب إنجليزية في المصدر (لم تُترجم ولم تُخترع '
            'عناوين عربية).',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildNumberRow() {
    return _filterRow(
      icon: Icons.tag,
      label: 'رقم الحديث',
      child: TextField(
        controller: _numberController,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          hintText: '...',
          border: InputBorder.none,
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _run(),
      ),
    );
  }

  Widget _buildNarratorRow() {
    final available = widget.db.narratorsAvailable;
    final label = !available
        ? 'حزمة الرواة بانتظار الموافقة'
        : (_narratorName ?? 'اختر راوياً');
    return _filterRow(
      icon: Icons.person,
      label: 'الراوي',
      onTap: _pickNarrator,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: available
                    ? Theme.of(context).textTheme.bodyMedium?.color
                    : SunnatiColors.inkMuted,
              ),
            ),
          ),
          if (_narratorName != null)
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: 'مسح اختيار الراوي',
              onPressed: () => setState(() => _narratorName = null),
            )
          else
            const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }

  /// Pink «بحث» button, as in mockup screen 4 (pink accent on the
  /// petrol/ivory/gold identity — the theme's blush pink).
  Widget _buildSearchButton() {
    return FilledButton.icon(
      onPressed: () => _run(),
      style: FilledButton.styleFrom(
        backgroundColor: SunnatiColors.blush,
        foregroundColor: SunnatiColors.petrol,
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      icon: const Icon(Icons.search),
      label: const Text(
        'بحث',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
      ),
    );
  }

  Widget _buildResults(SearchPage<SearchHit> page) {
    if (!widget.db.isAvailable) {
      return const EmptyLibraryCard(
        title: 'البحث غير متوفر بعد',
        detail: 'المكتبة قيد الاستيراد — لا توجد نصوص للبحث فيها بعد.',
      );
    }
    if (_numberNotFound.isNotEmpty) {
      return Center(child: Text(_numberNotFound));
    }
    if (page.items.isEmpty) {
      return const Center(child: Text('لا توجد نتائج مطابقة.'));
    }
    final note = page.semanticNote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Real result count from the query — never an invented number.
        Text(
          'نتائج البحث (${page.total})',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 8),
        if (note.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(note),
            ),
          ),
        ...page.items.map((hit) {
          final h = hit.hadith;
          return Card(
            child: ListTile(
              leading: const Icon(
                Icons.menu_book,
                color: SunnatiColors.gold,
              ),
              title: Text(
                h.text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_bookName(h.bookId)} — حديث ${h.num}'
                '${h.chapterTitle.isNotEmpty ? ' — ${h.chapterTitle}' : ''}',
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _ReaderOpener(db: widget.db, hadith: h),
                  ),
                );
              },
            ),
          );
        }),
      ],
    );
  }

  Widget _buildPagination(int total, int totalPages, bool hasMore) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed:
                _pageNumber > 1 ? () => _run(page: _pageNumber - 1) : null,
            child: const Text('السابق'),
          ),
          Text('صفحة $_pageNumber من $totalPages (إجمالي $total)'),
          TextButton(
            onPressed: hasMore ? () => _run(page: _pageNumber + 1) : null,
            child: const Text('التالي'),
          ),
        ],
      ),
    );
  }
}

/// Narrator picker dialog: search + list over the verified installed
/// narrators only ([SunnatiDatabase.listNarrators] /
/// [SunnatiDatabase.searchNarrators]). Returns the picked narrator's
/// display name, '' to clear the choice, or null when dismissed.
class _NarratorPickerDialog extends StatefulWidget {
  const _NarratorPickerDialog({required this.db});

  final SunnatiDatabase db;

  @override
  State<_NarratorPickerDialog> createState() => _NarratorPickerDialogState();
}

class _NarratorPickerDialogState extends State<_NarratorPickerDialog> {
  final _queryController = TextEditingController();
  late List<Narrator> _shown;

  @override
  void initState() {
    super.initState();
    _shown = widget.db.listNarrators(limit: 100);
  }

  void _onQueryChanged(String query) {
    setState(() {
      _shown = query.trim().isEmpty
          ? widget.db.listNarrators(limit: 100)
          : widget.db.searchNarrators(query.trim());
    });
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('اختر راوياً'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _queryController,
              decoration: const InputDecoration(
                hintText: 'ابحث باسم الراوي...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: _onQueryChanged,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: _shown.isEmpty
                  ? const Text('لا يوجد راوٍ موثّق بهذا الاسم.')
                  : ListView.builder(
                      shrinkWrap: true,
                      // Smoothness fix 2026-11-26 (review §3). NO
                      // itemExtent: picker rows are NOT fixed-height
                      // (subtitle joins kunya + status and wraps).
                      scrollCacheExtent: const ScrollCacheExtent.pixels(400),
                      itemCount: _shown.length,
                      itemBuilder: (context, i) {
                        final n = _shown[i];
                        return ListTile(
                          title: Text(n.displayName),
                          subtitle: Text(
                            [
                              if (n.kunya.isNotEmpty) n.kunya,
                              if (n.hasStatus) n.status,
                            ].join(' — '),
                          ),
                          onTap: () =>
                              Navigator.of(context).pop(n.displayName),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('مسح اختيار الراوي'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
      ],
    );
  }
}

/// One tab pill of the search tab row. Selected: pink fill; otherwise
/// an ivory pill with a neutral border (same visual language as the
/// hadith-page tab pills).
class _SearchTabPill extends StatelessWidget {
  const _SearchTabPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? SunnatiColors.blush
              : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? SunnatiColors.blush : SunnatiColors.neutral,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected
                ? SunnatiColors.petrol
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// Opens the book screen for a chapter found in the الأبواب tab. The
/// book screen needs a [UserRepository]; it is loaded here so the
/// search screen itself stays stateless about user data.
class _BookOpener extends StatelessWidget {
  const _BookOpener({required this.db, required this.book});

  final SunnatiDatabase db;
  final Book book;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UserRepository>(
      future: UserRepository.load(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return BookScreen(db: db, userRepo: snap.data!, book: book);
      },
    );
  }
}

/// Opens the reader for a search hit. The reader needs a [UserRepository];
/// it is loaded here so the search screen itself stays stateless about
/// user data.
class _ReaderOpener extends StatelessWidget {
  const _ReaderOpener({required this.db, required this.hadith});

  final SunnatiDatabase db;
  final Hadith hadith;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UserRepository>(
      future: UserRepository.load(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return HadithReaderScreen(db: db, userRepo: snap.data!, hadith: hadith);
      },
    );
  }
}
