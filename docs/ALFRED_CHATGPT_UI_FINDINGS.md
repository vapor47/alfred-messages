# Official ChatGPT workflow inspection

Inspected 2026-10-05 via the Gallery's linked official repository:

- https://alfred.app/workflows/alfredapp/openai/
- https://github.com/alfredapp/openai-workflow/blob/main/Workflow/info.plist
- https://github.com/alfredapp/openai-workflow/blob/main/Workflow/chatgpt

The official workflow uses one Text View containing Markdown history and a Script Input field below it. Its config is behaviour=2, inputtype=1, scriptinput=2, outputmode=1, stackview=false (info.plist lines 1296–1327). There is no outgoing unmodified Return connection (lines 177–219). Native Return runs the Text View script with the question; modifier branches provide distinct secondary actions. Two sequential views are unnecessary for simultaneous history and input, and are rejected for this project.

The script separates idle and streaming phases:

- Idle history return: no rerun (chatgpt lines 208–212).
- A submitted question initiates a bounded stream and sets streaming_now (214–226).
- Streaming: rerun every 0.1 seconds, append a marker, then replace only that response segment (80–89, 145–157).
- Completion/error/stall: returns without rerun (100–103, 139–143, 171–176).
- Streaming forces scroll=end; it does not implement conditional bottom-follow.

Local Alfred 5.8.1 framework inspection established that script execution disables input and the valid rerun branch bypasses re-enabling it. Therefore the official source pattern is consistent with input returning after the stream finishes; source inspection does not establish native typing/composition behavior during streaming. We have not run the official workflow with an API key or made any network API request.

Useful architecture to retain: a single persistent native Text View, history plus bottom input, native Return handled by its script, explicit action/stream state, limited response-segment updates rather than external-trigger re-entry. The official sample does not demonstrate unsolicited incoming updates while typing, draft/caret preservation across automatic refreshes, or conditional reading-position preservation. Copying its persistent chat/stream files would violate memory/off policies and is not proposed. Sending logic must not infer an explicit submission from a nonempty argument on an automatic rerun.

User clarified both history and reply must always be visible within Alfred. Custom window and sequential split-view prototypes are rejected, preserved only as diagnostic work. Production remains unchanged. Any next prototype must return to the combined Text View and clearly separate simultaneous layout (supported) from uninterrupted automatic updates (unresolved).

## Blink investigation after v0.9 native testing

Re-read the official upstream `Workflow/chatgpt` source. Its streaming path remains inside the existing Text View script lifecycle: append a marker (readStream lines 84–89), then use `replacelast` on 0.1-second reruns (152–157), with the final response omitting rerun (172–176). It does not use an external trigger to reopen the view for every chunk. This explains why the user's observed smooth streaming is compatible with our blinking external-trigger experiment. It demonstrates incremental rendering, not uninterrupted reply typing during reruns.

Our event envelope sets `prepared_revision=-1` because re-entry resets history; this forces a full prepared replacement regardless of the append comparison setting. Thus event tests so far have not tested true in-place incoming appends. Full replacement alone has not been isolated as the cause of blink: the re-entry/recreation route is the key difference. Next isolate native in-place append/replacelast with a short synthetic stream initiated by Return, then investigate invoking the existing script lifecycle for incoming events (e.g. a verified native Accessibility action). Any automated invocation must have a separate refresh-only operation and cannot infer sending from nonempty text. Continuous reruns still have the previously observed input-disable limitation; use bounded cycles and validate buffering/focus rather than claiming the official workflow solves unsolicited updates while typing.


## Backlog clarification after user follow-up

The user's smooth ChatGPT testing resolves the general investigation into whether the existing Text View can update without external-trigger blinking. Use its in-place rendering approach for subsequent Messages integration. Remaining checks concern incoming-event initiation, composing during updates and failure recovery; do not describe smooth rendering itself as an unaddressed investigation. See the current priorities in FUTURE_WORK.md.


## Production integration (0.7.0)

The resulting approach is now wired into the production Text View. A fresh exact-chat producer prepares frames in memory; the visible driver checks every 500 ms and fetches only changed frames. Each update replaces the last response segment in place, keeping the configured bounded transcript. Draft/range restoration and bounded process-specific keyboard buffering bridge the input-disabled interval. Invisible request markers and an independent private dispatch guard ensure automatic execution cannot send, including rejected stale sessions and helper-state loss. No external trigger reopens a closed conversation. These are implementation and automated-check results; the earlier smooth experimental rendering result does not itself validate production typing or rendering.
