# Deferred and unresolved features

The current direction is one Alfred Text View with Markdown history above a native reply field below, following the official ChatGPT workflow. Idle view responses do not schedule reruns. Version 0.7 adds active-view automatic refresh from the experiments; native production verification is the next check.

| Feature | Current evidence / limitation | Acceptance for future implementation |
| --- | --- | --- |
| Automatic incoming history updates while composing | Continuous reruns disable input in Alfred 5.8.1; external-trigger re-entry cleared input and reset history. | Both panes remain visible; incoming locally committed messages appear within 2 s p95 / 5 s normal max over 100 events, including events while typing. No automatic execution submits a draft. |
| Draft, caret, focus, selection and composition preservation | Alfred's documented workflow interface does not expose this state; The production driver now reads/restores Accessibility state and buffers keystrokes, based on the experiments; native production verification remains pending. Native clear/select is not caret preservation. Manual refresh with a nonempty draft is currently blocked to prevent loss. The automatic route restores caret/selection and checks focus; explicit modifier refresh remains a separate native validation item. | Preserve draft content first. Later validate exact caret, selection, focus and IME composition across changed/unchanged updates, manual refresh and update failures. |
| Conditional bottom-follow / older reading position | Current baseline explicitly opens/refreshes at bottom. Forced end scrolling interrupts older reading; omitted scrolling failed bottom-follow. | Follow arrivals at bottom; preserve message anchor and offset otherwise, including edits/deletions. |
| Native Return / Command-Return validation | Handler guards can be tested; actual native key routing and modifier re-entry need Alfred. | Return submits once by default. Command-only mode plain Return never sends; Command-Return submits once. History stays visible, failure retains draft, success clears only submitted draft. |
| Pending sends / ambiguous failures across helper restart | Duplicate attempt hashes (token/chat/content) currently live only in helper memory; native request is synchronous. Refresh must not issue a replacement token after ambiguity. | Incoming/refresh during sending cannot duplicate or lose a draft. Helper restart after ambiguous send never retries automatically or treats the old attempt as safe. Distinguish submission from delivery. |
| Failure recovery without replacing available history | Cached history can be used when fresh read fails; no retained history in off mode. Alfred/IPC failure preservation not validated. | Retain displayed history and draft, visibly indicate unavailable updates, provide manual recovery; no off/memory persistent content artifacts. |
| Exact navigation to Messages chat | Existing automation verifies identifier and activates Messages; it does not navigate to that chat. | Only label exact navigation if verified. Otherwise expose “Activate Messages” accurately. |
| Reaction/edit/deletion coverage | Full fresh reads reconcile supported rows; legacy/changed/deleted content coverage is incomplete. | Fixture and live checks cover reaction add/remove, changed/deleted rows; document unsupported schema/content forms. |
| Watcher recovery / scan ordering | Event watching, debounce and reconciliation exist; dirty-during-scan and replacement/wake recovery need stronger validation. | Prompt reconciliation after sleep, helper restart and database/WAL replacement; obsolete results cannot overwrite newer data or recreate caches after privacy-mode change. |
| Fresh-on-open and visible latency measurements | Exact-chat coherent reads are implemented separately from cached-list display; end-to-end native timing unmeasured. | Fresh-on-open <=1 s p95 over 100 opens against locally committed data. Cached list output <100 ms p95. Report UI latency separately from helper timing. |
| Permission inheritance and minimal helper setup | Stable helper app/LaunchAgent exist; FDA attribution is not established by assumption. | Validate Alfred-launched reader vs independent watcher permission attribution on this Mac; minimize setup based on evidence. |

All cache modes, configurable limits, read-only database access, exact GUID routing and policy-respecting diagnostics remain requirements. Memory/off may retain active UI drafts in Alfred memory but must not persist workflow message/contact data. No real test sends without an explicitly chosen test chat.

## Production automatic refresh (0.7.0)

The user-confirmed smooth ChatGPT rendering experiments are now integrated into production, rather than left as a future investigation. The driver uses prepared frames, an in-place `replace` of the complete bounded transcript, bounded keyboard buffering, draft/range restoration, exact-session checks and conditional scrollbar restoration. No continuous rerun chain or external-trigger re-entry is used. The experiments remain available as diagnostic source.

Backend reconciliation and no-send guards are verified automatically. Production typing, selection, focus, blinking, scroll behavior and lifecycle recovery still require native Alfred testing. Composition input methods and held modifiers defer updates; exact message-anchor preservation remains unresolved. Sending returns immediately without a delivery-wait loop. Automatic active-view refresh checks the available database delivery flags alongside incoming history.

## Rejected prototypes

Custom window and sequential history/reply views are retained only as diagnostic source. They are not candidate product UI designs: history and reply must be simultaneously visible inside Alfred.

## References

[Native validation](VALIDATION.md). Research notes on the official ChatGPT workflow are in the source repository at `docs/ALFRED_CHATGPT_UI_FINDINGS.md`.

## Compose outside recent conversations

### MVP: direct phone number

Typing `msg 7137035474` should open the combined Alfred history/reply view for that number, even if it is absent from the recent list.

- Normalize and validate phone input; define country-code handling and ambiguity explicitly.
- Resolve an existing direct conversation by that phone number using live read-only database data, independent of the recent-conversation limit. Never substitute a group that contains the number.
- If an existing direct conversation is found, read coherent fresh history for its exact chat ID. Resolve multiple matching chats explicitly rather than silently choosing an arbitrary route.
- If no direct conversation exists, show an empty compose view and the exact destination number. Create/start the conversation only on explicit send, through Messages automation; never write to the database.
- Opening or looking up this destination must not promote it in the recent list or modify activity. Sort existing recent conversations by actual committed message activity; include/promote the destination only when a message is sent/received and locally committed.
- Preserve cache/privacy modes and submission-versus-delivery distinction. Invalid/ambiguous destination and failed/ambiguous submission must retain the draft and never automatically retry.

Acceptance: fixtures cover existing chat outside recent limit, nonexistent destination, duplicate/ambiguous direct-chat matches, group exclusion, number formatting/country ambiguity, no recent-list promotion on open, and promotion only after committed message activity. Native composing and real sends require an explicitly chosen test destination.

### Later: contact / Messages name

Allow `msg <contact or Messages name>` to select a destination. Disambiguate identical names and multiple phone numbers before sending; show the exact selected number/chat. Maintain the Messages-based name architecture or explicitly review any additional permission needed to discover contacts that have no existing Messages participant. Opening a destination still must not promote it until message activity occurs.

## Latest native refresh result

Control-Return in v0.5 closes the Alfred window. The nonempty-draft refresh guard has not achieved view retention. This is a failed native check even though metadata/fixture checks pass. Recheck modifier routing, action/notification handling and native close behavior; do not claim refresh preserves the displayed view or draft until a live check verifies it.

## Prepared-result probe: native outcome

The synthetic prepared helper decouples history preparation from Text View execution and records numeric fetch analytics. User testing found that the external incoming trigger still clears the draft. The first probe incorrectly appended only two prepared incoming messages into a reset view, losing the displayed initial 30-message history and landing at the top. Corrected event re-entry requests full prepared history, but cannot claim draft preservation. Return selects existing input because the probe explicitly requests `inputfield: select`; subsequent typing can replace that selection. Fast prepared fetches do not solve native re-entry. Need an in-place single-update mechanism or a verified preservation mechanism before enabling automatic production updates. Script/IPC timings exclude Alfred's input-disabled interval and rendering.

## Accessibility experiments implemented (synthetic probe v0.8)

Historical: the separate `msg-ui-ax` experiments (since retired and removed) attempted draft/range restoration, a 500 ms typing-pause gate, approximate conditional scroll restoration via writable scrollbar fraction, and opt-in bounded memory-only keystroke capture/replay. Exact synthetic-session identity and frontmost Alfred are checked; ambiguous/missing controls and newer nonempty drafts cause restoration to abort. Active IME composition, held/modifier keys and exact message-anchor preservation remain unsupported. Buffer failure can discard synthetic queued characters, so this is not production functionality. Numeric AX outcomes and observed disabled intervals are recorded separately from fetch latency; no text or raw events are persisted. Prepared fetch now avoids a child-process launch and labels new inline IPC measurements separately from legacy timings. Native authorization, field/scroll exposure and successful replay require live Alfred checks; automated tests do not establish those capabilities. The workspace executable currently reports Accessibility trust false in the agent environment.

## Latest native v0.8.2 experiment results

User confirms pause-triggered draft/caret restoration (middle and end), selected-range restoration, and bottom placement. Older reading position still jumps to bottom. The corresponding older-position record detected `was_at_bottom=false` but had no scroll-write result: a writable scrollbar was not available on the reacquired view at restoration time. Need to wait for/reacquire the history scroll control and verify actual position after writing; API success alone is insufficient.

Immediate refresh loses approximately 2–3 characters while restoring the captured snapshot. Three buffered-mode records captured/replayed zero events; two reported target/focus mismatch. Thus the buffer experiment did not test successful queue/replay and does not establish that buffering cannot work. The event-target PID gate is unsuitable or inconclusive at the current tap location. Need a verified field/window-scoped event targeting mechanism and instrumentation for the snapshot-to-buffer-arm boundary before repeating. Native runs measured trigger-to-ready roughly 135–223 ms in the latest records; one sampled disabled interval was approximately 51 ms. Missing disabled samples are unmeasured, not zero. Pause mode mitigates collisions but does not guarantee lossless continuous typing. No automatic production updates are enabled by these findings.

## v0.8.3 follow-up fixes awaiting native tests

Buffer now uses `CGEventTapCreateForPid` to attach directly to Alfred, arms before snapshotting (with 25 ms settling), queues physical events through replay, tags replay events and records capture/post counts. It no longer infers targets from a session tap's PID field. Posting all queued events is not proof they became text; native text checks remain required. Scroll recovery checks explicit vertical scrollbar references, retries for up to 800 ms after releasing the keyboard buffer, and verifies target versus actual normalized fraction. Automated checks exercise capture accounting, replay-tag exclusion, queue bound and cleanup without installing a tap or injecting keystrokes. Exact pixel/message anchors, composition and held/modifier key behavior remain deferred.

## v0.8.3 native follow-up outcome

User reports continuous basic typing and insertion in the middle behave correctly with process-scoped buffering. Nine process-buffer runs captured 23 keyboard events and posted all 23 with no reported overflow or focus cancellation. This supports the basic synthetic case, not general lossless input or IME/shortcut behavior. Bottom arrivals remain visible; native re-entry visibly blinks. Older-message visibility is partially preserved, but the exact partial-message/pixel position shifts: scrollbar fraction restoration is not an exact anchor. Remaining work includes repeated/coalesced arrivals, real database events, failure/focus-change recovery, Return-path selection, richer editing keys/composition, reducing blink and optional precise reading anchors. These results do not authorize real sends or automatic production integration by themselves.

## v0.9 verification experiments (not production integration)

`msg-ui-stress` compares ten spaced arrivals, serialized burst handling and coalesced burst handling, with numeric requested/visible revision logs and buffer accounting. Exact-session/focus cancellation can be checked by closing or switching views before an arrival. Fault cases skip dispatch, refuse replay after restoration, or delete the helper's synthetic session (a state-loss simulation, not a real process restart). They intentionally expose recovery gaps without adding persistent failed-input storage. Tests serialize cycles by design; this is not evidence that overlap has caused a native failure. Deterministic tests cover queue progression/coalescing, injected revisions and session loss. Native event handling, draft integrity and cancellation still require user interaction.

## v0.9 native results: demonstrated requirements

User reports no text loss for spaced arrivals, serial bursts or coalesced bursts. Repeated native re-entry blinking is extremely distracting; coalescing is only slightly less distracting. At that stage, blink reduction was a usability blocker for ongoing automatic production updates. The subsequent ChatGPT testing established smooth in-place rendering; see the current priorities below. Completed stress runs reached their requested visible revision; coalesced burst runs used two cycles rather than ten for the uncoalesced burst.

Injected pre-dispatch trigger failure preserved the draft with no visible incoming update. Injected post-restoration/pre-replay failure lost buffered letters but resumed typing and retained the prior draft. Simulated helper session loss erased history and draft; typing resumed into the cleared field. These are observed recovery gaps, not hypothetical risks: preserve a recoverable active-view snapshot and handle missing helper state before destructive re-entry; do not discard failed queued input silently. The session-loss simulation is not evidence about a real process crash. Close/switch visible behavior still needs clarification despite a logged cancelled-view/focus result. Existing experiments serialize cycles and do not prove overlap itself has failed.

## Historical risk/priority review after v0.9 (parallel investigation)

Buffer loss in before-replay tests was deliberately forced by refusing replay and clearing the queue. No spontaneous character loss was reported in successful v0.8.3/v0.9 basic buffered typing tests. Natural probabilities cannot be estimated per day/week from these trials. Real failure paths remain transition timeout, failed AX restoration, focus/destination changes, tap disable, queue/drain limits and process termination. For the synthetic probe, prioritize removing blink; before real-draft buffering, add modest non-destructive cleanup and bounded in-memory recovery. Defer durable crash recovery and event-to-text reconstruction absent evidence requiring that complexity. Current `buffer_focus_changed=false` is not strong evidence: the flag is no longer assigned by the process-targeted tap, so mid-replay focus changes still need explicit testing.

Probe session expiry is deterministic after 120 seconds without a fetch/injection heartbeat; the synthetic background preparer does not renew that heartbeat. Session-loss injection deletes a session rather than restarting the helper. Production helper has no equivalent session TTL and rebuilds/reloads cache data by selected mode. No spontaneous production failure frequency has been measured. Cheap preflight validation and retaining the active view on missing state are high priority before real event integration; sophisticated persisted recovery is deferred. Test idle expiry, actual restart, reset between preflight and fetch, and memory/off mode rebuilds separately.

Subsequent ChatGPT testing established that in-place streaming updates can render smoothly. Its existing-view append/replacelast route supplies the rendering approach; the external-trigger re-entry experiments above describe an older route. Applying that approach to unsolicited Messages arrivals with draft protection remains integration work.

## v0.10 high-priority experiments

`msg-ui-priority` tests existing-view append initiation via tagged synthetic Return into the focused, read-only probe Script Input, with buffering and no external-trigger re-entry or extra rerun chain. Single and ten-arrival cases log view identity, buffer accounting and revision progress. This does not authorize or safely route synthetic Return into production sending code; explicit refresh/send separation remains mandatory. A separate scenario deletes helper state before preflight and rejects invalid prepared frames before any interception or view replacement. It tests the cheap non-destructive safeguard, not actual restart/rebuild or state loss after preflight. Native smooth rendering and preservation remain unverified until user testing.


## Current priorities after ChatGPT testing

The user observed smooth updates in the ChatGPT workflow and confirmed that this testing addressed the blinking investigation. Treat the in-place Text View rendering approach as established; do not list another general blink investigation as the next backlog task. This confirms the rendering approach, not uninterrupted composing during unsolicited Messages updates or production integration. The v0.10 probe descriptions above record implemented experiments rather than a complete record of subsequent human results.

Current user priority: carry the successful experiments into automatic production refresh while keeping base sending reliable. Version 0.7 implements that integration. A single submitted message appears immediately, and active-view refresh reconciles committed history and delivery flags. Sending returns immediately; there is no post-send delivery-wait rerun chain.

Next work:

1. Validate v0.7 automatic incoming updates in Alfred while typing, including middle insertion, highlighted replacement, Unicode paste and both send-key modes. Check focus, blinking, close/switch behavior and numeric refresh failures.
2. Validate immediate submitted-message entries and delivery reconciliation in a user-chosen test conversation, including consecutive sends without duplicate entries.
3. Check Control-Return routing separately; explicit refresh remains blocked with a nonempty draft. Fix any remaining native window-closing behavior.
4. Address observed base send/failure/draft-retention issues, then compose by phone number outside recent conversations.

Existing buffering and smooth-rendering results informed this implementation. Native production checks remain necessary; they should verify the integrated behavior rather than repeat the general feasibility investigation.


## Deferred: inline HEIC attachments without additional image storage

User deferred this work. Investigate reading the existing Messages attachment path and embedding that original HEIC directly in Alfred Markdown, without copying, converting or generating preview files. macOS ImageIO reports HEIC/HEIF decoding support, but Alfred HEIC rendering and access to protected attachment files remain unverified. The supplied attachment label is not a resolved file path; database/directory inspection from this environment was denied. Keep filename fallback for inaccessible, missing, incomplete or unsupported attachments. Future verification must cover Alfred access, sizing/decode cost, special-character paths and typing/scroll behavior during automatic image updates. Do not introduce temporary image files in memory/off modes.

## Current native evidence

The user confirmed automatic incoming updates work after v0.7.7. Broader typing, composition, lifecycle and exceptional-buffer checks remain separate; do not list general refresh feasibility as unresolved.


## Deferred: native contact-name verification after 0.8.0

The user cannot reliably reproduce the intermittent name issue and deferred further native investigation until it appears again. The implemented preservation/lookup fixes and automated checks remain in place. Revisit with numeric name_lookup_diagnostics and the affected UI location if it recurs; do not require another immediate native trial.
