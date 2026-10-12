# Conversation ordering audit (0.8.0)

No production code changes were made. The user deferred further contact-name verification until recurrence. Audited Reader aggregation/sorting, Engine publication/freshness, Service filesystem watching and list rendering, outgoing receipts, Script Filter metadata and fixture coverage.

## Strongest finding: Alfred knowledge ordering

Service list items carry stable chat UIDs but the root JSON does not set skipknowledge. Alfred documents that learned ordering can override item sequence. Disabling Alfred filtering and result caching does not disable UID knowledge ordering. Counterargument: SQL and the emitted item array are sorted correctly, and an unused object may initially show that order. This does not constrain Alfred after items have been actioned. Proposed correction: set root skipknowledge=true consistently and replace the Script Filter object UID once to remove this object's existing ordering history, keeping exact conversation UIDs. Alfred explicitly cautions that skipknowledge does not ignore previously learned knowledge. Do not clear all Alfred knowledge.

Reference: https://www.alfredapp.com/help/workflows/inputs/script-filter/json/#result-ordering-and-the-uid

## Reproduced backend failure paths

- A refresh request received while Engine.refresh is busy returns without recording dirty/pending state. Synthetic test blocked name lookup after raw publication, committed newer activity, requested another refresh and released lookup: cached ordering stayed behind a fresh read. Counterargument: coalescing avoids redundant scans and the 15-second timer eventually retries. Remaining defect: the pass does not guarantee a catch-up read, and slow name lookup can prolong the stale interval substantially. Record pending refresh requests and drain them after the pass. Prefer separating names from raw refresh so name resolution cannot block conversation-order updates; preserve generation checks.
- Reader recognizes seconds and nanoseconds when converting dates, but MAX(date), ordering and LIMIT use raw values before conversion. A synthetic mixed-unit fixture returned a chronologically older chat first. Counterargument: a normal modern database may consistently use nanoseconds, so this does not establish the user's actual cause. Conditional defect: normalize the supported units before aggregation, sorting and limiting, also for message history. Do not sort only the already-limited results.

## Other freshness and policy paths

- Cached get returns an existing snapshot without an age gate or freshness request. A disk snapshot can appear immediately after helper restart. Counterargument: immediate cached output is an intentional performance feature. Remaining gap: stale first results are not followed by a list rerun; define bounded stale-while-refresh behavior and retain exact selected chat identity.
- A populated Script Filter list emits no rerun. Helper cache and active conversation history can update independently while the visible list remains old. Counterargument: stable browsing position is useful and no incorrect sort occurs within the original snapshot. Product gap if visible recency must track arrivals: bounded list reruns with stable UIDs, skipknowledge and native selection-retention checks.
- Watchers can be absent, bind replaced DB/WAL inodes, or miss/coalesce events; rebinding occurs on 15-second reconciliation. Counterargument: directory watching, fresh SQLite opens and periodic reconciliation provide recovery. This is a delayed-freshness risk rather than proof of permanent incorrect ordering. Rebind on replacement events and test WAL creation/replacement and wake. Continuous debounce postponement is bounded only by periodic reconciliation, which can itself be skipped while refresh is busy.
- Cache read failures retain old snapshots; get returns them, and list output does not disclose lastError or freshness. Counterargument: retaining usable history is preferable to a blank list. Actual visibility gap: distinguish stale/unavailable data in list status without exposing content; retry safe reads with bounded policy.
- Successful send receipts overlay active history only. The list ranks locally committed database rows. Counterargument: submission acceptance is not proof of a saved message; the established policy explicitly uses committed activity. Not a defect by itself. Ensure catch-up refresh after commit rather than moving an uncertain attempt to the top.
- MAX(message.date) includes reactions and other joined rows. Counterargument: these are conversation activity; list snippets already support reactions. Policy choice, not a demonstrated bug. Define eligible activity explicitly before excluding events.
- Equal activity values use chat ROWID as the deterministic tie-breaker, not latest message ROWID. Counterargument: exactly equal timestamps do not establish a strictly newer conversation. Not a definite error; a latest-message-row tie-breaker is an optional refinement.
- Timestamp source, future/incorrect dates, imported history, pinned/native Messages ordering, duplicate titles or distinct service/group chats can make expected order differ from MAX(message.date). Counterargument: the workflow intentionally ranks stored committed activity rather than cloning every Messages presentation rule. Compare exact chat identities and timestamps before changing policy; never silently clamp timestamps or merge different chat IDs.

## Ruled out / verification limits

Name merging, participant filtering and list mapping preserve conversation array order. Names do not sort the list alphabetically. Limits are applied after SQL activity sorting for a uniform timestamp representation. Alfred result caching is not requested. SQL reads occur in a coherent read-only transaction; state changes after its snapshot are freshness issues, not a broken read. Existing generation checks reject obsolete privacy/settings publications; do not remove them. Current fixtures check emitted ordering but do not exercise Alfred knowledge sorting or native list refresh. No real Messages data or live Alfred ordering was inspected.

## Recommended sequence

Correct Alfred knowledge ordering and reset only this object once. Preserve pending refresh intent and decouple name completion from publication of old message snapshots. Add bounded list freshness and explicit stale status. Add mixed-unit sorting coverage and normalize where that representation is supported. Leave reaction, tie-break and native pinned-order policy unchanged unless the user requests a different definition of recency.


## Implemented item 1 only (0.8.1)

Root skipknowledge is enabled for conversation results and the list object uses a new stable identity to discard its old learned ordering on import. Conversation UIDs are retained. Other audit findings are not changed in this release.
