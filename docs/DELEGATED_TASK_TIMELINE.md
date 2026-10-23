# Delegated-task timeline

## Read-only boundary

A task row opens a phone sheet or wide-screen dialog above the mounted parent chat. Close/back returns to the same composer, scroll controller and parent state. The viewer has Refresh and explicit Load older controls, but no composer, task-control actions or nested `ChatScreen`.

`DashboardTaskHistory` uses `DesktopGatewayClient.normalizedGatewayBaseUrl` and `DashboardClient` authentication: password cookie, trusted proxy, or a local SPA token. It never opens a socket, watches/resumes a child, replaces the parent subscription, or closes/finalises a server runtime. Disposal closes only the viewer's HTTP client and timer; a closing wrapper blocks follow-up GETs after a late login.

Each read uses:

```text
GET /api/sessions/{Uri.encodeComponent(childStoredId)}
    [?profile=<exact saved gateway profile>]
GET /api/sessions/{Uri.encodeComponent(childStoredId)}/messages
    ?limit=50&offset=N&order=latest&inline_images=false&include_compacted=true
    [&profile=<exact saved gateway profile>]
```

The messages response must contain `session_id`, `messages` and matching pagination (`limit`, `offset`, `order`, `returned`); an explicitly selected profile must match on **every** detail and messages response. `include_compacted=true` is necessary even without rotation: stock Dashboard defaults it to false, hiding archived tool/reasoning rows after in-place compaction. It is a display read, not model replay, and does not reactivate archived rows.

Both stock detail and messages routes accept unambiguous prefixes. First require the detail response's bare `id` to equal the requested child ID exactly; a missing child whose ID prefixes a longer conversation is unavailable, and no messages request is made. If messages returns a different canonical `session_id`, read its exact detail and walk `parent_session_id` backwards to the original, checking each parent's `end_reason == 'compression'`. Each continuation must supply `source` and parseable/null `model_config`, must not have source `tool`, and must not carry `_delegate_from`, `_branched_from` or `_reset_from` markers. Reject cycles and chains beyond 32 hops. These are real stock detail fields, not invented `_lineage_root_id`/path fields or an assumed relationship between two valid IDs. Metadata is read anew per page; a rotation during a read is accepted only if its returned lineage can be proved before rows are published.

There is no API-server `data` fallback: that allowlist loses reasoning. Missing/rejected Dashboard authentication, incompatible responses and unprovable identity are explicit unavailable states. Older servers without enough detail metadata, non-compression continuations and marked/forked continuations fail closed; Refresh/Retry remains available. A 404 remains retryable: it cannot distinguish an unflushed child from an unsupported route. Each ordinary page costs two GETs; a canonical continuation requires additional bounded detail GETs. No child runtime RPC or socket is used.

## Identity and reopen

`GatewaySubagentActivity` retains `child_session_id`, `delegation_id`, `parent_id` and terminal status separately from `subagent_id`. Opaque IDs are accepted unchanged only when non-empty, at most 512 UTF-16 code units, free of control characters/surrounding whitespace, and not `.` or `..`. Invalid IDs are rejected, never repaired or shortened. Id-only progress preserves the known goal; terminal failure/interruption/completion is sticky under late progress.

Reopen recovery examines only `delegate_task` spawn calls (omitted action means spawn) and their known top-level result/`results` entries. Call arguments and result schemas both exclude `steer`, `stop`, `list` and other non-spawn actions; orphan `queued`, `interrupt_requested` and `subagents` control/list acknowledgements are ignored too. A request to stop is not evidence that the child stopped. Only recognised terminal statuses (`completed`, `failed`, `error`, `interrupted`, `cancelled`) recover terminal state; missing or unfamiliar statuses remain non-terminal. Real background `dispatched` payloads expand their parallel `goals`/`subagent_ids` without fabricating stored references.

Recovery accepts a real structured `child_session_id`, never an arbitrary nested `session_id`, task number, goal or live-log path. Without a retained reference, the row opens an explicit unavailable explanation. In particular, stock background dispatch may preserve runtime IDs and log paths but no durable child ID. Failure, interruption and cancellation have distinct accessible status/icons, and a mixed terminal group says “finished”, not that all tasks succeeded.

## Snapshot and pagination ownership

`DelegatedTaskController` owns a single request flight, generation fences and a two-second foreground polling timer. Lifecycle changes, completion and disposal invalidate pending reads; a newer generation queues behind an older flight. Backgrounded viewers do not poll. Completion triggers a final read; transient final-read failures receive up to three automatic retries. Successful completed snapshots stop polling, but Refresh remains available for delayed database flushes. Errors retain displayed rows; an empty successful response is not an unavailable state.

Cold open reads one page. Durable numeric row IDs determine deduplication/order, never content. Latest refreshes retain older loaded rows. A disjoint latest page resets paging coverage so Load older can fill the gap.

Paging coverage counts unique fetched IDs separately from retained display rows. Raw older-page lengths plus subsequent head growth can double-count an append-induced overlap and skip the old tail; a deterministic regression covers that interleaving. The existing parent `ChatHistoryWindow` is not changed.

## Rendering and verification

Recorded user/assistant/agent/tool/system rows render chronologically; `agent` uses assistant presentation and server-hidden rows are omitted. Markdown prose is selectable. Stock `display_commentary` is public assistant prose, even on an empty-content row; do not recover it from raw `codex_message_items` when server policy suppresses it. `display_reasoning` is authoritative whenever present, including explicitly empty/null values, and suppresses duplicate raw reasoning/sidecars. `display_content` is also authoritative when empty/null. Projected text that happens to look like JSON remains literal prose.

Without projected reasoning, collapsed reasoning reads exposed text/summary fields from `reasoning`, `reasoning_content`, `reasoning_details` and `codex_reasoning_items`, supporting JSON-string/native-list sidecars without displaying encrypted data. Tool cards retain actual call IDs, arguments and results; missing arguments are labelled, not invented. Expansion keys use durable rows and sidecar/call identities. Markdown images use alt text rather than automatic remote fetches. All new interface copy uses AppLocalizations; new English ARB keys have explicit English fallbacks in every shipped locale. Services/controllers expose typed failure reasons instead of user-facing English or raw exception strings.

Parent events update the open controller through a task-specific, disposed-safe bridge. Exposed live previews are separately labelled, never mixed into durable rows or mirrored as synthetic tool calls.

`test/fixtures/delegated_task_dashboard.json` is captured from real stock route functions with a disposable SessionDB: archived tool/reasoning rows, compression metadata, prefix resolution, enabled/disabled commentary projections and real registry steer/stop ACKs. The fixture records its backend commit. Regenerate with `python tools/capture_task_history_fixture.py /path/to/hermes-agent` using a Python environment containing the backend dependencies; it touches only its scratch database and this fixture, never existing profiles or a live server.

All four independent specification findings were reproduced as failing regressions before fixes. Focused tests additionally use mocked HTTP, controlled futures and fake-clock lifecycle transitions. They cover exact/prefix/foreign/fork identity, authentication/query shape, projected commentary rendering, spawn recovery, running child → persisted control ACK → real ChatScreen hydration → late progress → continued polling → actual completion, all locale labels, terminal icons, pagination overlap/gaps, stale-response disposal, retry, stable expansion, modal states and parent-chat dismissal on phone/wide layouts. This remains snapshot polling, not token streaming; missing historical child references cannot be reconstructed. Independent quality review, device checks and signed APK validation belong to the parent release workflow.
