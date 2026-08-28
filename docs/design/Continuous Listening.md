# Continuous Listening

Status: physical capture reuse and the candidate-after-commit loop are
implemented; extended hands-free and background acceptance checks remain.

## Outcome

Continuous listening lets a person dictate successive messages without
restarting capture or hearing start/stop chimes while the assistant is not
allowed to speak automatically. Each finalized spoken segment becomes its own
visible user message. The next candidate starts immediately, including while
Pi is still working.

The profile setting **Keep microphone on** is available only
while both **Play music** and **Automatically speak responses** are off. Its
saved value is retained while hidden. Turning on either output mode uses hard
suspension until the assistant output finishes; turning the setting off uses
the same hard-suspension path even when output is disabled.

## Candidate loop

1. The client and server open a live capture session and begin a candidate.
2. The existing endpointing rules finalize a candidate after configured silence
   or confirmed spoken `submit`. Repeating the terminal word in one accepted
   draft counts as repeated confirmation, and all terminal repetitions are
   removed from the submitted prompt.
3. Wheatley commits the normalized transcript as one user bubble.
4. If Pi is idle, the message starts a normal turn. If Pi is busy, the message
   enters the session's chronological admission queue and displays as queued
   without cancelling current work. At Pi's next boundary, all adjacent queued
   user segments already present are delivered as separate messages before one
   inference.
5. Physical capture continues across final transcription and durable commit.
   Frames recorded before the next candidate socket is ready are buffered and
   delivered to that candidate in order. It does not wait for the previous
   message to reach Pi or for Pi to answer.

## Queued bubble projection

Pi owns agent execution and is the source of truth for the dialogue, reasoning,
tool, and assistant order it has actually accepted. Wheatley remains a narrow
audio, admission-queue, and multi-client projection proxy: it submits each
accepted message at Pi's earliest supported boundary and does not construct a
second agent history.

A user input has three visible phases:

- a client-local STT draft is semi-transparent and appears at the end;
- a server-accepted input that Pi has not yet accepted is a semi-transparent
  queued bubble in the shared session tail;
- when Pi confirms the user-message boundary and begins work, that same stable
  bubble becomes opaque and moves once into Pi's canonical timeline.

The UI renders Pi's committed timeline followed by the FIFO queued-input tail
and then its own local draft. New Pi reasoning or tool events therefore appear
before queued bubbles and naturally push that transparent tail downward; a
queued bubble is never followed by agent activity. Multiple clients receive the
same accepted and delivered transitions, while an unaccepted draft remains
local to the capturing client.

Each bubble has a stable turn ID. Ordinary state changes update that ID in
place. Pi's delivered status and the ordered presentation journal form the
canonical boundary: every client moves the turn group once, and any late event
for an older turn inserts into that existing group instead of appending after a
newer bubble. A separate mutable `after_item_id` is unnecessary and would add a
second ordering authority.

The browser keeps this projection only in memory. Accepted voice and queue
recovery belong to the server/Pi boundary; the former browser IndexedDB
accepted-voice outbox and its resubmission path are removed. Open sessions
follow the durable presentation stream; Home views periodically reconcile the
small recent-chat index so chats created or changed by another client appear
without browser persistence.

Opening a session uses one snapshot-and-follow boundary. Completed turns come
from the materialized session view. Every processing turn keeps only its user
or admission shell and server-created scheduler provenance, then rebuilds all
Pi reasoning, tools, artifacts, and answer text from that turn's durable
Conversation events before subscribing after the snapshot watermark. The
client never mixes a partial materialized active turn with replayed deltas.

If the session SSE ends, the browser does not wait for a page reload. It obtains
a new presentation snapshot, applies entries after its prior watermark with
per-turn sequence deduplication, and reattaches after the new watermark. The
per-turn sequence remains remembered after completion or failure so a replayed
terminal suffix is idempotent. Codex presentation follows the equivalent
cursor-resume loop. These observers are independent of live audio: an audio or
capture failure may end its current candidate, but cannot permanently stop Pi
thinking and tool presentation.

The console follows that same session stream in addition to the response stream
for its own submission. It filters its own device events, reports turns admitted
by web or another client, deduplicates replay by canonical turn sequence, and
reattaches after a transport interruption. Its current append-only output can
report queued, Pi-started, and completed transitions, but cannot truthfully
recolor and move an earlier terminal line. Gray queued messages that become
normal and shift into canonical order require a model-driven terminal UI; that
presentation refactor remains a separate slice rather than fragile cursor
rewrites in the stream printer.

The browser owns one physical media stream across continuous candidate
boundaries. It detaches the finalized candidate's socket, continues recording
into a handoff buffer during final STT, then attaches the next candidate's
socket and flushes that audio before new live frames. The waveform remains live
throughout this handoff, and boundary chimes remain suppressed. Ownership checks
prevent a late completion from an older assistant turn from closing a newer
capture. Hard suspension stops the media tracks and audio context; the next
candidate must reacquire them.

Leaving a chat for Home is a hard capture boundary: it cancels the current
unaccepted candidate and releases the microphone. Any already accepted message
continues as ordinary server-owned background work, but it cannot keep creating
new voice candidates while the chat is hidden. New chat and recent-chat
navigation are therefore immediately available from Home and during accepted
background work in an open chat.

Submitting before even one audio frame arrives is an empty candidate, not a
terminal recording failure. The server keeps the same live session in listening
state and accepts the first subsequent frames normally.

## Transcript normalization

Partial STT text remains provisional and can replace its mutable suffix. Client
projection keys updates by candidate and revision so a new draft replaces the
old tail instead of briefly appending a duplicate suffix.

Preview stabilization bounds the mutable audio tail so long dictation does not
make every later draft transcribe the whole utterance. The smaller preview model
owns only responsive provisional text; final STT still transcribes the accepted
audio and remains authoritative. When a later candidate is accepted while Pi is
finishing an earlier turn, the transparent queued tail follows all current Pi
activity. Pi's confirmed user-message boundary moves it into the canonical
timeline, and live and restored projections use that same boundary and order.

Before a stable prefix is retained, Wheatley removes non-speech annotations such
as bracketed sound descriptions. Repeated annotation-only content normalizes to
empty. When the normalized retained prefix is empty, Wheatley discards its
prefix text and retained audio; final processing begins from the remaining
spoken candidate. The original accepted audio artifact, when one is retained by
the ordinary audit policy, remains truthful to what was submitted.

Normalization is conservative: it removes recognized annotation-only spans,
not bracketed words embedded in ordinary spoken content. The same normalizer is
used for draft presentation, stable-prefix decisions, and final prompt text.

## Music, scheduled work, and manual playback

Continuous capture and music are mutually exclusive, so microphone input stays
clean. Enabling music does not cut off a candidate already being recorded; the
hard-suspension policy takes effect when that candidate commits. Music begins
only after capture release and stops before microphone reacquisition. Automatic
response speech uses the same ordering. A later
physical speaker/headphone test may justify a reversible option to allow music
during capture; Wheatley does not assume acoustic echo cancellation makes that
combination harmless.

With automatic speech off, a scheduled task can add text, reasoning, tools, and
an answer without pausing the microphone. Its clickable `will run` item is an
admission barrier: earlier finalized voice segments stay before it and later
segments stay after it. Its visible events join the session in server order
while the current audio candidate continues. If the user manually
starts assistant playback or enables automatic speech, the existing voice-yield
protocol suspends and later resumes the same candidate rather than opening a
second recorder.

## Background browser behavior

Continuous listening does not weaken the truthful-capture requirement. The UI
shows whether worklet frames are actually arriving, not merely whether a record
button is logically active. If Firefox suspends capture in a covered,
background, other-tab, or minimized state, Wheatley preserves the candidate up
to the last received frame and reports that capture paused.

The implementation may recommend a documented Firefox/page or `about:config`
setting after physical verification. It does not use timer churn, synthetic
audio, or another undocumented workaround to pretend capture is continuous.

## State and recovery

The minimum state is:

- `off` — no continuous candidate;
- `listening(candidate)` — frames and draft revisions are arriving;
- `finalizing(candidate)` — one boundary is being committed while capture feeds
  the next candidate;
- `suspended(candidate, reason)` — capture/playback/browser policy has paused
  progress without discarding accepted frames;
- `failed(candidate, detail)` — recovery needs user action.

Reload may reconnect to a live server candidate when the same client/session
lease can prove ownership. Otherwise it ends the old candidate truthfully and
starts a new one; it never merges unrelated audio across reconnect.

## Later acceptance checks

- Twenty minutes of hands-free dictation creates ordered, non-overlapping
  bubbles without chimes or missed candidate boundaries.
- At least three messages spoken during one long Pi turn arrive as ordered
  steering messages at supported boundaries.
- Scheduled work appearing during capture does not lose or duplicate audio.
- Annotation-only silence does not grow retained prefix text or final replay
  cost.
- Foreground, covered-window, other-tab, and minimized Firefox states each show
  truthful capture status.
- Music-on speaker use and headphone use are compared physically; any necessary
  restriction is explicit and reversible.
