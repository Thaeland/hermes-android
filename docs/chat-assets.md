# Browsing chat assets

**Status: unreleased development.** The stable app version is unchanged.

Open **More → Assets** on a connection with an authenticated Hermes Dashboard.
The browser finds explicit `MEDIA:` file references in saved assistant replies,
including inline links. Paths inside Markdown code or quoted examples (including
list-item fences and lazy blockquote continuations), and user/tool/system messages,
are not treated as delivered files. Later real deliveries remain discoverable.

## Use

- The first scan reads a page of recent chats, then one page of recent messages
  per chat. Each scan reads at most ten message pages; it does not scan every
  transcript automatically.
- Use **Scan more chats** to inspect another recent-chat page. Pinned chats
  repeated by the server are deduplicated.
- Use **Scan older messages** to page backwards through chats already scanned.
- Search the files found so far by path, filename or source-chat title. The
  **All**, **Images**, **Audio**, **Video**, and **Documents and other files**
  filters apply to those results, not the whole server.
- Tap an image to fetch and preview it. Use its download button to share/save it
  through Android's system sheet. Other files use that sheet directly.
- **Open chat** opens the source conversation. Returning preserves the browser's
  loaded references and filters; reopening Assets starts a fresh scan.
- **Refresh** restarts discovery. Failed history reads show an incomplete-results
  warning and can be retried without repeating successful reads in the batch.

## Scope and limits

This is a view reconstructed from durable chat history, not an authoritative
server asset database. Ordinary user attachments, unlinked outputs, arbitrary
Markdown links and files never explicitly shared with `MEDIA:` are not indexed.
Archived chats are included when the Dashboard returns them. A file reference
can outlive the actual file; a missing or denied file shows a download error.

Results use the saved connection's Dashboard URL, authentication and selected
profile. Discovery does not request all profiles, create/resume sessions, submit
prompts, modify conversations or crawl filesystem trees. It keeps no separate
persistent transcript/file index on the phone. The server still applies its
normal filesystem policy; session context resolves relative paths but is not a
Project-specific filesystem ACL.

File bytes are loaded only after a tap and capped at **25 MiB per file** while
streaming. Oversized files can be downloaded through the authenticated Dashboard
instead. Opening a file uses the gateway host's path, never a same-named local
phone file. Shared files use the app's temporary share cache.

## Organisation features

The unused Organisation section and its **Pin, batch and undo** and
**AI-assisted filing** placeholders have been removed from More. These features
require backend functionality that does not exist as a complete contract.
Device-only pins and individual Project moves already work from the Chats menu;
they do not provide shared pin ordering, atomic batches, universal move undo or
correction-learning AI filing. The chat `session.undo` RPC edits transcript turns
and must not be used as organisation undo.

## Implementation

Discovery and inline/standalone media rendering share the locked Markdown grammar
for code and quote exclusions. Parser-only occurrence IDs correlate eligible
inline nodes with the original source matches; paths and replacement offsets are
never reconstructed from normalized Markdown text.

Hermes Agent assisted with this feature and its tests. No production release,
F-Droid update or physical-phone validation is implied by a local development
build. The `com.hermesagent.hermes_android.dev` debug package can be installed
alongside the stable app without replacing its connection data.
