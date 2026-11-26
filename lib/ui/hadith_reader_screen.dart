import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/chain.dart';
import '../models/hadith.dart';
import '../models/narrator.dart';
import 'assistant_screen.dart';
import 'commentaries_screen.dart';
import 'takhrij_screen.dart';
import 'widgets/isnad_text.dart';
import 'widgets/isnad_tree.dart';

/// Hadith reader: full text (diacritics kept), book/number/chapter,
/// gradings with scholars' names, transmitted commentary when available,
/// and working actions: favourite, note, copy, share, previous/next,
/// "ask SUNNATI" (retrieval), commentary and takhrij pages.
///
/// Nothing is shown as available when it is not: the commentary and
/// takhrij buttons open pages that themselves state what data exists;
/// the "no grading recorded" line is shown explicitly instead of silence.
class HadithReaderScreen extends StatefulWidget {
  const HadithReaderScreen({
    super.key,
    required this.db,
    required this.userRepo,
    required this.hadith,
    this.chapterHadiths = const <Hadith>[],
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final Hadith hadith;
  final List<Hadith> chapterHadiths;

  @override
  State<HadithReaderScreen> createState() => _HadithReaderScreenState();
}

class _HadithReaderScreenState extends State<HadithReaderScreen> {
  late Hadith _hadith;
  List<Narrator> _chainNarrators = const <Narrator>[];
  List<ChainLink> _chainLinks = const <ChainLink>[];

  @override
  void initState() {
    super.initState();
    _hadith = widget.hadith;
    widget.userRepo.touch(_hadith.stableId);
    _loadChain();
  }

  /// Verified chain data for the current hadith (empty until Phase-5
  /// chains are imported — the text then shows untapped, honestly).
  void _loadChain() {
    _chainLinks = widget.db.chainForHadith(_hadith.id);
    _chainNarrators = widget.db.narratorsForHadith(_hadith.id);
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
      _loadChain();
    });
    widget.userRepo.touch(_hadith.stableId);
  }

  @override
  Widget build(BuildContext context) {
    final isFav = widget.userRepo.isFavorite(_hadith.stableId);
    final hasNote =
        (widget.userRepo.data.notes[_hadith.stableId] ?? '').isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text('حديث ${_hadith.num}'),
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
            onPressed: () => Share.share(
              '${_hadith.text}\n(${_hadith.bookId} — حديث ${_hadith.num})',
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _hadith.chapterTitle,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          InteractiveIsnadText(
            db: widget.db,
            text: _hadith.text,
            confirmedNarrators: _chainNarrators,
          ),
          if (_chainNarrators.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'اضغط على اسم مميّز باللون البترولي لعرض بطاقة الراوي.',
                style: TextStyle(color: SunnatiColors.inkMuted, fontSize: 12),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'أسماء الرواة غير مرتبطة بعد — لا توجد بيانات سلسلة موثّقة لهذا الحديث.',
                style: TextStyle(color: SunnatiColors.inkMuted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          ExpansionTile(
            title: const Text('شجرة الإسناد'),
            subtitle: Text(
              _chainLinks.isEmpty
                  ? 'لا توجد بيانات سلسلة موثّقة'
                  : '${_chainLinks.length} روابط في السلسلة',
              style: const TextStyle(color: SunnatiColors.inkMuted),
            ),
            children: [
              SizedBox(
                height: 420,
                child: IsnadTree(db: widget.db, links: _chainLinks),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),
          _SectionTitle('الدرجة'),
          if (_hadith.hasGrades)
            ..._hadith.grades.map(
              (g) => ListTile(
                dense: true,
                title: Text(g.grade),
                subtitle: Text('حكم ${g.scholar}'),
              ),
            )
          else
            const Text(
              'لم يرد حكم مسجّل لهذا الحديث في المصدر.',
              style: TextStyle(color: SunnatiColors.inkMuted),
            ),
          const Divider(),
          _SectionTitle('الشرح المنقول'),
          if (_hadith.hasExplanation) ...[
            Text(_hadith.explanation, style: const TextStyle(height: 1.8)),
            const SizedBox(height: 6),
            Text(
              'المصدر: ${_hadith.explanationSource}',
              style: const TextStyle(color: SunnatiColors.inkMuted, fontSize: 12),
            ),
          ] else
            const Text(
              'لا يوجد شرح منقول لهذا الحديث بعد.',
              style: TextStyle(color: SunnatiColors.inkMuted),
            ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CommentariesScreen(
                        db: widget.db,
                        hadith: _hadith,
                      ),
                    ),
                  ),
                  child: const Text('الشروح'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TakhrijScreen(
                        db: widget.db,
                        hadith: _hadith,
                      ),
                    ),
                  ),
                  child: const Text('التخريج'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
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
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: widget.chapterHadiths.isEmpty ? null : () => _goTo(-1),
                child: const Text('الحديث السابق'),
              ),
              TextButton(
                onPressed: widget.chapterHadiths.isEmpty ? null : () => _goTo(1),
                child: const Text('الحديث التالي'),
              ),
            ],
          ),
        ],
      ),
    );
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
