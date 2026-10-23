# Encrypted UnifiedPush server companion

`server/mobile-push` is a distributable, opt-in Hermes plugin named **mobile-push**.
It is shipped with this Android repository but must be installed separately on the
server. Nothing in this change installs it, changes a running profile, opens the
operator's session database for writing or registers a real push endpoint.

## Deployment prerequisites and compatibility

- Python 3.11+; FastAPI, pywebpush, cryptography and dnspython versions within the
  ranges in `server/mobile-push/pyproject.toml`. Install into the Python environment
  actually used by **both** the Hermes dashboard and gateway/turn process. Dependency
  declarations in a Hermes manifest are advisory, not an automatic installer.
- A Hermes build providing the current observer hooks and plugin unload ledger.
  The integration suite was exercised against source revision `d923a5eb`: the real
  `PluginManager` loads the same physical source in two profile homes, preserves
  worker context, disposes each owner independently and reloads unchanged source.
- A running Hermes dashboard/API backend that sets a **verified**
  `request.state.session.provider` and `.user_id`. A legacy/shared dashboard token,
  gateway JSON-RPC token, arbitrary bearer token or client identity header is **not**
  a principal. If the installed authentication middleware does not supply that
  verified session for the Android client's credentials, the API returns **401**.
  Provision a compatible trusted authentication provider before enabling push.
- Use the trusted **in-process** plugin execution mode. In the inspected Hermes
  build, `plugins.isolation: host` forwards an ASGI request without the verified
  session object; these routes therefore fail closed with 401. Hosted/multi-tenant
  isolation is **not compatible** until a separately reviewed core seam forwards a
  verified principal. Do not forward identity through client headers, disable auth,
  or change a pooled deployment to in-process just to make this plugin work.
- Lifecycle hooks must load in every process that executes the subscribed turns.
  The dashboard API alone does not run turns or start the sender. Separate dashboard
  and gateway processes must use the same profile home and local SQLite files.
- Android must explicitly opt in, have a compatible UnifiedPush distributor, provide
  genuine Web Push `p256dh`/`auth` keys and decrypt RFC8291 `aes128gcm` messages. An
  endpoint URL alone is not an encrypted subscription. This is not an FCM service.
- Outbound HTTPS/DNS and a valid trusted certificate at the push service. The mobile
  device also needs authenticated access to this API for confirmation/reconciliation.
  Local/LAN services need the exact operator exception described below. Production
  never accepts a user-provided CA override or disables certificate verification.

The source contract is documented by [observer hooks][hooks] and
[dashboard backend plugins][dashboard]. No Hermes core patch is included here.

[hooks]: https://hermes-agent.nousresearch.com/docs/developer-guide/observer-hooks
[dashboard]: https://hermes-agent.nousresearch.com/docs/user-guide/features/extending-the-dashboard

## Operator installation (not performed by this implementation)

Select the intended profile and its current managed interpreter explicitly. The
following are operator instructions, not commands to run against an unrelated home.
Run them from the Android repository root and replace the absolute placeholders:

```sh
export HERMES_HOME=/absolute/path/to/selected/profile-home
export HERMES_PYTHON=/absolute/path/to/selected-hermes-environment/bin/python
export TMPDIR=/absolute/path/to/private/scratch
umask 077
mkdir -p "$HERMES_HOME/plugins" "$HERMES_HOME/plugin-data/mobile-push"
chmod 700 "$HERMES_HOME/plugin-data/mobile-push"
# Refuse/inspect an existing destination instead of blindly overwriting a live plugin.
test ! -e "$HERMES_HOME/plugins/mobile-push"
cp -R server/mobile-push "$HERMES_HOME/plugins/mobile-push"
uv pip install --python "$HERMES_PYTHON" ./server/mobile-push
"$HERMES_PYTHON" server/mobile-push/generate_vapid.py \
  --output "$HERMES_HOME/plugin-data/mobile-push/vapid-private.pem"
```

The generator uses exclusive creation, mode 0600 and never prints private material.
Keep the private P-256 PEM in a backed-up secret file, not config YAML, source control,
chat, a command argument or an Android build. The public key is returned by the
capabilities API. Config and key must be owner-only regular files (0600 or stricter);
symlink files are refused. The private database directory is mode 0700 and databases
are 0600. Preserve their WAL files when backing up a running instance; prefer an
ordinary SQLite-consistent backup or stop the plugin first. Treat subscription URLs,
auth secrets, challenge payloads and stored session scopes as private server state.

Create `$HERMES_HOME/plugin-data/mobile-push/config.json` with mode 0600. This is an
**operator-owned file**, not a client-writable route or an arbitrary plugin setting:

```json
{
  "enabled": false,
  "vapid_private_key_file": "/absolute/path/to/selected/profile-home/plugin-data/mobile-push/vapid-private.pem",
  "vapid_subject": "mailto:operator@example.org",
  "principals": [
    {
      "provider": "actual-verified-provider",
      "user_id": "actual-verified-user-id",
      "session_ids": ["actual-durable-session-id"],
      "owner_all_sessions": false
    }
  ],
  "private_endpoints": []
}
```

Use principal values from the **trusted authentication provider**, not values
claimed by a client. Session IDs must be exact durable `sessions.id` values in this
profile's `state.db`; the plugin checks that database read-only. Missing grants deny
access. `"*"` is not accepted in `session_ids`. Only an explicit operator
`"owner_all_sessions": true` grants that principal owner-wide eligibility; clients
must still submit a non-empty explicit list of durable session IDs. There is no
automatic parent/child lineage, runtime-alias or sibling-profile inheritance.
A new/rotated durable identity requires an updated operator grant and registration.

After review, set this file's `enabled` to true and explicitly enable `mobile-push`
in the same profile's `plugins.enabled` (for example `hermes --profile default plugins
enable mobile-push` for the default profile). Plan a normal dashboard and gateway
restart after draining active work. User-directory plugins are required: Hermes
refuses automatic backend Python import from an untrusted project directory.
`dashboard/manifest.json` declares `api: plugin_api.py`; its router is mounted at
`/api/plugins/mobile-push`. The tiny hidden dashboard bundle intentionally adds no UI.

Each API operation uses the home selected by Hermes' vetted request-local
`?profile=<name>` dependency, including capabilities, registration, confirmation,
revocation and events. Stores are keyed by that home; the API never derives a path
from client headers or chooses a principal from the profile parameter. Omitting
`profile` selects the dashboard's launch profile. Each lifecycle runtime separately
captures its own immutable home and must be enabled in the selected turn process;
selecting a profile in the API does not install hooks or start a worker for it.
ACLs, endpoint exceptions, key path and enabled policy are re-read on operations
and before sends; update this JSON by an atomic private-file replacement. Enabling
after a disabled startup requires a lifecycle-process restart to acquire hooks/worker. Disabling the
JSON policy halts sends but keeps pending bounded state until expiry. Unload stops
this owner's worker; a forced reload acquires a new owner, never another profile's
worker. Managed Hermes interpreter replacement may require reinstalling these Python
dependencies in the newly selected environment; do not assume a one-off pip install
survives an update.

### Optional exact LAN exception

Public HTTPS services are the default. For an operator-controlled private distributor,
use **both an exact lowercase host and exact literal IP addresses**, never wildcards
or CIDRs:

```json
"private_endpoints": [
  {"host": "push.home.example.org", "ips": ["192.168.1.40"]}
]
```

The TLS certificate must still be trusted and valid for that hostname. Every DNS
answer must be permitted. The same address under a different host is not permitted.
Unspecified, multicast and mapped/transition addresses remain refused. Tests use an
explicit `receiver.example.test` → `127.0.0.1` exception and a generated test-only CA;
that resolver fixture/CA injection is not a production setting.

## Exact API contract (schema 1)

All routes require the verified session object. Identity is only the tuple
`(request.state.session.provider, request.state.session.user_id)`; no identity headers,
request fields, query parameters or service-token principal fallbacks are accepted.
Mutating JSON bodies are strict (extra fields denied), at most 32 KiB.

### `GET /api/plugins/mobile-push/capabilities`

```json
{"schema":1,"transports":["webpush"],"vapid_public_key":"base64url-uncompressed-P256-public-key","enabled":true}
```

Missing/disabled config or an ungranted verified principal yields `enabled:false`
and an empty public key. No verified session yields 401 even on this endpoint.
Invalid private config/key yields generic 503 rather than leaking secret details.

### `PUT /api/plugins/mobile-push/registrations/{installation_id}`

```json
{
  "endpoint":"https://distributor.example.org/opaque-subscription-path",
  "keys":{"p256dh":"real-base64url-65-byte-P256-public-key","auth":"real-base64url-16-byte-auth-secret"},
  "registration_nonce":"fresh-client-base64url-random-nonce",
  "event_kinds":["turn_done","turn_error","input","input_resolved"],
  "session_ids":["exact-durable-session-id"]
}
```

Returns HTTP 200:

```json
{"generation":1,"status":"pending","registration_nonce":"fresh-client-base64url-random-nonce"}
```

`installation_id` and session IDs are 1–200 ASCII characters from
`A-Z a-z 0-9 _ . : @ -`. Use a globally unique random installation ID. The nonce is
16–128 base64url characters; use fresh cryptographic randomness on **every** update.
`event_kinds` has 1–4 entries from exactly the four values above; `session_ids` has
1–128 exact durable IDs; duplicate scopes are rejected. Keys are validated as a real
P-256 point and a 16-byte auth secret, not merely plausible strings.

An update, including endpoint/key/scope rotation, advances generation, requires a
previously unused nonce, immediately returns to pending and invalidates
all older queued deliveries/challenges. Generations are not reset after revocation.
An existing installation belonging to another principal returns 404. Operator ACL
failure/non-durable scope is 403; malformed/unsafe subscription is 422; changed-body,
revoked or superseded nonce replay is 409; capacity is 429. No wildcard/default
session grant is inferred.

An exact retry of the **current** nonce, endpoint, keys and ordered scope lists
recovers the committed generation and current `pending`/`active` status, after all
normal authentication, ACL, durable-session and endpoint checks. It does not
activate anything or delete queued ordinary hints. An expired **pending** challenge
is replaced by a fresh encrypted proof/event for the same generation; the old proof
is invalidated. An unexpired proof is left unchanged. Nonce hashes are retained as
per-installation tombstones across rotation/revocation, independently of event TTLs;
this history grows with genuine registration updates and must not be pruned as an
ordinary event-retention operation. Existing databases seed their current nonce on
open; previously discarded history cannot be reconstructed.

The pending registration receives an **encrypted challenge hint** through its supplied
endpoint/keys. Until confirmation it receives no ordinary turn/input hints. Merely
registering a URL, reading its metadata from `/events`, or knowing an event ID cannot
activate it.

### `POST /api/plugins/mobile-push/registrations/{installation_id}/confirm`

```json
{"generation":1,"challenge":"challenge-from-decrypted-push-only"}
```

Returns `{"generation":1,"status":"active"}` only if the principal owns the current
pending registration, generation is exact, the proof matches in constant time and
its five-minute deadline/current ACL permit activation. An exact retry against the
already-active same generation/proof recovers `active` even after the original
challenge deadline: it performs no activation or queue deletion. The proof hash is
retained until rotation/revocation for that recovery; no clear proof is returned by
PUT, confirmation or events. Invalid, expired-pending, revoked or superseded
confirmations return 409 (current ACL removal: 403). A late challenge can never
reactivate a rotated/revoked generation. Challenge proof is stored hashed; the
clear challenge is only in the private queued encrypted-push payload, cleared on
successful send/confirmation/revocation/expiry.

### `DELETE /api/plugins/mobile-push/registrations/{installation_id}`

Returns `{"generation":2,"status":"revoked"}` (the actual next generation).
Revokes ownership's registration, clears endpoint/keys/challenge and invalidates its
queue. Repeat deletes also advance generation. The owning verified principal may
revoke after the operator disables push/removes its grant. Another principal gets
404; no session gets 401. Tombstones retain ownership/generation to reject replay.

Send and revoke/update serialize through a SQLite write transaction: **successful**
revocation cannot be followed by a newly initiated send of the old generation. A
busy in-flight send yields generic 503 instead of a false successful revocation;
retry with bounded backoff. Already accepted push messages cannot be recalled, so
Android must immediately revoke local consent and reject old generation/nonce hints.

### `GET /api/plugins/mobile-push/events?after=0&limit=100`

```json
{
  "events":[
    {"cursor":2,"event_id":"opaque-id","kind":"turn_done","session_id":"durable-id","turn_id":"opaque-turn-id","created_at":1800000000,"expires_at":1800003600}
  ],
  "next_cursor":2,
  "has_more":false
}
```

`after` is a non-negative signed-64-bit integer cursor, exclusive. `limit` is 1–200
(default 100). Cursors are profile-database global but results and pagination are
principal-only; gaps are normal. Advance to `next_cursor`, follow `has_more` until
false and deduplicate by `event_id`. Only currently authorised, still-durable session
routes are returned. Expired/cancelled attention entries are omitted. No title,
content, command, arbitrary navigation URL or approval response token is returned.

`input`/`input_resolved` events carry `session_id` and observer `request_id` (optional
`turn_id` is absent when the upstream hook has no durable turn correlation). That
observer ID is **not** an RPC approval identifier: open the relevant session and
reconcile its authenticated current state; never construct/submit an approval from
it. A `challenge` event instead has `installation_id` and no session ID/turn ID.
It is metadata only and **never exposes the challenge proof**. Its installation and
principal scope are server-owned.

The authenticated events API is the routing authority; it is not an unlimited
transcript or a proof that an old attention request still exists. After a retention
window, missed hooks or connectivity loss, reconcile current authenticated chat state.

## Push payload, hooks and delivery semantics

The JSON plaintext encrypted using RFC8291 `aes128gcm`, with RFC8292 VAPID auth:

```json
{"schema":1,"event_id":"opaque-id","kind":"turn_done","generation":1,"registration_nonce":"client-nonce","expires_at":1800003600}
```

Only these fields are allowed; `kind:"challenge"` additionally carries `challenge`.
There are **no** session IDs, titles, chat/prompt/answer contents, commands, approval
codes, credentials or navigation URLs in the hint. `expires_at` is Unix seconds.
An accepted distributor response means only push-service acceptance, not device
receipt or that a user has read/reconciled anything.

- `on_session_end` requires durable `session_id`, explicit `turn_id`, boolean
  `completed`/`failed`/`interrupted`, and `turn_exit_reason`. Failed emits `turn_error`;
  completed emits `turn_done`; interrupted/incomplete/legacy payloads emit neither.
  `task_id`, model, platform and text are not copied into hints or routing records.
- `on_human_input_request`/`on_human_input_resolved` observe `approval`, `clarify` and
  `sudo` waits. Only durable session identity and observer request ID are retained.
  No `pre_approval_request` command payload is consumed. Resolved-first order is
  recorded as a tombstone so a later request cannot resurrect attention; terminal
  turns also cancel open attention. These hooks never answer, approve or deny.
- Hook enqueue uses bounded SQLite lock waits (25 ms per write attempt; durable
  session reads wait at most 100 ms). A separate **durable inbox** buffers observers
  during an in-flight network send, so the outbox's send/revoke lock does not drop
  normal concurrent turn completion. Inbox entries capture registration generations
  at observer admission and cannot adopt a later re-registration/consent. The worker
  drains inbox resolutions before initiating further hints. Disk failure, both databases busy or a capacity/expiry
  overflow can still lose a hint; hooks fail open and never block execution for
  network delivery. Reconcile chat state rather than treating push as a ledger of
  all possible runtime transitions.
- The profile-owned worker polls at one-second idle intervals. Committed outbox
  jobs/leases survive restarts. Leases are transactional and 30 seconds long;
  concurrent workers cannot double-send a claimed job. Up to five attempts use
  capped exponential backoff (cap 300 seconds), constrained by expiry. HTTP
  404/410 revoke the registration and advance generation; 408/429, transport and
  server failures retry. No response body is retained or logged.
- Before sending, recheck enabled policy, principal/session ACLs, current durable
  session, event kind consent, generation, attention state and expiry. Validate
  URL/DNS again on every attempt. HTTPS only, no URL userinfo/fragments/control
  characters/redirect following. Every answer must be globally routable unicast
  (or an exact private exception), excluding mapped/transition address tricks.
  Bounded DNS resolution uses two-second A/AAAA lifetimes; the verified address
  is connected **directly** without DNS lookup again, with original-host TLS SNI
  and certificate verification. No environment proxy, cookies, Hermes bearer token
  or client identity headers are sent to the distributor. Response status/header
  reads have a total deadline and an 8 KiB cap, including slow-drip peers.
- Normal events expire after one hour; challenges after five minutes. Retain at most
  10,000 events, 10,000 inbox rows and 10,000 attention tombstones; tombstones expire
  after two hours. At most 256 registrations (including revoked tombstones) per
  profile bound state/abuse without allowing generation reuse. Outbox rows are
  bounded by retained events × registrations; successful/exhausted rows retain only
  dedup metadata until their event expires. Old cursor gaps/expired events are not
  replayed indefinitely. Physical SQLite allocation is reused, not automatically
  shrunk; an operator may perform ordinary offline SQLite maintenance if needed.
- Delivery is **at least once**, not exactly once: a crash after distributor
  acceptance but before the SQLite commit can cause a retry. Clients must dedup
  persistent `event_id`, validate schema/generation/nonce/expiry and current local
  opt-in, and reconcile routing over the authenticated API. Cancellation cannot
  retract a push already accepted by the distributor; resolved/current state wins.

## Reproducible tests

From the repository root, use an isolated environment and an explicit scratch path:

```sh
export TMPDIR=/absolute/path/to/private/scratch
uv venv --python 3.11 "$TMPDIR/mobile-push-tests"
uv pip install --python "$TMPDIR/mobile-push-tests/bin/python" './server/mobile-push[test]'
"$TMPDIR/mobile-push-tests/bin/python" -m pytest server/mobile-push/tests -q \
  --basetemp="$TMPDIR/mobile-push-pytest"
"$TMPDIR/mobile-push-tests/bin/ruff" check server/mobile-push
"$TMPDIR/mobile-push-tests/bin/ruff" format --check server/mobile-push
```

The real-host integration tests additionally require an inspected Hermes source
checkout and its installed dependencies (these variables are read-only inputs):

```sh
export HERMES_AGENT_SOURCE=/absolute/path/to/hermes-agent-source
# Optional fallback site-packages for dependencies already in that selected environment:
export HERMES_AGENT_SITE_PACKAGES=/absolute/path/to/hermes-environment/lib/python3.14/site-packages
# Repeat the pytest command above with these variables set.
```

Without a source checkout the host integration tests are explicitly skipped;
the ordinary protocol/crypto tests still run. The host suite exercises one router
mounted by real `_mount_one_plugin_api`, the real profile dependency/resolver,
concurrent requests to two homes, and profile-bound lifecycle workers. A real Basic
password-login/cookie middleware probe confirms and retries a challenge decrypted
from an actual TLS loopback receiver. Recovery regressions cover lost PUT/confirm
acknowledgements, server-store restart, client-persistence gaps, pending expiry,
changed-body retries, policy removal and superseded/revoked nonce rejection.
A Starlette TestClient/httpx deprecation warning is upstream, not a skipped test.

The receiver uses real pywebpush encryption, independently decrypts with the generated
subscriber private key/auth secret, verifies the VAPID JWT signature/audience and
confirms registration using only the decrypted challenge. It exercises encrypted
input/resolution/turn hints and authenticated event-ID routing. DNS fixtures are
explicitly patched to a loopback address authorised by the operator exception; tests
do not pretend that a public distributor or a physical Android device was contacted.
Other tests cover missing/forged/foreign principals, session ACLs and lineage denial,
rotation/revocation/expired proof, dedup, queued attention races, retries/leases and
restart, busy-inbox persistence, SSRF/mixed answers/pinned connect, redirects,
permissions and safe generic failures.

**Still unverified deployment acceptance:** install/trust/auth-provider configuration
on the intended server; loading hooks in its real turn processes; a reachable genuine
UnifiedPush distributor; the Android connector's production subscription/decryption
and authenticated confirmation; delivery with a real background/killed process,
notification permissions, lock screen and battery constraints. No claim of deployed
or physical-device success is made by the local suite.
