import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/core/admin_pin.dart';

void main() {
  group('pinSetupError', () {
    test('accepts a normal PIN', () {
      expect(pinSetupError('4829'), isEmpty);
      expect(pinSetupError('193847'), isEmpty);
    });

    test('rejects non-digits and wrong lengths', () {
      expect(pinSetupError('123'), isNotEmpty);
      expect(pinSetupError('1234567890123'), isNotEmpty);
      expect(pinSetupError('12a4'), isNotEmpty);
    });

    test('rejects a repeated digit and sequences', () {
      expect(pinSetupError('0000'), isNotEmpty);
      expect(pinSetupError('7777'), isNotEmpty);
      expect(pinSetupError('1234'), isNotEmpty);
      expect(pinSetupError('4321'), isNotEmpty);
    });
  });

  group('createAdminPinHash / verifyAdminPin', () {
    test('a correct PIN verifies, a wrong one does not', () {
      final stored = createAdminPinHash('4829');
      expect(verifyAdminPin('4829', stored), isTrue);
      expect(verifyAdminPin('4828', stored), isFalse);
      expect(verifyAdminPin('', stored), isFalse);
    });

    test('two hashes of the same PIN differ (fresh salt)', () {
      final a = createAdminPinHash('4829');
      final b = createAdminPinHash('4829');
      expect(a, isNot(equals(b)));
      expect(verifyAdminPin('4829', a), isTrue);
      expect(verifyAdminPin('4829', b), isTrue);
    });

    test('malformed stored values never verify and never throw', () {
      expect(verifyAdminPin('4829', ''), isFalse);
      expect(verifyAdminPin('4829', 'garbage'), isFalse);
      expect(verifyAdminPin('4829', 'v1\$1\$aa\$bb'), isFalse);
    });

    test('a weak PIN cannot be hashed', () {
      expect(() => createAdminPinHash('1234'), throwsArgumentError);
      expect(() => createAdminPinHash('0000'), throwsArgumentError);
    });

    test('stored format carries version, iterations and salt', () {
      final stored = createAdminPinHash(
        '4829',
        saltHexForTest: '00' * 16,
      );
      final parts = stored.split(r'$');
      expect(parts[0], 'v1');
      expect(parts[1], '$kAdminPinIterations');
      expect(parts[2], '00' * 16);
      expect(parts[3].length, 64);
    });
  });

  group('PinLockout', () {
    test('locks after the maximum failures and clears on success', () {
      var state = const PinLockout();
      for (var i = 0; i < kAdminPinMaxAttempts - 1; i++) {
        state = state.recordFailure(1000);
        expect(state.isLockedAt(1000), isFalse);
      }
      state = state.recordFailure(1000);
      expect(state.isLockedAt(1000), isTrue);
      expect(
        state.remainingAt(1000),
        kAdminPinLockout,
      );
      expect(state.isLockedAt(1000 + kAdminPinLockout.inMilliseconds), isFalse);
      expect(state.cleared.failures, 0);
      expect(state.cleared.isLockedAt(1000), isFalse);
    });
  });
}
