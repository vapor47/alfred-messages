# Intermittent contact-name audit

Audited the production name path after user confirmation that automatic incoming refresh works in v0.7.7. No name-lookup implementation changes were made. Names are obtained from Messages participants through Apple events, not direct Contacts access. The installed Messages dictionary exposes both participant full name and participant name; the workflow currently reads only full name.

## Definite implementation failure paths

1. Engine.refresh publishes a contacts=false snapshot with an empty name dictionary before lookup, replacing previously resolved names on every background refresh. With no merge, transient or partial lookup results can remove good names for an entire refresh interval. Disk mode persists the empty/partial intermediate snapshot too.
2. MessagesNameResolver.resolve breaks its conversation loop on any thrown automation error. One unresolved exact chat, timeout or other error prevents later chats from being attempted; activity order determines who loses names. Participant-level script errors are swallowed individually, causing partial results without reason counts.
3. Service.view resolves names only when the entire retained dictionary is empty, rather than when the selected conversation has unresolved handles. Unrelated successful names can therefore prevent lookup for an uncached or out-of-limit chat. Explicit refresh uses this same condition.
4. prepareLiveViews selects the global retained dictionary whenever it is nonempty, replacing the active view's complete map with a possibly incomplete global map. No union or per-handle preference protects view-specific resolved names.
5. Send responses deliberately avoid synchronous lookup but take names only from global retained state. They do not reuse the active session's name map. In off mode retainedNames always returns an empty map, so sending can erase names that were present immediately before the send. The reused live session is then registered with the empty map. Incoming refresh does not itself resolve missing names.
6. Recent-list lookup covers only bounded recent conversations. Automatic exact-chat history reads do not discover names for new handles. In off mode, a failed or incomplete lookup stays in the active view until another explicit lookup occurs.
7. The conversation list has no rerun once any snapshot exists. If it opens during raw publication, the displayed phone/email labels can remain until the user reexecutes the filter, even after names populate in the helper.
8. Name-resolution failures are swallowed into empty/partial dictionaries. Cache error remains empty because database refresh succeeded, and current diagnostics report a lookup method rather than permission/result status.

## Data and external-state failures

- Messages Automation permission is independent of database Full Disk Access and Accessibility. Denial, revocation, application startup delays, unavailable exact chats, Messages unresponsiveness and the script's three-second per-chat timeout fall back silently.
- Lookups are serialized across all callers. Up to the configured conversation limit can be visited sequentially; slow but successful chats can delay the entire name map and block off-mode synchronous reads. There is no aggregate deadline or per-chat retry/backoff policy.
- Missing/empty full name, unreadable participant properties or malformed Apple event pairs are skipped. Participant name is available in the dictionary but is not a fallback. A nonempty full name equal to the handle is accepted as a successful resolution.
- Normalization removes phone punctuation but does not resolve country-code, national-format, international-prefix, extension or Unicode-digit differences. Emails are lowercased without trimming or prefix handling. Alternate email/phone identities are not linked. Do not fix this with ambiguous suffix matching.
- The script visits current participants only. Former group participants appearing in history may have no pair. Removed accounts/chats, duplicate scripting matches and database/script state mismatches can cause exact-chat resolution failure.
- Render.title prefers any nonempty database display_name to participant-derived names. A stored phone/email title is not automatically replaced by resolved contact names. Named group titles are intentional and must not be overwritten indiscriminately. Unknown/missing sender handles cannot be named; Me is intentionally not looked up.
- Renamed contacts can remain stale until another successful lookup. Existing avatar files are reused even when resolved names change, so initials can look unresolved independently of text labels. Cache clear, privacy-mode changes and limit reductions discard/prune retained names by design; correct repopulation is still required.

## Recommended correction order

Preserve and merge valid names across raw/partial refresh publication; resolve missing handles for the selected chat rather than testing dictionary emptiness; retain active-view names across sends and preparation. Continue after chat-specific errors while treating permission denial as a global condition. Add privacy-safe counts/error categories and targeted fixtures for partial failures, out-of-limit chats, off-mode sends and active-view map regression. Evaluate full-name then participant-name fallback and explicit conservative address normalization separately. Preserve exact chat routing, current cache policies and send responsiveness; do not add Contacts access as an implicit workaround.

Synthetic repro confirmed that background raw publication erases a populated name map, country-code/email-whitespace mismatches do not match, and an off-mode mock send loses names that were visible before sending. The repro uses the actual compiled Engine, resolver and Service with synthetic SQLite and injected names/sender. Actual Messages lookup failure distribution remains unmeasured; no real sends or Contacts access were performed.


## Implemented corrections (0.8.0)

Implemented raw/partial cache name preservation, per-selected-chat missing-name lookup, active-view merging and send retention, bounded background missing-name retries, chat-specific error isolation and numeric lookup diagnostics. Automation denial remains a global stop condition. Phone normalization, participant-name fallback, named group title precedence, avatar regeneration and live conversation-list reruns are unchanged. The findings above describe the audited v0.7.7 behavior; consult validation for corrected behavior and remaining native checks.
