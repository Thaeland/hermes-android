import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';

/// Opens web links only after an explicit tap. Gateway artifacts are handled by
/// their owning message; local files, relative paths and app intents stay inert.
Future<void> openMarkdownWebLink(BuildContext context, String? href) async {
  if (!context.mounted || href == null) return;
  final uri = Uri.tryParse(href);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    return;
  }

  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // Missing browser/plugin and rejected platform intents have the same UI.
  }
  if (opened || !context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(context.l10n.could_not_open_link)));
}
