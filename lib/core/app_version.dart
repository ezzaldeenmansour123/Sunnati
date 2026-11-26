/// Single source of truth for the app version.
///
/// The version shown in Settings → About MUST come from here, never from a
/// hand-written string in a widget (that is how Ezz-alsonah ended up showing
/// 1.0.0 while pubspec said 1.1.1+3). Keep [appVersion] in sync with
/// pubspec.yaml; [version_test.dart] guards the format, and CI guards the
/// match against pubspec (see .github/workflows/build.yml).
library;

/// Semantic version, e.g. `1.0.0`. Mirrors `version:` in pubspec.yaml.
const String appVersion = '1.0.0';

/// Build number, e.g. `1`. Mirrors the `+N` suffix in pubspec.yaml.
const int appBuildNumber = 1;

/// Display string, e.g. `1.0.0+1`.
const String appVersionDisplay = '$appVersion+$appBuildNumber';
