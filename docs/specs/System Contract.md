# System Contract

Status: implemented contract, 2026-08-20.

This document defines Wheatley's target technical contract. It names owners and
boundaries rather than freezing current file names or class shapes.

## Runtime boundary

Wheatley's authoritative runtime is the D server. It owns profile resolution,
conversation admission and execution, session history, presentation order,
speech services, scheduled tasks, artifacts, and coordination between active
clients. Pi is the agent runtime behind a narrow adapter. LM Studio is one
provider reached through Pi; it is not a Wheatley data store or scheduler.

The TypeScript web client and Tauri shell share one UI/runtime implementation.
The D console clients share the same HTTP, SSE, WebSocket, conversation, and
voice contracts. Clients own platform capture/playback and ephemeral UI state;
they do not independently reconstruct server policy.

## Canonical owners

| Concern | Canonical owner | Durable representation |
| --- | --- | --- |
| Profile instructions and settings | Profile runtime | Profile Markdown and JSON |
| Turn admission and lifecycle | `SessionQueue` in Conversation service | Queue state plus turn record and ordered events |
| Model dialogue and tool exchange | Pi adapter | Pi session plus Wheatley observation records |
| Cross-client visible order | Presentation journal | Monotonic session sequence |
| Session summaries and recent activity | History summary index | Rebuildable daemon index derived from history |
| Scheduled-task definition | Scheduled-task repository | Atomic profile-local task document |
| Schedule calculation | Schedule domain | Derived occurrence values |
| Claim, dispatch, and completion | Scheduler service | Claim/run lifecycle records |
| Active-chat coordination | Presence registry | Expiring process-local lease |
| Audio candidate | Voice session coordinator | Live state plus accepted artifacts |
| Generated/uploaded files | Artifact store | Immutable artifact plus metadata reference |

Derived indexes and presence leases are disposable. Profile files, accepted
turns, presentation records, task definitions, and artifacts are durable.

## Profile and generation configuration

Configuration is resolved once for an admitted turn from the shipped defaults,
profile configuration, selected model, and selected reasoning level. The
resolved values are frozen into that turn's execution/inspection context.

Each profile owns one required `workspace.path` setting. Relative paths resolve
from the profile folder; absolute paths allow a profile to use an external
workspace. The instruction API presents that path beside five editable
documents. Its Workspace document is the workspace's fixed `WHEATLEY.md`:
absence reads as empty, blank saves remove the file, and nonblank saves replace
it atomically. A changed path selects the working directory for new Pi sessions;
an existing Pi session continues with the working directory recorded in its Pi
session rather than being silently relocated.

`max_output_tokens` is required after default/profile resolution. The shipped
default is 8,192. Profile configuration may override it globally or for a
specific model. No provider default is used to fill a missing resolved value.

Sampling resolution proceeds from profile sampling defaults, to model values,
to a broad `thinking` or `non_thinking` mode, to an exact model-supported
reasoning-level override. Only explicitly present fields participate; a missing
field remains missing. A representative target shape is:

```json
{
  "generation": {
    "max_output_tokens": 8192,
    "models": {
      "lmstudio/unsloth/qwen3.8-27b": {
        "max_output_tokens": 4096,
        "sampling": {
          "non_thinking": {
            "temperature": 0.7,
            "top_p": 0.8,
            "top_k": 20,
            "presence_penalty": 1.5,
            "repetition_penalty": 1.0
          },
          "thinking": {
            "temperature": 0.6,
            "top_p": 0.95,
            "top_k": 20,
            "presence_penalty": 0.0,
            "repetition_penalty": 1.0
          }
        }
      }
    }
  }
}
```

The configuration vocabulary uses `repetition_penalty`; a provider adapter may
map it to an officially equivalent provider name such as LM Studio's
`repeat_penalty`. Provider adapters declare their supported fields. Startup or
turn admission rejects a configured field that the selected adapter cannot
officially carry.

The current Pi model uses LM Studio's OpenAI-compatible Chat Completions
endpoint. Its documented request supports temperature, `top_p`, `top_k`,
`presence_penalty`, `repeat_penalty`, and `max_tokens`. It does not document
`min_p`; therefore `min_p` is not part of the active LM Studio adapter until
that same supported Pi/tool-calling route exposes it. Wheatley does not switch
to LM Studio's native stateful endpoint merely to gain this field.

Reasoning capability comes from Pi's selected-model metadata, including its
actual supported levels and ordering. Wheatley does not narrow this to the
current `off`/`low`/`medium`/`high` application enum or fabricate levels to make
models look uniform. A binary capability projects as on/off. A multi-level
capability projects only its actual values, with the short labels `Min`, `L`,
`M`, `H`, `XH`, and `Max` where supported. The verified Qwen3.8 27B level set is
exactly `off`, `low`, `medium`, and `xhigh`; its missing `high` level remains a
hole in both validation and presentation.

## Pi and provider context

Wheatley uses Pi's official RPC and extension interfaces:

1. Every profile starts a chat with user-inspectable System and User authored
   sources, and may include its user-inspectable Workspace source through the
   System template: `system.md`, `user.md`, and `<workspace>/WHEATLEY.md`. All
   profiles share the same generic System text;
   System owns the former Agent runtime and tool instructions, while
   profile identity, audience details, preferences, and manually remembered
   context belong to User. There is no separate Agent or `memory.md` source.
2. The profile System document is the effective system-prompt template. It
   controls the exact placement or omission of profile User, profile name,
   workspace folder path, workspace `WHEATLEY.md`, and automatic Memory through
   its five supported placeholders. Wheatley renders these sources once when a
   Pi session starts, freezes the rendered context in that session, and uses
   empty text when the workspace file is absent. Edits affect new sessions, not
   an existing session. Pi's automatic context-file discovery is disabled, so
   no `AGENTS.md` or hidden parent/global context is appended. A removed
   placeholder removes that context, and an empty System stays empty.
   Scheduled-task execution policy lives visibly in System rather than in a
   per-occurrence hidden prompt.
   System and User also support `<default_response_language>`, resolved from the
   active profile language configuration. This and every other editable
   instruction substitution use angle-bracket syntax.
3. A normal current request is the ordinary Pi user prompt. Wheatley does not
   wrap it in `pi-turn-request.md` or prepend the complete runtime context to
   the user text.
4. A scheduled occurrence adds its frozen task/occurrence facts as turn-scoped
   system context and uses the task text as the initiating request.
5. Steering uses Pi's RPC steering behavior in all-at-boundary mode. Generation
   and tool execution are not aborted to deliver a steer. Adjacent admitted user
   messages are kept separate while entering one provider context before the
   next inference. If Pi completes after accepting a steer but before emitting
   that steer's user-message boundary, the completed parent and any already
   delivered steers remain successful. The undelivered accepted turn retains
   its durable claim and executes normally next on a recycled Pi worker.
6. Generation settings are added through Pi's official provider-request hook
   after strict adapter validation.

Pi RPC cannot currently admit an ordered system/user/current-user message
bundle as one prompt action. Pi's extension-injected custom message is appended
after the submitted user message, while its context hook can reorder only the
provider view rather than the durable Pi session. Wheatley therefore keeps
standing `user.md` instructions in the system prompt instead of fabricating a
misordered user turn or patching Pi. The profile files remain separated by
authorship so a future official ordered-context interface can preserve roles
without another content migration.

## Conversation and presentation events

Each session has one server-owned admission queue. Every accepted initiating
action receives a stable session ID, turn ID, origin, durable admission time,
and monotonic admission/presentation sequence. Once admitted, an action never
moves because a scheduler poll was late or because its theoretical
`scheduled_for` precedes another item. Its visible records use stable item IDs
so start/update/end events update one item rather than create duplicates.

An untouched new session has no conversation or model-context presentation
records. The session's single model-context activity item is emitted only by
its first real Pi turn, as that turn's first presentable record. The initiating
record follows it:

- ordinary/voice/steering turn: user message;
- scheduled turn: scheduled-task `will run` item.

Transcript activity previews represent maximal contiguous activity runs, not
whole turns. A user, scheduled-task item, assistant response, or other
non-activity record separates runs even when the surrounding activity shares a
turn ID. Side-panel selection uses the run identity, so selecting Model context
cannot also reveal later reasoning from the same turn and a different preview
cannot close the selected run.

Opening that item shows the exact rendered System-context snapshot frozen for
the first Pi turn. Initiating Pi user messages remain their own chronological
records and are never substituted for the System snapshot. Ordinary later
turns neither re-render the authored files nor add another model-context item.
Because the configured chat-completions provider is stateless, Pi still places
the same frozen system message at the beginning of each provider request; this
is request serialization, not another conversation item. Older sessions that
predate saved snapshots may use their legacy Pi-session context record.

The daemon dispatcher selects only the earliest nonterminal queue item and
executes one item per session at a time. A scheduled occurrence is an ordinary
ordered barrier; later items cannot pass it. The current implementation does
not batch adjacent messages into one Pi inference, so messages admitted after
the current claim wait for the next dispatcher turn.

A scheduled item's stable lifecycle is `will_run` → `running` → `completed` or
`failed`. It is clickable throughout and owns frozen task text, target, schedule,
configured/effective reasoning, due time, admission time, start time, and final
result. Admission claims the occurrence; later disabling the task changes future
discovery only.

Subsequent records may be reasoning start/delta/end, tool start/update/end,
artifact, assistant delta, completion, or failure. Per-turn
order is append-only. Reconnection continues strictly after a cursor. A client
uses one snapshot on open/reconnect and follows the presentation SSE stream;
it does not poll the full session on a timer.

Every live content callback carries its canonical turn ID. Concurrent parent
and steering streams therefore update only their own assistant, reasoning,
tool, and artifact items even when their events interleave in wall-clock time.
A real failure is presented as soon as its terminal event arrives and remains
visible after reload.

SSE carries durable conversation/presentation progress and speech text streams.
WebSocket carries bidirectional low-latency live audio and its control events.
HTTP carries bounded commands, snapshots, artifacts, settings, and task CRUD.
Transport heartbeats preserve quiet long-running streams without manufacturing
conversation events.

An accepted conversation status identifies both the canonical turn and its
client submission/device identity. For a browser live-audio submission, the
originating client maps its provisional bubble to that canonical turn, consumes
activity through its live WebSocket, and excludes the same turn from its
session-wide SSE projection. Acceptance of one candidate releases the capture
loop to start the next candidate; response streaming continues independently
and the queue dispatcher determines when each queued turn starts.

The active-chat presence endpoint remains a narrow lease protocol used for
scheduled voice yielding and target selection. It carries no conversation
history. The client renews a lease only while the relevant chat is open; expiry
is normal cleanup.

## Tool observation

A tool observation has three distinct layers:

1. **Call** — exact tool name and argument object emitted by Pi.
2. **Model result** — exact content parts Pi places back into model context,
   including error state and binary placeholders.
3. **Runtime metadata** — Wheatley timestamps, duration, running/final state,
   and artifact locators.

The first two layers are immutable observation data. Friendly summaries,
localized labels, extracted schedule fields, formatted JSON, and previews are
derived presentation. A formatter failure cannot fail the agent turn; unknown
official argument shapes receive a generic truthful label.

Every tool start is persisted and published before execution, and tool end
completes that same item. The invariant is independent of tool type and applies
to success, validation failure, runtime failure, and reload while running.
Model-visible validation errors identify the exact invalid field and accepted
shape. Tool schemas prefer a small explicit operation over overloaded unions;
the scheduler tools share task references and revision checks consistently.

## History, indexes, and artifacts

Profiles and sessions remain inspectable local files. Atomic writers own
mutable task/config documents. Append-only journals own ordered presentation
and audit history. Schema readers validate at the boundary and return domain
types; UI-specific projections do not become storage schemas.

The daemon maintains a recent-session summary index containing only the fields
needed by Home, hover recents, filters, unseen state, and activity icons. Every
authoritative history/presentation write updates it. Daemon startup can rebuild
it from profile history. Requests do not rescan all turns and tool sidecars.

An artifact record owns an internal stable ID, session/turn provenance, media
type, byte size, checksum, local location, and a safe API locator. Generated
images additionally own a model-visible positive `generated_image_id`, allocated
in session order independently of uploads and screenshots. A branch inherits
IDs visible at its branch point and continues after the inherited maximum. The
generation result exposes the generated-image ID, not the generic artifact ID.
The adapter can list IDs and supply selected image bytes to a later Pi turn; it
does not attach all historical images by default.

## Scheduled-task components

Scheduled tasks are separated into:

- a repository for atomic task/run persistence and revision checks;
- a schedule domain for parsing, validation, recurrence, due/missed occurrence
  calculations, and user-local time semantics;
- a lifecycle service for enable/disable/manual-run/needs-attention transitions;
- a dispatcher for claims, active-chat coordination, Conversation submission,
  and completion recording;
- API and Pi-tool adapters that expose the same application operations;
- client projections for list/editor/trigger presentation.

The dispatcher poll is a simple process-lifetime pull loop. It reports
operational failures durably instead of swallowing them. Manual run is an
occurrence request, not a schedule mutation. Static agent guidance is visible
in each profile's shared System document; each dispatch supplies only frozen
occurrence facts as private context.

Creation owns two server-side resolutions before the initial atomic save:

1. It prepends `This is a scheduled task run:\n\n` to the supplied task text.
   The resulting stored text is thereafter literal, visible, and editable; an
   update never performs prefix policy.
2. If reasoning is omitted, it copies the creating chat's persistent selected
   effort, excluding any one-turn `think` override. An explicit tool argument
   wins.

Every task persists its configured effort. A new-session target pins its model
and validates the exact pair on create/update; a later unavailable pair fails
the occurrence and moves the task to needs attention. An originating-session
target may select the nearest level in the current model's Pi-reported ordering,
preferring higher on a tie. It records configured and effective values without
mutating the task. Scheduled execution passes the effective effort as turn-local
input and never writes the session's persistent user setting.

## Failure and metrics contract

Once a turn is accepted, any terminal failure produces one durable failed event
and a failed turn state. Presentation formatting, optional metrics, and observer
disconnects cannot convert successful model work into a failed turn.

Duration is derived from authoritative lifecycle timestamps. Token and context
metrics come only from Pi/provider usage or provider statistics associated with
the request. Zero or absent provider usage means unavailable, not zero measured
tokens. Rates are shown only when both authoritative token count and the
matching timing interval exist.
