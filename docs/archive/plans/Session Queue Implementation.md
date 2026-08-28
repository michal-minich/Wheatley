# Session Queue Implementation

Status: implemented, independently audited, and corrected for the non-live
cutover scope, 2026-08-21. The audit repaired endpoint ordering, remote queue
ownership, cancellation/history reconciliation, terminal projection and
compaction, historical migration, frozen policy checks, and client sequence
projection. The old history reader remains the conversion oracle; official Pi
context prefill is unavailable in the bundled adapter. Controlled final reader
cutover, exhaustive deterministic races, staged-voice preparation resume, and
physical voice remain follow-up gates. Evidence is in
[Session Queue Verification](Session%20Queue%20Verification.md).

This plan turns the approved
[Session Message Queue](../../design/Session%20Message%20Queue.md) design into an
ordered engineering pass. The design owns queue semantics. The existing
[System Contract](../../specs/System%20Contract.md) and
[Product Behavior](../../specs/Product%20Behavior.md) continue to own unaffected
behavior, but their older admission and Model-context wording must be updated
after the implementation is proven.

## Mission

Replace process-local message ordering with one small, durable, server-owned
queue per session. A message receives its immutable position when the server
receives the user's submission signal, before slow final STT or other
preparation. Every client observes that same identity, position, and lifecycle;
at most one item executes in a session; restart restores safe queued work.

Keep STT, Pi execution, TTS/playback, and presentation as separate concerns.
This is not a general job system, database project, Pi rewrite, or broad UI
redesign.

## Working rules

Before changing code, Luna must read the project `AGENTS.md`, Coding Guide,
the approved queue design, both active contracts, this plan, and current agent
status. Current code decides exact seams and names; the approved design decides
observable behavior.

- Keep one canonical path. Do not leave a legacy queue, alternate loader,
  request-owned execution path, or client-owned accepted outbox beside the new
  path.
- Prefer direct domain modules and explicit state transitions over a framework,
  actor system, generic event bus, or pluggable storage abstraction.
- Preserve unrelated worktree changes. Do not stage or commit.
- Work in review-sized vertical slices. End every slice with focused tests,
  full builds relevant to the touched boundary, and a cumulative diff review.
- Use isolated temporary profile/session roots for migration and destructive
  recovery tests. Do not migrate real user profiles or deploy a new daemon
  reader before the primary agent's independent review.
- If inspection reveals a material conflict with an invariant below, stop and
  document the conflict. Exact type names, routes, JSON layout, and helper
  placement are Luna-level decisions and need not be escalated.

## Non-negotiable invariants

1. The D server is the only owner of accepted message order and lifecycle.
2. The submission boundary is server receipt of the reservation produced by
   text Send, recognized spoken `submit`, or silence/no-new-speech timeout when
   the end chime starts.
3. In one durable transition, the server stamps `submitted_at`, assigns a
   monotonic immutable session sequence, and records the stable item ID.
4. Final STT, audio encoding, image preparation, Pi availability, and client
   latency cannot change that sequence.
5. An earlier nonterminal item blocks every later item. In particular, a later
   `ready` item cannot pass an earlier `preparing` item.
6. At most one item is `running` per session. Different sessions may progress
   concurrently subject to existing global model-capacity limits.
7. Reservation, preparation completion, and cancellation are idempotent by
   stable item ID. Retrying cannot duplicate, reorder, revive, or overwrite an
   item with different content.
8. Only `preparing` and `ready` may be queue-cancelled. Cancellation is an
   atomic durable server transition; clients never apply it optimistically.
   Running stop remains a separate operation.
9. Pi unavailable before a safe execution claim leaves the item `ready`. Loss
   after execution may have begun records `interrupted`; it never automatically
   replays uncertain side effects.
10. A crash never requires reconstructing queue intent from partial turn,
    presentation, Pi, or client files.
11. Model context is a single first-Pi-turn record, not a queue item. An
    untouched session has no context presentation; the first real turn freezes
    and publishes it before that turn's user item, and it remains audio-silent.
12. The presentation journal and per-turn Conversation journals are observable
    projections/details. Neither is a second owner of queue order or state.
13. Every session supported by the current reader is explicitly migrated before
    the new runtime reads it. The finished runtime has one canonical reader and
    no compatibility fallback.

## Target ownership

Names in this table are recommendations. Luna may use simpler names that fit
the current package layout, but each concern must have exactly one owner.

| Concern | Recommended owner | Durable fact or output |
| --- | --- | --- |
| Item identity, order, and lifecycle | `SessionQueue` domain aggregate | One atomic queue state file with revision |
| Atomic load/change/save and locking | Queue store | Validated schema plus atomic replace |
| Earliest eligible claim and terminal advance | Queue dispatcher | Queue transitions only |
| Text/voice/scheduled admission | Small queue command API | Idempotent reservation/preparation commands |
| Final STT and artifact preparation | Existing voice/preparation services | Artifact references and `prepared` or failure command |
| Pi execution and detailed output | Existing Pi/Conversation runtime | Conversation journal and result references |
| Cross-client rendering/reconnect | Presentation projection | Snapshot plus ordered follow events |
| First Pi execution and Model context | Pi/Conversation runtime | One durable first-turn presentation record |
| Local unsubmitted draft | Originating client only | Ephemeral UI/capture state |

Prefer one stable identifier for queue item, accepted turn, presentation user
bubble, and client retry key. If an existing storage constraint requires two
identifiers, their one-to-one mapping must be durable at reservation time and
must never be inferred later.

## Initial code map to verify

This is a discovery map, not a required final file layout.

| Current area | Current role | Intended direction |
| --- | --- | --- |
| `conversation/runtime.d` | Accepts turns, emits acceptance, waits process-local lanes, claims, steers, and runs Pi | Reduce to queue commands plus execution of a durably claimed item |
| `turns/text/session_work_lanes.d` | Per-session mutexes and scheduled admission barriers | Remove as ordering authorities; retain only a narrowly named process exclusion if the Pi adapter truly needs one |
| `conversation/preparation.d` | Process-local preparation gate | Keep durable message preparation separate from Pi execution |
| `history/store/package.d` | Pending/running turn records, claims, recovery, Conversation and presentation writes | Keep detailed turn output; stop owning queue order/lifecycle |
| `presentation/store.d` | Durable ordered client projection and reconnect cursor | Project queue lifecycle and content without becoming queue authority |
| `conversation/pi_agent_runtime.d` | Builds context and emits Model context during first run | Retain first-turn ownership and exact Pi ordering |
| `turns/text/pi_prompt_prewarm.d` | Fake prompt-based cache warm-up | Delete the unsupported fake READY/prefill path |
| `startup/profile_startup.d` and voice startup | Resolve session and begin listening | Leave conversation presentation empty until a real turn |
| `voice/runtime.d` | Detects endpoint, runs final STT, saves accepted input, then enters Conversation | Reserve durably at endpoint/submit before final STT; complete preparation later |
| Browser `ChatSession`/`ChatTranscript`/message view | Uses local pending flags, ID replacement, and queued-tail reorder rules | Render explicit server item sequence/state; retain only unreserved local drafts |
| Console conversation observer/outbox | Observes shared presentation but also persists accepted submissions client-side | Observe server lifecycle; remove accepted-work ownership and keep Model context text-only |
| Scheduler dispatch | Uses a separate process-local admission barrier | Admit an ordinary `scheduled` queue item that acts as a normal barrier |

Inspect local/remote Conversation placement before choosing the dispatcher
boundary. The daemon that owns session history and admission must own the one
queue. A remote Pi or remote execution adapter may transport execution, but it
must not create a replicated or competing queue. Fail fast and record the issue
if the current remote boundary cannot preserve that ownership cleanly.

## Minimum persisted model

The exact JSON shape is Luna's decision. Keep it intentionally small. The queue
file needs a schema version, monotonic revision, next sequence, and ordered
items. An item needs enough durable information to decide every transition
without consulting request tasks or client memory:

```text
id
session_id
sequence
kind                     user | scheduled
source                   text | voice | console | scheduled | ...
client/device identity   where already part of admission identity
submitted_at             authoritative server timestamp
state                    preparing | ready | running | completed |
                         failed | cancelled | interrupted
text                     optional while preparing
artifact references      optional, immutable artifacts may outlive cancellation
frozen execution policy  model, base reasoning, language, scheduled provenance;
                         final prompt preparation may derive the turn-local
                         leading-`think` reasoning override
execution identity       only after a safe claim
failure/result reference terminal detail without duplicating journals
preparation progress     only what recovery/watchdog actually needs
```

The queue file is atomically replaced under one per-session writer exclusion.
Use an existing proven atomic JSON helper if it satisfies validation and crash
semantics. A queue mutation validates the previous revision and legal state
transition, writes a complete next state to a staged file, durably publishes
it, and only then emits projections or starts external work.

Do not store the whole Pi event stream or rendered transcript in the queue.
Store references to outputs already canonically owned elsewhere. Do not add a
second durable lifecycle journal unless inspection proves atomic snapshots
cannot meet the approved design; that would be a material architecture change.

## Legal state transitions

```text
preparing -> ready -> running -> completed
    |          |         |----> failed
    |          |--------> cancelled
    |-------------------> failed
running --uncertain process loss--> interrupted
```

- A direct text or already-final input may be reserved directly as `ready` in
  the same atomic admission.
- Voice is normally reserved `preparing`; final STT/encoding conditionally
  changes that same item to `ready` only if it is still `preparing`.
- A late preparation result after cancellation may store an immutable artifact
  but cannot revive the item.
- Claim and cancellation must serialize through the same queue mutation. If
  claim wins, cancellation returns canonical `running`; if cancellation wins,
  execution never starts.
- A terminal transition is irreversible. The active queue file may compact a
  terminal prefix only after canonical turn/presentation history durably owns
  the same ID, sequence, and final state; that is a one-way terminal handoff,
  not another active lifecycle owner. Cancelled items remain inspectable, and
  queue cancellation never deletes history or artifacts.

## Ordered implementation

### Slice 0 — baseline and discovery record

Trace text, accepted audio, live voice, console, scheduled, local/remote, new
session, resume, reconnect, and restart paths from transport through storage and
Pi. Record the current admission point, durable writes, process locks, client
projections, and error ownership for each path.

Before changing the supported reader, inventory every currently loadable
session in an isolated copy and capture a semantic baseline: profile/session
IDs, visible item order and IDs, terminal states, Model-context count, artifact
references/hashes, Pi-session reference, and the normal web/console history
views. Preserve a few representative fixture sessions, including completed,
failed, pending/running, scheduled, voice/artifact, branch, and older supported
layouts.

Gate: a short implementation note identifies the final proposed modules, the
authoritative daemon in local and remote placement, the chosen queue schema,
and any design conflict. No production behavior should change in this slice.

### Slice 1 — queue domain and atomic store

Implement queue types, validation, legal transitions, monotonic sequence and
revision, stable-ID idempotency, and one atomic per-session store. Make command
results return the canonical item and revision so APIs never construct state
from request-local assumptions.

Cover reserve, prepare, claim, complete, fail, cancel, interrupt-on-recovery,
and snapshot. Reject reuse of an ID with conflicting immutable admission data.
Keep policy-free filesystem mechanics separate from the small transition
domain, but do not introduce interfaces that have only one speculative use.

Gate: focused unit tests prove transition legality, idempotency, atomic failure,
sequence immutability, revision monotonicity, and one-running-item validation.
No request path should depend on the new store yet.

### Slice 2 — migration tool and canonical session reader

Build the explicit, versioned migrator while the old supported reader is still
available as the conversion oracle. The tool must support discovery/dry-run,
per-session staging, validation, atomic publish, exact failure reporting, and a
harmless second run.

Convert every layout the current reader successfully loads into the one new
canonical representation. Completed and failed history remains terminal
history, not fake queue work. Genuine pending work becomes `preparing` or
`ready` only when durable inputs make recovery unambiguous; uncertain running
work becomes `interrupted`. Preserve original session bytes in a documented
recovery location, but do not make runtime read them. Leave very old sessions
that the current reader cannot load untouched and outside discovery results.

At this stage, prove the tool on fixtures and an isolated copy of the real
session root. Do not migrate live data and do not deploy the new reader. Delay
deleting the conversion-only old reader until the final cutover slice.

Gate: semantic before/after comparison passes; an injected conversion failure
leaves the source and published target unchanged; a second run produces no
semantic or byte changes to canonical state.

### Slice 3 — first-turn Model context

Leave new and resumed sessions presentation-empty until real work begins. The
first Pi execution freezes the rendered system context and emits the single
Model-context record as part of that turn, before its initiating presentation
item. The old prompt-prewarm and bootstrap-marker paths are deleted because the
bundled Pi adapter has no official context-prefill RPC.

Model context has no queue sequence or cancellation action and remains silent.
Gate: a fresh session has no Model context, while the first turn proves exactly
one context record, correct live/restored ordering, and zero TTS/audio commands.

### Slice 4 — admission and preparation producers

Route every initiating path through the queue command boundary:

- text: one atomic reserve-as-ready command when Send reaches the server;
- live/automatic voice: reserve-as-preparing at endpoint timeout when the end
  chime starts, before final STT is queued or invoked;
- recognized spoken `submit`: reserve-as-preparing when the command closes the
  chunk, before final STT;
- already-final recorded input: reserve at its client/server submit boundary,
  then prepare without changing order;
- scheduled occurrence: reserve one `scheduled` item at durable admission;
- images or other required input: freeze policy and durable artifact references
  before declaring the item `ready`.

Persist enough captured audio or preparation source immediately after
reservation that crash recovery can retry preparation. If there is a narrow
unavoidable gap between reserving and durable source capture, recovery must
fail that item visibly; it may not remove it or allow silent overtaking.

Transport acknowledgement means durable reservation, not Pi start. Retried
submission IDs attach to the existing item. Client disconnect after
acknowledgement has no effect on preparation or execution.

Gate: controlled slow-STT tests show an earlier voice reservation blocking a
later ready text message from another client. Every producer passes the same
stable identity into queue, turn storage, presentation, and result paths.

### Slice 5 — dispatcher and Pi execution

Add one dispatcher over the durable queue owner. It inspects the earliest
nonterminal item only. `preparing` blocks; a terminal item is skipped; `ready`
waits for Pi availability, then is durably claimed
`running` immediately before the external execution boundary.

Keep global Pi/model capacity separate from per-session ordering. Sessions may
run concurrently; one session may not. Prefer simple sequential dispatch for
the first implementation. Adjacent-user steering/batching may remain only if
the current official Pi boundary can preserve one `running` item, truthful
non-cancellable state after delivery, stable identity, and all queue ordering
without adding another lifecycle state. Otherwise remove that optimization;
the approved design permits but does not require batching. A missed steering
boundary leaves the item eligible for normal next execution.

Refactor existing Conversation execution to consume a claimed queue item and
write detailed events/results back through queue terminal commands. Remove
process-local submission lanes, scheduled admission barriers, and request-task
waiters as ordering mechanisms. Retain a local Pi-worker exclusion only if its
role is explicit and queue-independent.

Before claim, an unavailable Pi leaves the item `ready` and returns process-safe
health information. After a possibly accepted external call, connection loss
ends as `interrupted`, not ready/failed/replayed. A server exception must not
terminate the daemon or leave the queue file between states.

The daemon dispatcher now owns the earliest-ready claim, performs a Pi launch
preflight before changing `ready` to `running`, retries ready work from its
watchdog when Pi is temporarily unavailable, and marks post-process-start
failures as `interrupted`. The original steering/admission execution barrier
is no longer an ordering authority. A complete deterministic fake-Pi race
matrix remains a verification gate.

### Slice 6 — projection, snapshot/follow, and cancellation API

Expose queue lifecycle in the session snapshot and ordered follow stream using
stable item ID, session sequence, state, and queue revision. Decide whether to
extend the current session-turn representation or add a narrow queue snapshot;
do not make clients merge two independently ordered authorities.

Project `admitted`, `prepared`, `started`, `completed`, `failed`, `cancelled`,
and `interrupted` only after their queue transition is durable. Preserve the
existing presentation cursor contract for detailed Pi output. Define one
snapshot/follow handoff that cannot miss a transition or duplicate a bubble
when a client reconnects during a mutation.

Add a narrow cancellation command for `preparing`/`ready`. The response always
contains canonical item ID, sequence, state, and queue revision. Cancellation
of `running` is rejected as a state conflict without invoking stop. Repeated
cancellation of `cancelled` returns the same state. Response/event arrival in
either order reduces to the same client projection.

Gate: API integration tests cover reconnect races, repeated reservation and
cancellation, cancellation/claim race in both orders, response loss, observer
disconnect, and exact snapshot/follow convergence.

### Slice 7 — web client projection

Replace `pending` inference and queued-tail movement rules with explicit server
sequence/state reduction. Keep a local provisional bubble only until durable
reservation acknowledgement; then map it once to the canonical stable item and
let the shared projection own it. Delete reorder and duplicate-suppression rules
that exist only because accepted order was implicit.

Render `preparing` and `ready` user items semi-transparent/gray in session
sequence. Offer X only for those two states. While a cancellation request is in
flight, show a local request affordance without changing canonical state. On
confirmed/shared `cancelled`, keep the bubble gray/disabled; on `running`
rejection, leave normal lifecycle rendering alone.

Model context remains a tool-styled, non-cancellable, audio-silent first-turn
prefix.
Running stop remains the existing separate affordance. Do not add permanent
artifact deletion.

Gate: reducer tests or a deterministic browser harness prove event-before-
response, response-before-event, reload, two-tab cancellation, originating-tab
ID reconciliation, and no duplicated or reordered bubbles.

### Slice 8 — console client projection

Make the console observer consume the same server item identity, sequence, and
state. Its append-only UI may print truthful queued/cancelled/started lines; it
does not need an in-place TUI recolor/move implementation in this pass.

Remove accepted-work ownership from console outbox/submission persistence once
the server has durably acknowledged an item. A pre-ack local retry may exist
only if it is clearly ephemeral/idempotent and cannot execute independently.
Closing the console never cancels accepted work.

Do not print Model context for an untouched new session. Print it exactly once
when the first real turn emits it, and restore it without duplication on
resume. Prove that no console speech, synthesis, or playback path receives it.

The console no longer persists or replays accepted work in a durable outbox.
It uses a process-local live-submission suppression set only to avoid duplicate
printing while its own API stream and shared observer overlap; a restarted
console observes the server-owned work normally. Model context is read
from the first turn in the shared presentation snapshot and printed once
without audio.

Gate: console/API tests must still show the same order and terminal states as
two browser clients, clean exit during queued/running work, and correct
new/resume context output without audio.

### Slice 9 — recovery, watchdog, and final migration cutover

On daemon startup, validate every canonical queue before dispatch:

- `preparing`: resume from durable source or fail explicitly if recovery is
  impossible. The current implementation takes the explicit-failure branch;
  staged-Opus final-STT resume remains a later recovery enhancement;
- `ready`: restore and dispatch in sequence;
- `running`: atomically mark `interrupted`, never replay automatically;
- terminal: retain, present, and never requeue.

The voice producer now publishes an operation-specific final-STT deadline and
progress timestamps. The daemon watchdog expires only preparing items with an
explicit producer deadline, fails the associated pending turn, publishes a
queue lifecycle projection, and wakes the next item. Legitimately slow work
without an expired producer deadline remains ordered. Broader forced-loss
coverage and the final reader cutover remain open.

After all isolated tests pass, finish the canonical reader and migration
cutover code: new runtime reads only canonical state, old compatibility
branches are removed from runtime, and absence or invalid canonical data fails
with the exact session rather than falling back. The standalone explicit
migrator may retain conversion-only parsing until controlled live migration;
no web, console, resume, history, or daemon runtime path may call it. Luna still
does not migrate the live profile root or deploy the new daemon.

Gate: forced termination at every transition reopens a valid queue; no
preparing/ready item is silently lost; only uncertain running becomes
interrupted; source-session clone migration and canonical-only loading pass.

### Slice 10 — deletion, contracts, and handoff

Delete superseded lanes, barriers, pending-turn startup failure, fake prewarm,
accepted client outboxes, runtime legacy loaders, client reorder heuristics,
and stale tests/resources after their replacements are green. The fake
prewarm module and accepted console outbox are now removed; the remaining
process-local lanes are limited to short admission exclusion/maintenance
work, and the conversion-only history reader remains until controlled cutover.
Search by old type names, state strings, API paths, and fallback comments; do
not rely only on compilation to find dead policy.

Update the active System and Product contracts to name `SessionQueue` as the
canonical admission/lifecycle owner, the exact submission boundary, the new
state machine, cancellation semantics, recovery, migration boundary, and
first-turn Model context. Change the queue design status from candidate
to implemented only after evidence is complete. Record verification chronology
and migration reports in agent status rather than bloating the contracts.

Gate: full checks pass from a clean process start, the cumulative diff contains
one path for every responsibility, and the handoff package below is complete.

## Automated verification matrix

### Queue/domain tests

- monotonic immutable sequence and revision under concurrent reservations;
- same-ID reservation retry returns the same item;
- same ID with conflicting immutable data is rejected;
- slow `preparing` item blocks later `ready` items;
- one running item per session, with independent sessions able to progress;
- every legal and illegal state transition;
- claim/cancel race in both orders and idempotent repeated cancellation;
- late preparation after cancellation cannot revive the item;
- scheduled item remains an ordinary barrier;
- missed Pi steering boundary leaves the item next, not failed or reordered;
- durable store failure never publishes an event or begins external work.

### Recovery tests

Force process loss after reservation, artifact persistence, preparation,
ready transition, claim write, external-call boundary, each terminal write, and
projection emission. Assert canonical restart state, identity, order, revision,
and absence of automatic replay for uncertain running work. Include corrupt or
incomplete staged files; the canonical file must stay valid and errors must be
exact rather than silently recovered through another reader.

### Migration tests

For every supported fixture and the isolated real-session copy, compare the old
reader baseline with the canonical result:

- session/profile/turn identities and chronological visible order;
- completed/failed/interrupted meaning and absence of synthetic queued work;
- exactly one Model-context record where supported;
- Pi-session and branch references;
- scheduled occurrence provenance;
- artifact counts, locators, sizes, and hashes;
- browser/console history JSON used by normal loading.

Run migration twice. Inject a per-session conversion/validation/publish failure
and prove unchanged source plus no partial canonical publish. Prove that
currently unsupported ancient directories remain byte-preserved and invisible
to the canonical runtime.

### Deterministic API and multi-client end to end

Use an isolated temporary profile root, the existing fake Pi RPC probe extended
only as needed, and a controllable fake final-STT boundary. Exercise two browser
clients and one console observer on the same session:

1. Start a voice message, trigger endpoint reservation, hold final STT, then
   send `ok` from the other browser. All clients must show voice sequence N as
   `preparing` and text N+1 as `ready`; Pi receives neither N+1 first.
2. Release final STT. Pi receives N and only then N+1, while every client keeps
   stable bubble identity and identical order through completion.
3. Queue two later messages, cancel one from the non-originating browser, and
   deliver the shared event before the HTTP response in one run and after it in
   another. All clients converge; Pi never receives the cancelled item; the
   following item progresses.
4. Race cancellation with claim. Assert either durable cancelled/no Pi call or
   durable running/rejected cancel, never both and never optimistic deletion.
5. Disconnect the originating client immediately after durable reservation.
   Other clients observe normal preparation/execution; reconnect produces no
   duplicate.
6. Kill/restart the daemon once with an item `preparing`, once `ready`, and once
   just after the external Pi boundary. Assert restore/restore/interrupted.
7. Insert a scheduled occurrence between user items. It remains in admission
   order and prevents adjacent-user batching across the barrier.
8. Create a new session while dictating. Console output begins with `Model
   context`, then `listening...`, then the user message; web shows one tool-style
   fixed prefix. Resume twice and assert no duplicate and no audio request.
9. Make Pi unavailable before claim, restart or restore it, and show that the
   app stays alive and the same `ready` item later executes. Drop Pi after the
   external boundary and assert `interrupted` without automatic retry.

Capture server queue snapshots/revisions, presentation cursors, client-visible
IDs/states, fake-Pi received messages, and process exit codes. Assertions must
check these facts directly; screenshots alone are insufficient.

### Real-stack confidence pass

After deterministic tests are green, use a disposable Tooltest profile and the
normal real Pi/Whisper stack for one text, one voice, one cancellation-before-
run, one reconnect, and one daemon restart scenario. Do not use personal active
sessions. A real pass proves integration, not exact crash timing; deterministic
fakes remain the authority for races.

The primary automated commands should include, adjusted only for actual project
scripts discovered by Luna:

```text
cd server/wheatleyd && dub test
cd server/wheatleyd && dub build --config=debug
cd server/wheatleyd && dub build --config=console
cd client && npm run lint
cd client && npm run typecheck
cd client && npm run build
```

Add one documented command for migration dry-run/validation and one for the
multi-client queue probe. Retain a new probe only if it is deterministic and
useful after the refactor; otherwise keep it as temporary verification and
remove it before handoff.

Physical microphone timing, audible chime/music/TTS interaction, and speaker or
headset quality remain maintainer checks. Automated evidence can prove audio command
absence for Model context and event timing, not physical acoustics.

## Luna handoff package

Leave the worktree uncommitted and provide the primary agent:

1. a concise ownership map naming the final queue, dispatcher, first-turn
   context,
   projection, and migration modules;
2. a requirement-to-file/test matrix for all thirteen invariants;
3. one redacted representative queue-state example and its schema/version;
4. migration dry-run and isolated-clone reports with counts, hashes, failures,
   preserved-original location, and exact commands;
5. deterministic E2E logs containing queue revisions, Pi receive order, all
   three client projections, restart results, and process exit codes;
6. full D/client build and test output summary;
7. a deletion inventory for old lanes, barriers, fallbacks, client ownership,
   and reorder rules;
8. any capability limit, especially real Pi prefill or remote placement, with
   the smallest chosen behavior and no hidden workaround;
9. the exact remaining maintainer physical checks;
10. confirmation that live profiles were not migrated and the deployed daemon
    was not replaced.

## Primary-agent independent verification

The primary agent will not treat Luna's green summary as proof. Verification
will:

1. review the cumulative diff against the approved design and all invariants;
2. search for competing admission owners, legacy readers/fallbacks, process-
   local ordering, client accepted outboxes, and queued-tail reorder rules;
3. inspect every external-work boundary for durable-before-side-effect order;
4. rerun focused race/recovery tests and the full D/client checks;
5. independently migrate a fresh isolated copy and compare semantic/hash
   reports;
6. rerun the slow-STT/two-browser/console scenario and one claim/cancel race;
7. check Model-context new/resume order and assert no speech/audio command;
8. review final contracts and status for claims stronger than evidence;
9. only then plan the controlled idle live-data migration, backup verification,
   daemon cutover, and post-cutover smoke test.

## Decisions left to Luna

Luna should choose and justify these during discovery without waiting for
approval unless they change an invariant:

- exact module, type, route, and event names;
- compact queue JSON schema and schema/version marker;
- reuse or replacement of existing atomic JSON/locking helpers;
- precise snapshot/follow integration with the presentation cursor;
- migration staging and preserved-original directory layout;
- operation-specific preparation progress markers and watchdog thresholds;
- deterministic fake-STT control mechanism;
- handling of Pi's lack of an official prefill mechanism;
- exact append-only console wording for queued/cancelled/interrupted states.

The following are not Luna-level choices: submission timing, server timestamp
and sequence authority, blocking order, one running item, cancellation states,
no optimistic client cancellation, no fallback reader, no automatic replay of
uncertain work, Model-context position/audio silence, or live-data cutover
before independent verification.

## Explicit non-goals

- a generic persistent job queue, SQL database, message broker, or event-sourced
  queue journal;
- more than one queue owner or more than one Pi execution in a session;
- exactly-once claims across an uncertain external Pi/tool boundary;
- automatic retry of `interrupted` work;
- permanent message/artifact deletion;
- running-turn cancellation redesign;
- TTS, music, playback, or STT quality refactor beyond queue integration;
- a console TUI capable of recoloring or moving old lines;
- new parsers for ancient sessions the current reader cannot load;
- unrelated continuous-listening, navigation, scheduling, or visual redesign.

## Completion condition

Implementation is ready for independent review when every producer uses the
one durable queue, every observer renders its canonical lifecycle, the new
runtime has one canonical loader, isolated migration and failure injection are
green, deterministic multi-client/restart scenarios pass, obsolete ownership
paths are deleted, and the Luna handoff package is complete. It is not yet
approved for live migration or deployment until the primary verification pass
finishes.
