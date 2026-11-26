import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../assistant/assistant_service.dart';
import '../assistant/explanation_template.dart';
import '../assistant/narrator_assistant.dart';
import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import '../models/hadith.dart';
import 'hadith_reader_screen.dart';
import 'narrator_detail_screen.dart';
import 'widgets/empty_library.dart';

/// SUNNATI assistant screen — local retrieval only (Phase 6).
///
/// Labelled honestly: "استرجاع من المكتبة". The assistant matches the
/// question against known phrasings and retrieves passages from the
/// installed library with their sources; it is NOT a language model, it
/// never generates answers and never issues rulings. When the database
/// has no evidence the screen says so explicitly ("لا توجد أدلة موثقة في
/// القاعدة") instead of showing a made-up answer. The 14-section
/// explanation shows every unavailable section as unavailable — never
/// filled with generated text.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({
    super.key,
    required this.db,
    this.initialQuery,
    this.hadith,
  });

  final SunnatiDatabase db;
  final String? initialQuery;

  /// The hadith the user came from, when opened from the reader: it gives
  /// "what are the routes of this hadith?" a hadith to answer about.
  final Hadith? hadith;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _controller = TextEditingController();
  late final AssistantService _service = AssistantService(widget.db);
  late final NarratorAssistantService _narratorService =
      NarratorAssistantService(widget.db);
  ExplanationLevel _level = ExplanationLevel.scholarly;
  AssistantAnswer? _answer;
  NarratorAssistantAnswer? _narratorAnswer;

  @override
  void initState() {
    super.initState();
    // Load the bundled phrasings dataset for intent-matching hints.
    // A missing asset leaves matching off; keyword intent still works.
    unawaited(_service.load());
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _controller.text = widget.initialQuery!;
      _ask();
    }
  }

  void _ask() {
    if (_controller.text.trim().isEmpty) return;
    // Narrator questions are answered from the database only, with
    // sources; anything else falls back to the general retrieval.
    final narratorAnswer = _narratorService.ask(
      _controller.text,
      hadith: widget.hadith,
    );
    setState(() {
      if (narratorAnswer.handled) {
        _narratorAnswer = narratorAnswer;
        _answer = null;
      } else {
        _narratorAnswer = null;
        _answer = _service.ask(_controller.text, level: _level);
      }
    });
  }

  void _usePattern(String pattern) {
    setState(() {
      _controller.text = pattern;
      _narratorAnswer = null;
      _answer = null;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final answer = _answer;
    final narratorAnswer = _narratorAnswer;
    return Scaffold(
      appBar: AppBar(title: const Text('المساعد — استرجاع من المكتبة')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'مساعد استرجاعي: يطابق سؤالك مع صياغات معروفة ويسترجع '
                  'الأدلة من المكتبة المثبّتة مع مصادرها. ليست نموذجاً '
                  'لغوياً توليدياً، ولا يولّد إجابات ولا يُفتي.',
                  style: TextStyle(color: SunnatiColors.inkMuted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                SegmentedButton<ExplanationLevel>(
                  segments: const [
                    ButtonSegment(
                      value: ExplanationLevel.simplified,
                      label: Text('مبسّط'),
                    ),
                    ButtonSegment(
                      value: ExplanationLevel.scholarly,
                      label: Text('علمي'),
                    ),
                    ButtonSegment(
                      value: ExplanationLevel.specialist,
                      label: Text('متخصص'),
                    ),
                  ],
                  selected: {_level},
                  onSelectionChanged: (s) => setState(() => _level = s.first),
                ),
                const SizedBox(height: 8),
                const Text(
                  'مساعد الرجال — اسأل عن راوٍ: ضع اسمه مكان «…».',
                  style: TextStyle(color: SunnatiColors.inkMuted, fontSize: 12),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: narratorQuestionPatterns
                      .map(
                        (p) => ActionChip(
                          label: Text(p),
                          onPressed: () => _usePattern(p),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: const InputDecoration(
                          hintText: 'اكتب سؤالك هنا…',
                          border: OutlineInputBorder(),
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _ask(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _ask,
                      child: const Text('اسأل'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: !widget.db.isAvailable
                ? ListView(
                    padding: const EdgeInsets.all(12),
                    children: const [
                      EmptyLibraryCard(
                        title: 'المساعد غير متوفر بعد',
                        detail:
                            'المكتبة قيد الاستيراد — لا توجد نصوص لاسترجاعها بعد.',
                        icon: Icons.smart_toy_outlined,
                      ),
                    ],
                  )
                : narratorAnswer != null
                    ? _NarratorAnswerView(
                        db: widget.db,
                        answer: narratorAnswer,
                      )
                    : answer == null
                        ? const Center(
                            child: Text(
                              'مثال: أحاديث في النية، أحاديث في الصلاة…',
                            ),
                          )
                        : ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          Card(
                            color: answer.refused
                                ? SunnatiColors.goldSoft
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    answer.note,
                                    style: const TextStyle(
                                      color: SunnatiColors.inkMuted,
                                    ),
                                  ),
                                  if (answer.matchedPhrasing != null) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      'أقرب صياغة معروفة: '
                                      '${answer.matchedPhrasing}',
                                      style: const TextStyle(
                                        color: SunnatiColors.inkMuted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          if (!answer.refused &&
                              answer.sections.isNotEmpty)
                            ...answer.sections.map(
                              (s) => _ExplanationSectionCard(section: s),
                            ),
                          ...answer.evidences.map(
                            (e) => e.hadith != null
                                ? _PassageCard(
                                    db: widget.db,
                                    hadith: e.hadith!,
                                    level: answer.level,
                                  )
                                : _CommentaryCard(evidence: e),
                          ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

class _PassageCard extends StatelessWidget {
  const _PassageCard({
    required this.db,
    required this.hadith,
    required this.level,
  });

  final SunnatiDatabase db;
  final Hadith hadith;
  final ExplanationLevel level;

  @override
  Widget build(BuildContext context) {
    final text = level == ExplanationLevel.simplified && hadith.text.length > 160
        ? '${hadith.text.substring(0, 160)}…'
        : hadith.text;
    return Card(
      child: InkWell(
        onTap: () async {
          final repo = await UserRepository.load();
          if (context.mounted) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HadithReaderScreen(
                  db: db,
                  userRepo: repo,
                  hadith: hadith,
                ),
              ),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, style: const TextStyle(height: 1.8)),
              const SizedBox(height: 6),
              Text(
                'حديث ${hadith.num} — ${hadith.chapterTitle}',
                style: const TextStyle(
                  color: SunnatiColors.inkMuted,
                  fontSize: 12,
                ),
              ),
              if (level != ExplanationLevel.simplified && hadith.hasGrades)
                Text(
                  hadith.grades.map((g) => '${g.scholar}: ${g.grade}').join('، '),
                  style: const TextStyle(
                    color: SunnatiColors.inkMuted,
                    fontSize: 12,
                  ),
                ),
              if (level == ExplanationLevel.specialist && hadith.hasExplanation)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    hadith.explanation,
                    style: const TextStyle(
                      color: SunnatiColors.inkMuted,
                      fontSize: 13,
                      height: 1.7,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders one men-assistant answer: sourced lines, a link to the
/// narrator's full page, teacher/student chips and linked hadiths — or an
/// honest "no verified data" note when the database has nothing.
class _NarratorAnswerView extends StatelessWidget {
  const _NarratorAnswerView({required this.db, required this.answer});

  final SunnatiDatabase db;
  final NarratorAssistantAnswer answer;

  Future<void> _openHadith(BuildContext context, Hadith hadith) async {
    final repo = await UserRepository.load();
    if (context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => HadithReaderScreen(
            db: db,
            userRepo: repo,
            hadith: hadith,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  answer.title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                if (answer.note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    answer.note,
                    style: const TextStyle(color: SunnatiColors.inkMuted),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (!answer.hasContent)
          const EmptyLibraryCard(
            title: 'لا توجد بيانات موثّقة',
            detail:
                'لم يُسجَّل عن هذا الراوي شيء في المكتبة المثبّتة بعد — تراجم الرواة وأحوالهم قيد الاستيراد في المرحلة 5.',
            icon: Icons.person_outline,
          ),
        ...answer.lines.map(
          (line) => Card(
            child: ListTile(
              title: Text(line.text),
              subtitle: line.source.isNotEmpty
                  ? Text('المصدر: ${line.source}')
                  : null,
            ),
          ),
        ),
        if (answer.narrator != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NarratorDetailScreen(
                    db: db,
                    narratorId: answer.narrator!.id,
                  ),
                ),
              ),
              child: const Text('فتح صفحة الراوي الكاملة'),
            ),
          ),
        if (answer.narrators.isNotEmpty)
          Wrap(
            spacing: 8,
            children: answer.narrators
                .map(
                  (n) => ActionChip(
                    label: Text(n.displayName),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NarratorDetailScreen(
                          db: db,
                          narratorId: n.id,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ...answer.hadiths.map(
          (h) => Card(
            child: ListTile(
              title: Text(
                h.text.length > 120
                    ? '${h.text.substring(0, 120)}…'
                    : h.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('حديث ${h.num} — ${h.chapterTitle}'),
              onTap: () => _openHadith(context, h),
            ),
          ),
        ),
      ],
    );
  }
}

/// One section of the 14-section explanation. An unavailable section is
/// shown as unavailable ("غير متوفر في المصادر المتاحة") — never filled
/// with generated text — and its source line is omitted because there is
/// no source to show.
class _ExplanationSectionCard extends StatelessWidget {
  const _ExplanationSectionCard({required this.section});

  final ExplanationSection section;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${section.index}. ${section.title}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                if (!section.available)
                  const Text(
                    'غير متوفر',
                    style: TextStyle(
                      color: SunnatiColors.inkMuted,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              section.content,
              style: TextStyle(
                height: 1.8,
                color: section.available
                    ? null
                    : SunnatiColors.inkMuted,
              ),
            ),
            if (section.source.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'المصدر: ${section.source}',
                style: const TextStyle(
                  color: SunnatiColors.inkMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A standalone HadeethEnc commentary passage. Shown ONLY as its own
/// passage with its own HadeethEnc key and attribution — never as the
/// commentary of a Nine-Books hadith (the two are not linked).
class _CommentaryCard extends StatelessWidget {
  const _CommentaryCard({required this.evidence});

  final RagEvidence evidence;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              evidence.text,
              style: const TextStyle(height: 1.8),
            ),
            const SizedBox(height: 6),
            Text(
              'شرح منقول — ${evidence.source}',
              style: const TextStyle(
                color: SunnatiColors.inkMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
