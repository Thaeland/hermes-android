import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Adds local application and third-party notices without reading assets yet.
void registerAppLicenses({AssetBundle? assetBundle}) {
  if (_registered) return;
  _registered = true;

  LicenseRegistry.addLicense(() async* {
    final bundle = assetBundle ?? rootBundle;
    const notices = <String, String>{
      'LICENSE': 'Hermes Android',
      'assets/fonts/OFL.txt': 'Cinzel',
      'third_party/embedded-push-notice.md': 'embedded-fcm-distributor (3.1.0)',
      'third_party/embedded-push-relink.md': 'embedded-fcm-distributor (3.1.0)',
      'third_party/licenses/embedded-fcm-distributor-LGPL-2.1.txt':
          'embedded-fcm-distributor (3.1.0)',
    };
    for (final notice in notices.entries) {
      yield LicenseEntryWithLineBreaks([
        notice.value,
      ], await bundle.loadString(notice.key));
    }
  });
}
