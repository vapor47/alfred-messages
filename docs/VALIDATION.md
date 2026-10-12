# Validation

Environment confirmed: macOS 26.3 (25D125), Alfred 5.8.1, Apple Silicon. This is a local ad-hoc signed build.

## Automated checks

`./scripts/test.sh` runs eight core fixture suites plus the real request-handler suite in a release build. All pass. The test harness uses synthetic data and mocked send callbacks; it never sends a message or reads the user's conversation contents.

Covered:

- Read-only SQLite, missing database and incompatible schemas; no accidental database creation.
- Recent-conversation ordering and 30/30 limits; chronological history, Unicode, attributed-body decoding, reactions, attachment labels and unavailable content.
- Participant-name matching and fallback and participant-name filtering within named groups; Markdown escaping.
- Atomic 0600 cache files, disk-to-memory/off purge, no persistent message/contact/avatars in memory/off, stale background-read rejection, immediate retained-limit reductions and clear cache.
- Memory restart behavior, off startup policy, and off mode with zero file watchers and zero retained snapshot.
- Real request and response codecs, both send-key settings, initial-input guard, preservation of draft/history on failure, successful submission clearing, refresh retaining/selecting the input and preserving its token after ambiguous submission.
- Exact selected group ID propagation to a mocked send callback; duplicate and pending-submission rejection, ambiguous failure consuming its token, and no automatic retry.
- AppleScript compilation and parameter passing using a harmless subroutine. Compiling scripts that load the Messages dictionary required an unavailable GUI/XPC service in this sandbox; live Messages script compilation remains unverified. No send script was executed against Messages.
- Benchmark policy: a memory/off benchmark never writes the simulated disk cache.
- Database/WAL event freshness on synthetic data.

`docs/fixture-results.json` contains measurements from 35 synthetic conversations × 40 messages, using the default 30/30 limits and 50 warm list samples per mode. These measure the actual helper handler and JSON codecs; they exclude the Unix socket, executable startup and Alfred. They are fixture results, not a live performance guarantee. Cold values measure configuration through first ready list; Name lookup uses injected fixtures/fallback handles; no live Messages name automation is performed by tests.

The archive is checked with `unzip -t`, both plists with `plutil -lint`, the app signature with `codesign --verify --deep --strict`, and shell entry points with `zsh -n`. Native workflow connections, modifier masks, settings defaults, executable bits and bundled binary equality are inspected during packaging verification.

## Checks blocked in this environment

The user's Messages database denies access (`authorization denied`). No personal messages were inspected. The execution sandbox also denies binding the private Unix socket; `scripts/integration.py` is supplied for separate-process testing in ordinary Terminal. No external installation paths were changed from this restricted session.

Alfred's native Text View behavior has been implemented using its documented JSON and script interface but cannot be exercised by the available tools. Confirm these in Alfred before relying on live replies:

1. Install the helper and grant Full Disk Access. Restart it and confirm `msg` lists real conversations without marking them read.
2. Select a user-chosen test conversation, first a direct conversation and then a group. Confirm names, participant filtering, snippets, chronological history, timestamps and reactions/attachment labels.
3. In `command-return` mode, type a draft and press plain Return: it must remain and no message must be submitted. Press Command-Return and verify the exact group receives it once. Test default Return sending separately.
4. Confirm the separate input field clears after submission, history stays visible, and the footer distinguishes submission from delivery.
5. Use Control-Return with an unsent draft and confirm the native Alfred input survives refresh. Induce a denied Automation permission and confirm the draft remains. Check Messages before deliberately retrying an ambiguous error.
6. Switch disk → memory → off with Apply settings. Confirm the workflow-owned cache directory disappears. Restart the helper and log out/in to confirm the policy remains selected and drafts stay in Alfred while its view remains open.
7. Run `msg-cache` → Benchmark on real data. Record both cold and warm timings; the full cached-output target is below 100ms p95 and normal freshness within two seconds. Measure off mode separately without an instant-output promise.
8. Run `python3 scripts/integration.py` from this source checkout after building to exercise the local socket, process startup/restart and synthetic privacy checks. It uses a private test endpoint and database, not personal Messages data.
9. Sleep/wake the Mac, restart the helper with a draft displayed, and change workflow limits and send keys. Confirm refresh/reconciliation recovers and the draft remains until successful submission.
10. Verify helper removal unloads the agent and removes its app, settings, cache and endpoint.

No live send has been performed. A user-selected conversation and macOS permission grants are required for that final validation.

## Implementation differences from the plan

Off mode removes watchers and retained data but leaves a small idle LaunchAgent endpoint for request and duplicate-submission coordination. It does not perform background reads. A fresh helper starts off until Alfred applies the selected mode.

Activate Messages resolves the exact selected chat and activates Messages. The installed public scripting dictionary provides no command to select that chat in Messages' window; selection there remains manual.

Disk-mode avatars are generated initials; memory/off use the bundled icon. Contact photos, inline media and sending attachments are not included.


## Combined-view baseline (0.2.0)

History and reply field share one native Text View. Idle history responses emit no rerun. Fresh exact-GUID reads use a short read-only transaction; fixtures verify an open chat outside the recent limit and an immediately committed edit. Automatic helper refresh still updates the list/cache, but displayed history changes only on open, explicit refresh or submission. Current refresh selects the draft and scrolls to end; caret/reading anchor preservation is deferred in [FUTURE_WORK.md](FUTURE_WORK.md).

The native Return boundary explicitly tags return-send; empty-action, initial-load and refresh handler calls cannot send even with nonempty drafts. Modifier branches still re-enter the same native Text View and require live validation. No pending/ambiguous submission is retried automatically. Token survival across helper restart remains deferred.


## Messages names (0.4.0)

Name lookup uses Messages participant handle/full name through Apple events, after database commit. Cached raw data publishes before background name resolution. Direct Contacts access and its permission prompt are removed. Fixtures cover formatted phone/email matching, Unicode names, empty/unknown fallback and injected name rendering. Live Messages Automation authorization, returned handles/full names and timeout behavior remain to test on this Mac.


## Submission responsiveness / refresh guard (0.5.0)

User confirmed native Return submission works; Command-Return testing deferred. Synchronous name lookup after submission has been removed and fixture verifies zero name lookups on an off-mode send response. Fixtures verify different explicit content may submit after an ambiguous attempt finishes, identical attempt stays suppressed, pending chat guard remains. Native refresh with a draft now routes to a terminal notification with vitoclose=false; empty-input condition is required before re-entry. Package checks verify this routing. Actual Messages automation latency remains unmeasured and may still disable input while the send itself runs. Native refresh-guard behavior must be checked; no real sends performed by agent.


## Control-Return correction (0.5.1)

The v0.5 false flag failed live: Control-Return closed the view. The connection now uses vitoclose=true, with an updated package assertion. Test a nonempty synthetic draft first: the same view and draft should stay; refresh is blocked. Then test empty input: fresh history should open and remain visible. Native success is not claimed until these checks pass.


## Immediate sent history and delivery refresh (0.6.0)

The regression fixture deliberately accepts a send before committing its message row. The response immediately contains a submitted entry, clears the input and emits no rerun. A subsequent explicit refresh reconciles new outgoing rows in the exact chat beyond the pre-send ROWID boundary. It reads receipt candidates inside the same read-only transaction as history, avoiding a commit race between acknowledgment and rendering. Fixtures cover consecutive and identical pending sends, an old identical delivered row, a same-text row in another chat, distinct row claims, dated delivery confirmation, read-implies-delivered, send failure, reopened-view status and transient-receipt clearing. No real Messages send is performed. Existing schema fixtures without delivery columns continue to pass.

Only actual delivery/read fields confirm delivery; is_sent alone does not. Automation supplies no message GUID, so reconciliation uses exact chat, a new row beyond the pre-send boundary and identical text; an identical concurrent send from another client in the same chat remains inherently indistinguishable. Unsupported/absent delivery fields never become invented delivery confirmation. Submitted text stays in helper memory for a bounded UI receipt lifetime, never cache files or logs. The new v06 endpoint starts the updated bundled helper rather than reaching an already-running v05 binary.

Native checks: import v0.6, send one reply in an explicitly chosen test conversation and verify it appears before another send. After delivery, use Control-Return with empty input and verify the footer changes. Send two replies consecutively and check neither appears twice after refresh. Verify the field becomes usable after each send response. These native checks and actual Messages delivery latency remain untested in the restricted workspace; Unix-socket binding is also unavailable here. Automatic delivery polling is intentionally absent at the user's request.


## Production automatic refresh (0.7.0)

Automated checks cover prepared-frame revision progress, exact session/chat routing, draft-independent history, stale-settings rejection, malformed/duplicate marked request no-send routing, helper-state loss, transient state clearing and retention of explicit send failures during incoming updates. The production driver's pure self-test covers bounded capture decisions and the private dispatch guard, including malformed guard state; it installs no event tap and posts no native event. Package verification checks the bundled executable and native workflow metadata. Numeric prepared/returned counts do not prove Alfred rendered an update or preserved typing.

Native checks still required: import v0.7, use `msg-cache` → **Automatic refresh access**, grant the production Messages Helper Accessibility permission, and reopen a conversation. Receive a message while typing a known sequence, inserting in the middle, replacing highlighted text and pasting Unicode. Verify history and available delivery status change without Control-Return; check characters, caret, focus and blinking. Read older history during arrivals and inspect scrollbar retention. Close or switch conversations before an update and ensure no reopening or wrong-chat result. Test both send-key modes and refresh recovery. The agent has not performed real sends or native Alfred testing; socket binding is denied in this workspace.

Active frames stay in memory in every cache mode and expire after heartbeat loss. Refresh guard files persist only opaque session/nonce/PID metadata. IME composition and held modifiers defer updates. Scrollbar fraction is approximate, not an exact message anchor. A fault pauses automatic updates rather than claiming successful recovery; diagnostics report numeric failures. Failure recovery is bounded and does not establish lossless editing across arbitrary process crashes.


## Refresh driver lifecycle correction (0.7.1)

The driver previously exited as soon as its writable reply control disappeared after first discovery. A send can temporarily disable or replace that control; a replacement driver can meanwhile fail to acquire the existing driver's session lock. The driver now continues heartbeating while the exact session remains visible and waits for its reply control to return. Closing/switching still stops it. This addresses a lifecycle defect found during investigation, not a confirmed diagnosis of the user's particular failed update. Native send-followed-by-arrival verification remains necessary.


## Visible-view identification correction (0.7.2)

User diagnostics confirmed Accessibility trust, 13 prepared frames, zero returned frames and six `view-marker-unavailable` failures. The previous invisible identifier existed only in the footer, unlike the experiments' readable identifier in history. Initial and replacement transcripts now include the same exact readable session label beneath history. Fixture assertions verify its presence on both paths. The driver distinguishes a missing view identifier from an identified view with an unavailable reply control. This fixes the identification mechanism; native arrival/typing confirmation is still required. No message contents or identifiers were added to diagnostics.


## Hide internal view identity (0.7.3)

Removed the visible View/UUID label and the extra separator beneath history. Initial, automatic and failure responses now use only an invisible encoded session marker; the transcript retains the marker location introduced in 0.7.2 rather than moving it back to the footer alone. Fixtures verify that initial and automatic history retain the internal marker without exposing the UUID. Native Accessibility exposure of the invisible transcript marker still requires verification; this build does not establish successful native automatic refresh. Exact-session checking remains fail-closed.


## Accessible link identity (0.7.4)

The invisible text route remained unverified and the user still reported absent automatic updates. Session identity now uses the conversation heading's Markdown link destination, leaving its visible title unchanged. The driver checks AX URL attributes and attributed-text link metadata as well as ordinary attributes. No fallback chooses a conversation by title or window position. Startup failures distinguish missing Alfred, inaccessible windows, unavailable link identity and unavailable reply control. Fixtures verify the link destination on initial and replaced history, with no visible View/UUID label. Native metadata exposure, dispatch and typing remain unverified until tested in Alfred; automated passes are not a claim that automatic refresh works end to end.


## Fetched but undisplayed refresh (0.7.5)

User confirmed no visible automatic update despite one returned frame and no failure. The frontend previously silently dropped responses if heading identity became unavailable during execution. It now also accepts an exact annotated field paired with the independent session/nonce dispatch guard; a rejected response reports `frontend-result-discarded`. It never accepts a guard alone or a conversation title match. Complete bounded transcripts now use native in-place `replace`, since the production route creates no explicit append segment for `replacelast`. Rendering, blink and typing behavior require native confirmation; a returned frame still is not proof of display.


## Refresh recovery correction (0.7.6)

User diagnostics recorded one returned frame, dispatch failure and a paused refresh. The driver incorrectly required completion in its initial wait even when bounded recovery later succeeded. Final success now requires confirmed request capture, draft restoration and completed replay, regardless of which wait completed them. Missing reply controls during the initial wait are retried without restoring or dispatching into unidentified controls. Annotation readback is given up to 100 ms to reflect a successful AX setter; posting still requires exact annotation verification and focus. Dispatch diagnostics now identify focus, buffer, setter error code or readback failure without logging draft contents. Pure driver tests cover successful recovery and refusal when any capture/restore/replay condition is missing. Native incoming updates and editing remain unverified.


## Definite refresh audit fixes (0.7.7)

Fetching no longer advances the applied revision. A new auto-finish operation acknowledges frontend acceptance after JSON is written to stdout; rejected results remain eligible for a new prepared request. Finalization validates exact session/chat and the prepared generation, is idempotent, and retains an acknowledgment distinct from backend capture. Diagnostic frames_accepted counts frontend acceptance, not proof of native rendering. The driver keeps the dispatch guard until finalization and the writable input returns. The obsolete combined heading/footer completion detector is removed.

Every restoration now requires focus, the original window and no intervening mouse/scroll interaction. Empty newer input is never replaced with a nonempty snapshot. Mouse events pass through but invalidate restoration/replay. Completion and recovery renew heartbeats at 500 ms intervals while the exact session or guarded annotated field is identifiable; closure/switch never authorizes renewal or replay. Regression fixtures cover fetched-but-unaccepted changes, rejection and retry, wrong-chat acceptance, idempotent finalization and rejection remaining rejected. Native rendering and buffer failure handling remain separate unresolved checks.


## Contact-name preservation (0.8.0)

Raw/partial background cache publication merges known valid names and prunes by current limits. Selected history resolves missing handles even when unrelated cached names exist. Active views merge names and preserve them across sends, including off mode, without synchronous lookup after sending. Background selected-chat retries are limited to once every 30 seconds per active session and publish only to the matching generation. Automation failures retain numeric codes; per-chat timeout/unavailable errors continue to later chats while permission denial stops the pass. Name lookup reports numeric attempts, outcomes, unresolved counts, participant failures and malformed pairs; it logs no names, addresses or content.

New synthetic checks cover raw publication while lookup is blocked, partial/empty refresh preservation on disk and in memory, timeout/unavailable-chat isolation, permission-denial stopping, missing selected-chat lookup with unrelated cached names, outside-recent access, names across off/cached sends, and names retained in automatic history frames. Existing zero-synchronous-lookup send, privacy-transition and routing checks remain applicable. Actual Messages property availability, address normalization and native naming outcomes remain external checks; no Contacts access or real sends were added.


## Preserve chronological list order (0.8.1)

Only ordering audit item 1 is changed. All conversation-list responses now set root skipknowledge=true, retaining stable chat UIDs for routing/selection. The conversation Script Filter has a new fixed object UID to reset this object's previously learned ordering, as Alfred documents existing knowledge is not ignored by adding skipknowledge alone. Cache tools and other workflow objects retain their identities. Backend fixtures verify the flag and existing descending activity output in all cache modes and empty results. Package validation checks the new object identity and its connection to Text View. Native ordering after import requires confirmation; cache freshness, refresh coalescing, timestamp semantics and list reruns are unchanged.
