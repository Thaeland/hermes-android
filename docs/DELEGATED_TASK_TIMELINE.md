# Delegated-task timeline

## Read-only boundary

A task row opens a phone sheet or wide-screen dialog above the mounted parent chat. Close/back returns to the same composer, scroll controller and parent state. The viewer has Refresh and explicit Load older controls, but no composer, task-control actions or nested `ChatScreen`.

`DashboardTaskHistory` uses `DesktopGatewayClient.normalizedGatewayBaseUrl` and `DashboardClient` authentication: password cookie, trusted proxy, or a local SPA token. It never opens a socket, watches/resumes a child, replaces the parent subscription, or closes/finalises a server runtime. Disposal closes only the viewer's HTTP client and timer; a closing wrapper blocks follow-up GETs after a late login.

Each read uses:

```text
GET /api/sessions/{Uri.encodeComponent(childStoredId)}/messages
    ?limit=50&offset=N&order=latest&inline_images=false
    [&profile=<exact saved gateway profile>]
```

The response must contain `session_id`, `messages` and matching pagination (`limit`, `offset`, `order`, `returned`); an explicitly selected profile must match. A returned session ID may be the server-resolved compression continuation. There is no API-server `data` fallback: that allowlist loses reasoning. Missing/rejected Dashboard authentication and incompatible responses are explicit unavailable states. A 404 remains retryable: it cannot distinguish an unflushed child from an unsupported route.

## Identity and reopen

`GatewaySubagentActivity` retains `child_session_id`, `delegation_id`, `parent_id` and terminal status separately from `subagent_id`. Opaque IDs are accepted unchanged only when non-empty, at most 512 UTF-16 code units, free of control characters/surrounding whitespace, and not `.` or `..`. Invalid IDs are rejected, never repaired or shortened. Id-only progress preserves the known goal; terminal failure/interruption/completion is sticky under late progress.

Reopen recovery examines only `delegate_task` calls and their known top-level result/`results` entries. It accepts a real structured `child_session_id`, never an arbitrary nested `session_id`, task number, goal or live-log path. Without a retained reference, the row opens an explicit unavailable explanation. Background dispatch results retain their running/unknown status rather than claiming successful completion.

## Snapshot and pagination ownership

`DelegatedTaskController` owns a single request flight, generation fences and a two-second foreground polling timer. Lifecycle changes, completion and disposal invalidate pending reads; a newer generation queues behind an older flight. Backgrounded viewers do not poll. Completion triggers a final read; transient final-read failures receive up to three automatic retries. Successful completed snapshots stop polling, but Refresh remains available for delayed database flushes. Errors retain displayed rows; an empty successful response is not an unavailable state.

Cold open reads one page. Durable numeric row IDs determine deduplication/order, never content. Latest refreshes retain older loaded rows. A disjoint latest page resets paging coverage so Load older can fill the gap.

Paging coverage counts unique fetched IDs separately from retained display rows. Raw older-page lengths plus subsequent head growth can double-count an append-induced overlap and skip the old tail; a deterministic regression covers that interleaving. The existing parent `ChatHistoryWindow` is not changed.

## Rendering and verification

Recorded user/assistant/agent/tool/system rows render chronologically; `agent` uses assistant presentation and server-hidden rows are omitted. Markdown prose is selectable. Collapsed reasoning reads exposed text/summary fields from `reasoning`, `reasoning_content`, `reasoning_details` and `codex_reasoning_items`, supporting JSON-string/native-list sidecars without displaying encrypted data. Tool cards retain actual call IDs, arguments and results; missing arguments are labelled, not invented. Expansion keys use durable rows and sidecar/call identities. Markdown images use alt text rather than automatic remote fetches.

Parent events update the open controller through a task-specific, disposed-safe bridge. Exposed live previews are separately labelled, never mixed into durable rows or mirrored as synthetic tool calls.

Focused tests use mocked HTTP, controlled futures and fake-clock lifecycle transitions. They cover identity, authentication/query shape, transcript variants, persisted reopen, pagination overlap/gaps, stale-response disposal, retry, stable expansion, modal states and real parent-chat dismissal on phone/wide layouts. This remains snapshot polling, not token streaming; missing historical child references cannot be reconstructed. Independent integration review, device checks, the full suite and signed APK validation belong to the parent release workflow.
