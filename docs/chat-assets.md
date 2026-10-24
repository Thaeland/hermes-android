# Generated attachments and chat assets

**Status: 3.0.0 release-candidate development.** This feature does not publish a
release or change the stable app version.

## Send a file from Hermes

Android explicitly requests the stock gateway's attachment-capable rich-chat
source (`desktop`) when creating or cold-resuming a session, instead of
inheriting the host process's TUI instructions. Each ordinary Remote Gateway
prompt also identifies its current surface as `android`. Gateways with Android
surface-note support tell the agent it is talking to the native Android app,
including when reattaching to an already-live TUI session, without rewriting the
user's message or cached system prompt. Older gateways ignore the surface value;
their already-live sessions retain the original instructions until rebuilt.

Ask the agent to generate a file and deliver it in its reply. The standard Hermes
contract is an explicit gateway-host path, on its own line:

```text
MEDIA:/absolute/path/to/report.pdf
MEDIA:"/absolute/path/with spaces/chart.png"
```

The app also recognises explicit filesystem Markdown links in assistant replies,
such as `[report](/srv/output/report.pdf)` or
`[notes](file:///srv/output/notes.txt)`. Absolute, home-relative (`~/`) and Windows
paths are supported. Ordinary relative documentation links and web links are not
reinterpreted as gateway files. Successful recognised image-generation results
can supply an image even when the final answer omits its `MEDIA:` marker.

Files appear in the **chat timeline**, independently of verbose tool details.
Inline file links open the same preview as file cards. Nothing is downloaded
merely because a message or card is rendered. User messages, code/quoted examples
and model-only or compaction carriers are not treated as deliveries. Generated
files are references to the connected host, never same-named files on the phone.

## Preview, download and share

- Tap a file card or inline delivery link to open its preview popup.
- Images support zoom. Android PDF previews show rendered pages with paging.
  Text, Markdown, JSON, CSV and other recognised text formats are selectable,
  inert text; scripts, HTML and external resources are not executed.
- Office documents, archives and other unsupported binaries show file information
  and an honest no-inline-preview message. They can still be saved or shared.
- Use **Download** on either the card or popup to open Android's save picker.
  Choose a destination to write the original bytes. Cancelling is not reported
  as a successful save. A failure remains visible and retryable.
- **Share** is separate: it passes a temporary copy to Android's share sheet.
- File bytes are loaded only after a tap and capped at **25 MiB per file** while
  streaming, including responses without a Content-Length. Oversized files must
  be retrieved through the authenticated Dashboard instead. Preview text and
  native PDF rendering have additional display/resource bounds.
- Closing/replacing the owning card cancels its active transfer. Popup and card
  actions share the cached bytes instead of downloading the same file again.

Filesystem reads use the saved Dashboard origin, prefix, authentication, client
certificate and selected profile, plus the owning durable session where the
backend supports cwd resolution. The backend's filesystem restrictions still
apply; a session is not a per-file capability grant.

Some image providers return only an HTTPS image URL. After an explicit tap, the
phone contacts that image host directly, using a separate credential-free client
and bounded HTTPS-only redirects. No Dashboard cookies, bearer tokens or client
certificate are sent to it. Signed image URLs can expire; plaintext HTTP image
URLs are not supported. Markdown images do not trigger automatic remote loads.

## More → Assets

Open **More → Assets** on a connection with an authenticated Hermes Dashboard.
It uses the same delivery rules as the timeline, plus recognised saved media-tool
results. Duplicate references to the same exact session/path are merged.

- The first scan reads a page of recent chats, then one page of recent messages
  per chat. Each scan reads at most ten message pages; it does not scan every
  transcript automatically.
- Use **Scan more chats** to inspect another recent-chat page. Pinned chats
  repeated by the server are deduplicated.
- Use **Scan older messages** to page backwards through chats already scanned.
- Search found files by path, filename or source-chat title. **All**, **Images**,
  **Audio**, **Video**, and **Documents and other files** filter those results,
  not the whole server.
- **Open chat** opens the source conversation. Returning preserves found
  references and filters; reopening Assets starts a fresh scan.
- **Refresh** restarts discovery. Failed history reads show incomplete results
  and can be retried without repeating successful reads in the batch.

## Scope and limits

Assets is reconstructed from durable chat history, not an authoritative server
asset database. Ordinary user uploads, unlinked outputs and arbitrary tool-result
paths are not indexed. Only recognised producer contracts can add implicit media
results; there is no universal generated-document attachment array. Older compact
resume responses may omit producer results, so durable discovery uses Dashboard
history. Referenced files may have expired or been removed. Archived chats are
included when the Dashboard returns them.

Discovery stays on the saved connection's profile. It does not request all
profiles, create/resume sessions, submit prompts, modify conversations or crawl
filesystem trees. It keeps no separate persistent transcript/file index on the
phone. Live received output and saved history retain their existing separate
ownership and provenance; discovering a file does not prove a turn completed.

## Organisation entries

**Pin, batch and undo** and **AI-assisted filing** still need separate backend
contracts. Device-only pins and individual Project moves already work from the
Chats menu; they do not provide shared pin ordering, atomic batches, universal
move undo or correction-learning filing. The chat `session.undo` RPC edits
transcript turns and must not be used as organisation undo.

Hermes Agent assisted with implementation and regression tests. Local tests and
APK builds do not imply physical-phone acceptance, a production release or an
F-Droid update. The `com.hermesagent.hermes_android.dev` debug package can be
installed alongside the stable app without replacing its connection data.
