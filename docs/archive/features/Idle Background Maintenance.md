# Idle Background Maintenance

Status: candidate feature design for review, 2026-08-11. This is not yet an
accepted implementation contract.

## Outcome

Wheatley should use quiet time for small model-backed maintenance without
delaying the user's next turn.

After a configurable period with no user activity—initially 15 minutes—the
server may start one maintenance run. When it finishes, the server may start
one more only if the user has remained inactive for the whole interval. The
first two maintenance kinds are:

1. consolidate pending automatic memory in the background; and
2. generate a short, useful title for an untitled chat.

These are separate runs, never one batch prompt or a simultaneous maintenance
fan-out. A user turn may begin while one maintenance run is already executing.
The running maintenance is allowed to finish, but no successor maintenance run
starts until another complete inactivity interval has passed.

## Intended interaction

```text
last user activity
        |
        | 15 minutes
        v
choose one eligible maintenance run
        |
        +---- user remains inactive ----> finish -> choose one more
        |
        +---- user becomes active ------> finish -> stop the chain
                                              |
                                              | 15 minutes from new activity
                                              v
                                         may choose again
```

Example:

- Primary has an untitled completed chat and pending automatic-memory evidence.
- After 15 quiet minutes, Wheatley starts one memory consolidation.
- If it completes while Primary is still idle, Wheatley starts one title run.
- If Primary starts a new chat during the memory run, that memory run continues.
  The title run does not start afterward. The new chat runs normally, possibly
  concurrently with the finishing memory run.
- Fifteen minutes after Primary's latest activity, Wheatley may consider the title
  again.

## Facts

### User-provided facts and intent

- The initial inactivity interval should be configurable, with 15 minutes as
  the starting value.
- Automatic memory should no longer run before a new chat turn/session starts.
- Idle maintenance runs should execute one by one, not as a batch.
- An in-flight maintenance run should finish gracefully if the user returns.
  The return should prevent only the next maintenance run until the user has
  again been inactive for the configured interval.
- LM Studio is configured to permit two concurrent model runs and is expected
  to queue excess API requests. This is supplied operational knowledge; it has
  not been independently load-tested for this design.
- Chat-title behavior needs a new Markdown instruction template editable from
  the web instruction screen.

### Current code-derived facts

- Each accepted nonempty user prompt is appended to profile-owned
  `memory_auto_todo.md` when its turn is created. Automatic memory intentionally
  treats an accepted prompt as evidence even when the assistant response later
  stops or fails.
- Automatic memory is currently planned only during startup of a new,
  non-resumed local session. It can therefore delay session startup before the
  user's turn begins.
- Current memory eligibility uses `memory.auto_trigger_bytes` and
  `memory.auto_max_pending_hours`. The tracked defaults are 8,192 bytes and 24
  hours. The runner contains its own loop and may process more than one prepared
  memory batch in the same startup operation.
- Memory publication is already profile-owned, mutex-protected, inspectable,
  and atomic. A successful run replaces `memory_auto.md`; pending evidence and
  per-run artifacts support recovery.
- Wheatley's `PiRunGate` already limits Pi work. The tracked public default for
  `pi.max_concurrent_runs` is currently **1**, even though the intended LM
  Studio capacity supplied for this feature is **2**. Foreground/background
  overlap will require the effective Wheatley value to be 2; LM Studio's queue
  does not bypass Wheatley's own gate.
- Recent-chat summaries currently expose the first meaningful user text as
  `initial_user_text`; the Home list displays and searches that text. There is
  no generated session title in `session.json` or `SessionMetadata`.
- `InstructionDocuments` currently owns seven editable documents: four
  profile documents and three app-wide private prompt templates. Setup copies
  missing templates without overwriting edits, runtime has no tracked-resource
  fallback, and the UI saves the complete document set atomically.
- `Reliable Background Turns.md` is the proposed next implementation contract,
  not implemented fact. It should establish the server-lifetime execution and
  profile change-stream seams that this feature can reuse.

## Recommended runtime model

### One server-owned idle-maintenance owner

Add one small process-lifetime owner, provisionally `IdleMaintenance`. It owns:

- the last meaningful user-activity time;
- an activity generation that changes whenever user activity is observed;
- the single maintenance lane;
- selection of the next eligible maintenance item; and
- the decision to continue or stop after a run.

The browser must not own the timer. Closing the browser, changing screens, or
using another client must not create a second clock or cancel server
maintenance. The maintenance owner should use a monotonic clock for elapsed
time and ordinary timestamps only for persisted diagnostics.

At server startup, wait one full inactivity interval before starting any
maintenance. Do not immediately drain old work merely because no client is
connected at process start.

### What resets inactivity

The safest initial definition is server-wide meaningful user activity:

- starting or resuming a chat session;
- beginning a valid live voice interaction; or
- submitting an accepted text, image, or live-audio request.

Passive polling, history refreshes, speech playback, tool callbacks, and model
output should not reset the clock. Repeated audio packets should not continually
rewrite global scheduling state; the live interaction's start already marks the
user active.

This definition intentionally treats profile/chat navigation as activity. A
person reading or opening chats should not have a maintenance chain begin under
them merely because they have not yet submitted a prompt.

### One run, then recheck

Before starting a maintenance run, capture the current activity generation.
After the run reaches success or failure:

1. if the generation changed, stop;
2. if the elapsed idle duration is now shorter than the configured interval,
   stop;
3. otherwise derive and start exactly one next eligible run; or
4. stop if no work is eligible.

Do not prepare a list and enqueue it in advance. Eligibility may change while a
run executes, and a returning user must prevent all not-yet-started work.

Failure should be inspectable and should end the current chain. Waiting another
full idle interval before retry avoids a tight loop around a bad prompt, model,
or output. Derived work remains pending, so a generic durable job queue is not
needed:

- missing title means title work remains;
- pending memory evidence means memory work remains.

### Concurrency

The maintenance lane permits at most one maintenance model run at a time.
Foreground conversations remain governed by the existing per-session lanes and
`PiRunGate`.

If the user returns during maintenance:

- do not cancel the maintenance process;
- immediately record new user activity;
- allow the foreground turn to request the other Pi/model slot;
- publish each result through its existing owner; and
- do not begin another maintenance run after the current one.

With an effective `pi.max_concurrent_runs` of 2, this gives the intended common
case: one maintenance run plus one foreground run. More foreground work may
still wait in Wheatley's or LM Studio's existing queue. No priority scheduler is
proposed yet. Real use should decide whether a background run ever causes
noticeable foreground latency.

## Maintenance kind 1: automatic memory

### Behavior change

Remove automatic-memory planning and execution from new-session startup.
Starting or resuming a chat must use the currently published
`memory_auto.md` immediately and must never wait for consolidation.

When idle maintenance selects memory work, it should:

1. select one profile with pending accepted user evidence;
2. atomically capture one bounded evidence snapshot;
3. run one memory consolidation using the existing private memory instruction;
4. atomically publish the new `memory_auto.md` on success; and
5. leave evidence arriving after the snapshot pending for a later run.

A foreground turn that starts while consolidation is in progress uses the
previous complete auto-memory snapshot. It does not wait. Later turns see the
new snapshot after successful publication. This is the principal product
trade-off of moving memory out of the turn path.

### Meaning of “not batched”

Recommended interpretation:

- do not combine title generation and memory into one model request;
- do not combine several profiles into one memory request;
- do not execute an internal loop that drains several memory slices before
  returning control to the idle owner;
- one selected profile evidence snapshot equals one maintenance run.

The snapshot may contain several pending accepted prompts from that profile;
otherwise each user message would rewrite the complete cumulative memory in a
separate expensive call. If the snapshot is too large for the hard input bound,
process one oldest safe slice and leave the remainder pending. The idle owner
may select another memory run only after rechecking inactivity.

This interpretation needs the maintainer's confirmation because “not batches at all”
could instead mean one accepted user prompt per memory call.

### Configuration cleanup

Recommended target configuration:

```json
{
  "maintenance": {
    "idle_seconds": 900
  },
  "memory": {
    "auto_enabled": true,
    "models": ["..."]
  },
  "pi": {
    "max_concurrent_runs": 2
  }
}
```

Remove `memory.auto_trigger_bytes` and `memory.auto_max_pending_hours` from the
current contract if idle time becomes the sole normal trigger. Retain a hard
per-run input bound as an implementation safety limit, not as product scheduling
policy.

## Maintenance kind 2: chat title

### Eligibility and result

A chat is eligible when it:

- has no generated title;
- has at least one meaningful accepted user request;
- has at least one terminal visible conversation turn; and
- has no accepted nonterminal turn when selected.

The title run receives a stable snapshot of the visible conversation: user and
assistant text only, excluding system prompts, memory, tools, reasoning, runtime
messages, and maintenance artifacts. Image-only turns may contribute their
user-visible filename or description when available.

Recommended output contract:

- one line only;
- same language as the chat;
- normally two to six concrete words;
- maximum 80 Unicode characters;
- no surrounding quotes, label, generic “Chat about …”, or terminal punctuation;
- preserve Slovak diacritics.

Invalid output fails the run visibly in diagnostics and leaves the chat
untitled for a later idle retry. Do not silently invent a server-side title by
truncating model output.

### Storage and Home behavior

Store the successful generated title as profile/session metadata, recommended
as `title` in `session.json`. Extend the canonical `SessionMetadata` owner so
every later `session.json` rewrite preserves it. This also lets existing session
sync/export carry the title without a second sidecar owner.

Recent-session summaries should expose both:

- `title`, optional until generation succeeds; and
- `initial_user_text`, retained for search, inspection, and the pre-title
  presentation.

Home displays the generated title when present. Before then it continues to
display the existing initial user text. Search should match both fields. When a
title finishes while Home is open, reuse the profile change stream proposed for
reliable background turns to refresh the row; title publication must not depend
on UI delivery.

Recommended initial rule: generate a title once and keep it stable even if the
chat is continued later. Continuous retitling makes links and recognition less
stable. A future explicit rename/regenerate action can be added if real use
shows the need.

### New editable instruction template

Add one app-wide private template:

```text
$WHEATLEY_HOME/prompts/session-title.md
```

Recommended instruction-editor identity:

| Tab | ID | Scope | Required placeholders |
| --- | --- | --- | --- |
| Chat title | `session_title` | app-wide | `<profile_name>`, `<session_language>`, `<visible_conversation>` |

`InstructionDocuments` should own this as its eighth document. The existing
setup behavior should copy the tracked default only when the private file is
missing. Runtime should read only the private template, validate the exact
placeholder set, and fail fast without a tracked-resource fallback. The editor
should continue saving all editable documents as one validated transaction.

The prompt should define the output rules above and contain only title policy.
Scheduling, storage, retries, and UI behavior belong to server owners, not the
Markdown instruction.

## Work selection

Recommended initial priority:

1. pending automatic memory, because it affects the next answer;
2. the most recently active eligible untitled chat;
3. remaining eligible work one item at a time.

Each selection is derived after the previous run finishes. Do not persist a
precomputed work list. If several profiles are used actively, add simple
oldest-eligible fairness only when real starvation appears; a generic scheduler
is not justified by these two maintenance kinds.

## Visibility and failure

Idle maintenance should be quiet:

- no system bubble, TTS announcement, thinking music, or automatic chat resume;
- title completion appears only as the renamed Recent-chat row;
- memory completion affects subsequent prompt context and the editable Auto
  memory document;
- structured server logs and the existing memory run artifacts remain
  available for inspection.

Title runs should have similarly compact diagnostic artifacts or log fields:
profile, session, instruction/template identity, model, start/end time, terminal
status, and failure message. They must not become normal conversation turns or
pollute Pi chat history.

## Assumptions

- The authoritative Wheatley server stays running long enough to observe the
  idle interval. No OS-level scheduled task or wake-from-sleep promise is part
  of this feature.
- A single server-wide activity clock is preferable initially because current
  use and the two-model capacity make it the safest latency policy.
- Exactly one maintenance run may overlap foreground work; maintenance does not
  need its own LM Studio endpoint or model pool.
- Existing ordered memory-model selection is suitable for both memory and title
  work unless measured quality shows otherwise.
- A generated title is derived metadata, not user-authored conversation and not
  evidence for automatic memory.
- The reliable-background-turn implementation should land first or provide the
  same server-lifetime ownership seam. This feature should not create a second
  background framework beside it.

## Uncertainties and risks

- LM Studio queue behavior under one long maintenance run plus several
  foreground sessions has not been measured. Queueing may be correct but still
  add visible first-token latency.
- The effective private Wheatley `pi.max_concurrent_runs` value was not located
  during this design pass. The tracked default is 1 and conflicts with the
  desired two-run overlap unless private configuration already overrides it.
- Server-wide versus per-profile inactivity changes behavior when primary and
  secondary profiles use different clients simultaneously. Server-wide is safer; per-profile
  gives more background throughput.
- It is not yet decided whether opening/resuming a chat without submitting a
  prompt should count as activity. This proposal recommends that it does.
- Long-running foreground work may leave the human idle for 15 minutes while a
  model is still working. Title eligibility avoids active sessions, but memory
  could still overlap that run. The two-slot model makes this acceptable in the
  proposed contract, subject to real latency evidence.
- Remote Conversation placement and offline-appliance sync currently do not
  share a complete upstream automatic-memory trigger. Initial implementation
  should run maintenance only on the profile-authoritative server; appliance
  integration remains a later exact-placement decision.

## Decisions requested from the maintainer

These are the choices that materially change the contract. Recommended answers
are included so implementation can proceed after a short review.

1. **Inactivity scope — recommend server-wide.** Any user activity in any
   profile resets the one clock. Choose per-profile only if primary and secondary profiles
   should be able to trigger background work independently while the other is
   chatting.
2. **Memory run unit — recommend one profile snapshot containing all bounded
   pending prompts.** Confirm that “not batched” means no mixed/multiple jobs and
   no internal drain loop, rather than one complete memory rewrite per individual
   user prompt.
3. **Title lifetime — recommend generate once.** Keep the first good title
   stable when a chat continues; add explicit rename/regenerate later only if
   wanted.
4. **Activity meaning — recommend session open/resume, live interaction start,
   and accepted submissions.** Confirm whether merely opening/reading a chat
   should postpone maintenance.
5. **Presentation — recommend silent maintenance.** No chat status or speech;
   only update the title row and future memory context.

## Scope now / not now

### In the first implementation slice

- configurable 15-minute server-owned inactivity timer;
- one serialized maintenance lane with generation recheck;
- automatic memory removed from new-session startup;
- one background memory run at a time;
- one title run per eligible chat;
- `session-title.md` as the eighth editable instruction document;
- canonical persisted session title and Recent-chat display/search support;
- focused scheduling, overlap, persistence, restart, and validation checks.

### Explicitly not now

- a generic job database, worker farm, cron service, or precomputed batch queue;
- cancelling a healthy maintenance run when the user returns;
- foreground-priority preemption inside LM Studio;
- manual title editing, title history, automatic retitling, or title suggestions;
- UI progress for invisible maintenance;
- cross-process continuation after server death;
- appliance/offline maintenance ownership beyond the authoritative server;
- a new model registry solely for chat titles.

## Acceptance scenarios

1. A new chat starts immediately even with pending auto-memory evidence; no
   memory LLM call occurs in startup.
2. After 15 configured quiet minutes, exactly one eligible maintenance run
   starts.
3. With several eligible titles, only one title model run exists at a time.
   The next starts only after the previous terminal result and an idle recheck.
4. User activity during a title or memory run does not cancel it. A foreground
   turn can execute concurrently when the effective Pi/model limit is 2.
5. After that user activity, no successor maintenance run starts until another
   full 15-minute idle interval passes.
6. A foreground turn arriving during memory consolidation uses the previous
   complete `memory_auto.md`; publication is atomic and later turns use the new
   version.
7. A title run publishes one validated title without changing conversation
   turns or Pi history. Reload, restart, and sync preserve it.
8. A failed maintenance run leaves its source work pending, records the failure,
   and does not retry in a tight loop.
9. Instruction editing loads and atomically saves all eight documents; deleting
   or corrupting required placeholders in `session-title.md` fails visibly.
10. Tracked defaults and active configuration agree on the intended idle period
    and two-run concurrency before claiming foreground/background overlap.
