import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/narrator_logic.dart';
import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/book.dart';
import '../models/chain.dart';
import '../models/grade.dart';
import '../models/hadith.dart';
import '../models/narrator.dart';
import '../models/takhrij.dart';
import 'assistant_screen.dart';
import 'book_screen.dart';
import 'commentaries_screen.dart';
import 'isnad_analysis_screen.dart';
import 'takhrij_screen.dart';
import 'widgets/empty_library.dart';
import 'widgets/isnad_text.dart';
import 'widgets/sunnati_bottom_nav.dart';
import 'widgets/untranslated_tag.dart';

/// Hadith page — mockup screen 3 (the «جامع الكتب التسعة» layout, copied
/// as DESIGN only; every word of content comes from the installed DB).
///
/// Layout, top to bottom, exactly as the mockup:
/// * AppBar with the REAL book name.
/// * Chapter header: the REAL book + باب title from the `chapters` table
///   (verbatim — the source titles are English, e.g. `Revelation`, and no
///   Arabic title is ever invented; an untranslated title carries a
///   visible «غير مترجم» tag; a «غير مصنّف» chapter shows exactly
///   that). Tapping it opens the book's chapters page.
/// * Pink pill «رقم الحديث: N» (the real number).
/// * The matn in large readable Amiri text (real hadith text, unmodified).
/// * A separate «الإسناد» section with a pink pill header; the isnad is
///   rendered through [InteractiveIsnadText], so every parsed narrator
///   name is in ONE distinctive RED and tappable (user decisions
///   2026-11-26 15:03 + 17:23); a tap shows the status + source as an
///   inline line embedded in the hadith text right under the name —
///   never a popup card/sheet, never the full details page, never a
///   navigation (user decision 2026-11-26 17:23).
/// * A tabs row — تخريج / الحكم / رواة / شرح / تعليقات — the «جامع
///   الكتب التسعة» tab set (user decision 2026-11-26 17:26, reconciled
///   with the mockup tabs: الغريب had no data and is dropped, and the
///   user's ملاحظات live inside تعليقات). Each tab shows REAL data or
///   an honest empty state, never invented content.
/// * An «تحليل الإسناد» button opening the analysis screen.
///
/// The isnad/matn split is the parser's own data: the isnad is the text
/// up to the end of the last parsed narrator name (`hadith_narrators`
/// offsets); the matn is the verbatim remainder. When no parser rows
/// exist the whole text is shown as the matn and the isnad section says
/// honestly that the isnad has not been parsed yet — no boundary is ever
/// guessed.
class HadithReaderScreen extends StatefulWidget {
  const HadithReaderScreen({
    super.key,
    required this.db,
    required this.userRepo,
    required this.hadith,
    this.chapterHadiths = const <Hadith>[],
    this.showBottomNav = true,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final Hadith hadith;
  final List<Hadith> chapterHadiths;

  /// Whether this reader draws the shared bottom nav. True for pushed
  /// readers (the mockup shows the nav — الحديث active — on the hadith
  /// page). False only when the reader IS the الحديث tab root inside
  /// the shell (`_HadithTab` in `main.dart`), where the shell's own nav
  /// is already shown and a second bar would duplicate it.
  final bool showBottomNav;

  @override
  State<HadithReaderScreen> createState() => _HadithReaderScreenState();
}

/// The five tabs of the hadith page, in «جامع الكتب التسعة» order
/// (RTL: تخريج first). User decision 2026-11-26 17:26: adopt the
/// reference tab set (تخريج، حكم، رواة، شرح، تعليقات), reconciled with
/// the mockup tabs — الغريب is dropped (its table is empty: 0 rows,
/// it only ever showed an honest empty state) and the user's own
/// ملاحظات live inside تعليقات. Private folders and the thematic tree
/// are FUTURE scope, not this build.
enum _ReaderTab { takhrij, hukm, narrators, sharh, comments }

const Map<_ReaderTab, String> _tabLabels = <_ReaderTab, String>{
  _ReaderTab.takhrij: 'تخريج',
  _ReaderTab.hukm: 'الحكم',
  _ReaderTab.narrators: 'رواة',
  _ReaderTab.sharh: 'شرح',
  _ReaderTab.comments: 'تعليقات',
};

class _HadithReaderScreenState extends State<HadithReaderScreen> {
  late Hadith _hadith;
  List<Narrator> _chainNarrators = const <Narrator>[];
  List<ChainLink> _chainLinks = const <ChainLink>[];
  List<HadithGradeDetail> _gradeRecords = const <HadithGradeDetail>[];
  List<TakhrijEntry> _takhrijEntries = const <TakhrijEntry>[];
  List<HadithVariant> _variants = const <HadithVariant>[];
  _ReaderTab _tab = _ReaderTab.sharh;

  /// Inline message from a tap on the coverage line (null: none
  /// tapped). Shown as a small red line right under the coverage line,
  /// inside this page — never a sheet, never a navigation (user
  /// decision 2026-11-26 17:23). The in-text taps render their own
  /// line inside [InteractiveIsnadText]; the narrators tab renders its
  /// own line under the tapped row.
  String? _inlineMessage;

  /// Index into [_chainNarrators] of the narrator tapped in the رواة
  /// tab (null: none tapped). The status + source line is shown right
  /// under that row, inline — never a sheet, never a navigation.
  int? _selectedNarratorIndex;

  @override
  void initState() {
    super.initState();
    _hadith = widget.hadith;
    widget.userRepo.touch(_hadith.stableId);
    _loadData();
  }

  /// Verified chain + tab data for the current hadith. Empty lists mean
  /// "no such data recorded", and the tabs say so honestly.
  void _loadData() {
    _chainLinks = widget.db.chainForHadith(_hadith.id);
    _chainNarrators = widget.db.narratorsForHadith(_hadith.id);
    _gradeRecords = widget.db.gradeRecordsForHadith(_hadith.id);
    _takhrijEntries = widget.db.takhrijForHadith(_hadith.id);
    _variants = widget.db.variantsForHadith(_hadith.id);
  }

  /// Real book name from the DB (`books` table), falling back to the
  /// canonical Nine Books list, then to the raw book id.
  String get _bookName {
    for (final b in widget.db.books()) {
      if (b.id == _hadith.bookId) return b.name;
    }
    for (final b in nineBooks) {
      if (b.id == _hadith.bookId) return b.name;
    }
    return _hadith.bookId;
  }

  Book? get _book {
    for (final b in widget.db.books()) {
      if (b.id == _hadith.bookId) return b;
    }
    for (final b in nineBooks) {
      if (b.id == _hadith.bookId) return b;
    }
    return null;
  }

  /// Chapter header, verbatim from the `chapters` table: the real book +
  /// the real باب title. A «غير مصنّف» chapter shows exactly that —
  /// never an invented باب title. An empty title shows the book alone.
  /// An untranslated (English) title is shown with a visible
  /// «غير مترجم» tag next to it (see [UntranslatedChapterTag]) —
  /// never presented as if it were the Arabic باب, never replaced by
  /// an invented Arabic title.
  String get _chapterHeader {
    final title = _hadith.chapterTitle.trim();
    if (title.isEmpty) return _bookName;
    if (title == 'غير مصنّف') return 'غير مصنّف';
    return '$_bookName — $title';
  }

  /// End of the last parsed narrator name in the hadith text (parser
  /// offsets from `hadith_narrators`), or null when no parser row
  /// carries usable offsets.
  int? get _isnadEnd {
    int? end;
    for (final link in _chainLinks) {
      if (link.hasOffsets && link.endChar != null) {
        end = end == null || link.endChar! > end ? link.endChar! : end;
      }
    }
    if (end == null || end <= 0 || end > _hadith.text.length) return null;
    return end;
  }

  /// Matn: the verbatim text after the last parsed narrator name; the
  /// whole text when no isnad boundary is recorded.
  String get _matnText {
    final end = _isnadEnd;
    if (end == null) return _hadith.text;
    final rest = _hadith.text.substring(end);
    if (rest.trim().isEmpty) return _hadith.text;
    return rest;
  }

  /// Isnad: the verbatim text up to the last parsed narrator name; the
  /// whole text when no isnad boundary is recorded (the widget then
  /// falls back to name search over the verified narrators).
  String get _isnadText {
    final end = _isnadEnd;
    if (end == null) return _hadith.text;
    return _hadith.text.substring(0, end);
  }

  /// Chain links whose offsets lie inside the isnad slice, so the
  /// widget's spans are placed at their stored positions.
  List<ChainLink> get _isnadLinks {
    final end = _isnadEnd;
    if (end == null) return _chainLinks;
    return _chainLinks
        .where((l) => l.hasOffsets && l.endChar! <= end)
        .toList();
  }

  /// Rebuild after a note change made from a tab widget (tabs are
  /// separate widget classes and may not call the protected [setState]).
  void refresh() {
    setState(() {});
  }

  void _showNoteDialog() {
    final controller = TextEditingController(
      text: widget.userRepo.data.notes[_hadith.stableId] ?? '',
    );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ملاحظة'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'اكتب ملاحظتك الخاصة…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () async {
              await widget.userRepo.setNote(_hadith.stableId, controller.text);
              if (context.mounted) Navigator.of(context).pop();
              if (mounted) setState(() {});
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  void _goTo(int delta) {
    final list = widget.chapterHadiths;
    if (list.isEmpty) return;
    final index = list.indexWhere((h) => h.stableId == _hadith.stableId);
    final next = index + delta;
    if (index < 0 || next < 0 || next >= list.length) return;
    setState(() {
      _hadith = list[next];
      _inlineMessage = null;
      _selectedNarratorIndex = null;
      _loadData();
    });
    widget.userRepo.touch(_hadith.stableId);
  }

  /// Tap a narrator in the رواة tab: show ONLY his status + source as
  /// an inline line right under that row — never the full details
  /// page/sheet, never a navigation (user decision 2026-11-26 17:23).
  /// The full narrator page is reachable only from the narrators
  /// encyclopedia. Tapping the same row again hides the line. The
  /// line's text is built at render time by [_NarratorsTab] from the
  /// honest ladder ([inlineStatusForTap]).
  void _openNarrator(Narrator narrator) {
    final index = _chainNarrators.indexOf(narrator);
    setState(() {
      _selectedNarratorIndex =
          (index < 0 || _selectedNarratorIndex == index) ? null : index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isFav = widget.userRepo.isFavorite(_hadith.stableId);
    final hasNote =
        (widget.userRepo.data.notes[_hadith.stableId] ?? '').isNotEmpty;
    final book = _book;
    return Scaffold(
      appBar: AppBar(
        title: Text(_bookName),
        actions: [
          IconButton(
            icon: Icon(
              isFav ? Icons.favorite : Icons.favorite_outline,
              color: isFav ? SunnatiColors.gold : null,
            ),
            tooltip: 'المفضلة',
            onPressed: () async {
              await widget.userRepo.toggleFavorite(_hadith.stableId);
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: Icon(
              hasNote ? Icons.note_alt : Icons.note_add_outlined,
            ),
            tooltip: 'ملاحظة',
            onPressed: _showNoteDialog,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'نسخ النص',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _hadith.text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('تم نسخ نص الحديث')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'مشاركة',
            onPressed: () => SharePlus.instance.share(
              ShareParams(
                text:
                    '${_hadith.text}\n(${_hadith.bookId} — حديث ${_hadith.num})',
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          // Chapter header (mockup: «كتاب الإيمان - باب قول النبي ﷺ …»
          // with a chevron). Tapping it opens the book's chapters page.
          Card(
            child: InkWell(
              onTap: book == null
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BookScreen(
                            db: widget.db,
                            userRepo: widget.userRepo,
                            book: book,
                          ),
                        ),
                      ),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              _chapterHeader,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color:
                                    Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                          if (isUntranslatedChapterTitle(
                            _hadith.chapterTitle,
                          )) ...[
                            const SizedBox(width: 6),
                            const UntranslatedChapterTag(),
                          ],
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.keyboard_arrow_down,
                      color: SunnatiColors.inkMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Hadith-number pill (mockup's pink pill).
          Center(child: _PinkPill('رقم الحديث: ${_hadith.num}')),
          const SizedBox(height: 16),
          // Matn — large readable Amiri text, unmodified.
          Text(
            _matnText,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: SunnatiTheme.fontFamily,
              fontSize: 22,
              height: 1.9,
            ),
          ),
          const SizedBox(height: 20),
          // Separate isnad section (mockup's pink «الإسناد» pill).
          const Center(child: _PinkPill('الإسناد')),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _chainLinks.isEmpty
                  ? const Text(
                      kIsnadNotParsedMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: SunnatiColors.inkMuted),
                    )
                  : InteractiveIsnadText(
                      db: widget.db,
                      text: _isnadText,
                      confirmedNarrators: _chainNarrators,
                      chainLinks: _isnadLinks,
                      narratorsAvailable: widget.db.narratorsAvailable,
                    ),
            ),
          ),
          _CoverageLine(
            state: hadithCoverageState(
              hasVerifiedNarrators: _chainNarrators.isNotEmpty,
              hasVerifiedLinks:
                  _chainLinks.any((l) => l.narratorId != null),
              hasParserRows: _chainLinks.isNotEmpty,
            ),
            onShowMessage: (message) => setState(
              () => _inlineMessage =
                  _inlineMessage == message ? null : message,
            ),
          ),
          if (_inlineMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _inlineMessage!,
                style: isnadInlineStatusStyle(context),
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: 12),
          // Isnad analysis (built by the parallel worker with exactly
          // this constructor).
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => IsnadAnalysisScreen(
                    hadithId: _hadith.id,
                    chainLinks: _chainLinks,
                    bookName: _bookName,
                  ),
                ),
              ),
              icon: const Icon(Icons.analytics_outlined),
              label: const Text('تحليل الإسناد'),
            ),
          ),
          const SizedBox(height: 16),
          // Tabs row (جامع الكتب التسعة set: تخريج / الحكم / رواة /
          // شرح / تعليقات). The narrators live in the رواة tab now —
          // the standalone «رواة الحديث» section above the tabs was
          // removed with the 2026-11-26 17:26 reconciliation.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final tab in _ReaderTab.values)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: _TabPill(
                      label: _tabLabels[tab]!,
                      selected: _tab == tab,
                      onTap: () => setState(() => _tab = tab),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // LAZY tab content (smoothness fix 2026-11-26, review §4):
          // only the SELECTED tab's widget is ever instantiated —
          // [_TabContent] switches on [_tab] and builds that one tab
          // alone, so the other four tabs' widgets (and their DB reads,
          // e.g. the sharh tab's commentary count) are never built
          // while the user reads the matn/isnad. The matn and isnad
          // above stay visible on every tab by design.
          _TabContent(tab: _tab, state: this),
          const SizedBox(height: 20),
          // Ask SUNNATI about this hadith (retrieval, as before).
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AssistantScreen(
                    db: widget.db,
                    hadith: _hadith,
                    initialQuery: _hadith.text.length > 60
                        ? _hadith.text.substring(0, 60)
                        : _hadith.text,
                  ),
                ),
              ),
              child: const Text('اسأل سُنَّتي'),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: widget.chapterHadiths.isEmpty
                    ? null
                    : () => _goTo(-1),
                child: const Text('الحديث السابق'),
              ),
              TextButton(
                onPressed: widget.chapterHadiths.isEmpty
                    ? null
                    : () => _goTo(1),
                child: const Text('الحديث التالي'),
              ),
            ],
          ),
        ],
      ),
      // Shared bottom nav (mockup screen 3: الحديث active). Tapping a
      // tab replaces the stack with a fresh shell on that tab — see
      // `sunnatiGoToTab`. Not drawn when this reader is the الحديث tab
      // root itself (the shell already shows the nav there).
      bottomNavigationBar: widget.showBottomNav
          ? SunnatiBottomNav(
              currentIndex: 4,
              onTap: (index) => sunnatiGoToTab(context, index),
            )
          : null,
    );
  }
}

/// Pink pill exactly as the mockup's: pale pink fill, petrol bold text.
class _PinkPill extends StatelessWidget {
  const _PinkPill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: SunnatiColors.blush,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: SunnatiColors.petrol,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// One tab of the mockup's tabs row. Selected: pink fill; otherwise an
/// ivory pill with a neutral border.
class _TabPill extends StatelessWidget {
  const _TabPill({
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

/// Content of the selected tab — real data or an honest empty state.
/// Reads its data from the owning [_HadithReaderScreenState].
///
/// LAZY by construction: the switch below instantiates exactly one
/// tab widget — the selected one. Unselected tabs are never built
/// (their widgets, DB reads and empty states do not exist in the tree
/// until the user taps that tab), which is what keeps a tab switch
/// from rebuilding the whole page's content.
class _TabContent extends StatelessWidget {
  const _TabContent({required this.tab, required this.state});

  final _ReaderTab tab;
  final _HadithReaderScreenState state;

  @override
  Widget build(BuildContext context) {
    switch (tab) {
      case _ReaderTab.takhrij:
        return _TakhrijTab(state: state);
      case _ReaderTab.hukm:
        return _HukmTab(state: state);
      case _ReaderTab.narrators:
        return _NarratorsTab(state: state);
      case _ReaderTab.sharh:
        return _SharhTab(state: state);
      case _ReaderTab.comments:
        return _CommentsTab(state: state);
    }
  }
}

/// رواة: the verified narrators of this hadith (real data only).
/// Tapping a row shows ONLY his status + source as an inline line
/// right under that row — never the full details page, never a
/// navigation (user decision 2026-11-26 17:23). The full narrator page
/// is reachable only from the narrators encyclopedia.
class _NarratorsTab extends StatelessWidget {
  const _NarratorsTab({required this.state});

  final _HadithReaderScreenState state;

  @override
  Widget build(BuildContext context) {
    final narrators = state._chainNarrators;
    if (narrators.isEmpty) {
      return const EmptyLibraryCard(
        title: 'لا يوجد راوٍ موثّق مرتبط بهذا الحديث بعد',
        detail:
            'لم تُربط أسماء الإسناد برواة موثّقين بعد — لا يُعرض هنا أي راوٍ غير موثّق.',
        icon: Icons.person_outline,
      );
    }
    final selected = state._selectedNarratorIndex;
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < narrators.length; i++) ...[
            ListTile(
              dense: true,
              title: Text(narrators[i].displayName),
              subtitle: narrators[i].hasStatus
                  ? Text(
                      '${narrators[i].status} — ${narrators[i].statusSource}',
                    )
                  : null,
              trailing: const Icon(Icons.chevron_left, size: 18),
              onTap: () => state._openNarrator(narrators[i]),
            ),
            if (selected == i)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    inlineStatusLineText(
                      inlineStatusForTap(
                        name: narrators[i].displayName,
                        outcome: narratorTapOutcome(
                          verifiedLink: true,
                          narratorsAvailable:
                              state.widget.db.narratorsAvailable,
                        ),
                        status: narrators[i].status,
                        statusSource: narrators[i].statusSource,
                      ),
                    ),
                    style: isnadInlineStatusStyle(context),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// شرح: the transmitted commentary linked to this hadith, if any.
/// The HadeethEnc rows are NOT linked to any hadith (no reliable key),
/// so they are never presented as the commentary OF this hadith.
class _SharhTab extends StatelessWidget {
  const _SharhTab({required this.state});

  final _HadithReaderScreenState state;

  @override
  Widget build(BuildContext context) {
    final hadith = state._hadith;
    final db = state.widget.db;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hadith.hasExplanation) ...[
              Text(hadith.explanation, style: const TextStyle(height: 1.8)),
              const SizedBox(height: 6),
              Text(
                'المصدر: ${hadith.explanationSource}',
                style: const TextStyle(
                  color: SunnatiColors.inkMuted,
                  fontSize: 12,
                ),
              ),
            ] else ...[
              const EmptyLibraryCard(
                title: 'لا يوجد شرح مرتبط بهذا الحديث بعد',
                detail:
                    'الشروح الكلاسيكية غير مستوردة بعد، وشروح موسوعة الحديث (HadeethEnc) مقاطع مستقلة بمفاتيحها الخاصة غير مربوطة بهذا الحديث بعينها، لذلك لا تظهر هنا كشرحٍ له.',
                icon: Icons.menu_book_outlined,
              ),
              const SizedBox(height: 8),
              Text(
                'شروح موسوعة الحديث المثبّتة: ${db.commentaryCount()} شرحاً — ابحث فيها من شاشة البحث (نطاق «الشروح»).',
                style: const TextStyle(color: SunnatiColors.inkMuted),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CommentariesScreen(
                      db: db,
                      hadith: hadith,
                    ),
                  ),
                ),
                child: const Text('عرض صفحة الشروح'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// تخريج: real takhrij rows and recorded routes, if any. Both tables are
/// currently empty (0 rows), so the honest empty state is expected.
class _TakhrijTab extends StatelessWidget {
  const _TakhrijTab({required this.state});

  final _HadithReaderScreenState state;

  @override
  Widget build(BuildContext context) {
    final hadith = state._hadith;
    final db = state.widget.db;
    final entries = state._takhrijEntries;
    final variants = state._variants;
    if (entries.isEmpty && variants.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const EmptyLibraryCard(
            title: 'لا توجد مصادر تخريج مسجّلة لهذا الحديث بعد',
            detail:
                'جدولا التخريج والطرق غير مستوردَين بعد (المرحلة 5) — لا تُعرض هنا أي مصادر أو طرق غير موثقة.',
            icon: Icons.account_tree_outlined,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TakhrijScreen(db: db, hadith: hadith),
              ),
            ),
            child: const Text('فتح مختبر التخريج'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (variants.isNotEmpty) ...[
          _SectionTitle('طرق الحديث (${variants.length})'),
          for (final v in variants)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (v.variant != null) ...[
                      Text(
                        'حديث ${v.variant!.num} — ${v.variant!.chapterTitle}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        v.variant!.text,
                        style: const TextStyle(height: 1.8),
                      ),
                    ] else
                      const Text(
                        'الطريق مسجّل كمرجع فقط دون نص مستورد.',
                        style: TextStyle(color: SunnatiColors.inkMuted),
                      ),
                    if (v.variantType.isNotEmpty)
                      Text('نوع الطريق: ${v.variantType}'),
                    if (v.diffNote.isNotEmpty)
                      Text('ملاحظة مسجّلة: ${v.diffNote}'),
                    if (v.source.isNotEmpty)
                      Text(
                        'المصدر: ${v.source}',
                        style: const TextStyle(
                          color: SunnatiColors.inkMuted,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
        if (entries.isNotEmpty) ...[
          const _SectionTitle('مصادر التخريج'),
          for (final e in entries)
            Card(
              child: ListTile(
                title: Text(
                  [
                    if (e.sourceBook.isNotEmpty) e.sourceBook,
                    if (e.sourceRef.isNotEmpty) e.sourceRef,
                  ].join(' — '),
                ),
                subtitle: Text(
                  [
                    if (e.grade.isNotEmpty) 'الحكم: ${e.grade}',
                    if (e.notes.isNotEmpty) e.notes,
                    if (e.source.isNotEmpty) 'المصدر: ${e.source}',
                  ].join('\n'),
                ),
              ),
            ),
        ],
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TakhrijScreen(db: db, hadith: hadith),
            ),
          ),
          child: const Text('فتح مختبر التخريج'),
        ),
      ],
    );
  }
}

/// الحكم: real `hadith_grades` rows with grader + source when present.
/// Bukhari/Muslim carry no per-hadith grade (authenticity is at
/// collection level) and Ahmad/Darimi carry none in the source — the tab
/// says so instead of inventing a grade.
class _HukmTab extends StatelessWidget {
  const _HukmTab({required this.state});

  final _HadithReaderScreenState state;

  @override
  Widget build(BuildContext context) {
    final hadith = state._hadith;
    final records = state._gradeRecords;
    if (records.isNotEmpty) {
      return Card(
        child: Column(
          children: [
            for (final g in records)
              ListTile(
                dense: true,
                title: Text(g.gradeAr),
                subtitle: Text(
                  [
                    'حكم ${g.grader}',
                    if (g.source.isNotEmpty) 'المصدر: ${g.source}',
                  ].join('\n'),
                ),
              ),
          ],
        ),
      );
    }
    if (hadith.hasGrades) {
      return Card(
        child: Column(
          children: [
            for (final g in hadith.grades)
              ListTile(
                dense: true,
                title: Text(g.grade),
                subtitle: Text('حكم ${g.scholar}'),
              ),
          ],
        ),
      );
    }
    final detail = switch (hadith.bookId) {
      'bukhari' || 'muslim' =>
        'صحيح على مستوى المجموعة — لا درجة لكل حديث في المصدر.',
      'ahmad' || 'darimi' =>
        'لا توجد درجة في المصدر لهذا الكتاب — لم تُخترَع درجة.',
      _ => 'لم تُسجَّل درجة لهذا الحديث في المصدر بعد.',
    };
    return EmptyLibraryCard(
      title: 'لم يرد حكم مسجّل لهذا الحديث في المصدر.',
      detail: detail,
      icon: Icons.verified_outlined,
    );
  }
}

/// تعليقات: the user's own comments/notes on this hadith, with
/// add/edit. There is no shared-comments data in the library, so only
/// the user's own note is ever shown here — never invented comments
/// from other users.
class _CommentsTab extends StatelessWidget {
  const _CommentsTab({required this.state});

  final _HadithReaderScreenState state;

  @override
  Widget build(BuildContext context) {
    final note =
        state.widget.userRepo.data.notes[state._hadith.stableId] ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (note.isEmpty)
              const Text(
                'لا توجد تعليقات لهذا الحديث بعد — أضف تعليقك الخاص.',
                style: TextStyle(color: SunnatiColors.inkMuted),
              )
            else
              Text(note, style: const TextStyle(height: 1.8)),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: state._showNoteDialog,
                  child: Text(note.isEmpty ? 'إضافة تعليق' : 'تعديل التعليق'),
                ),
                if (note.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      await state.widget.userRepo.setNote(
                        state._hadith.stableId,
                        '',
                      );
                      if (state.mounted) state.refresh();
                    },
                    child: const Text('حذف التعليق'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Honest coverage line under the hadith text — one of four states,
/// never claiming verification that does not exist.
///
/// * verified + package installed: tap hint (plain, not tappable).
/// * verified links but package held back: the pending-approval line,
///   tappable — it shows the pending message as an inline red line
///   under this line (rung b), showing NO status.
/// * parser rows but zero verified links: the "not linked yet" line,
///   tappable — it shows rung (c)
///   ('لا توجد ترجمة موثّقة لهذا الراوي بعد') as an inline red line,
///   since the names themselves are plain and must never look tappable.
/// * no parser rows at all: the "isnad not parsed yet" line (plain —
///   there is no name to tap).
class _CoverageLine extends StatelessWidget {
  const _CoverageLine({required this.state, required this.onShowMessage});

  final HadithCoverageState state;

  /// Called with the honest message to show as an inline red line
  /// under the coverage line when a tappable coverage line is tapped.
  /// Never opens a sheet, never navigates (user decision 2026-11-26
  /// 17:23).
  final void Function(String message) onShowMessage;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: SunnatiColors.inkMuted, fontSize: 12);
    switch (state) {
      case HadithCoverageState.verifiedAvailable:
        return const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'اضغط على أي اسم أحمر لعرض حالته ومصدرها في سطر مدمج تحت الاسم؛ وغير الموثّق ببيان صريح.',
            style: style,
          ),
        );
      case HadithCoverageState.verifiedHeldBack:
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: GestureDetector(
            onTap: () => onShowMessage(kNarratorsPendingApprovalMessage),
            child: const Text(
              kNarratorsPendingApprovalMessage,
              style: style,
            ),
          ),
        );
      case HadithCoverageState.parserRowsNoVerified:
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: GestureDetector(
            onTap: () => onShowMessage(kNoVerifiedBiographyMessage),
            child: const Text(
              kNoVerifiedChainMessage,
              style: style,
            ),
          ),
        );
      case HadithCoverageState.notParsed:
        return const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            kIsnadNotParsedMessage,
            style: style,
          ),
        );
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
