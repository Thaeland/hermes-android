import 'package:flutter/widgets.dart';

import 'package:hermes_android/l10n/app_localizations.dart';

export 'package:hermes_android/l10n/app_localizations.dart' show AppLocalizations;

/// Convenience accessor for the generated [AppLocalizations].
///
/// Screens and widgets can read localized strings with `context.l10n.someKey`
/// instead of importing and resolving [AppLocalizations] everywhere.
extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;
}
