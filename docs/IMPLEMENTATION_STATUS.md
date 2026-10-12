# Messages for Alfred

Browse recent conversations, read history in Alfred's Markdown Text View, and submit replies to the exact selected Messages chat. Built for this Mac: macOS 26.3, Alfred 5.8.1 with Powerpack, Apple Silicon. No third-party runtime is needed. The importable build is `dist/Alfred-Messages.alfredworkflow`.

The conversation UI uses Markdown history above a native reply field in one Alfred Text View. Version 0.7 integrates the in-place refresh approach developed in the UI experiments: the helper prepares fresh exact-chat history, and an active-view driver checks for changes every 500 ms. During a short update it buffers typing in memory and restores the draft and selection. It does not use a continuous Alfred rerun chain. Production native behavior still needs verification; see [docs/VALIDATION.md](docs/VALIDATION.md).

## Setup

1. Import the `.alfredworkflow` and run `msg`. The helper is bundled and starts on demand; no Terminal installation or LaunchAgent registration is required.
2. Reading the protected Messages database requires Full Disk Access. Start by granting Alfred this permission, as with Mouseless Messenger. Whether that covers the Alfred-launched Swift helper on this Mac remains to validate. If database access is denied, the helper's diagnostic will say so; the bundled helper app may need its own grant. Caching itself does not require Full Disk Access.
3. Messages Automation permission is needed for participant names and replying. Names come from Messages; no separate Contacts permission is required. Denied/unavailable automation falls back to phone numbers/email addresses without preventing database history reads. These macOS grants are separate from importing the workflow.
4. For automatic history updates, run `msg-cache`, choose **Automatic refresh access**, and grant the bundled **Messages Helper** Accessibility access in System Settings. Reopen the conversation afterward. The production helper has a separate identity from the experimental helper; its permission may need granting again after reinstalling an ad-hoc signed build.

The helper remains alive to retain memory-only cache and watch database events until it exits or the Mac restarts; the next invocation starts it again. No login agent is installed. The app bundle stays inside the imported workflow rather than being copied elsewhere. Old manually installed helper/LaunchAgent files are not automatically deleted: use the old uninstall script if desired, then invoke the new workflow. Its versioned endpoint avoids connecting to the old helper. Helper-restart and version-update behavior still need live testing.

## Use

Type `msg` to list 30 recent conversations by activity. Filter by conversation name or participant. Return performs a fresh coherent read of the exact selected chat, even outside the recent list, and opens 30 messages in chronological order, scrolled to the newest. Reactions appear as sender/timestamp events with the target text when available; attachments appear as labels. Reading history only uses read-only SQLite queries and does not mark messages read.

Write a reply in the separate Text View input field. Return submits by default. Set `send_key` to `command-return` to require Command-Return; plain Return then preserves the draft. A successful submission immediately appears in history as **Submitted to Messages**, even before Messages saves its database row, and clears the input. The temporary entry reconciles with the saved message without duplication. Sending returns immediately without waiting for delivery. Active-view background refresh reconciles committed messages and updates available delivery flags; explicit refresh also checks them. Submission, sent and delivered are distinct states; errors select and retain the draft. The history remains in Text View.

Control-Return performs a fresh exact-chat read only when the reply field is empty. With a nonempty draft, refresh is blocked and the current view is retained; a notification explains why. It does not reset the submission token or authorize retry of an ambiguous attempt. Option-Return activates Messages and retains/selects the draft. Messages' public scripting dictionary has no command to select a chat in its UI, so this action activates the app after resolving the exact chat; select the conversation in Messages yourself. It does not mark messages read on the workflow's behalf.

`msg-cache` offers Clear cache, Refresh, Cache status, Apply settings, Benchmark, and Automatic refresh access. Benchmark returns counts, limits and timings, never message content. Changing settings takes effect on the next workflow invocation; use Apply settings to apply immediately. Limits are clamped to 1–200. There is no automatic retry after an ambiguous failure. Rapid duplicate submissions are blocked by a per-view token and a pending-chat guard. Tokens are held in helper memory for up to 24 hours; restarting the helper clears them, so check Messages before manually retrying after a restart.

## Cache settings and privacy

| `cache_mode` | Data retained | Background behavior |
| --- | --- | --- |
| `disk` (default) | Bounded summaries, transcripts, resolved contact names and generated initials avatars | DB/WAL/directory change events, coalesced reads, 15-second reconciliation |
| `memory` | Same summaries, transcripts and names in helper memory; bundled icon | Same watcher; rebuild after helper restart/login |
| `off` | No reusable conversation cache; bundled icon. Active-view frames are temporarily held in memory | No file watcher or cache reconciliation; fresh exact-chat reads while a view is active |

The on-demand helper remains running as a local IPC endpoint in off mode, to coordinate submissions; it has no background Messages watcher or retained snapshot. Each ordinary request reads the database and resolves Messages participant names on demand. In all cache modes, an active conversation additionally prepares fresh exact-chat frames approximately once per second, retaining them only in memory. Active-view state expires six seconds after its last heartbeat. These reads do not resolve names on every update; the view retains its already resolved names. This small long-lived endpoint is an implementation difference from completely stopping the helper in off mode.

Disk cache is confined to `~/Library/Application Support/AlfredMessages/cache`. Switching away from disk removes that directory before acknowledging the mode change, resets memory, and rejects stale in-flight reader results. Mode and limit settings are stored separately in `settings.json`, containing no contact/message data. Cache files are atomically replaced with mode 0600 under mode 0700 directories. The private Unix socket and lock in `/tmp/alfred-messages-<uid>` contain no message data. Helper stdout/stderr are discarded by the helper process; it writes no content logs. Alfred's Script Filter result cache is disabled by omitting its optional `cache` output entirely. Do not enable Alfred's workflow debugger while displaying sensitive conversations: Alfred owns the UI and may record script outputs independently of the helper.

Memory and off modes never write personal avatars, contact names or message content to files, including temporary files. In disk mode avatars use initials, not contact photos. Clear cache removes disk and memory snapshots. An active cached-mode watcher may rebuild the cache on the next database event or reconciliation; switch to off to keep it empty. Unsent drafts are held by Alfred while displayed and briefly by the refresh driver during an update. Buffered keystrokes and draft snapshots stay in memory. Private temporary refresh guards contain only opaque session/refresh identifiers and a process ID; lock files contain no content. Updates pause for input methods requiring composition and while modifiers are held. Scroll restoration uses scrollbar position, not an exact message anchor. Refresh faults pause the driver and appear in numeric diagnostics; they are not counted as successful updates. After successful submission, the helper temporarily retains submitted text in memory to bridge database commit delays; it is never written to workflow cache files. These UI receipts expire after 120 seconds without a receipt-status check, checked every second, or are removed by Clear cache. Saved database messages continue to follow the selected cache policy. Off mode does not control macOS swap, Alfred's own memory or system-owned database files. Opening Messages can cause Messages itself to mark its selected chat read.

## Helper operations

The workflow's `run` wrapper invokes the stable app's executable. Operations: `list [filter]`, `view [draft]` (history/send/refresh/open through session variables), `history`, `send [draft]`, `open`, `refresh`, `configure`, `clear`, `diagnostics`, `benchmark`, `permissions`, and `daemon`. Internal active-view operations are `auto-check`, `auto-prepare`, `auto-fetch`, `auto-result`, `auto-fault`, and `watch-view`; `accessibility` requests access only when explicitly invoked. Automatic fetches carry a marked nonce and cannot submit a draft. A separate private dispatch guard blocks unmarked sends during an unresolved refresh, including helper-state loss. All IPC requests include settings. `chat_id` carries the database `chat.guid` unchanged; AppleScript resolves exactly one chat with the same identifier and never falls back to a participant. Draft and chat values are Apple event arguments, never source-code interpolation. SQLite opens with `SQLITE_OPEN_READONLY` and `PRAGMA query_only=ON`.

## Build and verify

Requires Apple's Command Line Tools for development only:

```sh
./scripts/test.sh
./scripts/build.sh
```

The build compiles Swift, generates native Alfred metadata and a 256px bundled icon, ad-hoc signs the helper app, and ZIPs the importable workflow. Python is used only at build/test time. Rebuilding/reinstalling an ad-hoc signed app can require re-granting macOS permissions. This is a local build, not a notarized public release.

Tests use a standalone Swift harness (no XCTest or full Xcode required), synthetic SQLite fixtures, the actual request handler, and mock send closures. `python3 scripts/integration.py` additionally exercises separate-process IPC on an unrestricted local Mac; this execution sandbox denied socket binding. See `docs/VALIDATION.md` for results and remaining live checks. The benchmark uses one reader and renderer with the same limits for all modes. If the selected policy is memory or off, the disk comparison simulates persistence in memory and says so; it never creates a disk benchmark cache. Under disk policy the disk benchmark does a real atomic write/reload. Timings exclude Alfred UI and IPC; do not treat them as a measured end-to-end p95. Cached output below 100ms p95 and normal freshness within two seconds are targets, not verified live promises.

## Removal

Delete the workflow in Alfred. The new build creates no LaunchAgent or separately installed app. Clear cache before removal if desired. A running helper can remain alive until logout/restart; lifecycle-aware shutdown is deferred. The retained uninstall script is for cleaning up the legacy manual installation, not required setup for this build.

## References

Native UI behavior follows [Alfred Text View](https://www.alfredapp.com/help/workflows/user-interface/text/) and [Text View JSON](https://www.alfredapp.com/help/workflows/user-interface/text/json/). Cache output follows [Script Filter JSON](https://www.alfredapp.com/help/workflows/inputs/script-filter/json/). Exact-chat automation follows the installed macOS Messages scripting dictionary at `/System/Applications/Messages.app/Contents/Resources/Messages.sdef`.


## Earlier implementation notes

## Use

Type `msg` to list 30 recent conversations by activity. Filter by conversation name or participant. Return performs a fresh coherent read of the exact selected chat, even outside the recent list, and opens 30 messages in chronological order, scrolled to the newest. Reactions appear as sender/timestamp events with the target text when available; attachments appear as labels. Reading history only uses read-only SQLite queries and does not mark messages read.

Write a reply in the separate Text View input field. Return submits by default. Set `send_key` to `command-return` to require Command-Return; plain Return then preserves the draft. A successful submission immediately appears in history as **Submitted to Messages**, even before Messages saves its database row, and clears the input. The temporary entry reconciles with the saved message without duplication. Explicit refresh checks delivery flags and updates the footer; sending does not start an automatic refresh loop, so typing is available again immediately after the send response. Submission, sent and delivered are distinct states; errors select and retain the draft. The history remains in Text View.

Control-Return performs a fresh exact-chat read and retains/selects the draft. It does not reset the submission token or authorize retry of an ambiguous attempt. Option-Return activates Messages and retains/selects the draft. Messages' public scripting dictionary has no command to select a chat in its UI, so this action activates the app after resolving the exact chat; select the conversation in Messages yourself. It does not mark messages read on the workflow's behalf.

`msg-cache` offers Clear cache, Refresh, Cache status, Apply settings, and Benchmark. Benchmark returns counts, limits and timings, never message content. Changing settings takes effect on the next workflow invocation; use Apply settings to apply immediately. Limits are clamped to 1–200. There is no automatic retry after an ambiguous failure. Rapid duplicate submissions are blocked by a per-view token and a pending-chat guard. Tokens are held in helper memory for up to 24 hours; restarting the helper clears them, so check Messages before manually retrying after a restart.

## Cache settings and privacy

| `cache_mode` | Data retained | Background behavior |
| --- | --- | --- |
| `disk` (default) | Bounded summaries, transcripts, resolved contact names and generated initials avatars | DB/WAL/directory change events, coalesced reads, 15-second reconciliation |
| `memory` | Same summaries, transcripts and names in helper memory; bundled icon | Same watcher; rebuild after helper restart/login |
| `off` | No retained message/contact data between requests; bundled icon | File watchers removed; reconciliation does no reads |

The on-demand helper remains running as a local IPC endpoint in off mode, to coordinate submissions; it has no background Messages watcher or retained snapshot. Each request reads the database and resolves Messages participant names on demand. This small long-lived endpoint is an implementation difference from completely stopping the helper in off mode.

Disk cache is confined to `~/Library/Application Support/AlfredMessages/cache`. Switching away from disk removes that directory before acknowledging the mode change, resets memory, and rejects stale in-flight reader results. Mode and limit settings are stored separately in `settings.json`, containing no contact/message data. Cache files are atomically replaced with mode 0600 under mode 0700 directories. The private Unix socket and lock in `/tmp/alfred-messages-<uid>` contain no message data. Helper stdout/stderr are discarded by the helper process; it writes no content logs. Alfred's Script Filter result cache is disabled by omitting its optional `cache` output entirely. Do not enable Alfred's workflow debugger while displaying sensitive conversations: Alfred owns the UI and may record script outputs independently of the helper.

Memory and off modes never write personal avatars, contact names or message content to files, including temporary files. In disk mode avatars use initials, not contact photos. Clear cache removes disk and memory snapshots. An active cached-mode watcher may rebuild the cache on the next database event or reconciliation; switch to off to keep it empty. Unsent drafts are held by Alfred while displayed. After successful submission, the helper temporarily retains submitted text in memory to bridge database commit delays; it is never written to workflow cache files. These UI receipts expire after 120 seconds without a receipt-status check, checked every second, or are removed by Clear cache. Saved database messages continue to follow the selected cache policy. Off mode does not control macOS swap, Alfred's own memory or system-owned database files. Opening Messages can cause Messages itself to mark its selected chat read.

## Helper operations

The workflow's `run` wrapper invokes the stable app's executable. Operations: `list [filter]`, `view [draft]` (history/send/refresh/open through session variables), `history`, `send [draft]`, `open`, `refresh`, `configure`, `clear`, `diagnostics`, `benchmark`, `permissions`, and `daemon`. All IPC requests include settings. `chat_id` carries the database `chat.guid` unchanged; AppleScript resolves exactly one chat with the same identifier and never falls back to a participant. Draft and chat values are Apple event arguments, never source-code interpolation. SQLite opens with `SQLITE_OPEN_READONLY` and `PRAGMA query_only=ON`.

## Build and verify

Requires Apple's Command Line Tools for development only:

```sh
./scripts/test.sh
./scripts/build.sh
```

The build compiles Swift, generates native Alfred metadata and a 256px bundled icon, ad-hoc signs the helper app, and ZIPs the importable workflow. Python is used only at build/test time. Rebuilding/reinstalling an ad-hoc signed app can require re-granting macOS permissions. This is a local build, not a notarized public release.

Tests use a standalone Swift harness (no XCTest or full Xcode required), synthetic SQLite fixtures, the actual request handler, and mock send closures. `python3 scripts/integration.py` additionally exercises separate-process IPC on an unrestricted local Mac; this execution sandbox denied socket binding. See `docs/VALIDATION.md` for results and remaining live checks. The benchmark uses one reader and renderer with the same limits for all modes. If the selected policy is memory or off, the disk comparison simulates persistence in memory and says so; it never creates a disk benchmark cache. Under disk policy the disk benchmark does a real atomic write/reload. Timings exclude Alfred UI and IPC; do not treat them as a measured end-to-end p95. Cached output below 100ms p95 and normal freshness within two seconds are targets, not verified live promises.

## Removal

Delete the workflow in Alfred. The new build creates no LaunchAgent or separately installed app. Clear cache before removal if desired. A running helper can remain alive until logout/restart; lifecycle-aware shutdown is deferred. The retained uninstall script is for cleaning up the legacy manual installation, not required setup for this build.

## References

Native UI behavior follows [Alfred Text View](https://www.alfredapp.com/help/workflows/user-interface/text/) and [Text View JSON](https://www.alfredapp.com/help/workflows/user-interface/text/json/). Cache output follows [Script Filter JSON](https://www.alfredapp.com/help/workflows/inputs/script-filter/json/). Exact-chat automation follows the installed macOS Messages scripting dictionary at `/System/Applications/Messages.app/Contents/Resources/Messages.sdef`.


## Return sending feedback and latency fix (0.5.0)

User confirmed names and Return sending; observed stalled grey input and duplicate/pending error after abandoning a request. Exact timing cause unproven. Removed synchronous Messages-name lookup after any submission attempt; fresh read uses retained names/handle fallback and background enrichment. Guard now keys exact token/chat/draft and still blocks concurrent chat submissions; a changed explicit draft after completion is distinct, same ambiguous draft remains blocked. Manual refresh with nonempty input is routed to a notification without Text View re-entry; empty-input refresh reopens fresh history. This is draft-loss prevention, not caret-preserving refresh. Command-Return validation deferred at user request. No live sends made by agent.

## Latest user feedback and deferred composing

User reports Control-Return closes the window in v0.5; refresh/view retention remains failed. Added direct-phone-number compose MVP and later contact/Messages-name destination selection to FUTURE_WORK.md. Lookup must find existing direct-chat history outside the recent limit, exclude groups, and must not promote/open-create destinations in recent history until committed message activity. Feature is deferred, not implemented. Command-Return sending tests remain deferred at user's request. Names and at least one native Return submission are confirmed; stalled-send/new-draft behavior after v0.5 not yet confirmed.

## Investigation: Control-Return closes before refresh guard

Installed v0.5 metadata matches packaged metadata: Control-Return connection has `vitoclose=false`. Read-only inspection of local Alfred 5.8.1 framework shows `AlfredWorkflowUserInterfaceTextView handleAction:` calls `isVitoForInputUid:inWorkflowUid:withMods:modOverride:` and posts a hide notification before processing the outgoing action when that returns false (0x1493f8–0x14940c). The manager recognizes the matching connection's `vitoClose=true` as the early true path (0x14198–0x141a0 -> 0x142fc). Thus our assumption that false meant preserve the view was incorrect for this path. The conditional/notification runs after the view has already been hidden.

Proposed fix: set `vitoclose=true` on the Control-Return connection (currently produced by `uid != 'REFRESH'` in package.py), and change the package assertion accordingly. Preserve the nonempty-draft guard; its blocked branch must remain terminal and never re-enter the Text View. Test draft-present branch keeps the same native view, then empty-draft refresh separately. This addresses premature hiding, not caret restoration across re-entry or automatic updates. Proposal only: production source/package left unchanged while user continues v0.5 tests.


## Control-Return hide fix (0.5.1)

Implemented the authorized connection correction: Control-Return now has vitoclose=true, so native outgoing-action handling suppresses hiding before the refresh guard. Package check requires true; draft-present branch remains a terminal notification, empty-input branch alone reaches refresh re-entry. Helper binary/IPC protocol unchanged; no helper reinstall needed. Native draft-present and empty-input behavior require retesting.


## Base send/history correction (0.6.0)

Successful automation acceptance now creates a transient submitted-message entry immediately, bridging Messages' delayed database commit. Exact-chat reconciliation inside the coherent history transaction replaces it with the saved row and reads optional sent/delivered/read/error fields. The footer reflects the active submission on explicit refresh; a reopened view reports the latest outgoing row's known status. Successful send clears the draft; failed/duplicate attempts retain their error instead of displaying an earlier receipt's success. No reruns or automatic submissions are introduced. The user chose immediate return to typing with delivery checks on explicit refresh. Receipts remain memory-only and expire after 120 seconds without status checking or on Clear cache. Workflow version is 0.6.0 with a v06 helper endpoint; fixture verification passes, native verification remains required. Automatic incoming-update integration is lower priority than these base behaviors.
