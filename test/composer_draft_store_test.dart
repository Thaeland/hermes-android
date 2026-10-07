import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/composer_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a saved draft round-trips per session', () async {
    await ComposerDraftStore.save('s1', 'half typed');

    expect(await ComposerDraftStore.read('s1'), 'half typed');
    expect(await ComposerDraftStore.read('s2'), isNull);
  });

  test('empty text clears the draft instead of resurrecting it', () async {
    await ComposerDraftStore.save('s1', 'typed');
    await ComposerDraftStore.save('s1', '   ');

    expect(await ComposerDraftStore.read('s1'), isNull);
  });
}
