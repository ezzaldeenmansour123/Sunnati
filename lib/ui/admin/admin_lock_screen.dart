import 'package:flutter/material.dart';

import '../../core/admin_pin.dart';
import '../../data/admin_repository.dart';
import '../../data/database.dart';
import '../../data/user_repository.dart';
import 'admin_panel_screen.dart';

/// Admin panel gate (Phase 8).
///
/// Separate from the normal UI: the panel opens only from Settings →
/// "لوحة الإدارة", and only after the PIN. On first opening the owner
/// sets a PIN (4–12 digits, no repeated digit, no sequence); there is
/// NO default PIN anywhere in the code. The PIN is stored as a salted
/// iterated SHA-256 hash (see `lib/core/admin_pin.dart`) — never in
/// plain text. After 5 wrong attempts the panel locks for 5 minutes.
class AdminLockScreen extends StatefulWidget {
  const AdminLockScreen({
    super.key,
    required this.db,
    required this.userRepo,
  });

  final SunnatiDatabase db;
  final UserRepository userRepo;

  @override
  State<AdminLockScreen> createState() => _AdminLockScreenState();
}

class _AdminLockScreenState extends State<AdminLockScreen> {
  AdminPinStore? _pinStore;
  bool _loading = true;
  String? _error;

  final _pinController = TextEditingController();
  final _pinConfirmController = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final store = await AdminPinStore.load();
    if (!mounted) return;
    setState(() {
      _pinStore = store;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _pinController.dispose();
    _pinConfirmController.dispose();
    super.dispose();
  }

  Future<void> _setupPin() async {
    final store = _pinStore;
    if (store == null) return;
    final pin = _pinController.text.trim();
    final error = pinSetupError(pin);
    if (error.isNotEmpty) {
      setState(() => _error = error);
      return;
    }
    if (pin != _pinConfirmController.text.trim()) {
      setState(() => _error = 'الرمزان غير متطابقين.');
      return;
    }
    try {
      await store.setPin(pin);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message);
      return;
    } on StateError catch (e) {
      setState(() => _error = e.message);
      return;
    }
    if (!mounted) return;
    _openPanel();
  }

  Future<void> _unlock() async {
    final store = _pinStore;
    if (store == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lockout = store.lockout;
    if (lockout.isLockedAt(nowMs)) {
      final remaining = lockout.remainingAt(nowMs);
      setState(
        () => _error =
            'اللوحة مقفلة بعد محاولات خاطئة — أعد المحاولة بعد '
            '${remaining.inMinutes + 1} دقائق.',
      );
      return;
    }
    final ok = await store.verifyPin(_pinController.text.trim());
    if (!mounted) return;
    if (ok) {
      _openPanel();
    } else {
      final left = kAdminPinMaxAttempts - store.lockout.failures;
      setState(
        () => _error = left > 0
            ? 'رمز غير صحيح. بقيت $left محاولات قبل القفل المؤقت.'
            : 'رمز غير صحيح. اللوحة مقفلة 5 دقائق.',
      );
    }
  }

  void _openPanel() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => AdminPanelScreen(
          db: widget.db,
          userRepo: widget.userRepo,
          pinStore: _pinStore!,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = _pinStore;
    return Scaffold(
      appBar: AppBar(title: const Text('لوحة الإدارة')),
      body: _loading || store == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Icon(Icons.admin_panel_settings_outlined, size: 48),
                const SizedBox(height: 12),
                Text(
                  store.isPinSet
                      ? 'أدخل رمز الإدارة لفتح اللوحة.'
                      : 'هذه أول مرة تفتح فيها لوحة الإدارة.\n'
                          'اضبط رمزاً (4–12 رقماً) — لا يوجد رمز افتراضي، '
                          'والرمز يُحفظ مشفراً على جهازك فقط.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(height: 1.8),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _pinController,
                  keyboardType: TextInputType.number,
                  obscureText: _obscure,
                  maxLength: 12,
                  decoration: InputDecoration(
                    labelText: store.isPinSet ? 'رمز الإدارة' : 'الرمز الجديد',
                    counterText: '',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onSubmitted: (_) =>
                      store.isPinSet ? _unlock() : _setupPin(),
                ),
                if (!store.isPinSet) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pinConfirmController,
                    keyboardType: TextInputType.number,
                    obscureText: _obscure,
                    maxLength: 12,
                    decoration: const InputDecoration(
                      labelText: 'تأكيد الرمز',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _setupPin(),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: store.isPinSet ? _unlock : _setupPin,
                  child: Text(store.isPinSet ? 'فتح اللوحة' : 'ضبط الرمز'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'اللوحة منفصلة عن واجهة المستخدم العادية، ولا تؤثر على '
                  'المكتبة. كل إجراء فيها يُسجَّل في سجل التدقيق.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
    );
  }
}
