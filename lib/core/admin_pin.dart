/// Admin PIN (Phase 8) — pure Dart, no Flutter import.
///
/// The admin panel is protected by a PIN the owner sets on first opening
/// of the panel. There is NO default PIN anywhere in the code, and no PIN
/// (or any secret / API key) is ever stored in plain text:
///
///   stored string = "v1$iterations$saltHex$hashHex"
///   hash = SHA-256 iterated [kIterations] times over (salt + pin),
///   salt = 16 random bytes (hex), first round hashes salt+pin, every
///   later round hashes the previous digest.
///
/// The hash + salt live in SharedPreferences only (see
/// `lib/data/admin_repository.dart` [AdminPinStore]); the PIN itself is
/// never written to disk, to logs, or to the database. Verification is a
/// constant-time comparison of the hex digests.
///
/// Lockout: 5 consecutive wrong attempts lock the panel for 5 minutes;
/// a successful unlock clears the counter. The lockout state is kept in
/// [PinLockout], a pure value type the store persists.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Stored-hash format version.
const String kAdminPinFormatVersion = 'v1';

/// SHA-256 iterations for the PIN hash. Deliberately modest (a PIN is
/// short; the lockout, not the iteration count, is the brute-force
/// defence) so unlock stays instant on low-end devices.
const int kAdminPinIterations = 10000;

/// Salt length in bytes (stored hex-encoded).
const int kAdminPinSaltBytes = 16;

/// Minimum / maximum PIN length (digits only).
const int kAdminPinMinLength = 4;
const int kAdminPinMaxLength = 12;

/// Failed attempts before the panel locks.
const int kAdminPinMaxAttempts = 5;

/// Lockout duration after [kAdminPinMaxAttempts] failures.
const Duration kAdminPinLockout = Duration(minutes: 5);

final RegExp _pinRegExp = RegExp(r'^\d{4,12}$');

/// Why a PIN candidate is rejected at setup time ('' = acceptable).
String pinSetupError(String pin) {
  if (!_pinRegExp.hasMatch(pin)) {
    return 'الرمز من 4 إلى 12 رقماً فقط.';
  }
  if (pin.split('').toSet().length == 1) {
    return 'الرمز لا يكون رقماً واحداً مكرراً.';
  }
  var ascending = true;
  var descending = true;
  for (var i = 1; i < pin.length; i++) {
    final prev = pin.codeUnitAt(i - 1) - 0x30;
    final cur = pin.codeUnitAt(i) - 0x30;
    if (cur != prev + 1) ascending = false;
    if (cur != prev - 1) descending = false;
  }
  if (ascending || descending) {
    return 'الرمز لا يكون أرقاماً متتابعة.';
  }
  return '';
}

/// Create a stored hash string for [pin] (with a fresh random salt).
/// Throws [ArgumentError] when the PIN fails [pinSetupError].
String createAdminPinHash(String pin, {String? saltHexForTest}) {
  final error = pinSetupError(pin);
  if (error.isNotEmpty) throw ArgumentError(error);
  final saltHex = saltHexForTest ?? _randomSaltHex();
  return _hashWithSalt(pin, saltHex);
}

/// Verify [pin] against a stored hash string. Returns false for a
/// malformed stored value (never throws on bad input).
bool verifyAdminPin(String pin, String stored) {
  try {
    final parts = stored.split(r'$');
    if (parts.length != 4 || parts[0] != kAdminPinFormatVersion) {
      return false;
    }
    final iterations = int.parse(parts[1]);
    final saltHex = parts[2];
    final expectedHex = parts[3];
    if (iterations <= 0 || saltHex.isEmpty || expectedHex.isEmpty) {
      return false;
    }
    final actual = _hashWithSaltAndIterations(pin, saltHex, iterations);
    final actualHash = actual.split(r'$').last;
    return _constantTimeEquals(actualHash, expectedHex);
  } catch (_) {
    return false;
  }
}

String _randomSaltHex() {
  final random = Random.secure();
  final bytes = List<int>.generate(kAdminPinSaltBytes, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _hashWithSalt(String pin, String saltHex) =>
    _hashWithSaltAndIterations(pin, saltHex, kAdminPinIterations);

String _hashWithSaltAndIterations(String pin, String saltHex, int iterations) {
  var digest = sha256.convert(utf8.encode('$saltHex:$pin')).bytes;
  for (var i = 1; i < iterations; i++) {
    digest = sha256.convert(digest).bytes;
  }
  final hashHex =
      digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '$kAdminPinFormatVersion\$$iterations\$$saltHex\$$hashHex';
}

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Pure lockout state: consecutive failures + the instant the lock ends
/// (epoch milliseconds, 0 = not locked).
class PinLockout {
  const PinLockout({this.failures = 0, this.lockedUntilMs = 0});

  final int failures;
  final int lockedUntilMs;

  bool isLockedAt(int nowMs) => lockedUntilMs > nowMs;

  /// Remaining lockout as a Duration (zero when not locked).
  Duration remainingAt(int nowMs) {
    if (!isLockedAt(nowMs)) return Duration.zero;
    return Duration(milliseconds: lockedUntilMs - nowMs);
  }

  /// State after one more failed attempt at [nowMs].
  PinLockout recordFailure(int nowMs) {
    final nextFailures = failures + 1;
    if (nextFailures >= kAdminPinMaxAttempts) {
      return PinLockout(
        failures: 0,
        lockedUntilMs: nowMs + kAdminPinLockout.inMilliseconds,
      );
    }
    return PinLockout(failures: nextFailures, lockedUntilMs: 0);
  }

  /// State after a successful unlock.
  PinLockout get cleared => const PinLockout();
}
