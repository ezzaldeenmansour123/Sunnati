import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/database.dart';
import '../models/narrator.dart';
import 'narrator_detail_screen.dart';
import 'widgets/empty_library.dart';

/// Narrators encyclopedia (master prompt §10) — Phase 5.
///
/// Search by name, kunya or laqab, including part of a name (the query is
/// normalised before matching, so `زهر` finds `الزهري`), with filters by
/// generation (الطبقة) and by jarh-wa-ta'dil verdict — both filter lists
/// come from the database itself, so they can never offer a value with no
/// rows. Tapping a narrator opens his full page.
///
/// No narrator data is imported yet (no verified, licensed narrator source
/// has been selected — Phase 5). The screen therefore honestly reports
/// that no biographies are installed yet. It never invents a biography, a
/// status (ثقة/ضعيف…) or a death year.
class NarratorsScreen extends StatefulWidget {
  const NarratorsScreen({super.key, required this.db});

  final SunnatiDatabase db;

  @override
  State<NarratorsScreen> createState() => _NarratorsScreenState();
}

class _NarratorsScreenState extends State<NarratorsScreen> {
  final _controller = TextEditingController();
  List<Narrator> _results = const <Narrator>[];
  List<String> _tiers = const <String>[];
  List<String> _statuses = const <String>[];
  String? _tier;
  String? _status;
  bool _searched = false;
  late final int _totalNarrators;

  @override
  void initState() {
    super.initState();
    _totalNarrators = widget.db.narratorCount();
    _tiers = widget.db.narratorTiers();
    _statuses = widget.db.narratorStatuses();
    _results = widget.db.listNarrators();
  }

  void _run() {
    setState(() {
      final query = _controller.text.trim();
      _results = query.isEmpty
          ? widget.db.listNarrators(tier: _tier, status: _status)
          : widget.db.searchNarrators(
              query,
              tier: _tier,
              status: _status,
            );
      _searched = true;
    });
  }

  void _resetFilters() {
    setState(() {
      _tier = null;
      _status = null;
      _run();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('موسوعة الرواة')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: TextField(
              controller: _controller,
              decoration: const InputDecoration(
                hintText: 'ابحث عن راوٍ بالاسم أو الكنية أو اللقب…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _run(),
              onChanged: (_) {
                if (_controller.text.trim().isEmpty && _searched) _run();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(_tier),
                    initialValue: _tier,
                    decoration: const InputDecoration(
                      labelText: 'الطبقة',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _tiers
                        .map(
                          (t) => DropdownMenuItem(value: t, child: Text(t)),
                        )
                        .toList(),
                    onChanged: _tiers.isEmpty
                        ? null
                        : (v) => setState(() {
                              _tier = v;
                              _run();
                            }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(_status),
                    initialValue: _status,
                    decoration: const InputDecoration(
                      labelText: 'حكم الجرح والتعديل',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _statuses
                        .map(
                          (s) => DropdownMenuItem(value: s, child: Text(s)),
                        )
                        .toList(),
                    onChanged: _statuses.isEmpty
                        ? null
                        : (v) => setState(() {
                              _status = v;
                              _run();
                            }),
                  ),
                ),
                if (_tier != null || _status != null)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'مسح التصفية',
                    onPressed: _resetFilters,
                  ),
              ],
            ),
          ),
          Expanded(
            child: _totalNarrators == 0
                ? ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      // When the narrators package is held back pending
                      // approval, the empty state names that reason —
                      // it must not look like a bug or a missing feature.
                      // (When the package IS installed the count is > 0
                      // and this branch is never reached.)
                      if (!widget.db.narratorsAvailable)
                        const EmptyLibraryCard(
                          title: 'حزمة الرواة قيد انتظار الموافقة',
                          detail:
                              'تراجم الرواة الموثّقة قيد انتظار الموافقة ولم تُثبَّت بعد — لا تُعرض هنا أي ترجمة غير موثقة.',
                          icon: Icons.people_outline,
                        )
                      else
                        const EmptyLibraryCard(
                          title: 'لا توجد تراجم بعد',
                          detail:
                              'لم تُستورد تراجم الرواة بعد — مصدر موثّق ومرخّص للتراجم وأحوال الرواة (ثقة، ثبت، ضعيف، مدلس…) قيد الاختيار في المرحلة 5. لا تُعرض هنا أي ترجمة غير موثقة.',
                          icon: Icons.people_outline,
                        ),
                      if (_searched)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'لا توجد نتائج — لا تراجم مثبّتة بعد.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: SunnatiColors.inkMuted),
                          ),
                        ),
                    ],
                  )
                : _results.isEmpty
                    ? const Center(
                        child: Text(
                          'لا توجد نتائج مطابقة للبحث أو التصفية.',
                          style: TextStyle(color: SunnatiColors.inkMuted),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final n = _results[index];
                          return Card(
                            child: ListTile(
                              leading: const Icon(
                                Icons.person_outline,
                                color: SunnatiColors.gold,
                              ),
                              title: Text(n.displayName),
                              subtitle: Text(
                                [
                                  if (n.kunya.isNotEmpty) n.kunya,
                                  if (n.hasLaqab) n.laqab,
                                  if (n.tier.isNotEmpty) n.tier,
                                  if (n.hasStatus)
                                    '${n.status} (${n.statusSource})',
                                  if (n.hasDeath)
                                    'توفي ${n.deathYearHijri}هـ',
                                ].join(' — '),
                              ),
                              trailing: n.isDisputed
                                  ? const Chip(label: Text('مختلف فيه'))
                                  : null,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => NarratorDetailScreen(
                                    db: widget.db,
                                    narratorId: n.id,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
