import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_version.dart';
import '../core/theme.dart';
import '../data/database.dart';
import '../data/user_repository.dart';
import 'admin/admin_lock_screen.dart';

/// Settings (master prompt §13): appearance (light/dark/system), font
/// size, storage info, sources & licences, backup import, and About.
/// Every row does something real; nothing is a placeholder row.
///
/// The version shown here comes from [appVersionDisplay] — a single source
/// of truth (see `lib/core/app_version.dart`).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.db,
    required this.userRepo,
    required this.onThemeModeChanged,
    required this.onFontScaleChanged,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;
  final ValueChanged<String> onThemeModeChanged;
  final ValueChanged<double> onFontScaleChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<void> _importBackup() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      _snack('الحافظة فارغة — انسخ نسخة احتياطية JSON أولاً.');
      return;
    }
    try {
      await widget.userRepo.importJson(text);
      if (mounted) setState(() {});
      _snack('تم استيراد النسخة الاحتياطية بنجاح.');
    } on FormatException catch (e) {
      _snack('تعذّر الاستيراد: ${e.message}');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showSources() {
    // Phase 5 core: the narrators attribution (plan §2.4, verbatim) plus
    // the live installed status — the dialog never claims narrators are
    // installed when they are not.
    final narratorsStatus = widget.db.narratorsAvailable
        ? 'قاعدة الرواة مثبّتة: ${widget.db.narratorCount()} راوٍ موثّق.'
        : 'قاعدة الرواة غير مثبّتة — ${widget.db.narratorsUnavailableReason}';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('المصادر والتراخيص'),
        content: SingleChildScrollView(
          child: Text(
            'الكتب التسعة: مجموعة quranlab/hadith (revision مثبّت في بيانات المكتبة) — المتن العربي ملكية عامة.\n\n'
            'مسند أحمد وسنن الدارمي: رقمنة mhashim6/Open-Hadith-Data تحت ODbL-1.0 / DbCL-1.0 — مع النسبة والمشاركة بالمثل.\n\n'
            'شرح موسوعة الأحاديث النبوية: HadeethEnc.com — دون تعديل، مع ذكر المصدر ورقم الإصدار.\n\n'
            'تراجم الرواة: نصوص كتب الرجال مأخوذة من OpenITI — Open Islamicate Texts Initiative (KITAB Project)، برخصة Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0)، https://creativecommons.org/licenses/by-nc-sa/4.0/ — معرّف الملف: 0852IbnHajarCasqalani.TaqribTahdhib (طبعة محمد عوامة، الأولى، دار الرشيد، 1406هـ/1986م). حُوِّل النص إلى قاعدة بيانات منظمة (اشتقاق)؛ قاعدة الرواة المشتقة منشورة بنفس الترخيص CC BY-NC-SA 4.0.\n\n'
            '$narratorsStatus\n\n'
            'خط Amiri: SIL Open Font License 1.1.\n\n'
            'لا يُنسخ أي محتوى من sunnah.com.',
            style: const TextStyle(height: 1.7),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    // Phase 5 core: the narrators sentence reflects the live installed
    // state instead of the old "no verified data yet" claim.
    final narratorsLine = widget.db.narratorsAvailable
        ? 'تراجم الرواة: ${widget.db.narratorCount()} راوٍ موثّق من تقريب التهذيب (OpenITI).'
        : 'تراجم الرواة بلا بيانات موثقة بعد.';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حول التطبيق'),
        content: SingleChildScrollView(
          child: Text(
            'سُنَّتي | SUNNATI\n'
            'الإصدار $appVersionDisplay\n\n'
            'السنة النبوية بين يديك، بفهم موثّق وذكاء متقدم.\n\n'
            'مكتبة حديثية عربية تعمل دون إنترنت. المساعد يسترجع من المكتبة فقط ولا يولّد إجابات.\n\n'
            'المرحلة الحالية: 9–10 — الاختبارات الشاملة وحزمة الإصدار v1.0.0. الكتب التسعة مثبّتة وموثّقة (65,712 حديثاً). $narratorsLine التخريج والطرق بلا بيانات موثقة بعد — تُعرض الشاشات ذلك بصراحة ولا تخترع شيئاً.',
            style: const TextStyle(height: 1.7),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.userRepo.themeMode;
    final scale = widget.userRepo.fontScale;
    final meta = widget.db.meta();
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _Section('المظهر'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('الوضع الليلي'),
                  trailing: DropdownButton<String>(
                    value: mode,
                    items: const [
                      DropdownMenuItem(value: 'system', child: Text('تلقائي')),
                      DropdownMenuItem(value: 'light', child: Text('فاتح')),
                      DropdownMenuItem(value: 'dark', child: Text('ليلي')),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      await widget.userRepo.setThemeMode(v);
                      widget.onThemeModeChanged(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
                ListTile(
                  title: const Text('حجم الخط'),
                  subtitle: Slider(
                    value: scale,
                    min: 0.85,
                    max: 1.6,
                    divisions: 15,
                    label: scale.toStringAsFixed(2),
                    onChanged: (v) async {
                      await widget.userRepo.setFontScale(v);
                      widget.onFontScaleChanged(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
          _Section('التخزين والبيانات'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('الأحاديث المثبّتة'),
                  subtitle: Text(
                    widget.db.isAvailable
                        ? '${widget.db.totalHadiths()} حديثاً'
                        : 'لا توجد أحاديث بعد — المكتبة قيد الاستيراد',
                  ),
                ),
                if (meta.isNotEmpty)
                  ListTile(
                    title: const Text('مصدر المكتبة'),
                    subtitle: Text(
                      '${meta['source'] ?? ''}\nrevision: ${meta['source_revision'] ?? '—'}',
                    ),
                  ),
                ListTile(
                  title: const Text('تصدير نسخة احتياطية (JSON)'),
                  subtitle: const Text('تُنسخ إلى الحافظة'),
                  trailing: const Icon(Icons.ios_share),
                  onTap: () async {
                    await Clipboard.setData(
                      ClipboardData(text: widget.userRepo.exportJson()),
                    );
                    _snack('تم نسخ النسخة الاحتياطية إلى الحافظة.');
                  },
                ),
                ListTile(
                  title: const Text('استيراد نسخة احتياطية (JSON)'),
                  subtitle: const Text('من نص منسوخ في الحافظة'),
                  trailing: const Icon(Icons.file_download_outlined),
                  onTap: _importBackup,
                ),
              ],
            ),
          ),
          _Section('الإدارة'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('لوحة الإدارة'),
                  subtitle: const Text(
                    'محمية برمز — استيراد ومراجعة المحتوى وسجل التدقيق',
                  ),
                  trailing: const Icon(Icons.admin_panel_settings_outlined),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AdminLockScreen(
                        db: widget.db,
                        userRepo: widget.userRepo,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _Section('حول'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('المصادر والتراخيص'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: _showSources,
                ),
                ListTile(
                  title: const Text('حول التطبيق'),
                  subtitle: Text('الإصدار $appVersionDisplay'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: _showAbout,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'يعمل دون إنترنت. لا حسابات، لا إعلانات، ولا تُرسل بياناتك إلى أي خادم.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SunnatiColors.inkMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
