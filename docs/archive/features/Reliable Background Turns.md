# Reliable Background Turns

Status: implemented and end-to-end verified 2026-08-12; restart/outbox
concurrency repaired 2026-08-13.

## Outcome

Once Wheatley has a complete user request, the authoritative server owns its
processing. Losing the submitting HTTP, SSE, or WebSocket connection, opening
another chat, changing profile, reloading, or closing the browser must not stop
final STT, Pi, tools, artifacts, response generation, or terminal persistence.
Only an explicit Stop or Cancel has cancellation meaning.

This is a narrow lifecycle correction, not a general job system. Most Wheatley
interactions already have an obvious atomic boundary. Continuous live recording
is the only unusual input because the request is being created incrementally.

## Interaction Boundaries

| Interaction | Server continuation point | Disconnect behavior |
| --- | --- | --- |
| Text or image turn | The complete request is validated and the pending turn is durably created. | Continue Conversation independently of the response connection. |
| Continuous live recording | Audio bytes arrive incrementally after a valid live-turn start. | Unexpected disconnect acts as an endpoint: finish the decoder with the audio received so far, run final STT, and process meaningful speech. |
| Explicit live-recording Cancel | The server receives an explicit cancel command before acceptance. | Discard the candidate and do not create a user turn. |
| Model, reasoning, speech, language, or chat setting | The small command is validated and atomically saved. | The command either succeeds or fails normally; it does not create background work. |
| Open/resume/list/delete/history command | The request is validated and its one filesystem mutation or read completes. | Normal request semantics. Deletion remains unavailable while that session has active accepted work. |
| Response event stream | The corresponding turn has already been accepted. | The stream is only an observer. Its loss never stops the turn. |

Model and reasoning selection for an accepted turn remain the immutable
snapshot chosen when that turn was submitted. Changing a preference while an
older turn runs affects later turns only.

## Simple Client Submission

This task must not add a client outbox, offline queue, optimistic “sending”
message, automatic retry, or a second client-owned turn state.

For typed text:

1. the user types a message and presses Send;
2. keep the exact message in the composer and disable both the input and Send;
3. call the server submission API;
4. when the server returns successful durable acceptance, clear the composer
   and enable the input and Send;
5. on any failure, enable the input and Send but leave the exact message in the
   composer.

The user can then retry, edit, copy, or preserve the text manually. Wheatley
does not claim that an unaccepted request will be recovered later.

Successful submission response means **the server has accepted ownership**, not
that the model response has finished. Streaming/following the accepted turn is
a separate observation. This early acceptance is what lets the composer become
available and lets the user open another session while the server continues.

The user may also submit another message into the same session while an earlier
turn is processing. Each successfully accepted message is appended to that
session and enters a strict FIFO queue. The server processes those turns one at
a time against the same linear Pi history. Different sessions may process in
parallel. The accepted user message appears in the transcript only after server
acceptance; there is still no optimistic “sending” bubble.

## Live Recording Disconnect

Continuous recording needs one explicit server rule because a disappeared
client cannot send its normal finish command.

On an unexpected WebSocket close after a valid live-turn start:

1. stop waiting for more input;
2. flush/finish the audio decoder;
3. use all valid audio samples received before the close;
4. seal the live draft state;
5. run the normal final transcription and existing draft-versus-final selection;
6. if the result contains meaningful user speech, persist the accepted audio,
   transcript, and immutable turn policy, then start Conversation;
7. if no meaningful speech exists, end without creating a turn.

This path should share the normal endpoint/final-STT implementation. A
disconnect is another endpoint reason, not a parallel transcription workflow.
Record it as `client_disconnect` in audio metrics.

An explicit Cancel must remain distinguishable from an unexpected close. Cancel
means discard; network loss, tab close, navigation, sleep, or process loss means
“finish what arrived.” If the transport cannot currently distinguish these,
add one small typed cancel command and treat an uncommanded close as disconnect.

The server cannot recover samples that never arrived. The promise is to process
the valid prefix already received, not to recreate the missing end of a sentence.

## Opening A Session With Work In Progress

Opening/resuming a session already exists and should remain the same user
action. The only new behavior is that its history response must truthfully
include any accepted nonterminal turn, replay that turn's durable event journal,
and follow new events until terminal or until the view detaches again.

The selected browser view may be Home, a different session, or a different
profile while the old server turn continues. Returning to the original session
does not resubmit or restart the turn.

### Automatic speech on reopen

Automatic speech is based on the state of each assistant bubble when the
session is opened:

- **Waiting for the first assistant token:** say nothing yet. If a new assistant
  bubble starts while this session remains open, speak it normally.
- **An assistant bubble is currently streaming:** when automatic speech is on,
  start that bubble from its beginning using the complete text accumulated so
  far, then continue with its new streamed text.
- **The latest assistant bubble is already finished:** do not read it when the
  session opens, even if the overall turn is still active and Pi is processing
  tools or input tokens before a later response.
- **A later assistant bubble starts after opening:** speak that new bubble
  normally.
- **The turn was already terminal when opened:** do not automatically read its
  completed answer. Manual Speak remains available.

Changing away from the session stops its local automatic speech and thinking
music, but not server-side work. Hidden sessions do not speak over the focused
session.

Pi already exposes assistant text `start`, `delta`, and `end`. Wheatley's
Conversation journal currently persists only assistant deltas. Persist the
existing start/end item boundaries as well so a reopened client can distinguish
an actively streaming bubble from a completed bubble without timing guesses.
This is presentation state for the canonical item, not a second transcript.

## Home Processing State

The Home recent-session list should show which sessions the authoritative server
is currently processing.

Add a boolean processing fact to each recent-session summary, derived from the
server execution owner. It is true whenever that session has at least one
accepted nonterminal turn, including a queued turn, waiting for the first token,
running tools, or streaming an assistant bubble. It becomes false only after all
accepted turns in that session are terminal.

Use a new small SVG progress icon: a quarter-circle line rotated by a simple
client-side CSS animation. It occupies the same leading marker space as the
current small blue active-chat dot. When a row is both the currently selected
chat and processing, keep the blue dot centered inside the rotating arc. A
processing non-current chat shows the rotating arc without the dot. The row's
other styling and layout remain unchanged.

Home should update when:

- a session becomes visible in Recent chats after its first accepted prompt;
- a session starts processing;
- a session finishes, stops, or fails;
- a session is removed.

Use one small profile-scoped server change stream. It can emit an invalidation
or compact session-status change and let the browser refresh the already-small
recent-session summaries. It is presentation synchronization only: losing this
stream does not affect Conversation, and reconnecting/reloading obtains current
state from the normal recent-session response.

## URL And Browser Navigation

Each Home session row must be a real link while retaining its current visual
appearance. The canonical route is:

```text
/chat/wheatley/2026-08-11-22_30_00
```

The URL form deliberately replaces the canonical session ID's `/` separators
with `-` so links remain readable. Map the example route back to the stored
session ID `2026/08/11/22_30_00`. Parse the fixed session shape strictly—year,
month, day, and `HH_MM_SS` with its optional collision suffix—rather than
performing an ambiguous global hyphen replacement. Do not emit `%2F` in session
URLs.

- An ordinary unmodified left click may be intercepted to open the chat without
  a full reload and push the canonical URL into browser history.
- Right click must expose normal browser link actions, including Open Link in
  New Tab.
- Middle click and modifier-click should retain native link behavior.
- Loading that URL directly in a new tab selects the profile and resumes the
  exact session.
- The web host/dev server must serve the client application for `/chat/...`
  routes so a direct load does not become a static-file 404.
- Browser Back from a session opened from Home returns to Home; Forward opens
  it again. A `popstate` handler applies the URL state without creating another
  history entry.
- The app's Home action updates the URL consistently. An invalid/deleted session
  falls back to that profile's Home and replaces the invalid history entry.

Do not make the row look like a conventional underlined web link. Change its
semantics and navigation behavior, not the established presentation.

## Implementation Result

The process-local reliability slice is implemented without a generic job queue
or client outbox:

- a short per-session submission lane durably publishes each accepted turn and
  emits `conversation_accepted` before the existing execution lane; later
  accepted turns wait in FIFO order while other sessions may execute through
  the four-slot Pi gate;
- response writers are observers of the durable journal. Failed SSE writes and
  finalization no longer control Conversation, and an intentionally disconnected
  Qwen turn completed once with its terminal answer persisted;
- recent-session and session-history responses expose server-derived processing
  state. An opened nonterminal session refreshes its canonical stored/journal
  projection until terminal, and persisted assistant start/end status events
  distinguish a currently streaming bubble for automatic speech;
- unexpected live-audio close finishes the decoder and normal final-STT path
  with `client_disconnect`; the browser now sends an explicit typed `cancel`
  before a deliberate close so Cancel remains discard;
- typed Send keeps and disables the exact draft until durable acceptance,
  clears it only after acceptance, and preserves/re-enables it on failure.
  Accepted user bubbles are not optimistic, same-session submissions remain
  usable while the previous response runs, and switching views does not Stop;
- Home renders the new rotating quarter-circle SVG and nests the current-chat
  dot inside it. Visible Home state refreshes from the compact authoritative
  recent-session response every 2.5 seconds. This deliberately small polling
  observer replaces the proposed additional change-stream protocol for now;
- recent rows are real anchors with strict readable session mapping, direct
  `/chat/<profile>/<YYYY-MM-DD-HH_MM_SS>` loading, native context-menu/new-tab
  behavior, SPA left-clicks, and Back/Forward routing;
- `pi.max_concurrent_runs` now defaults to 4, matching LM Studio's stated local
  request capacity while leaving session creation and accepted queues unbounded.

Machine verification covered all 84 D unittest modules, full client lint and
production build, compiled console text chat, a real disconnected HTTP turn,
same-session FIFO acceptance/execution, same-profile parallel sessions, and
Firefox direct URL/Home/Back/reopen/composer-failure behavior. The real model
checks used Qwen3.6 35B A3B for disconnect/FIFO/parallel tests and Qwen3.6 27B
for the deliberately slow browser-switch test.

The remaining human/physical check is microphone-driven live-audio disconnect
and explicit Cancel on actual capture hardware. Uploaded-recording final STT and
image staging share the same observer-independent server request behavior, but
their mid-stage disconnect matrix was not rerun with physical files in this
pass. Process crash/power-loss recovery remains deliberately out of scope.

## Baseline Facts Before Implementation

These are code-derived facts as of 2026-08-11:

1. Submission IDs, atomic pending-turn publication, execution claims, terminal
   commit fencing, gap-free Conversation sequences, and durable event replay
   already exist.
2. Different sessions—including sessions in one profile—can already execute
   concurrently. The per-session lane keeps one Pi history linear, and the
   global Pi gate bounds total model work.
3. Exact recent-session resume and normal terminal history restoration already
   exist.
4. `ConversationRuntime.run` still executes synchronously inside its submitting
   request. Its durable sink writes the journal first and then writes the live
   transport; a transport exception can therefore propagate back into the
   producer.
5. Text, image, uploaded-audio, accepted-live-voice, and live-audio response
   paths still pass response/socket writers directly into Conversation.
6. The browser owns one selected `ChatSession` and currently forbids chat
   switching while streaming, transcribing, recording, or live listening.
7. The current live-audio loop returns when `socket.connected` becomes false.
   It does not yet finalize received audio as a disconnect endpoint.
8. Pi's event adapter already observes assistant text start/end, but the common
   durable Conversation event currently carries assistant deltas only.
9. Browser IndexedDB is currently used only for metadata about an already
   accepted live-voice prompt. It stores profile/session/submission identity,
   transcript, policy, artifact identity, and replay cursor—not PCM, the
   recording, or another audio copy.
10. Recent-session rows are currently buttons, and the browser client has no
    URL/history owner or `popstate` handling for Home versus an exact session.
11. Recent-session summaries currently contain identity, start time, language,
    and initial prompt, but no live processing fact or profile-wide change
    notification.

The observed `Connection closed while writing data` log is consistent with the
request/producer coupling, but a focused test must establish the exact Vibe.d
disconnect exception timing rather than relying on that one log.

## Recommended Implementation

### 1. Detach accepted Conversation work from its observer

Give each accepted turn one small server-owned execution keyed by its existing
session and submission/turn identity. It holds the active session-use lease and
runs the existing `ConversationRuntime` workflow through terminal persistence.
It does not own another copy of the prompt, events, tools, or result; those stay
in the filesystem turn and event journal.

The submitting request may follow that journal immediately. If its response
write fails, only the observer ends. Conversation continues.

For one session, accepted executions enter one explicit FIFO lane. A later
message waits until every earlier accepted turn in that session is terminal,
then continues from the updated Pi history. This is the existing linear-session
rule made usable from the re-enabled composer, not a general scheduler.

Do not add a database queue, scheduler, generic worker framework, or new durable
job schema. The daemon process is the execution lifetime boundary.

### 2. Let an opened session follow its accepted active turn

Expose the session's accepted nonterminal turn and current journal cursor in the
existing session/history contract or one narrow active-turn field. Let the
browser attach to that turn by identity and replay events after its cursor. It
must not need to resend the original text, image, or audio.

The event journal remains the source for active presentation; ordinary stored
turn history remains the source after terminal completion.

### 3. Persist assistant bubble boundaries

Project Pi's existing text start/end facts into the common Conversation event
stream and journal beside deltas. The browser uses those exact item boundaries
for pending bubble state and the automatic-speech rules above.

Avoid a separate speech-state database or heuristic inactivity timeout.

### 4. Finalize live audio on unexpected close

Refactor the current normal endpoint and disconnect path to call the same
finish-decode, final-STT, selection, acceptance, and Conversation entry point.
Only the endpoint reason differs. Keep explicit Cancel on the discard path.

Once meaningful live speech is accepted, the server should start Conversation
without requiring the disconnected client to send a second approval. Model and
reasoning were already pinned at live-turn start.

### 5. Permit browser switching after input acceptance

- Keep the exact composer text visible and disable composer input/Send only
  while the submission request is unresolved. On acceptance clear/re-enable;
  on failure retain/re-enable. Add no “sending” bubble, retry loop, or client
  persistence.
- After acceptance, Home/new/recent/profile navigation detaches presentation
  but never calls Stop.
- During live capture, switching/closing produces the disconnect-finalization
  behavior above; explicit Cancel still discards.
- Returning restores terminal history or follows accepted active work.

The first slice still needs only one selected `ChatSession`. Several retained
session controllers, unread badges, and simultaneous visible streams can remain
later UI improvements.

### 6. Publish processing changes to Home

Project the server execution owner's current processing fact into recent-session
summaries. Emit one small profile-scoped change notification when sessions are
added/removed or processing changes, and refresh/patch the Home list.

Render the new rotating quarter-circle SVG in the current marker slot, with the
existing active-chat dot centered inside it when both states apply.

### 7. Make session navigation URL-addressable

Add one small browser route/history owner for profile Home and exact session.
Render recent rows as styled anchors. Intercept only normal same-tab clicks;
preserve native context-menu/new-tab behavior and apply Back/Forward through
`popstate`.

## IndexedDB Scope

Do not add the general IndexedDB outbox proposed in the first draft. Text and
image interactions have clear complete-request boundaries; the disabled
composer plus clear-on-acceptance/retain-on-failure behavior is the complete
client contract for this task.

The existing `AcceptedVoiceOutbox` uses IndexedDB for one narrower recovery
window: after the server has already preserved live audio and accepted its
transcript, the browser stores small metadata and an event replay cursor so a
lost WebSocket can finish the commit/replay through HTTP. It intentionally does
not store the audio itself. Cursor checkpoint is one atomic read/write
transaction. Because the entry is origin-shared, another view may receive the
terminal event and delete it first; a later checkpoint then treats absence as
successful terminal acknowledgement rather than storage corruption, and never
resurrects the deleted entry.

With the new rule that the server starts Conversation directly after accepting
meaningful live speech—even when the socket disappears—that client commit
window may become unnecessary. During implementation, either:

- reduce the existing entry to reconnect/follow metadata if it still provides
  a real recovery need; or
- remove it once the server and session-open path fully own continuation.

Do not retain two recovery paths by habit. The final implementation should have
one clear owner.

## Failure And Recovery Limits

- Client disconnect is not a failure of accepted work.
- Explicit Stop cancels an active Conversation turn and saves the existing
  stopped terminal result.
- Explicit live Cancel discards an unaccepted recording candidate.
- An OS kill, daemon crash, power loss, or machine restart still ends in-process
  Pi/tool execution. Existing execution fencing should record an honest
  ambiguous failure rather than repeat arbitrary external effects.
- Interrupted-turn recovery begins only after the new daemon successfully owns
  its listening port. The normal launcher waits for the complete previous
  process to exit, not merely for its listener to close, before starting a new
  owner. An unsuccessful or overlapping daemon start therefore cannot fail a
  turn still owned by the prior process or create two writers for one event
  journal.
- A client-dependent tool such as camera capture may fail if its required
  hardware client disappears. Server ownership cannot supply absent hardware.
- Hidden-chat automatic audio is not part of background execution.

## Implementation Order

1. Add focused slow-agent tests proving that text/image Conversation finishes
   after its observer disconnects.
2. Separate accepted execution from SSE/WebSocket delivery while preserving the
   existing journal, fences, per-session lane, Pi gate, Stop, and deletion lease.
3. Add accepted-active-turn restore/follow to session open.
4. Persist assistant item start/end and implement reopen speech rules.
5. Treat unexpected live-audio close as `client_disconnect`, finalize received
   audio, and process meaningful speech; preserve explicit Cancel as discard.
6. Implement the exact composer disable, clear/retain, and re-enable behavior;
   allow same-session FIFO appends and browser session/profile switching after
   acceptance.
7. Add processing state and the rotating quarter-circle indicator to Home, plus
   profile-scoped recent-session change notifications.
8. Add canonical profile/session URLs, anchor rows, direct-link loading, and
   Back/Forward handling.
9. Reassess and simplify the existing accepted-voice IndexedDB entry once the
   server no longer waits for client commit.

## Acceptance Criteria

### Server and protocol

1. Disconnect a text or image response stream before first token, during a
   server tool, and during assistant streaming. Every accepted turn completes
   once with its tool results, artifacts, final text, and terminal event saved.
2. Disconnect continuous live audio after meaningful partial speech. Wheatley
   finalizes exactly the received prefix, records `client_disconnect`, runs
   final STT, and processes the resulting prompt.
3. Disconnect live audio before meaningful speech. No turn is created.
4. Send explicit live Cancel after speech. No turn is created.
5. Explicit Stop after the response observer detached still stops the correct
   active turn and records `stopped`.
6. Two sessions in one profile execute concurrently; two turns in one session
   retain their existing order.
7. Active execution keeps session deletion busy after all observers detach and
   releases it after terminal persistence.

### Session reopen and speech

1. Open a turn waiting for its first token: nothing old is spoken; its first new
   assistant bubble is spoken when it starts.
2. Open while an assistant bubble is streaming: automatic speech starts that
   bubble at its beginning and continues without duplicating its accumulated
   text.
3. Open after that bubble ended while the agent is doing tools or preparing a
   later response: the completed bubble is not spoken; the later new bubble is.
4. Open a terminal turn: no automatic replay occurs; manual Speak works.
5. Switch away during work: local speech/music stops, server work continues,
   and reopening restores the correct active or terminal state.
6. Repeat the scenarios with automatic speech off: nothing starts speaking.

### Client submission, Home, and navigation

1. Press Send: composer text and Send become disabled and the message remains
   visible until the server answers the acceptance request.
2. Acceptance clears the composer and re-enables both controls. A network or
   server failure re-enables both and preserves the exact text for manual retry
   or copying. No “sending” bubble, automatic retry, or IndexedDB entry exists.
3. Submit two messages into one session before the first completes. Both appear
   only after acceptance and execute in acceptance order against one linear Pi
   history; a different session can execute concurrently.
4. Starting a turn adds/updates its Home row with the rotating quarter-circle;
   terminal persistence removes the processing state. A newly created session
   and a session changed by another tab/client appear without reloading Home.
5. The current active-chat dot remains centered inside the rotating indicator
   while that current session is processing.
6. Home rows remain visually unchanged but are real links. Right click offers
   normal link actions; `/chat/wheatley/2026-08-11-22_30_00` opens the stored
   `wheatley` session `2026/08/11/22_30_00` directly in the current or a new tab.
7. Home → session → browser Back returns to Home, and Forward reopens the same
   session without restarting or resubmitting its active turn.

## Scope

In this task:

- server-owned continuation for accepted text, image, and live voice turns;
- disconnect-finalization of continuous recording;
- active-turn restore/follow on normal session open;
- durable assistant bubble boundaries and precise reopen speech behavior;
- browser switching after the relevant continuation point;
- same-session FIFO submission and sequential processing;
- simple composer acceptance/failure behavior without client robustness layers;
- live processing indicators and recent-session status notifications;
- URL-addressable sessions with native links and browser Back/Forward;
- preservation of current concurrent-session semantics.

Later:

- several retained `ChatSession` view owners, unread badges, or completion
  notifications outside the Home processing state;
- cross-process resumable Pi/tools or exactly-once external effects;
- a distributed queue or multi-server scheduler;
- simultaneous execution of turns within one linear session;
- automatic playback from hidden chats.

The governing rule is: **complete requests and received live-audio prefixes are
server work; connections only deliver input and observe results.**
