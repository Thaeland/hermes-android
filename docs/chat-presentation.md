# Chat presentation

## Verbose Mode

With Verbose Mode off, you see user messages and assistant replies with successful
completion evidence. The transcript hides commentary, incomplete or failed replies,
tools, reasoning, delegated tasks, background reports and source diagnostics.
Approvals and input requests remain accessible in both modes.

With Verbose Mode on, you can inspect the retained detail. Tools, reasoning,
delegated tasks, background reports, notices and message metadata start collapsed.
Your expansion choices survive updates and lazy scrolling during the visit.
Closing and reopening the chat resets those choices. Covering a chat with a task
inspector does not start a new visit.

## Completion and saved history

A successful response receipt confirms received prose. An owned successful turn
terminal can confirm the current final response, but cannot promote earlier interim
commentary. Ordinary stream EOF, an idle gateway and a durable row ID do not prove
that an assistant finished its reply. A definitive failure revokes that response's
completion marker before storage cleanup finishes; admission stays blocked until
its existing recovery and persistence checks permit another prompt.

For saved assistant rows, quiet mode requires source-local completion metadata,
such as a successful status or `finish_reason: stop`. Some gateways omit that
metadata from saved messages. Quiet mode hides those rows, including older answers;
use Verbose Mode to read them. App-owned received replies survive route reattachment
while their owner remains alive. After an app restart, saved history must supply
its own completion evidence. REST/SSE received replies remain local to the chat
visit.

The app keeps saved and received Remote Gateway output as independent sources.
Verbose Mode labels them and can show repeated prose across the sources. Quiet mode
hides the labels without merging the underlying rows. The display filter does not
remove raw messages or add synthetic messages to request history.

After a successful REST/SSE reply, a stale history GET must not erase its received
body or receipt timeline. Handover requires the final response's own durable ID and
a saved, successful response with that same ID. The current SSE protocol supplies
no such message ID, so the app retains that reply for the visit. Matching text,
newer IDs and message order cannot establish correspondence.

## Current activity

One bar above the composer shows the current tool or other active work in either
mode. Saved tools and late updates from older delegated tasks do not start it.
Completion removes the active indicator. Stop hides it for that turn without
claiming the gateway has accepted another prompt. Failure and uncertain-outcome
notices use the same area without a typing spinner.
