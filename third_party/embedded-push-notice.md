# Embedded push distributor notice

Hermes Android uses `org.unifiedpush.android:embedded-fcm-distributor:3.1.0`,
maintained by [UnifiedPush](https://codeberg.org/UnifiedPush/android-embedded_fcm_distributor).
It is unmodified. It supplies the optional Google Play Services transport; no
Firebase or Google Play Services client SDK is bundled by this dependency.
Google infrastructure and a functioning Play Services runtime are still required
for that transport. External UnifiedPush distributors remain supported.

## Licence discrepancy and release review

The published [3.1.0 POM](https://repo.maven.apache.org/maven2/org/unifiedpush/android/embedded-fcm-distributor/3.1.0/embedded-fcm-distributor-3.1.0.pom)
declares Apache-2.0, but the [exact upstream tag's LICENSE](https://codeberg.org/UnifiedPush/android-embedded_fcm_distributor/raw/tag/3.1.0/LICENSE)
contains LGPL-2.1. This repository does **not** infer a dual licence or claim that
the component is Apache-only. The upstream LGPL text is retained verbatim in
[licenses/embedded-fcm-distributor-LGPL-2.1.txt](licenses/embedded-fcm-distributor-LGPL-2.1.txt).
Resolve the upstream grant, or confirm all applicable LGPL distribution obligations
are met, before publishing an APK release. This notice is not a claim of F-Droid
approval or legal clearance.

## Source and replacement/rebuild

- Exact tagged upstream source: <https://codeberg.org/UnifiedPush/android-embedded_fcm_distributor/src/tag/3.1.0>
- Published source JAR: <https://repo.maven.apache.org/maven2/org/unifiedpush/android/embedded-fcm-distributor/3.1.0/embedded-fcm-distributor-3.1.0-sources.jar>
- Hermes Android source and build scripts are in this repository; Flutter 3.44,
  Dart 3.12, JDK 17 and Android SDK 36 are used for this change.

To modify or replace the library, obtain its exact source, make your changes and
build/publish the Android library to a local Maven repository using its upstream
Gradle build instructions. In this app's Android Gradle configuration, substitute
the embedded distributor dependency with your locally built AAR or Maven artifact,
then run `flutter pub get` and `flutter build apk --debug`. The app's entire source
is available, so the application can be rebuilt/relinked with a modified library;
no vendor registration project, Firebase secret or release signing key is needed
for a development build. An altered APK cannot replace an installed release signed
by a different key; the debug application uses a separate `.dev` application ID.
A release distributor must retain the corresponding library and application source,
licence notices, and any required relinking materials for the binaries it actually
ships rather than relying on these upstream URLs alone.
