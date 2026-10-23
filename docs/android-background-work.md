# Android background work

These features are under development on the background-turns branch. They are not
part of the published v2.1.30 release. A local build or passing test suite is not
proof that a particular phone has the new version installed.

## Keeping an active chat connected

Normal Remote Gateway turns belong to the application, not the open chat screen.
Leaving a chat detaches its view without cancelling its submitted turn. Reopening
that chat attaches to the retained text, exposed reasoning, tools and requests.
You can run different chats at the same time. Duplicate views of one chat share
send admission and its transport.

The timeline presents assistant text and protocol-exposed reasoning between the
tool batches where they arrived. A later update to a tool changes the original
card rather than moving it to the end. This is a presentation view, not extra
messages inserted into the server transcript. Reasoning that the server does not
expose is never inferred or displayed.

When Android backgrounds the app during unresolved work, one foreground service
protects the active connection. It is shared by active chats, not one service per
chat. Quiet chat-specific ongoing notifications identify the work and open its
chat. The native foreground-service disclosure is separate from optional chat
notifications.

In **Settings → Background work**, **Keep chats active in the background** controls
this protection. A stored choice must be loaded before protection can start.
Turning optional notifications off does not hide Android's required service
disclosure. Android notification permission is still required for ordinary chat
notifications.

This is not a guarantee of uninterrupted networking. Doze, network changes,
manufacturer battery policies, low memory and process termination can interrupt a
connection. The battery-settings button opens Android settings; it does not grant
an exemption or promise that selecting Unrestricted solves every restriction.

## Reconnect and process restart

The app does not resend a submitted prompt after a disconnect. Recovery
resumes the durable server session and reconciles its authoritative history. A
running or unknown server status is not treated as a successful final response.

The app stores a minimal pending-turn receipt for restart recovery. It does not
journal the prompt, password, approval answer or secret in that receipt. Retained
live text and tools are in-memory presentation state; after process death the
server's durable history is the source of truth. A late authoritative history
response replaces settled optimistic presentation, while loading older history
does not discard a still-retained turn.

Without an enabled push transport, a terminated app cannot learn
about completion until it runs and reconnects. Android Force stop blocks background delivery and is not a supported way to test
background push.

## Optional encrypted UnifiedPush

UnifiedPush is a separate, explicit opt-in for server-originated hints when a live
socket is unavailable. It has no FCM dependency. It requires all of:

- A compatible UnifiedPush distributor installed and configured on the phone.
- The [server companion](mobile-push-server.md), installed and enabled in
  the intended Hermes profile with a private VAPID key and explicit session grants.
- A trusted authenticated dashboard session. A shared API bearer token or a
  client-supplied identity header is not a substitute.
- A saved connection and explicit durable-session allowlist selected in the
  [Android push settings](mobile-push-android.md). The server contract allows at
  most 128 IDs, each 1–200 ASCII characters from `A–Z`, `a–z`, `0–9`, `_`, `.`,
  `:`, `@` and `-`.

The encrypted endpoint challenge must complete before activation. Subscription
renewal, revocation, account edits and recovery must preserve generation/nonce
fences; old proofs and notification taps cannot regain authority after disable.
Lost registration responses and expired pending proofs must be recoverable without
asking the user to approve a new account or a broader scope.

Push carries an opaque event hint, not chat contents, a command, or approval
authority. The app resolves the hint through the authenticated server API and
checks current consent again before opening the chat. Push does not submit a prompt or answer an approval without user input. Disabling push removes local authority
first; a failed server revoke remains pending for a later authenticated retry.

The inspected Hermes isolated plugin host does not forward the trusted ASGI
session required by this companion. That deployment fails closed until a trusted
core integration seam is available. Read the server guide before installation;
this repository does not install a live plugin or configure a distributor.

## Acceptance checks on a phone

Confirm the installed build in **Settings → About**, then test against the intended
Gateway and record the phone model, Android version and battery policy.

1. Start one turn, leave its screen, return and confirm it was submitted once.
2. Background and lock the phone during work. Confirm one foreground-service
   disclosure and a quiet ongoing entry for the active chat.
3. Tap that entry with another route open. Confirm the intended chat is focused
   without a Flutter error, duplicate submission or stale-account navigation.
4. Start a turn in each of two chats. Completing one must not stop protection for the
   other. When all work settles, ongoing entries and protection must stop.
5. Interrupt networking and restore it. Confirm recovery does not resend the prompt
   and that the final durable reply replaces optimistic text/tools without
   duplication.
6. Test protection and optional notifications as separate controls. Deny notification
   permission, grant it later in Android settings, and return to the app to check
   that permission state refreshes without another unsolicited prompt.
7. If push is configured, test endpoint renewal, a restarted app during pending
   registration, completion with the app process absent, expired proof recovery,
   disable/re-enable and stale notification taps. Do not call a foreground-only
   notification test evidence of killed-process distributor delivery.

For a disposable emulator and labelled local fixture, use the
[developer smoke test](android-background-smoke-test.md). That fixture performs no
model inference and is not a production Gateway or distributor acceptance test.
