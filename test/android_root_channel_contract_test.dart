import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'activity installs battery settings beside push and existing intent/keepalive channels',
    () {
      final activity = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/MainActivity.kt',
      ).readAsStringSync();
      expect(
        activity,
        contains(
          'BackgroundWorkPlatform.install(this, flutterEngine.dartExecutor.binaryMessenger)',
        ),
      );
      expect(activity, contains('MobilePushBridge.attach(channel)'));
      expect(activity, contains('MobilePushBridge.captureTap(this, intent)'));
      expect(activity, contains('MobilePushBridge.detach()'));
      expect(activity, contains('shareChannelName'));
      expect(activity, contains('launchChannelName'));
      expect(activity, contains('keepAliveChannelName'));
      final battery = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/BackgroundWorkPlatform.kt',
      ).readAsStringSync();
      expect(
        battery,
        contains('com.hermesagent.hermes_android/background_work'),
      );
      expect(battery, contains('"openBatterySettings"'));
      expect(
        battery,
        contains(
          'Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)',
        ),
      );
      expect(
        battery,
        isNot(
          contains(
            'Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
          ),
        ),
      );
    },
  );
}
