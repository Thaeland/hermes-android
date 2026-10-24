import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what the connection dialog asks `file_picker` for.
class _FakeFilePicker extends FilePicker {
  final List<({FileType type, List<String>? allowedExtensions})> calls =
      <({FileType type, List<String>? allowedExtensions})>[];

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    @Deprecated('allowCompression is deprecated and has no effect.')
    bool? allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool? withData = false,
    bool? withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls.add((type: type, allowedExtensions: allowedExtensions));
    return null;
  }
}

Future<_FakeFilePicker> _openClientCertificateSection(
  WidgetTester tester,
) async {
  final picker = _FakeFilePicker();
  FilePicker.platform = picker;
  addTearDown(() => FilePicker.platform = _FakeFilePicker());

  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(HermesApp(connManager: ConnectionManager(prefs)));
  await tester.pumpAndSettle();

  await tester.tap(find.byTooltip('Add Connection'));
  await tester.pumpAndSettle();

  await tester.enterText(
    find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == 'Host',
    ),
    'https://gateway.example',
  );
  await tester.pumpAndSettle();

  final scrollable = find
      .descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Scrollable),
      )
      .first;
  final toggle = find.byKey(const Key('connection_client_certificate_toggle'));
  await tester.scrollUntilVisible(toggle, 200, scrollable: scrollable);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
  return picker;
}

Future<void> _tapPickerButton(WidgetTester tester, Key key) async {
  final button = find.byKey(key);
  final scrollable = find
      .descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(button, 200, scrollable: scrollable);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Android picks certificate files unfiltered so PEM files are selectable',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final picker = await _openClientCertificateSection(tester);
      await _tapPickerButton(
        tester,
        const Key('connection_client_certificate_pick_cert_pem'),
      );
      await _tapPickerButton(
        tester,
        const Key('connection_client_certificate_pick_key_pem'),
      );
      await _tapPickerButton(
        tester,
        const Key('connection_client_certificate_pick_p12'),
      );

      expect(picker.calls, hasLength(3));
      for (final call in picker.calls) {
        expect(call.type, FileType.any);
        expect(call.allowedExtensions, isNull);
      }

      // Reset before the test body ends: flutter_test verifies foundation
      // debug variables are unset after every test.
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'desktop keeps the extension filter for certificate files',
    (tester) async {
      // flutter_test defaults to an Android target, so pin the desktop
      // platform explicitly for this case.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      final picker = await _openClientCertificateSection(tester);
      await _tapPickerButton(
        tester,
        const Key('connection_client_certificate_pick_cert_pem'),
      );
      await _tapPickerButton(
        tester,
        const Key('connection_client_certificate_pick_p12'),
      );

      expect(picker.calls, hasLength(2));
      expect(picker.calls[0].type, FileType.custom);
      expect(picker.calls[0].allowedExtensions, [
        'pem',
        'crt',
        'cer',
        'key',
      ]);
      expect(picker.calls[1].type, FileType.custom);
      expect(picker.calls[1].allowedExtensions, ['p12', 'pfx']);

      // Reset before the test body ends: flutter_test verifies foundation
      // debug variables are unset after every test.
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
