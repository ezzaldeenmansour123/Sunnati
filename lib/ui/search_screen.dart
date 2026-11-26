import 'package:material_ui/material_ui.dart';

import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/book.dart';
import '../models/commentary.dart';
import '../models/grade.dart';
import '../models/hadith.dart';
import '../search/search_history.dart';
import '../search/search_service.dart';
import 'hadith_reader_screen.dart';
import 'widgets/empty_library.dart';

/// Advanced search (master prompt §7): word / phrase / part of a hadith,
/// in all books or one book, by hadith number (with book filter), by
/// grade, by narrator (isnad region), by Companion (last narrator
/// candidate), by chapter (the topic filter — chapters are the topic
/// divisions the data actually has; their titles are English in the
/// source), in the commentaries, in the takhrij scope (text-similarity
/// grouping — the verified takhrij table is empty, and the screen says
/// so), with lexical semantic expansion («بحث دلالي معجمي» — roots +
/// synonyms, NOT embeddings and NOT an LLM), saved search history, and
/// paginated results (one SQL page at a time — never thousands of rows
/// in memory).
///
/// Every result always shows the book, the hadith number, the chapter
/// and the source.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.db});

  final SunnatiDatabase db;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

const String _kLibrarySource = 'مكتبة سُنَّتي — الكتب التسعة (quranlab/hadith)';

String _scopeLabel(SearchScope scope) {
  return switch (scope) {
    SearchScope.all => 'المتن والسند',
    SearchScope.matn => 'المتن فقط',
    SearchScope.isnad => 'السند فقط',
    SearchScope.commentary => 'الشروح',
    SearchScope.takhrij => 'التخريج',
  };
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _narratorController = TextEditingController();
  final _companionController = TextEditingController();
  String? _bookId;
  String? _grade;
  int? _chapterId;
  SearchScope _scope = SearchScope.all;
  bool _semantic = false;
  SearchPage<SearchHit>? _page;
  SearchPage<Commentary>? _commentaryPage;
  bool _searched = false;
  int _pageNumber = 1;
  List<Chapter> _chapters = const <Chapter>[];
  SearchHistory? _history;

  late final SearchService _search = SearchService(widget.db);

  @override
  void initState() {
    super.initState();
    SearchHistory.load().then((h) {
      if (mounted) setState(() => _history = h);
    });
  }

  SearchQuery get _currentQuery {
    return SearchQuery(
      text: _controller.text,
      bookId: _bookId,
      grade: _grade,
      chapterId: _chapterId,
      narrator: _narratorController.text,
      companion: _companionController.text,
      scope: _scope,
      semantic: _semantic,
      page: _pageNumber,
    );
  }

  void _run({int page = 1}) {
    _pageNumber = page;
    final query = _currentQuery;
    if (_scope == SearchScope.commentary) {
      setState(() {
        _commentaryPage = _search.searchCommentaries(query);
        _page = null;
        _searched = true;
      });
    } else {
      setState(() {
        _page = _search.search(query);
        _commentaryPage = null;
        _searched = true;
      });
    }
    _history?.add(query);
  }

  void _runHistory(SearchHistoryEntry entry) {
    _controller.text = entry.text;
    _narratorController.text = entry.narrator;
    _companionController.text = entry.companion;
    setState(() {
      _bookId = entry.bookId;
      _grade = entry.grade;
      _chapterId = entry.chapterId;
      _scope = entry.scope;
      _semantic = entry.semantic;
    });
    _loadChapters();
    _run();
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

  void _showSimilar(Hadith base) {
    final similar = _search.findSimilar(base);
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('روايات مشابهة — ${base.bookId} ${base.num}'),
          content: SizedBox(
            width: double.maxFinite,
            child: similar.isEmpty
                ? const Text(
                    'لا توجد روايات مشابهة فوق العتبة (تشابه جاكارد 0.30).',
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: similar.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            'التشابه النصي وحده ليس دليلاً على وحدة الحديث '
                            '(البرومبت §11) — قارن النص والسند بنفسك.',
                            style: TextStyle(fontStyle: FontStyle.italic),
                          ),
                        );
                      }
                      final s = similar[i - 1];
                      return Card(
                        child: ListTile(
                          title: Text(
                            s.hadith.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${_bookName(s.hadith.bookId)} — حديث '
                            '${s.hadith.num} — تشابه '
                            '${(s.jaccard * 100).round()}٪ '
                            '(${s.common} مشتركة)',
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => _ReaderOpener(
                                  db: widget.db,
                                  hadith: s.hadith,
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إغلاق'),
            ),
          ],
        );
      },
    );
  }

  String _bookName(String bookId) {
    for (final b in widget.db.books()) {
      if (b.id == bookId) return b.name;
    }
    return bookId;
  }

  @override
  void dispose() {
    _controller.dispose();
    _narratorController.dispose();
    _companionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final books = widget.db.books().where((b) => b.hasData).toList();
    final page = _page;
    final commentaryPage = _commentaryPage;
    final note = page?.semanticNote ?? commentaryPage?.semanticNote ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('البحث المتقدم')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _buildFilters(context, books),
                const SizedBox(height: 8),
                if (note.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(note),
                    ),
                  ),
                if (_grade != null)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'التصفية بالدرجة تُظهر الأحاديث ذات الدرجة المسجلة '
                        'فقط — البخاري ومسلم (صحيح على مستوى المجموعة) '
                        'وأحمد والدارمي (بلا درجة في المصدر) لا يظهران.',
                      ),
                    ),
                  ),
                if (!_searched) ...[
                  const SizedBox(height: 8),
                  const Center(
                    child: Text(
                      'اكتب كلمة أو جملة أو رقم حديث، ثم اضغط «بحث».',
                    ),
                  ),
                  _buildHistory(),
                ] else if (page != null)
                  _buildHadithResults(page)
                else if (commentaryPage != null)
                  _buildCommentaryResults(commentaryPage),
              ],
            ),
          ),
          if (_searched && (page != null || commentaryPage != null))
            _buildPagination(
              page?.total ?? commentaryPage?.total ?? 0,
              page?.totalPages ?? commentaryPage?.totalPages ?? 1,
              page?.hasMore ?? commentaryPage?.hasMore ?? false,
            ),
        ],
      ),
    );
  }

  Widget _buildFilters(BuildContext context, List<Book> books) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          decoration: const InputDecoration(
            hintText: 'ابحث عن كلمة أو جملة أو رقم حديث…',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _run(),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: SearchScope.values.map((scope) {
            return ChoiceChip(
              label: Text(_scopeLabel(scope)),
              selected: _scope == scope,
              onSelected: (_) => setState(() => _scope = scope),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _narratorController,
          decoration: const InputDecoration(
            labelText: 'الراوي (بحث في السند فقط)',
            hintText: 'مثال: الزهري',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _run(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _companionController,
          decoration: const InputDecoration(
            labelText: 'الصحابي (آخر راوٍ في السند)',
            hintText: 'مثال: أبو هريرة',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _run(),
        ),
        const SizedBox(height: 4),
        const Text(
          'إن كتبت اسم راوٍ أو صحابي قُدّم على نص البحث؛ البحث بالاسم '
          'لا يُوسَّع بالجذور والمرادفات (أسماء أعلام).',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          key: ValueKey(_bookId),
          initialValue: _bookId,
          decoration: const InputDecoration(
            labelText: 'الكتاب',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('جميع الكتب'),
            ),
            ...books.map(
              (b) =>
                  DropdownMenuItem<String?>(value: b.id, child: Text(b.name)),
            ),
          ],
          onChanged: (v) {
            setState(() => _bookId = v);
            _loadChapters();
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<int?>(
          key: ValueKey(_chapterId),
          initialValue: _chapterId,
          decoration: const InputDecoration(
            labelText: 'الموضوع (الباب)',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('أي موضوع')),
            ..._chapters.map(
              (c) => DropdownMenuItem<int?>(value: c.id, child: Text(c.title)),
            ),
          ],
          onChanged:
              _bookId == null ? null : (v) => setState(() => _chapterId = v),
        ),
        const Text(
          'الموضوع = باب الكتاب؛ عناوين الأبواب إنجليزية في المصدر '
          '(لم تُترجم ولم تُخترع عناوين عربية). اختر كتاباً أولاً.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          key: ValueKey(_grade),
          initialValue: _grade,
          decoration: const InputDecoration(
            labelText: 'الدرجة',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('أي درجة'),
            ),
            ...gradeFilterOptions.map(
              (g) => DropdownMenuItem<String?>(value: g, child: Text(g)),
            ),
          ],
          onChanged: (v) => setState(() => _grade = v),
        ),
        SwitchListTile(
          title: const Text('بحث دلالي معجمي'),
          subtitle: const Text(
            'توسيع الاستعلام بجذور الكلمات والمرادفات من قواميس '
            'التطبيق. ليس تضمينات متجهية ولا نموذجاً لغوياً.',
          ),
          value: _semantic,
          onChanged: (v) => setState(() => _semantic = v),
        ),
        FilledButton.icon(
          onPressed: () => _run(),
          icon: const Icon(Icons.search),
          label: const Text('بحث'),
        ),
      ],
    );
  }

  Widget _buildHistory() {
    final history = _history;
    if (history == null || history.entries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'عمليات بحث سابقة',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            TextButton(
              onPressed: () async {
                await history.clear();
                if (mounted) setState(() {});
              },
              child: const Text('مسح الكل'),
            ),
          ],
        ),
        ...history.entries.asMap().entries.map((e) {
          final i = e.key;
          final entry = e.value;
          return ListTile(
            title: Text(entry.label),
            subtitle: Text(
              '${_scopeLabel(entry.scope)}'
              '${entry.semantic ? ' • دلالي معجمي' : ''}',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await history.removeAt(i);
                if (mounted) setState(() {});
              },
            ),
            onTap: () => _runHistory(entry),
          );
        }),
      ],
    );
  }

  Widget _buildHadithResults(SearchPage<SearchHit> page) {
    if (!widget.db.isAvailable) {
      return const EmptyLibraryCard(
        title: 'البحث غير متوفر بعد',
        detail: 'المكتبة قيد الاستيراد — لا توجد نصوص للبحث فيها بعد.',
      );
    }
    if (page.items.isEmpty) {
      return const Center(child: Text('لا توجد نتائج مطابقة.'));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text('النتائج: ${page.total} حديثاً'),
        ),
        ...page.items.map((hit) {
          final h = hit.hadith;
          return Card(
            child: ListTile(
              title: Text(h.text, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_bookName(h.bookId)} — حديث ${h.num} — '
                    '${h.chapterTitle}',
                  ),
                  const Text('المصدر: $_kLibrarySource'),
                  if (hit.tier == 'semantic' || hit.tier == 'phrase')
                    Text(
                      hit.tier == 'phrase'
                          ? 'مطابقة عبارة حرفية'
                          : 'نتيجة دلالية معجمية (جذر/مرادف)',
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                ],
              ),
              trailing: IconButton(
                icon: const Icon(Icons.compare_arrows),
                tooltip: 'روايات مشابهة',
                onPressed: () => _showSimilar(h),
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

  Widget _buildCommentaryResults(SearchPage<Commentary> page) {
    if (!widget.db.isAvailable) {
      return const EmptyLibraryCard(
        title: 'البحث غير متوفر بعد',
        detail: 'المكتبة قيد الاستيراد — لا توجد شروح للبحث فيها بعد.',
      );
    }
    if (page.items.isEmpty) {
      return const Center(child: Text('لا توجد نتائج مطابقة.'));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text('النتائج: ${page.total} شرحاً (HadeethEnc)'),
        ),
        ...page.items.map((c) {
          return Card(
            child: ListTile(
              title: Text(
                c.explanation.isNotEmpty ? c.explanation : c.text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.title.isNotEmpty ? c.title : c.hadithKey),
                  if (c.gradeAr.isNotEmpty) Text('الدرجة: ${c.gradeAr}'),
                  Text('المصدر: ${c.source} — ${c.attribution}'),
                ],
              ),
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
