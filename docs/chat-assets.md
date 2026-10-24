# Generated attachments and chat assets

**Status: 3.0.0 release-candidate development.** This feature does not publish a
release or change the stable app version.

**Draft review status:** the app-only revision is not ready to merge. Review
identified pending fixes for custom typed voice-stop phrases, image-only history
presentation and literal client-note examples. Non-normal transport exports also
need public-projection hardening. The full regression suite and APK builds must
be rerun after those fixes; earlier attachment-build results do not validate this
revision.

## Send a file from Hermes

These attachment features are implemented in the app and use existing Hermes
gateway, history and authenticated file routes. They do not require a backend
patch, Android-specific surface support, companion or new server configuration.

For Remote Gateway connections, Android requests the stock rich-chat source
(`desktop`) on create/resume. The app also adds a short, versioned Android
client-context note to ordinary chat requests, including REST/SSE and reused
TUI sessions. It explains the file-delivery syntax and distinguishes host paths
from the phone. Slash commands and the fixed default stop controls remain
unchanged; preserving custom voice-stop phrases is still a draft review item. No
extra agent turn, agent reset or model/provider change is introduced.

The note is ordinary user-message context, **not privileged or model-only
metadata**. The backend saves it as part of the submitted user turn, so other
clients, raw exports and future model context may include it. Android omits
only its exact known note from user bubbles, edit/retry text, its chat export
and recognised session previews. It never rewrites fetched transcript rows,
alters earlier saved messages or strips assistant/tool output.

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

## Organisation features

The unused Organisation section and its **Pin, batch and undo** and
**AI-assisted filing** placeholders have been removed from More. These features
require backend functionality that does not exist as a complete contract.
Device-only pins and individual Project moves already work from the Chats menu;
they do not provide shared pin ordering, atomic batches, universal move undo or
correction-learning AI filing. The chat `session.undo` RPC edits transcript turns
and must not be used as organisation undo.

Hermes Agent assisted with implementation and regression tests. Local tests and
APK builds do not imply physical-phone acceptance, a production release or an
F-Droid update. The `com.hermesagent.hermes_android.dev` debug package can be
installed alongside the stable app without replacing its connection data.
