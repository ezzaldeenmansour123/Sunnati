import 'package:flutter_test/flutter_test.dart';
import 'package:sunnati/core/app_version.dart';

void main() {
  test('single source of truth: version is well-formed', () {
    expect(appVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    expect(appBuildNumber, greaterThanOrEqualTo(1));
  });

  test('display string combines version and build number', () {
    expect(appVersionDisplay, '$appVersion+$appBuildNumber');
    expect(appVersionDisplay, '1.0.0+1');
  });
}
