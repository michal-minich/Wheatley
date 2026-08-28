# Session Message Queue

Status: independently audited and corrected, 2026-08-21. The active queue now
has one placement-aware owner, endpoint-time voice admission, durable lifecycle
projection, terminal handoff/compaction, confirmation-driven cancellation, and
sequence-based browser/console projection. No live profile or daemon was
migrated in this audit. Controlled reader cutover, full deterministic race
coverage, and physical voice remain explicit gates in the verification note.

## Outcome

Every submitted user message has one durable position in its session, is
visible to every client, and progresses through one server-owned lifecycle.
Slow STT, client disconnection, another client's faster message, or a daemon
restart must not silently change that position.

The submission boundary is the moment the server receives the client's signal
that the user has finished submitting the entry:

- text: the user presses **Send**;
- voice command: Wheatley recognizes the terminal spoken `submit`;
- automatic voice endpoint: the configured silence/no-new-speech timeout
  expires, when the end-of-speech chime begins.

For voice, this signal means “this captured chunk is closed and now needs final
STT.” The server records `submitted_at` and reserves the position immediately,
before final STT waits for capacity or begins calculating. Final STT, audio
encoding, and other preparation happen after this boundary and cannot change
the message's position.

The queue is conceptually a small ordered list of messages with metadata. At
most one item runs in a session. Pi execution, STT, TTS, and client presentation
are separate concerns around that list.

## Current verified behavior

- An unaccepted voice draft remains local to the capturing client.
- After server acceptance, a stable turn ID and durable Conversation event are
  propagated to every client observing the session.
- Other clients show the accepted user message as queued. Pi delivery changes
  that same message to canonical/in-progress; it does not create another
  message.
- Reasoning, tools, answer text, completion, and failure are routed by the
  stable turn ID.
- Reconnecting clients rebuild from a durable snapshot and continue after its
  cursor. The originating client suppresses the duplicate copy from the shared
  session stream.
- Accepted work continues when all clients disconnect.

This correctly handles cross-client identity and propagation after acceptance.

## Remaining boundary

The durable queue now reserves voice order before final STT, dispatches from
the queue owner, recovers safe work on restart, and keeps accepted work alive
when observers disconnect. Pi has no supported context-prefill RPC in the
bundled adapter. Wheatley therefore leaves an untouched session empty and lets
the first real Pi turn freeze and present its context in physical turn order.

The explicit migrator still retains the old history reader as its conversion
oracle; controlled live migration and deletion of that conversion-only reader
remain a separate final-cutover operation. Restarted `preparing` voice work is
currently failed explicitly and unblocks later items; resuming final STT from a
staged Opus artifact is not yet implemented. Deterministic fake-Pi/fake-STT
coverage for every timing race, a paired two-daemon remote-placement pass, and
the physical voice/browser matrix remain verification work.

## Canonical owner

The D server owns one `SessionQueue` per session.

- Clients submit input and observe state; they never own accepted work.
- STT prepares the content of a queue item; it does not decide ordering.
- Pi consumes ready items selected by the queue dispatcher; Pi steering is an
  execution optimization, not another queue.
- TTS consumes assistant content independently and cannot fail or reorder the
  conversation.
- Scheduled occurrences are ordered queue items and act as explicit barriers.

One Pi worker per active session remains reasonable. Worker count and global
model concurrency are independent of queue ownership.

## First-turn Model context

Creating or resuming a session does not start a hidden Pi turn or publish
conversation content. Listening and STT may begin while the transcript remains
empty.

The first real Pi turn freezes the session's rendered System context and emits
**Model context** once as part of that turn. Durable presentation orders it
immediately before the initiating user message, or before the scheduled-task
item for a scheduled turn. Resuming restores that existing turn-owned item and
does not emit another copy.

Model context is observable session content, but it is not a user queue item and
does not consume a message sequence. The web UI shows it as a tool-styled,
non-cancellable bubble; the console prints it once in turn order. Neither client
offers an X for it. It is always audio-silent: never announce it, synthesize it,
or route it through any audio/TTS queue.

## Pi/LLM availability

Pi/LLM is a critical dependency. Wheatley does not need a degraded fallback or
special recovery workflow when it is unavailable, but dependency failure must
not crash the server or client and must never leave a half-written session.

An item is not durably changed from `ready` to `running` until execution is
actually claimed. If Pi cannot be reached before that claim, the item remains
durably `ready`; when Pi is available again, the dispatcher can continue from
the same item. If communication is lost after execution may have started, the
item becomes `interrupted` rather than being replayed automatically.

Every external Pi boundary is surrounded by durable queue state. Normal app
exit, forced exit, or daemon restart must therefore reopen a consistent session
and restore `preparing`/`ready` work without reconstructing intent from partial
files.

## Queue item

Each accepted item contains at least:

```text
id                     stable submission ID
session_id
sequence
kind                 user | scheduled
source               text | voice | console | scheduled | ...
client_id
submitted_at         server time when submission signal is received
state
text                 optional while preparing
audio/artifact       optional reference
model and base reasoning
                     frozen execution policy; final prompt preparation may
                     derive the one-turn leading-`think` override
failure/result       optional terminal reference
```

At the submission boundary, the client immediately sends a lightweight
reservation to the server. The client creates the stable `id` at this boundary
and reuses it if the reservation request must be retried. The reservation
does not provide the authoritative time. In one durable admission transition,
the server records its current time as `submitted_at` and assigns the durable
`sequence`. Repeating the same reservation returns the same queue item rather
than creating a duplicate. No final text is required yet.

Both submission time and ordering therefore use the server's receipt of the
submission signal. Client clocks are irrelevant. The timestamp is normally
very close to the user's Send/submit/endpoint action, but importantly it is
earlier than final STT completion and earlier than final STT execution when the
STT lane is busy.

For voice, Wheatley reserves the sequence as soon as spoken `submit` is
recognized or the configured silence endpoint expires, before final STT. The
saved audio and reservation survive while STT produces final text.

The reservation freezes the selected reasoning preference, but final text may
start with Wheatley's leading `think` instruction. During the same durable
`preparing -> ready` transition that stores that text, the queue replaces the
item's effective reasoning with the model's highest supported mode. This is a
turn-local derived policy: it does not mutate the session/profile preference,
and the next ordinary turn returns to that persistent preference.

## State machine

```text
preparing -> ready -> running -> completed
    |          |         |----> failed
    |          |--------> cancelled
    |-------------------> failed
running --daemon loss---> interrupted
```

- `preparing`: position is reserved; final STT or another required preparation
  is incomplete.
- `ready`: complete input is waiting for execution.
- `running`: Pi owns the one active execution in the session.
- `completed`, `failed`, and `cancelled`: terminal states.
- `interrupted`: execution may have produced external side effects and is not
  automatically repeated.

## Ordering invariants

1. The submission boundary is the server receiving the reservation signal
   generated by Send, recognized spoken `submit`, or expiry of the configured
   silence endpoint. Final STT is never the ordering boundary.
2. Sequence is assigned durably at that boundary and is total, monotonic, and
   immutable within a session.
3. Every client projects accepted items in sequence order.
4. A nonterminal earlier item blocks every later item. A later `ready` item
   cannot pass an earlier `preparing` item.
5. At most one item is `running` in a session.
6. Starting, completing, failing, or cancelling changes state, never identity
   or sequence.
7. Adjacent ready user messages may be delivered to Pi together at a supported
   boundary, but remain separate queue items.
8. A scheduled item is a normal ordered barrier. No separate admission-barrier
   registry decides its position.
9. If Pi misses a steering boundary, the item remains queued and runs normally
   next. No repair path changes its order.
10. Retrying admission with the same item ID is idempotent and cannot reserve a
    second sequence.
11. A `preparing` item must eventually become `ready`, `failed`, or `cancelled`.
    A progress-aware watchdog may fail lost preparation work but must not punish
    legitimately slow STT or move a later item ahead silently.

Example:

```text
41  preparing  "some long text..."  final STT still running
42  ready      "ok"
```

Item 42 remains visible and queued, but cannot start until item 41 becomes
ready or terminal.

## Client projection

The session snapshot contains the ordered queue items and their current states.
The follow stream publishes simple lifecycle changes:

```text
admitted
prepared
started
completed
failed
cancelled
interrupted
```

Every event carries the stable item ID and session sequence. The originating
client and other clients consume the same lifecycle; local submission streams
may reduce latency but cannot create a second presentation authority.

An unaccepted STT draft remains client-local or explicitly ephemeral. It is not
part of shared history until the server reserves a queue item.

## Cancellation

A bubble X has two deliberately simple meanings:

- local draft, not yet reserved by the server: remove it locally and forget it;
- server-reserved `preparing` or `ready` item: mark it durably `cancelled`.

Durable cancellation keeps the queue item, sequence, already-stored audio, and
other artifacts. It does not delete files, send the message to Pi, or create a
second cleanup workflow. Every client receives the `cancelled` transition and
may keep the bubble visible as gray/disabled. The dispatcher skips the terminal
item and immediately considers the next queue item.

Because the queue is shared, any authenticated client with access to the same
session may request cancellation of an item it currently sees as queued. The
client does not optimistically mark or remove the item. It may show that the X
request is pending, but the bubble remains queued until the server confirms the
state transition or a shared lifecycle event reports it.

If preparation is still running, cancellation requests that work to stop when
practical. A late STT or encoding result checks the queue state and must not
return the item to `ready`; it may leave an already-created artifact stored.

Cancellation and execution claim are one queue-owner transition. Cancellation
wins only while the item is `preparing` or `ready`. Once it is `running`, the
cancel request is rejected and reports the server's current state; it does not
affect Pi. If cancellation is not confirmed—because it was rejected, the
response was lost, or the request is still racing—the requesting client makes
no queue-state change. It keeps its current projection and waits for the normal
snapshot/follow-stream updates. A shared `cancelled` event may arrive before
the HTTP/WebSocket request response, and either arrival order must produce the
same UI state. The response returns the canonical item ID, sequence, state, and
queue revision. Repeated cancellation of an already-cancelled item returns the
same cancelled state so client retries are harmless.

Stopping `running` work is a separate explicit operation with different UI and
failure semantics. Completed history is not queue cancellation.

Permanent history/artifact deletion, if ever needed, is a separate explicit
feature. It is not part of queue cancellation.

## Recovery

- `preparing`: resume preparation from its durable artifact, or fail explicitly
  if the required artifact cannot be processed.
- `ready`: restore and dispatch in sequence order.
- `running`: mark `interrupted`; do not automatically repeat potentially
  side-effecting tools.
- terminal items: retain their final history and do not requeue.
- client reconnect: observe the current snapshot; it never changes execution
  ownership.

Retry creates an explicit new execution decision. The UI may preserve a link to
the interrupted item, but retry must not pretend exactly-once execution is
possible after an unknown process boundary.

## Storage direction

The initial implementation uses one atomically replaced queue state file per
session with a monotonic revision. It is the only durable owner of queue order
and lifecycle. The queue contains only a few items and does not require a
general database.

Detailed Pi observations and completed readable turn artifacts may remain
separate outputs, but they must be projections or referenced results—not
additional owners of queue order. Queue snapshots and WebSocket/follow events
are derived from the state file and its revision; they are not a second durable
queue journal. Existing Conversation storage continues to own detailed Pi
output, not queue state.

## Existing-session migration

Before the new queue runtime becomes authoritative, one explicit migration
converts every session that the current supported reader can successfully load.
After migration, web, console, resume, queue, and history paths use only the new
canonical representation. The old supported reader and runtime fallbacks are
removed rather than retained beside the new loader.

Historical completed messages become canonical terminal history, not synthetic
queue entries. Each migrated session receives an empty current queue unless it
contains genuinely recoverable pending work; uncertain previously-running work
is recorded as `interrupted`, never silently replayed.

The migration is eager rather than triggered by viewing a session. It is
versioned, idempotent, and stages and validates each converted session before an
atomic publish. Migration failure leaves that source session unchanged and
reports the exact session instead of falling back to its old format. Original
files are preserved for recovery even though normal runtime stops reading them.

Very old filesystem sessions that the current supported reader cannot load are
outside the migration boundary. They remain untouched as retained artifacts and
do not require another compatibility reader.

## Acceptance checks

1. Two browser tabs and one console show the same accepted message order and
   state transitions without duplication.
2. The server stamps time and reserves order immediately when it receives the
   signal generated by a Send press, recognized spoken `submit`, or
   silence-timeout endpoint. An earlier slow final-STT item blocks a later ready
   text or voice item from another client.
3. Reload during `preparing`, `ready`, and `running` preserves identity, order,
   and visible progress.
4. Daemon restart restores `preparing` and `ready` items in order and marks only
   genuinely running work `interrupted`.
5. Confirmed cancellation projects the queued bubble as cancelled for every
   client without affecting the running item; the durable item remains
   cancelled and inspectable while a purely local draft simply disappears. A
   rejected or racing request causes no optimistic state change.
6. Pi missing a steering boundary leaves the message queued and later executes
   it exactly once within the surviving process.
7. TTS or playback failure does not fail, delay, or reorder Conversation.
8. Retrying the same reservation or cancellation request is harmless and does
   not duplicate or revive the item.
9. Lost or hung preparation eventually fails visibly and unblocks the next
   item; it never permits silent overtaking.
10. An untouched new console session has no Model context. The first real Pi
    turn durably emits it before the first user message; resuming restores the
    existing single item without injecting a duplicate. Web shows a tool-styled
    non-cancellable bubble; console prints a non-cancellable message; neither
    produces an audio announcement or TTS.
11. Pi unavailable before execution leaves the item consistently `ready` and
    does not crash Wheatley. Pi loss after a possibly started execution records
    `interrupted`; daemon or app restart reopens consistent session state.
12. Every session loadable by the current supported reader is migrated once and
    then loads through the one canonical web/console/history path. Completed
    history remains terminal history rather than becoming queued work.
13. Re-running migration is harmless. An injected per-session migration failure
    leaves its source unchanged and reports it without runtime fallback.
14. Older unsupported filesystem artifacts remain byte-preserved outside the
    active loader and do not require migration.

## Remaining implementation choices

- exact queue state-file schema;
- migration staging/backup paths and version marker;
- preparation watchdog thresholds and operation-specific progress checks.

These do not change the product contract. UI styling beyond truthful state,
permanent artifact cleanup, and automatic replay of interrupted execution can
be deferred.
