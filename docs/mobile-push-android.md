# Optional Android UnifiedPush

This transport is **off by default**, uses **no Firebase/FCM SDK**, and is separate
from local notifications and active-turn background connection handling. It binds
one explicitly chosen saved connection per Android installation. It does not
subscribe other connections, all users, or every session automatically.

## Setup

1. Install/configure a UnifiedPush distributor on the phone yourself (for example
   ntfy or Sunup). Hermes does not install one or create an external account.
2. The operator separately installs/enables the `mobile-push` dashboard plugin and
   authorizes your dashboard principal plus the durable session IDs you select.
   Default operator/session ACLs deny registration. A stock server without the
   plugin is shown as unavailable, not as successfully registered.
3. Open this connection's Settings → Android UnifiedPush. Choose the installed
   distributor, paste durable session IDs from your server session browser (one
   per line), check explicit consent, then Enable. IDs are not titles or local
   temporary chat IDs. No wildcard/all-users subscription is offered.
4. Android notification permission is requested only on that explicit action.
   An endpoint from the distributor is registered over the connection's existing
   authenticated DashboardClient. Subscriber `p256dh` and `auth` come from the
   connector; they are **not** the server's VAPID public key.
5. Keep/reopen Hermes until **Active**. The server sends an encrypted challenge;
   receiving it proves possession of the subscriber private key. The native
   service queues that proof even if the Activity/Flutter engine is absent or the
   authenticated PUT has not returned its generation yet. Only an authenticated
   confirmation response activates the installation.

Pending is not active. `Reconcile / retry` refreshes the authenticated event feed,
retries distributor registration when it failed, and retries failed server
revocations. Delivery is best-effort, not a guarantee. A changed endpoint
immediately clears local generation/active authority and queued old taps; the
next foreground reconciliation registers and confirms it again. Editing,
removing or importing a bound saved connection revokes native authority before
changing its credentials/metadata; opt in again afterwards.

Disable revokes local consent, queued hints, taps, subscription material, and
visible transport notifications **before** distributor IPC or authenticated
server DELETE. Failed server revocations remain recorded for foreground retry.
They are never sent using another connection or changed credentials. If the
original login/origin is no longer available, revoke the stale installation
server-side. Local authority remains off regardless.

## Privacy and lifecycle

* The official native connector `org.unifiedpush.android:connector:3.3.5` receives
  through its manifest receiver and our non-exported `MobilePushService`. It does
  not require an Activity, Flutter UI, foreground socket, or background startup
  screen. Only `PushMessage.decrypted == true` is accepted; plaintext fallback
  messages from the connector are discarded.
* The connector manages subscription key generation and encrypted private-key
  storage. Hermes stores its endpoint/auth material, consent, installation nonce,
  generation, session allowlist, pending challenge/revocation/tap queues and a
  bounded 256-event dedup window in an AES-GCM envelope, using a non-exportable
  Android Keystore key. SharedPreferences contains ciphertext only. Backups are
  disabled in the app manifest. Neither endpoints, auth secrets, proofs nor
  payloads are logged or exported by configuration backup.
* Hints contain only schema/event ID/kind/generation/nonce/expiry and an optional
  challenge. Unknown kinds, wrong installation/nonce/generation, expired hints,
  disabled consent, and unconfirmed notifications are rejected natively.
* Native notifications are generic (no session ID/title/text/approval token).
  Notification taps carry a locally issued event/installation/nonce/revision,
  are revalidated against durable authority and expiry, and resolve session IDs
  **only** from the authenticated plugin event feed. No arbitrary URL, automatic
  approval, or prompt resubmission is implemented.
* Current master/per-kind notification preferences are synchronized into native
  encrypted state. Suppression cancels already-visible transport notifications.
  These preferences suppress delivery, not consent; use Disable to unsubscribe.
  Android notification permission is never requested from the headless service.
* Background delivery is not the same as Android **Force stop**: force-stopped
  applications generally cannot receive broadcasts until opened again. OEM
  battery/distributor restrictions can also prevent delivery.

## Root integration API (app owner)

No `main.dart` edits are included, to keep this feature cherry-pick isolated from
parallel background-chat/root changes. Settings is integrated and functional;
the app root must install these hooks for startup confirmation and tap routing:

```dart
final mobilePush = MobilePushService.shared;

// After normal ConnectionManager credential hydration, after the first frame.
// Do not await this before runApp / first frame. Startup never requests consent.
unawaited(mobilePush.initialize(widget.connManager));
mobilePush.addListener(onMobilePushChanged);

Future<void> onMobilePushChanged() async {
  if (!mounted || !mobilePush.hasPendingTap) return;
  final route = await mobilePush.takePendingNotificationRoute();
  if (!mounted || route == null) return;
  // Existing authenticated session lookup, if necessary:
  final session = await fetchSession(route.connection, route.sessionId);
  if (!mounted || !await mobilePush.isRouteCurrent(route)) return;
  if (!mounted) return;
  // Navigate synchronously here through existing notification/chat routing.
  // Never convert this into an approval/answer action or resubmit a prompt.
  openSession(route.connection, session);
}

// When current NotificationPrefs change, await parity before reporting saved:
await mobilePush.syncPreferences(notificationPrefs.value);
// This listener is also installed automatically by initialize().

// Explicit consent revocation; local native invalidation precedes HTTP DELETE:
await mobilePush.disable();

// On root teardown: remove its listener. The app-lifetime singleton owns its
// lifecycle observer; it automatically reconciles on resumed. Do not dispose it
// from a Settings screen. Tests may dispose their injected service instance.
mobilePush.removeListener(onMobilePushChanged);
```

`takePendingNotificationRoute()` consumes a single pending native tap and returns
`MobilePushRoute(connection, sessionId, eventId, authority)` or null. There are no
approval fields. Recheck `isRouteCurrent(route)` after **every** async boundary
before navigation. Both methods recheck current saved connection credentials,
consent, installation/nonce/revision, preferences and event expiry. The service
also rechecks ownership after registration, confirmation and each event page.
The root should serialize its own route-open requests to avoid two simultaneous
listeners navigating twice. It can call `refresh()` explicitly after recovering
network or changing account metadata; ConnectionManager already invalidates native
authority before saved-account edits/import/removal.

The Settings widget can also be embedded directly:
`MobilePushSettings(connection: selected, connectionManager: manager)`.
It only exposes manual allowlisted durable IDs, distributor availability, explicit
consent, Pending/Active/Error, reconcile/retry and revoke controls. It remains
accessible in the Settings fallback when model settings fail to load.

## Frozen server API

Paths are relative to DashboardClient's authenticated origin and dashboard path
prefix, never the Gateway chat/API key origin:

* `GET /api/plugins/mobile-push/capabilities` → schema 1, enabled, transports
  containing `webpush`, VAPID public key.
* `PUT /api/plugins/mobile-push/registrations/{installation_id}` → endpoint,
  keys `{p256dh, auth}`, registration_nonce, explicit event_kinds and session_ids;
  response `{generation, status: pending, registration_nonce}`.
* `POST .../registrations/{id}/confirm` → `{generation, challenge}`;
  response must contain `status: active` before local activation.
* `DELETE .../registrations/{id}` revokes.
* `GET .../events?after=<cursor>&limit=100` → events, next_cursor, has_more.
  Cursor pages are read to exhaustion (safety cap fails honestly rather than
  returning partial reconciliation). Only unexpired allowlisted events route.

## Dependency/build compatibility and verification

Version 3.3.5 and its `PushService`, `PushEndpoint.pubKeySet` and
`PublicKeySet.pubKey/auth` APIs were verified against the published Maven source
JAR and AAR. The Flutter wrapper is not used (avoids transitive AGP drift). The
connector publishes the JVM `tink` artifact, whereas flutter_secure_storage
already depends on `tink-android`: bundling both creates duplicate classes.
The app excludes connector's `tink` and explicitly uses the published
`tink-android:1.23.0`. This cryptographic library is not Firebase messaging.

Run from the repository (Flutter 3.44 / Dart 3.12):

```sh
export TMPDIR=/Users/sam.russell/.hermes/cache/scratch
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME="$HOME/Library/Android/sdk"
flutter pub get
flutter analyze lib/core/services/mobile_push_api.dart \
  lib/core/services/mobile_push_service.dart lib/core/widgets/mobile_push_settings.dart \
  lib/core/services/connection_manager.dart test/mobile_push_service_test.dart
flutter test test/mobile_push_service_test.dart
flutter build apk --debug
(cd android && ./gradlew :app:testDebugUnitTest --tests '*MobilePush*Test')
```

Dart tests use controlled native MethodChannel callbacks and an authenticated
HTTP fixture for opt-in, permissions, unavailable/forbidden servers, challenge
race, stale generations, renewal/disable races, durable failed revoke retry,
per-kind preferences, event cursor paging and authenticated routing. Native JVM
Robolectric tests exercise the real headless service/bridge with the connector's
decrypted flag controlled, durable encrypted storage with a test-injected AES
key (not AndroidKeystore acquisition), generic notifications, bounded dedup,
renewal, disable, preferences and corrupt ciphertext. Test fixture subscription
material is never used by production code. They are not evidence of physical
killed-process delivery. No connected-device/distributor end-to-end test has
been performed; that remains required before claiming device delivery works.
