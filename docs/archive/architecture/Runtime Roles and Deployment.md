# Runtime Roles and Deployment

Status: accepted direction and active implementation, 2026-08-05. The
synchronized-session foundation, active Profile Runtime replica
boundary, unified semantic Conversation event stream, and in-process
Conversation/Agent Runtime ownership boundary are implemented. The server-side
durable submission, execution fence, and event replay prerequisite is also
implemented. Default launches now select and validate an explicit
`standalone_local` or `synced_hybrid` composition. A durable console-text
submission outbox, active versioned profile replica, bounded appliance
retention, explicit Conversation placement seam, accepted-audio artifact
identity, browser/console playback acknowledgements, the exact remote-turn
Profile synchronization gate, the remote Conversation HTTP adapter, and the
browser/Tauri and console accepted-voice recovery outboxes are implemented.
Pre-acceptance input gating and physical device gates remain.

This document owns Wheatley's proposed runtime roles, capability placement,
deployment profiles, transport choices, data-use implications, and evolution
order. [Architecture](Architecture.md) remains the source of truth for what
was implemented at the time; [Architecture Diagrams](Architecture%20Diagrams.md)
provides several structural and sequence views. This document supersedes
[Client Unification and Placement](Client%20Unification%20and%20Placement.md) as
the forward structural plan; that document remains useful as the first code
coupling audit and source map.

## Recommendation

Build **logical components with explicit owners**, not a set of microservices.
Keep one modular D runtime as the default composition on macOS, Linux,
Raspberry Pi-class, and N150-class machines. Use direct typed calls when two
components share a process, and add a network adapter only where an actual
device or process boundary requires one.

Do not make one D binary the contract for every target. Browser, Tauri iOS, and
the 32-bit 512 MB Luckfox Lyra Zero W cannot sensibly host the current D +
Node/Pi + subprocess stack. They need a smaller device runtime with selected
local capabilities. A thin Tauri client that calls the same API as the browser
is a valid long-term deployment, not merely a temporary compromise. Tauri
macOS may optionally package the full runtime as a sidecar later. Tauri iOS
should initially remain thin, with local audio IO and media caching but remote
Whisper, the configured Wheatley voice, Pi, and LLM.

The main roles are:

1. **Profile Runtime** — the sole owner of profiles, resolved configuration,
   sessions, memory, history, and durable artifacts.
2. **Conversation Runtime** — accepted messages in; ordered agent, reasoning,
   tool, token, artifact, completion, and error events out. The current Pi
   worker is its first agent adapter.
3. **Voice Runtime** — the voice-session coordinator and Listener: capture
   lifecycle, VAD, endpointing, drafts, final STT selection, retry, calibration,
   and spoken-stop/barge-in policy.
4. **Audio Runtime** — the one device-local owner of narration and audible
   output: chimes, music, speech, tool announcements, priorities, ducking,
   cancellation, route recovery, and interruption. Speech synthesis is a
   placeable capability beneath it, not the same thing as playback.
5. **Device Shell** — browser, Tauri, terminal, or headless controls and
   presentation. It reports capabilities and adapts platform IO; it does not
   own durable product state or reimplement turn policy.

### Simplicity constraints

The roles above are a map of responsibility, not a demand for five services,
five base classes, or a dependency-injection framework. Prefer the smallest
shape that makes ownership visible:

- keep one obvious composition root for the normal D runtime;
- call colocated modules directly with typed values;
- introduce an interface when it isolates a real responsibility or supports a
  second implementation, not merely to wrap another call;
- keep classes and modules cohesive and small enough to understand in one
  sitting, splitting orchestration, policy, storage, and platform IO instead of
  collecting them in another large coordinator;
- share domain commands/events, with thin HTTP/SSE/WebSocket codecs around
  them; do not create parallel transport-specific business logic;
- prefer explicit configuration and a few named deployment compositions over
  discovery, plugin registries, or a generic capability mesh;
- require each extraction to remove duplicated ownership or make a measured
  placement possible. A new forwarding layer alone is not progress.

The first complete offline reference should be an x86-64 N150-class machine
with 16 GB RAM because it has the lowest packaging risk for today's toolchain.
A 16 GB Raspberry Pi 5 is the valuable second reference because it proves ARM64
and tighter resource scheduling. Lyra Zero W should be designed as an online
audio edge, not as the fully offline host.

## Clarified outcome

Wheatley should support these product forms without becoming several different
assistants:

- a normal local Mac runtime with browser, console, or Tauri presentation;
- a plain browser against a remote Wheatley runtime;
- a thin Tauri macOS application against a remote runtime, with an optional
  local sidecar composition later;
- a thin Tauri iOS application with local device/audio and media-cache behavior
  but remote speech recognition, speech synthesis, and agent initially;
- a small online voice appliance such as Lyra Zero W;
- a capable Raspberry Pi or N150 appliance that works fully offline;
- hybrid deployments where a capable appliance keeps a small offline profile
  replica, synchronizes completed turns with the server history, and may send
  selected compute-heavy STT or agent/model work to that server.

Local placement is desirable for different reasons:

| Capability | Main reason to place locally |
| --- | --- |
| Capture, VAD, endpointing | Avoid sending silence continuously; privacy and responsiveness |
| Music and chimes | Trivial local playback; no repeated downloads |
| TTS | Offline speech, lower latency, voice privacy; moderate data saving |
| STT | No microphone upload, offline listening, privacy; meaningful compute cost |
| Pi + LLM | Full offline operation, privacy, control, latency; little ordinary client-data saving |

Keep placement understandable through three named compositions; these names are
concepts, not a frozen configuration schema:

- **standalone local** — an unpaired capable device owns Profile and runs every
  required capability locally, so it works with WAN and LAN unavailable;
- **synced offline/hybrid appliance** — the server is the complete profile and
  history archive, while the device keeps the current/last session, a profile
  snapshot, and a durable outbox. It can run every required capability locally
  when offline and prefer configured remote STT or Agent/LLM compute when online;
- **thin remote** — Profile, Conversation, and heavy voice capabilities live on
  the server; the browser/Tauri/device owns presentation, capture/output, and
  its bounded media cache.

Resolve the chosen capability placement before a turn and record it with the
turn. A configured hybrid may choose its local fallback for the next turn when
the server is unavailable, but it must not silently move STT or agent execution
mid-turn. A paired appliance never becomes a second shared-filesystem writer:
it appends immutable offline work to its replica/outbox, and the server Profile
Runtime resolves imports when connectivity returns.

## What exists today

The current implementation is already close to several useful seams, but not
to the target ownership model:

- `wheatleyd` owns HTTP validation, profile/session persistence, live audio
  interpretation, Whisper workers, TTS, Pi invocation, tools, and most turn
  policy. `WheatleyApi` constructs almost the entire object graph.
- The browser/Tauri client and D console each still contain a substantial
  voice loop. They share semantic events but not one coordinator or one output
  owner.
- `HistoryStore` and `AppConfigStore` assume one process writer. Their locks
  and caches do not make a shared iCloud folder safe for concurrent writers on
  several machines.
- Pi is already wrapped by a persistent newline-JSON RPC subprocess. It also
  depends directly on the profile/session directory, extension files, and
  reverse HTTP callbacks into Wheatley.
- Preview and final Whisper now resolve independently to either a supervised
  local `whisper-server` or a fixed trusted-LAN `whisper-server` endpoint. The
  current deployment sends both small preview and final large-v3 WAV to two
  services on the remote user's Mac. This is a narrow recognition-compute adapter; Voice
  policy and accepted audio remain in `wheatleyd`. See
  [STT Placement](STT%20Placement.md).
- Browser live capture is still 16 kHz mono PCM16. Console capture can send PCM
  or Ogg/Opus at a configured nominal bitrate.
- Browser speech is segmented and synthesized on the server; console speech
  segments locally and calls server TTS. Generated speech is encoded as
  disposable Ogg/Opus (24 kbit/s by default) before transfer.
- The current macOS/iOS Tauri build is deliberately thin and points to the remote user's
  Mac mini. Its macOS build, iOS simulator build, and unsigned device archive
  are measured; a signed physical iPhone turn is not.
- The API is an unauthenticated trusted-process/trusted-LAN boundary. It must
  not be exposed directly to the public internet.

The code-derived detail remains in
[Voice Turn Lifecycle](Voice%20Turn%20Lifecycle.md). Its proposal sections are
historical input, not the target authority.

## Target logical model

```text
Device Shell
  -> Profile Runtime         profile/config/history intent
  -> Conversation Runtime    typed turns
  -> Voice Runtime           voice/device intent

Voice Runtime                VoiceSessionCoordinator, Listener
  -> Conversation Runtime    accepted transcripts
  -> Audio Runtime           lifecycle/output intent
  -> DeviceAudio             capture requests

Conversation Runtime         AgentRuntime
  -> Profile Runtime         state and commits
  -> Audio Runtime           semantic events

Audio Runtime                NarrationPlanner, OutputArbiter
  -> Voice Runtime           playback/route acknowledgements
  -> DeviceAudio             playback requests

DeviceAudio                  microphone, speaker, OS audio session
```

The boxes describe ownership. They do not imply one process, one executable,
or HTTP between every pair. The shell has explicit Profile and Conversation
ports for configuration/history and typed turns; text-only clients do not pass
through Voice Runtime. Voice submits accepted transcripts to Conversation.
Conversation events and Voice output directives feed Audio Runtime. State and
event streams return to the shell through the matching local or remote ports.

### Profile Runtime

The Profile Runtime is the only canonical writer of durable user state within
one authoritative store. It
owns:

- profile identity and, once WAN/device access exists, authorization policy;
- app/profile/device preferences that are genuinely durable;
- session creation, resume, history, memory, and current policy selection;
- a resolved immutable profile/session snapshot for other runtimes;
- artifact metadata, durable blobs, and export/backup behavior.

"Durable user state" does not include node/deployment secrets and paths,
device-local calibration or caches, or runtime scratch data. Those stay with
their owning node or device and are only referenced in the resolved snapshot
when another role needs the resulting fact.

The current filesystem profile tree remains a good storage adapter. In a paired
deployment, the server Profile Runtime is the complete archive and sync
authority. An offline device has a bounded `ProfileReplica`, not another writer
of the server tree: it retains the current/last session, last acknowledged
profile snapshot, and unsynced outbox. In a genuinely standalone deployment,
the device's local Profile Runtime is authoritative.

iCloud may hold or back up the server adapter; it is not the sync protocol.
Remote components call typed profile/session/sync ports and never mount or
directly open the same live iCloud tree.

Do not split `HistoryStore` as a cleanup project. Extract only the capabilities
needed by real callers, beginning with:

```text
resolveSession(...) -> ResolvedSessionConfig
begin/resume/finish session
append/read turn events
open ArtifactSink / resolve ArtifactRef
load prompt and memory context
```

### Conversation Runtime and Agent Runtime

The Conversation Runtime accepts a validated user message—typed text or an
accepted transcript plus artifact references—and emits ordered semantic
events. It owns one turn-policy snapshot, agent cancellation, tool sequencing,
and committing normalized results through the Profile Runtime.

`AgentRuntime` is a smaller capability inside it:

```text
run / resume / cancel
    in:  session context, message, model/reasoning/tool policy, ArtifactRefs
    out: reasoning, token, tool, artifact, done, error events
```

The existing persistent Pi worker is the first adapter. Pi should remain
co-located with the Conversation Runtime initially because it currently shares
session files, a tool workspace, extensions, and reverse callbacks. The
**Conversation Runtime** may be local or remote; Pi itself does not need to
become a public network service.

Implementation status, 2026-08-05: the transport-independent Conversation seam
and its first ownership extraction are delivered. `ConversationEvent` has
typed `status`, `assistant_delta`, `reasoning`, `tool`, `completed`, and
`failed` variants.
`ConversationEventStream` assigns profile/session identity, the canonical
stored turn ID, timestamp, and a gap-free sequence beginning at one. The Pi
collector emits those domain values and no longer constructs SSE or WebSocket
JSON.

The former HTTP-named runner is now `ConversationRuntime`: it owns accepted
turn validation, one resolved policy snapshot, session serialization,
cancellation, agent invocation, terminal history commit, and completion/failure
events. It depends on a small injected `AgentRuntime` contract whose input
contains the complete message, frozen settings, reasoning/memory choices,
semantic event stream, narration-content sink, and cancellation probe.
`PiAgentRuntime` is the current in-process adapter and exclusively owns the Pi
worker registry, prompt/context assembly, process invocation, and Pi-specific
failure evidence. The normal composition root constructs both directly; no
loopback service or dependency-injection framework was added.

Conversation events and accepted submissions are now durable in the current
filesystem adapter as described under Remote submission and recovery. This
still does not hide every history operation behind narrow Profile Runtime
ports. Remote placement is now concrete: the Profile-owned gate synchronously
acknowledges prior local work, hands off even an empty exact session, and
materializes one exact remote terminal turn before local exposure. The HTTP
Conversation port and local narration projection remain small adapters rather
than compatibility code inside the domain boundary.

A local llama.cpp or LM Studio server is a provider used by Pi, not a separate
Wheatley product boundary. On a full offline box, Pi and the provider run
locally. On iOS, embedding llama.cpp is technically possible, but token
inference alone does not reproduce Pi's Node runtime, tools, sessions, and
extensions. A native iOS agent would be a distinct future implementation, not
an endpoint switch.

### Voice Runtime and Listener

The Voice Runtime belongs near the microphone when hardware allows it. Its
coordinator owns the voice-turn state machine: listen, endpoint, accept/reject,
commit, response pending, retry, cancel, and failure. It emits lifecycle facts
and output intent but does not choose exact narration, music, cue overlap, or
playback ordering. It enters and leaves observed `speaking`/barge-in states from
Audio Runtime acknowledgements rather than client inference.

Implementation status, 2026-08-05: the first complete in-process boundary is
delivered. One closed `VoiceEventKind` vocabulary covers ready, listening,
retry, candidate rejection, audio/speech evidence, preview, endpoint, accepted
transcript, resume choice, and failure. Server helpers accept the enum, and
browser/console exhaustively consume the same `voice_event` envelope. Localized
messages no longer select client workflow.

`WheatleyApi` constructs one `VoiceRuntime`, and its guarded
`VoiceSessionCoordinator` owns candidate/retry, endpoint, final transcription,
accepted transcript, commit, response pending/streaming, and terminal
transitions. It calls Profile and Conversation runtimes directly in the default
monolith. Browser/console capture remains device IO driven by semantic events;
browser/Tauri answer and reasoning playback plus console automatic answer
speech now report observed lifecycle facts into a process-local Voice speaking
registry. Physical route/capture acknowledgements remain outside those slices.
`thinking_music` remains an output directive pending that Audio slice rather
than being mislabeled Voice state.

The full Listener owns:

- capture lifecycle requested through an `AudioInput`/`DeviceAudio` adapter;
- pre-roll, VAD, endpointing, draft scheduling and assembly;
- preview and final STT through a `SpeechRecognizer` capability;
- final transcript selection and candidate rejection;
- session/input-device noise calibration;
- stop-speaking or barge-in recognition that depends on microphone and
  playback state;
- the durable accepted-prompt recording delivered through an `ArtifactSink`.

There are two deliberate seams. Audio entering a local or remote Listener is an
audio-level boundary:

```text
AudioInput or EdgeCapture -> timed PCM/Opus frames + format/device facts
                           -> Listener
```

The Listener's coordinator-facing boundary is semantic and text-level:

```text
Listen(CapturePolicy) / Stop
    -> ListeningStarted, DraftChanged, EndpointReached,
       CandidateRejected, TranscriptAccepted{text, language, recording}
```

Placement is tiered rather than all-or-nothing. A constrained device can run
an `EdgeCapture` subset: pre-roll, conservative VAD/endpointing or keyword
detection, and Opus encoding. It sends only candidate utterances to a remote
Listener/STT owner. That does not provide the privacy or zero-audio traffic of
local STT, but it captures most of the all-day bandwidth saving.

Every accepted spoken prompt must retain its audio in the profile, even when
STT ran locally. Transfer must be either lossless or at least 32 kbit/s Opus
quality; lower-bitrate assistant-speech settings do not apply to user
recordings. Profile Runtime always normalizes the durable copy to 32 kbit/s
Opus as `user.opus`, matching current storage. A remote turn may begin from the
accepted transcript while the durable device outbox finishes uploading audio,
but the voice turn is not durably complete until Profile Runtime acknowledges
the recording artifact. Rejected noise/drafts need not be preserved unless a
diagnostic mode asks for them.

The current live server stages the exact VAD-selected recording before
acceptance, atomically records the server-established transcript/start facts in
a per-submission sidecar, and includes a stable
`runtime-user-audio:<submission_id>` reference in `transcript_accepted`. A
submission-scoped GET can retrieve only that accepted normalized Opus, and a
narrow HTTP SSE commit reconstructs the accepted request from the server sidecar
and reuses Conversation submission fencing/event replay. A daemon restart or
lost WebSocket after acceptance therefore no longer destroys the server-side
commit path. Browser/Tauri and console both persist accepted metadata before the
fast WebSocket commit, then automatically resume through HTTP SSE after a lost
connection. Continuous raw capture is never treated as replayable.

Spoken stop remains optional. Console run profiles now configure both
`speech_interrupt` and the required `speech_interrupt_phrases` list. The default
accepts `stop speaking` and `stop`, including repetitions. A later shared Voice
policy may resolve phrases by profile/language rather than device run profile.

### Audio Runtime, narration, and synthesis

Narration and audible-output policy must always be owned beside the speaker.
Audio Runtime is its sole owner. One `OutputArbiter` answers:

- what may be audible now;
- whether cues may overlap capture;
- whether music is playing, delayed, ducked, or cancelled;
- how tool announcements and answer speech are ordered;
- when the device route is ready after microphone release;
- what an interruption or capture restart cancels.

The Conversation Runtime emits semantic text/tool/reasoning events, not WAV
URLs as its core contract. A `NarrationPlanner` turns those events into ordered
speech items. A `SpeechSynthesizer` turns speech items into native buffers,
encoded chunks, or temporary media references. The selected synthesizer may be:

- local Piper or Supertonic;
- a remote Wheatley Piper/Supertonic synthesizer returning compressed audio.

This separation avoids making server-generated WAV the permanent architecture.
The configured profile voice is part of Wheatley's character. Thin iOS should
therefore use the same remote Piper/Supertonic voice initially, preferably as
24 kbit/s Opus, with 16 kbit/s available after a listening comparison. Apple
TTS is not part of the planned fallback path; changing that would require a
separate future product decision rather than an automatic capability fallback.

Synthesized assistant audio is derived, disposable output. Do not preserve it
in the profile or build a large cross-turn speech cache. Stream it from memory
when practical; any client/server temporary files should be deleted after
playback or cancellation and swept on startup as a crash-recovery measure.

Music is different because it is small, reusable source media. Give every
track a stable human-readable code such as `busted-jazz`, never an ordinal
whose meaning changes when the catalog is reordered. A server selection carries
small metadata:

```text
MediaAssetRef { code, revision, media_type, size_bytes, sha256, url }
```

Audio Runtime checks a bounded local cache by `code + sha256`, fetches a miss
over ordinary HTTP, verifies it, and then plays locally. Browser Cache Storage
or IndexedDB, a Tauri filesystem cache, and an appliance filesystem cache are
different adapters behind the same tiny contract. Lazy first-use download lets
the server add tracks later without shipping a new client. A conservative
64 MB default limit with LRU eviction is ample for today's roughly 9 MB set and
prevents an unbounded cache. Chimes are tiny stable assets and may remain
packaged locally. Browser/Tauri now implements this contract with Cache
Storage: it verifies both cache hits and downloads against the server SHA-256,
keys entries by `code + sha256`, and evicts least-recently-used entries above
64 MB. The console/appliance filesystem adapter remains a separate later slice.

Implementation status, 2026-08-05: the first device-local output arbiters are
delivered without replacing platform players. Browser/Tauri constructs one
`BrowserAudioRuntime`, which owns the listening-chime, thinking-music, streamed
speech/user-audio, and Bluetooth/output-recovery adapters. `ChatSession`,
`ChatSpeech`, and live capture address that role; they no longer compose those
players independently. Capture restart cancels local speech and thinking music,
music cannot start while capture is active, and speech waits for the one shared
post-microphone recovery window.

The D console composition root likewise constructs one `ConsoleAudioRuntime`
for text or voice mode. It owns turn speech, system announcements, cues,
thinking music, and the optional spoken-interrupt monitor. A tested output state
allows intentional cue/capture overlap and current tool-speech/music overlap,
while rejecting music/speech start during capture and cancelling active output
on recapture. Native processes remain adapters. Browser/Tauri automatic answer
and reasoning speech now emits `queued`, `started`, `finished`, `cancelled`, and
`failed` facts after actual WebAudio transitions. Ordered best-effort delivery
retries three times through a narrow HTTP endpoint. Voice owns a process-local
registry and derives `speaking` from observed starts; a later queued output from
the same session/adapter retires stale state left by a lost terminal
acknowledgement. Console automatic answer speech follows the same contract from
its native-process adapter: one per-output worker sends facts off the playback
path with two bounded attempts and stops after an undeliverable predecessor so
it cannot create an invalid remote sequence. User-recording playback remains
deliberately local and unreported. Tool/system announcements, music, chimes,
physical route/capture facts, durable acknowledgement delivery, and a common
narration-content policy remain later slices.

Voice lifecycle ownership and Audio output-policy ownership remain distinct,
and neither independently controls the hardware. Audio reports
`PlaybackQueued`, `PlaybackStarted`, `PlaybackFinished`, `PlaybackCancelled`,
`PlaybackFailed`, and route/capture changes back to Voice so speaking, retry,
and barge-in transitions use observed state. One device-local `DeviceAudio`
platform adapter owns the OS audio session, microphone and output routes, and
full-duplex constraints. The Listener requests capture through it; the
OutputArbiter requests playback. On today's desktop/server paths, FFmpeg and
the native player are implementations behind that adapter rather than the
architectural boundary.

### Device Shell

The shell owns presentation and user intent. Browser, Tauri, terminal, and a
headless appliance may present different controls, but they consume the same
semantic state. Platform adapters own microphone permission prompts,
screen/background lifecycle, buttons, display, and telemetry such as battery
or thermal pressure. `DeviceAudio`, rather than the shell's UI logic, owns the
OS audio-session lifecycle.

The shell reports capabilities such as audio formats, background recording,
available Wheatley synthesizers/recognizers, route recovery needs, and spoken-
stop support. A capability report describes fact; the resolved session
configuration selects policy.

## Configuration ownership

The current `config.json` carries facts at several different levels. Separate
them logically before deciding whether they need separate files:

| Configuration | Owns |
| --- | --- |
| Node/deployment | hosted roles, endpoints, roots, model/tool paths, authentication, resource limits |
| Profile/product | server-canonical product choices grouped by subsystem: persona/conversation, memory, tools, voice/listening, audio/output, and media |
| Device | presentation preference, audio route facts, permissions, local calibration/cache |
| Resolved session | immutable effective values sent to Voice and Conversation for this session/turn |

Other components should receive one validated `ResolvedSessionConfig`; they
should not repeatedly call `effectiveConfigProperties` or read profile files.
Mutable UI choices that affect a turn are snapshotted once before the turn.
The groups can remain sections of one validated `config.json`; subsystem
ownership does not require a file or service per group. Node secrets never
sync. A paired offline device keeps the last acknowledged profile/product
snapshot plus its own device settings.

Implementation status, 2026-08-05: `ProfileRuntime.resolveSession` is now the
sole runtime caller of `HistoryStore.effectiveConfigProperties`. It merges the
app/profile properties, resolves the active language, and exposes a
read-only-by-interface snapshot whose property index is copied for each typed
settings adapter. Startup, Conversation/Pi settings, Voice/Listener settings,
preview/final STT, TTS, and Codex tool policy no longer reopen effective
configuration independently. A live voice socket resolves once before capture;
uploaded audio, TTS, and text interactions resolve once at their operation
boundary. The fields are still progressively typed by their existing settings
modules; later Voice, Audio, and Conversation slices will move those groups
under their final role-owned types rather than creating another generic config
framework.

For `synced_hybrid`, the same profile boundary activates one complete,
hash-validated server snapshot of `system.md`, `user.md`, `memory.md`, and
`memory_auto.md` after local work is acknowledged. The appliance never merges
or edits that replica as a second authority. `standalone_local` continues to
resolve its ordinary local profile documents.

## Data and artifact ownership

Preserve the current distinction between versioned resources, replaceable
machine state, and durable private data. A conceptual installation layout is:

```text
resources/                  immutable release prompts, translations, media
app-data/
  models/{stt,tts,llm}/     replaceable downloaded models
  cache/media/              bounded, replaceable music/media cache
  runtime/{agent,voice,speech,audio}/
                             owner-private cache and temporary state
device-data/
  settings/                  durable local permissions/calibration choices
  outbox/                    durable unacknowledged remote submissions
user-data/
  Profiles/...              canonical Profile Runtime data
```

On iOS these map to the appropriate application-support and cache directories
inside one sandbox. On desktop the roots may differ so only durable profile
data is synchronized or backed up. `device-data` is local and non-purgeable; it
must not be treated as cache or synchronized as canonical profile state.

Each runtime may directly access only its private machine-local subfolder. It
uses ports for every cross-owner operation. In particular, an edge Listener
must submit every accepted spoken prompt through `ArtifactSink`; it must not
construct a session path itself. The outbox owns any not-yet-acknowledged
recording bytes and cannot evict them as cache.

Images, audio, and files do not change the message/event architecture. Events
carry small metadata:

```text
ArtifactRef { id, media_type, size_bytes, sha256, purpose }
```

The bytes travel through a streaming upload/download or a platform-local
artifact adapter. Do not base64 substantial binaries into JSON, SSE, or normal
turn events.

## Profile history synchronization

Implementation status, 2026-08-05: the fixed complete-turn export/import,
timestamp-path merge, restart-safe acknowledgement outbox, periodic upload,
latest complete-session manifest/download, Pi first-file-wins preservation,
and idempotent memory-todo append are implemented in `wheatleyd`. Synced-hybrid
devices also atomically acknowledge a versioned, hash-identified replica of
effective product configuration plus `system.md`, `user.md`, `memory.md`, and
`memory_auto.md`, and prune older sessions only after every exportable turn is
acknowledged. The newest current/previous sessions, incomplete turns, and
pending or unacknowledged outbox work are retained. In `synced_hybrid`, the
four server-authoritative documents become active as one validated snapshot
only after local exportable work has been acknowledged; an unpaired
`standalone_local` profile continues to read and write its local documents.
Known exact turn paths are skipped before session files are downloaded, so the
periodic loop does not repeatedly consume audio bandwidth.

Remote Conversation now has both its Profile-owned synchronization prerequisite
and its execution adapter. `RemoteTurnSyncGate` shares the periodic sync mutex
and, before a remote turn, uploads and acknowledges every prior exportable
local turn, rejects incomplete/pending work, and atomically ensures the exact
session exists upstream even when it has zero turns. The accepted-audio path
allows only the submission being handed off and rejects another staged prompt.
It uploads the exact locally normalized Opus through a bounded, SHA-256-bound,
codec-validated multipart import; retries with the same facts are idempotent and
conflicts never overwrite the first accepted artifact.

`RemoteConversationHttpPort` then streams the normal upstream Conversation SSE
contract, validates profile/session/turn identity and every sequence, proxies
stop, and projects semantic answer/reasoning/tool events into the local speech
registry. Exact-session/exact-turn routes import the referenced terminal turn
and artifacts locally before the terminal event is exposed. They never select
the server's merely latest session. Repeated materialization is an ACK-only
no-op, configured Conversation/sync API bases must name the same authority, and
a network or validation failure never falls back to local execution.

Keep the first sync implementation close to Wheatley's current filesystem
model. It does not need a distributed database, globally coordinated session
IDs, vector clocks, or Pi-log reconstruction.

### Storage identity and merge rule

Current session directories already use `YYYY/MM/DD/HH_MM_SS[_2]`; turn
directories use `HH_MM_SS_micros[_2]`. Preserve those relative paths as the
sync identity. The server has the full archive. A paired offline appliance
keeps only its current/last session, the acknowledged profile snapshot, and a
durable outbox.

When reconnecting, the appliance uploads each complete missing turn under its
existing relative session and turn paths. The server creates missing
directories and otherwise keeps files already present. A same-second session
started independently on two devices may therefore become one merged session.
That outcome is acceptable: it is much simpler than adding permanent identity
and conflict machinery for an implausible event. Turn timestamps and existing
`_2` suffixes retain their normal ordering; the UI can order turns by the
stored timestamp/path as it does today. The normal product convention remains
one active client per session; continuing it on another device is sequential
after sync, not a collaborative live-session feature.

Sync is explicit server API work, not concurrent mounting of the same iCloud
profile directory. Start with one narrow HTTP multipart import behind the
existing trusted boundary per completed turn: safe relative session/turn paths,
`session.json`, `turn.json`, the required `user.opus` for a spoken prompt, and
any named turn artifacts. Add device authentication before WAN exposure.
Images and files can later use the same repeated artifact part. A request is
acknowledged only after the complete turn has been committed atomically. The
device then removes that outbox item. Repeating an already present turn path is
an acknowledgement/no-op; no agent, tool, or memory work is rerun.

For the reverse direction, a paired appliance downloads the server's latest
complete-session snapshot after its exportable local work is acknowledged. It
then prunes only older fully exportable sessions whose turns and Pi file are
acknowledged and which have no pending outbox marker. The newest two sessions
are always retained. Browser and thin
Tauri clients need no full replica for history browsing: they continue to read
the server archive online. Local voice, TTS, or media caching can be added to
those clients independently.

### Session metadata, Pi, and memory

`session.json` and the first `pi_session.jsonl` already present in a merged
server session are authoritative. If an import brings a different Pi session
log for that path, preserve it as `pi_session_2.jsonl`, then `_3`, and so on,
but do not splice, replay, or reconstruct Pi JSONL. The initial history UI may
show the imported turn's durable `turn.json` result without every Pi-derived
detail. This is preferable to a large event-normalization migration solely for
an edge-case collision. A normal non-colliding session preserves its own Pi log
unchanged.

When a genuinely new imported turn is committed, append its user prompt to the
server-owned `memory_auto_todo.md` through the existing memory API. Use the
relative session/turn path already accepted by the importer as the simple
idempotency key, so a retried upload does not append the prompt twice. Never
merge or copy generated `memory_auto.md`, its processing file, or its cursor
from the appliance. The server remains the memory authority while paired; a
standalone unpaired device remains its own authority.

### Offline appliance experience

An appliance can continue the retained last session or start a new one. A
voice command for “new session” can be added later; the underlying command
should exist before that phrase is implemented. The appliance does not need a
general history browser. Once all turns in an older local session are
acknowledged and a newer session becomes current, the older replica may be
removed. Fully standalone mode retains whatever local history policy the maintainer
chooses because no server archive exists.

## Deployment profiles

| Deployment | Profile + Conversation | Voice / STT | TTS | Audio + shell | Status |
| --- | --- | --- | --- | --- | --- |
| Local Mac, browser/console | local D runtime + local Pi/provider | local server today | local server today | local client | Implemented primary development shape; not necessarily WAN-offline |
| Thin browser/Tauri | remote runtime | remote; raw PCM live transport today, durable prompt normalized to 32 kbit/s Opus | remote Ogg/Opus at configured 16–32 kbit/s | local playback/presentation and lazy media cache | Valid long-term deployment; native physical phone turn still unverified |
| Standalone Tauri macOS | remote by default; optional local packaged runtime | remote or local | compressed remote or local | local Tauri and media cache | Thin target is sufficient; desktop sidecar remains optional |
| Thin/hybrid Tauri iOS | remote initially | remote Whisper; local capture/Opus gate first, optional whisper.cpp later | compressed remote Piper/Supertonic profile voice | local native audio/Tauri UI and media cache | Target; requires physical background/battery/voice probes |
| Lyra Zero W edge | remote | local edge gate + Opus; remote STT | remote initially | local chimes/music/output | Recommended target for this board |
| Offline/hybrid N150 | server archive + last-session replica; full local fallback and optional remote compute | local or remote by turn | local or remote profile voice | local | Recommended first offline reference; unmeasured |
| Offline/hybrid Raspberry Pi 5 | server archive + last-session replica; full local fallback and optional remote compute | local with fitted models or remote | local or remote profile voice | local | Recommended ARM64 reference after measurement |

"Fully offline" should mean a cold start and normal voice conversation with
WAN disabled, including profile/session access, STT, TTS, music, Pi, a local
model provider, and the selected offline-safe tools. Having source code that
can theoretically be installed on Linux does not satisfy this gate.

### Platform implications

**Luckfox Lyra Zero W.** The official specification is a 32-bit RK3506B with
three Cortex-A7 cores and 512 MB RAM. Wheatley's current setup scripts accept
only x86-64 and ARM64 audio targets, and its default Whisper small + large-v3
models alone exceed the device by several gigabytes. The board is suitable for
audio IO, local assets, VAD/keyword work, and Opus; current STT, Pi/Node, and an
LLM are not an install-as-is target. The actual USB/I2S/PDM microphone and
speaker path must be proven on the intended enclosure. See the
[Luckfox specification](https://wiki.luckfox.com/Luckfox-Lyra/Introduction/)
and [whisper.cpp model memory table](https://github.com/ggml-org/whisper.cpp/blob/master/README.md#memory-usage).

**Raspberry Pi 5 and N150.** Both are plausible offline hosts with enough RAM,
but model concurrency matters: preview STT, final STT, TTS, Pi, and the LLM can
compete at the endpoint. N150/x86-64 minimizes current toolchain risk; Pi 5
proves the desired ARM appliance. Neither support claim should be made until a
complete measured run passes. See the
[Raspberry Pi 5 product brief](https://datasheets.raspberrypi.com/rpi5/raspberry-pi-5-product-brief.pdf)
and [Intel N150 specification](https://www.intel.com/content/www/us/en/products/sku/241636/intel-processor-n150-6m-cache-up-to-3-60-ghz/specifications.html).

**Tauri macOS.** Tauri supports packaged sidecar executables, so a standalone
Mac app can launch a bundled D runtime rather than force a rewrite. Models and
large dependencies can still be installed into Application Support after the
small app bundle is installed. See
[Tauri sidecars](https://tauri.app/develop/sidecar/).

**Tauri iOS.** The current subprocess architecture is not the right unit for
iOS. Local capabilities must be compiled into the signed app through Rust,
Swift, C/C++, or an XCFramework. Wheatley should not initially use Apple speech
recognition: keyboard dictation remains available for manual text entry, but
Wheatley's voice path needs Whisper's behavior for names and non-dictionary
words. Initial voice STT remains remote Whisper; a future local implementation
should evaluate whisper.cpp, not silently switch recognition semantics. The
configured remote Piper/Supertonic voice also remains the initial TTS because it
is tied to profile personality. No Apple STT or TTS fallback is planned;
Wheatley uses Whisper and its existing configured synthesizers. whisper.cpp and
llama.cpp provide iOS examples/XCFramework paths, which proves native inference
is possible but not that it meets Wheatley's quality, background, battery, or
thermal requirements. See
[whisper.cpp iOS](https://github.com/ggml-org/whisper.cpp/blob/master/examples/whisper.swiftui/README.md) and
[llama.cpp iOS](https://github.com/ggml-org/llama.cpp/blob/master/examples/llama.swiftui/README.md).
Long recording or playback also needs an appropriate iOS audio session and
background mode and must be tested under lock, interruption, Bluetooth route
changes, battery use, and thermal pressure. See
[Apple background execution](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes).

## Transport decisions

Transport follows placement; it does not define the logical architecture.

### Direct calls

Use typed in-process calls when roles share a process. Do not make Profile,
Conversation, Voice, STT, or TTS call loopback HTTP merely because a clean
interface exists. The current Pi stdio RPC and Whisper loopback HTTP remain
reasonable adapters because they cross real subprocess boundaries.

### WebSocket

Use one long-lived device channel for genuinely bidirectional live behavior:

- binary PCM/Opus upstream when the Listener is remote;
- start, stop, commit, cancel, configure, and capability facts upstream;
- capture/output directives, drafts, accepted transcripts, and live turn
  events downstream;
- sequence and turn identifiers plus a replay cursor so reconnect or failure is
  observable.

WebSocket is the right transport for live audio and device control. A local
native shell implements the same port directly rather than opening a socket to
itself.

### HTTP and SSE

SSE provides no capability that WebSocket fundamentally cannot provide. It
still has practical value for today's request-scoped, ordered, server-to-client
startup, text-turn, narration, and Codex streams: normal HTTP request
correlation, simple completion/cancellation, proxy tooling, and easy testing.

SSE remains during the refactor. One semantic Conversation event contract is
now serialized over either SSE or the live WebSocket; the transports no longer
have parallel response-event vocabularies. The implemented common envelope is:

```text
{
  profile_id,
  session_id,
  turn_id,
  sequence,
  timestamp,
  kind,
  payload
}
```

Text and uploaded-audio HTTP responses use one SSE event name,
`conversation`. A live-audio socket carries the same envelope in a
`conversation_event` WebSocket message. Browser and console adapters validate
profile/session identity, stable turn identity, and the next exact sequence
before dispatch. A `failed` event is terminal and ordered like `completed`;
capture, transcript, and other Voice lifecycle messages remain a distinct
protocol. Sequence assignment remains an in-process concern while every event
is appended to the turn's durable journal before transport delivery. A retry
with the same submission identity replays that journal after its acknowledged
cursor rather than constructing another response vocabulary.

Reconsider SSE only if every interactive client later maintains one persistent
multiplexed device/session WebSocket and removing SSE would delete more code
than it adds. There is no architectural need to decide that now.

Use ordinary HTTP JSON for commands and queries, and streaming HTTP/multipart
for artifact bytes. Do not turn the WebSocket into a generic file-transfer
protocol.

Media and speech follow the same simple split: events carry a `MediaAssetRef` or
temporary speech reference, while ordinary HTTP transfers the bytes. Stable
music responses may be cached by code/hash; generated speech responses are
consumed and discarded. Do not base64 either into SSE, and do not use the live
WebSocket as a general download channel.

### Remote submission and recovery

Sequence identifiers make failure visible but do not prevent a duplicate agent
turn. Every remote typed message or accepted transcript must use a persisted,
crash-recoverable submission contract before the first placement adapter ships:

- the originating device assigns a globally unique `submission_id`, or scopes
  a locally unique value with `device_id`, before submission;
- Conversation atomically creates one durable turn with the complete accepted
  payload and execution state `pending`; the scoped submission key maps to that
  turn before the device receives an acceptance acknowledgement;
- a worker acquires a fenced execution claim and records `running` before it
  invokes Agent Runtime, then records a terminal result; a stale worker cannot
  commit after another recovery attempt owns the fence;
- retrying the same submission returns the same turn and event stream and never
  creates a second turn. Recovery may resume the same turn when Agent Runtime's
  checkpoint semantics prove that safe;
- after an uncertain crash involving tools or other non-idempotent effects, the
  turn becomes visibly `ambiguous/failed` instead of being invoked again
  automatically. A new run requires explicit user authorization and a new
  submission ID;
- the device keeps the submission in durable `device-data/outbox/` until the
  durable `pending` record is acknowledged, and reconnect resumes persisted
  events after the last acknowledged sequence;
- artifact upload is separately resumable/idempotent by artifact ID and hash.

Implementation status, 2026-08-05: the server half of this contract is now
delivered for every text, uploaded-audio, and accepted live-audio turn. The wire
field is the required `submission_id`; clients currently generate a UUID-based
value before capture/submission. `turn.json` atomically publishes the mapping,
the complete accepted payload, `pending` state, and later a unique `running`
execution claim. Terminal commits must present that same claim. A replay that
finds interrupted `pending`/`running` work invalidates the old claim and records
an ordered terminal `ambiguous` failure instead of invoking Agent Runtime again.

Each semantic event is flushed to `conversation.events.jsonl` before it is
delivered. Repeating the same payload and `submission_id` returns the same
canonical turn and replays events after required non-negative
`after_sequence`; reusing the ID with a different accepted payload fails. A
crash after terminal history but before its terminal event reconstructs that
event from the committed turn. The first browser live attempt and live-console
voice currently start at cursor zero. Console text persists its request before
transport, checkpoints nonterminal received sequences, and replays pending
entries after restart before accepting a new prompt.

Browser/Tauri now also persists a metadata-only accepted-voice entry in
IndexedDB before sending the WebSocket commit. It checkpoints nonterminal event
sequences, removes the entry only on a terminal event, and drains pending work
sequentially on startup, reconnect, and profile selection through the
restart-safe HTTP SSE commit. The 32 kbit/s Opus and accepted manifest remain
the single durable server-side audio copy; IndexedDB contains no PCM, Opus,
drafts, or live-socket state. The console follows the same contract in its
filesystem outbox: it persists accepted identity/text/start policy before the
WebSocket commit, checkpoints only nonterminal Conversation events, and drains
retained entries through HTTP SSE before opening a new capture. A terminal
event directly deletes the entry, so a crash cannot preserve an unreplayable
terminal cursor. These metadata-only outboxes must reconnect to the same API
authority that announced acceptance; changing authority while a prompt is
pending is not a supported recovery case. The separate profile-history sync
outbox continues to cover completed-turn replication.

The first remote-audio version should not pretend it can resume in the middle of
an utterance. If that live channel breaks before transcript acceptance, fail the
candidate visibly and begin a new capture; do not splice uncertain audio across
connections.

### Remote access security

Current trusted-LAN CORS is not authentication. An iPhone outside the home
cannot safely connect by publishing port 8765. WAN use requires TLS plus an
authenticated device boundary—initially a private VPN can provide that
boundary; a productized route would need enrollment, revocable credentials,
and authorization at the Profile/API edge.

## Mobile-data calculation

These figures use decimal carrier units, a 30-day month, and payload only.
Allow additional transport/carrier overhead. For a constant stream:

```text
MB per hour = kilobits per second * 0.45
```

### Microphone upload

Current browser PCM16 mono at 16 kHz is:

```text
16,000 samples/s * 16 bits = 256 kb/s = 32,000 bytes/s
```

| Uplink | Per hour | 1 h/day monthly | 8 h/day monthly | Continuous monthly |
| --- | ---: | ---: | ---: | ---: |
| Current PCM16 | 115.2 MB | 3.46 GB | 27.65 GB | 82.94 GB |
| Opus 32 kb/s payload | 14.4 MB | 0.43 GB | 3.46 GB | 10.37 GB |
| Opus 24 kb/s payload | 10.8 MB | 0.32 GB | 2.59 GB | 7.78 GB |
| Opus 16 kb/s payload | 7.2 MB | 0.22 GB | 1.73 GB | 5.18 GB |

The concern is therefore reasonable. Even nominal 32 kb/s Opus is eight times
smaller than PCM. The current console forces one Ogg page per 20 ms frame, so
container overhead and content-dependent Opus VBR make its observed stream
larger than the nominal row; local probes put it roughly in the 18–23 MB/hour
range before network overhead. Larger pages or raw framed Opus should be
measured rather than assumed.

Local speech gating multiplies the transmitted figure by the speech duty cycle.
For example, sending 32 kb/s Opus during only 10% of an eight-hour listening
window is about 0.35 GB/month payload instead of 3.46 GB. Local STT avoids the
continuous stream, but Wheatley's preservation rule still transfers or stores
the much smaller accepted-prompt recording.

The recording policy is therefore fixed at the product level:

- preserve every accepted user spoken prompt in its profile;
- transfer it as lossless audio or at no less than 32 kbit/s Opus quality;
- always normalize the profile artifact to 32 kbit/s Opus `user.opus`, matching
  the current storage contract;
- allow deferred Wi-Fi upload, but retain the recording in the durable device
  outbox until Profile Runtime acknowledges it;
- do not offer transcript-only persistence for an accepted voice turn.

### Returned speech and music

Piper and Supertonic synthesize a temporary WAV on the server, then Wheatley
encodes the returned disposable artifact as Ogg/Opus. The default
`tts.assistant_opus_bitrate_kbps` is 24 and is deliberately bounded to 16–32
kbit/s until listening tests choose a different target. This does not alter the
separate accepted-user-audio contract: that is always normalized and stored as
32 kbit/s `user.opus`.

The source voice is approximately 22.05 kHz mono PCM16 WAV, so the transfer
comparison is:

| Speech transport | Per spoken hour | 10 min/day monthly | 30 min/day monthly |
| --- | ---: | ---: | ---: |
| Source WAV (not transferred) | 158.8 MB | 0.79 GB | 2.38 GB |
| Opus 32 kb/s | 14.4 MB | 0.07 GB | 0.22 GB |
| Opus 24 kb/s | 10.8 MB | 0.05 GB | 0.16 GB |
| Opus 16 kb/s | 7.2 MB | 0.04 GB | 0.11 GB |

Local TTS is still useful for offline use, privacy, latency, and consistent
availability. It is not required merely to solve mobile data: 24 or 16 kbit/s
remote Opus removes most of that cost while preserving the configured Wheatley
voice. Assistant speech is derived and disposable, so these figures are
transport cost rather than a reason to retain generated files.

The five current thinking tracks total roughly 8.9 MB and each response is a
complete 1.5–2.1 MB MP3. If no effective cache intervenes, fetching a track for
20 turns per day costs roughly 0.9–1.3 GB/month even when playback stops early.
Use the stable-code, hash-verified, lazy client cache described above and send
only the selected asset reference and gain. The two chimes total about 72 kB
and should simply be local assets.

### LLM traffic

Ordinary LLM traffic is not the mobile-data priority. In a remote-conversation
deployment, the phone sends an accepted transcript and receives semantic text
events; Pi constructs and sends the full model context on the server. Even a
large text turn is normally kilobytes to hundreds of kilobytes, not hundreds of
megabytes. Images and user files are the exception.

Local iOS LLM work should therefore be justified by offline operation,
privacy, latency, cost, or product quality—not by expected mobile-data savings.

## Recommended evolution

Run platform probes in parallel with review-sized architecture slices. A probe
is evidence, not a new contract.

### Evidence track

1. **Offline reference.** Install the current stack plus an explicit local
   provider/model on a 16 GB N150-class host. With WAN disabled, measure cold
   start, resident memory, preview/final STT real-time factor, TTS real-time
   factor, LLM TTFT/tokens per second, endpoint contention, and a complete
   voice turn. Repeat on Pi 5 after the model/resource plan is credible.
2. **iPhone audio.** Sign and run the existing Tauri client on the physical
   iPhone. Measure foreground and locked/background capture, audio-session
   interruptions, Bluetooth routing, Opus cost, battery, thermal state, and
   actual cellular bytes. Verify the lazy music cache, durable 32 kbit/s user
   recording outbox, and remote profile voice at 16/24/32 kbit/s. Evaluate
   local whisper.cpp only if remote Whisper becomes insufficient; Apple speech
   recognition is not a Wheatley voice-path candidate.
3. **Lyra edge.** Prove the real microphone/speaker path, 32-bit toolchain,
   Opus encoding, conservative VAD/keyword detector, memory, CPU, boot, and
   Wi-Fi recovery. Do not begin by porting Pi or current Whisper models.

### Implemented foundations and next gates

The **Synchronized session foundation — full server history replication with
durable acknowledgement state** and the active **Profile Runtime replica**
slices have been implemented without combining them
with Listener, Audio, remote-compute, or iOS-native refactors.

Implemented and machine-verified:

- existing appliance startup can start or continue its last session with the
  server absent;
- every exportable completed offline turn, including the existing normalized
  32 kbit/s `user.opus` for voice,
  survives restart through durable history plus persisted acknowledgement state
  and uploads when the server returns;
- retries do not create a second turn or a second memory-todo entry;
- the server history shows imported turns and remains the full archive;
- an appliance imports the server's latest complete session only after its
  exportable pending work is acknowledged, and existing startup can explicitly
  start a new session; older acknowledged replicas are pruned while current,
  previous, pending, incomplete, and unacknowledged sessions are preserved;
- the paired device atomically stores and activates one versioned snapshot of
  effective configuration, personality/prompt documents, and memory only after
  locally completed work is acknowledged;
- an artificial same-second session collision produces the intentionally
  simple merged session, keeps the first session/Pi files authoritative, and
  preserves a second Pi log under a numbered filename.

The delivered slices are:

1. **Narrow HistoryStore sync facade.** Added only the export, import, latest
   snapshot, and safe-file resolution operations the sync path needs; the broad
   resolved-config restructuring was not forced into this goal.
2. **Complete-turn boundary.** A text or voice turn is safe to
   export only after terminal history is present. Voice export requires its
   normalized 32 kbit/s `user.opus`; existing history is the durable payload,
   and the outbox records pending state before the network attempt.
3. **Server import.** One narrow HTTP multipart endpoint validates the
   existing relative timestamp paths, commits a complete missing turn, treats
   an existing path as a retry, applies the first-file-wins session/Pi rule,
   and appends a newly imported prompt to memory todo once.
4. **Appliance sync loop.** A configured background loop pushes durable history
   entries, records ACKs atomically, then pulls the latest complete session.
5. **Automated vertical coverage.** Tests cover restart-safe acknowledgements,
   text plus voice/Opus reconstruction, idempotent retry/memory todo, pending
   audio exclusion, latest-session allowlisting, and a fabricated same-second
   merge/Pi collision. A real two-machine offline/reconnect run remains the
   physical deployment gate.
6. **Placement later.** A later goal can add remote STT/Agent selection, local
   media cache/compressed TTS, and platform-native audio as separate goals. iOS
   continues to use remote Whisper and the configured Wheatley TTS; no Apple
   STT fallback is implemented.
7. **Resolved session configuration.** Added one in-process Profile Runtime
   boundary and immutable-by-interface snapshot. Every current settings
   consumer resolves through it; live voice uses one snapshot for the socket
   rather than rereading profile configuration during candidates.
8. **Semantic Conversation events.** Added one typed, transport-independent
   response stream from Pi through Conversation Runtime to browser and console.
   SSE and live WebSocket carry the same identified, sequenced envelope and
   clients reject identity changes or sequence gaps.
9. **Conversation/Agent ownership.** Moved the accepted-turn coordinator out of
   the HTTP/text adapter namespace into `ConversationRuntime`, injected one
   placeable `AgentRuntime` capability, and made `PiAgentRuntime` its concrete
   adapter. Request, response, cancellation, startup prewarm, text HTTP, and
   live voice callers now name the domain role while remaining direct calls in
   the default D composition.
10. **Durable Conversation submission and replay.** Promoted the former client
    correlation value to required `submission_id`, persisted the accepted
    payload and canonical turn mapping before execution, fenced terminal commit
    with a unique execution claim, journaled events before delivery, and made
    retries replay after `after_sequence`. Interrupted work fails visibly and
    cannot be committed by its stale claim. Later slices added the console-text
    origin outbox, both accepted-voice client outboxes, and the remote adapter.
11. **Typed Voice event protocol.** Replaced the parallel ready/listening/
    preview/endpoint/transcript/error WebSocket shapes with one closed domain
    vocabulary and `voice_event` envelope consumed exhaustively by browser and
    console. Candidate rejection and endpoint reached are explicit facts;
    thinking music stays separate for the Audio Runtime slice. Coordinator
    ownership remains the next Voice step.
12. **Voice Runtime coordinator.** Moved live session orchestration out of the
    transport/audio-turn namespace into one composition-root-owned
    `VoiceRuntime`. A tested `VoiceSessionCoordinator` guards candidate retry,
    endpoint, final transcription, transcript acceptance, commit, response,
    cancellation, and failure transitions. Device capture remains an adapter;
    output arbitration and browser speaking acknowledgements arrived in later
    slices below.
13. **Device-local Audio Runtime arbitration.** Added one browser/Tauri and one
    D-console output owner above existing platform adapters. Voice and text
    paths now route cues, thinking music, streamed speech, system speech,
    recovery, and spoken interruption through them. Capture restart cancels
    conflicting output, the console transition rules are unit-tested, and the
    existing intentional cue and tool-speech overlap policy is preserved. The
    later playback slices report browser/Tauri and console automatic speech;
    route/capture acknowledgements remain.
14. **Disposable compressed assistant speech.** Remote Piper/Supertonic now
    synthesizes to a server-temporary WAV and returns one Ogg/Opus artifact at
    configured 16–32 kbit/s (24 by default). Browser/Tauri decode the ordinary
    HTTP artifact through their existing audio path; console downloads an
    `.opus` temporary file for an Opus-capable existing player (the default is
    ffplay). The generated response is
    still deleted after GET/cancellation; it is neither profile history nor a
    cache. User prompt recordings remain independently normalized to 32 kbit/s
    `user.opus`.
15. **Stable thinking-music references and browser cache.** The next-track API
    now returns `{asset, title, gain_db}`, where `asset` is the documented stable
    `MediaAssetRef`; immutable asset bytes have a separate ordinary HTTP URL.
    `title` is the manifest-owned friendly display name rather than a filename.
    Catalog tracks use explicit human-readable `code` and `revision`, plus
    measured byte size and SHA-256. Browser/Tauri verifies every fetched or
    cached asset, caches it by `code + sha256` in Cache Storage, and applies a
    64 MB LRU bound. The D console follows the same selection/reference API but
    retains its existing temporary-file playback until its filesystem-cache
    adapter is deliberately added.
16. **Crash-durable live prompt handoff and lifecycle repair.** Voice now
    normalizes accepted PCM into profile-local durable 32 kbit/s Opus staging
    before emitting transcript acceptance. Conversation moves that artifact
    into the turn before publishing `turn.json`; the asynchronous attachment
    path and its terminal-history race are gone. Browser cancellation/failure
    always clears Audio Runtime's capture guard, typed-live text enters response
    pending before Conversation events, and disposable generated TTS files are
    swept on daemon startup.
17. **Explicit deployment composition.** Run profiles now choose
    `standalone_local` or `synced_hybrid` rather than inferring profile authority
    from an optional environment variable. Standalone rejects an upstream;
    hybrid requires one and is launched by `scripts/server/hybrid.sh`. The
    selected composition is visible in health output. This slice fixed
    deployment authority and sync activation only; STT/TTS remain local, while
    later slice 26 made Conversation independently placeable.
18. **Offline reference preflight.** `scripts/probes/offline-readiness.sh`
    performs a read-only check of installed local audio/STT/TTS dependencies and
    models, `standalone_local` daemon health, Pi launchability, and profile
    availability. It deliberately does not promote that preflight into an
    offline-support claim: a configured provider response and complete voice
    turn with WAN disabled still require the named N150/Pi physical gate.
19. **Bounded profile replica and session retention.** Synced-hybrid refresh now
    stores an atomic SHA-256-versioned effective product-config snapshot and
    prunes only older fully exportable/acknowledged sessions. Current/previous,
    incomplete, pending-outbox, and unacknowledged sessions are tested retained.
    A later slice extended this same snapshot with the four authoritative
    profile documents rather than adding another synchronization mechanism.
20. **Origin-device console-text outbox.** The D console persists the complete
    text request and submission ID before sending, checkpoints its replay cursor
    after nonterminal Conversation events, reopens/replays pending entries
    before accepting new input, and removes them directly on a terminal event.
    Optional local `user.opus` storage exists in the outbox contract. Browser/
    Tauri accepted voice uses its own metadata-only IndexedDB outbox; console
    accepted voice now reuses this filesystem owner without duplicating Opus.
21. **Explicit Conversation placement seam.** Callers now depend on a narrow
    `ConversationPort` plus preparation port; `ConversationRuntime` is the
    direct local adapter. Startup selects `local` or `remote` once. Remote
    placement is now delivered by slice 26 and never silently falls back. The
    Profile synchronization prerequisite is delivered in slice 25.
22. **Active synchronized profile documents.** The versioned replica now
    contains validated, individually hashed `system.md`, `user.md`, `memory.md`,
    and `memory_auto.md` content. Synced-hybrid activates them atomically only
    after all exportable local turns/Pi state are acknowledged; standalone
    remains local-authoritative.
23. **Restart-safe accepted live-audio commit.** `transcript_accepted` carries
    the stable key for the exact server-staged normalized `user.opus`. Before
    that event, Voice atomically records an accepted manifest with the server-
    established transcript, pinned turn policy, full audio metadata, byte count,
    and SHA-256. A scoped GET and idempotent HTTP SSE commit survive a lost
    WebSocket/restart while preserving the canonical `audio_live` submission.
    Browser/Tauri origin-outbox wiring arrived in slice 27 and console wiring
    in slice 28. Continuous raw capture is never treated as replayable.
24. **Observed playback lifecycle.** Browser/Tauri automatic answer/reasoning
    speech and console automatic answer speech report typed queue/start/terminal
    facts through a narrow endpoint. Voice owns process-local speaking state,
    delivery retries are bounded and off the audio path, duplicate events are
    idempotent, and a new queued output reconciles a lost prior terminal.
    Physical audio-route/capture acknowledgements remain.
25. **Exact remote-turn synchronization gate.** A Profile-owned gate shares the
    sync mutex, uploads/ACKs prior complete work, rejects incomplete or pending
    artifacts, hands off an exact zero-turn session, and materializes one exact
    terminal turn and artifacts before local terminal exposure. It is
    idempotent, never substitutes the latest unrelated server session, and
    requires Conversation and sync to name the same upstream authority.
26. **Remote Conversation HTTP placement.** A synced-hybrid runtime can now
    select the paired authority once at startup; `run-profiles/remote.json` and
    `scripts/server/remote.sh` provide the concrete composition. The adapter
    performs the exact gate, streams and validates the common SSE journal,
    proxies stop, projects remote semantic output into local narration/TTS, and
    materializes the exact terminal turn before delivering terminal. Accepted
    uploaded/live Opus is transferred without base64 through an idempotent
    64 MiB-capped, SHA-256 and FFmpeg-validated import. Local Pi, prompt prewarm,
    and session auto-memory do not run; network failure is visible and never
    causes mid-turn fallback.
    Upstream session-boundary auto-memory/prewarm needs a future exact-session
    preparation command and is deliberately not emulated through the UI startup
    stream.
27. **Browser/Tauri accepted-voice origin outbox.** Before the fast WebSocket
    commit, the client durably stores the accepted artifact identity, canonical
    text/policy, and replay cursor in IndexedDB. Startup, online recovery, and
    profile selection drain it through HTTP SSE; nonterminal cursors are
    checkpointed and terminal is the deletion acknowledgement. The server-
    staged Opus remains the only audio copy, and pre-acceptance capture is not
    resumed.
28. **Console accepted-voice origin outbox.** Console live voice persists the
    accepted artifact identity, canonical transcript, exact start-pinned policy,
    and cursor before invoking presentation callbacks or sending the WebSocket
    commit. Direct WebSocket and HTTP recovery validate ready/profile/session,
    stable nonempty turn identity, gap-free sequence, and nested completed-turn
    identity. Only nonterminal sequences are checkpointed; terminal is direct
    deletion. Startup and reconnect recovery gate new capture while retained
    work remains. The outbox stores no second Opus copy because the accepting
    daemon already durably owns the normalized 32 kbit/s artifact and manifest.

Durable playback and physical route/capture acknowledgements, upstream remote
session preparation, and device-local pre-acceptance input gating remain later
goals.

The remaining bandwidth work is device-local input gating and placement-aware
remote/local compute selection; it should use these target concepts rather than
create another client-specific pipeline.

## Deliberately not now

- no service discovery, capability mesh, or orchestration platform; the only
  automatic placement behavior is an explicitly configured hybrid choosing its
  local fallback before the next turn;
- no separate daemon for every logical role;
- no live shared-write profile folder across devices; explicit turn import and
  last-session snapshot download are enough;
- no remote Pi protocol exposed as a public product API;
- no native iOS agent/LLM project merely because llama.cpp can compile there;
- no Apple STT or TTS integration; use Whisper and Wheatley's configured
  Piper/Supertonic voice;
- no claim that Raspberry Pi, N150, or Lyra is supported before the named
  physical gate passes;
- no universal replacement of SSE with WebSocket;
- no protocol-level base64 blobs or generic binary-message framework;
- no cleanup of all `HistoryStore` methods beyond what the next real caller
  needs.

## Remaining human decisions

Nothing further is required to continue the synchronized-session goal. The
server is the full paired-device archive; appliance sync now retains current/
previous and unsafe-to-prune sessions plus a versioned active configuration/
profile-document snapshot. Browser/Tauri accepted-commit retry is delivered;
console accepted-commit retry is now delivered on the same server-owned-audio
contract. Pre-acceptance capture is deliberately not replayed. Timestamp-path
merge and first-file-wins behavior are intentional.
User recording fidelity and the absence of Apple STT/TTS fallbacks are also
settled.

Only these later choices need the maintainer's input:

1. **First physical offline reference.** Recommended: N150 16 GB for the fastest
   proof; choose Pi 5 first only if ARM portability matters more than setup risk.
   This does not block the sync implementation.
2. **Assistant-speech bitrate.** Start with remote Opus at 24 kbit/s. Before
   freezing the default, the maintainer should listen to short 16/24/32 kbit/s samples
   from the real EN/SK profile voices; this is a quality check, not an
   architectural decision.
3. **Spoken-stop vocabulary.** Keep it disabled by default. Before expanding it
   beyond the current console behavior, choose the desired English/Slovak phrase
   lists and whether they vary by profile or only by language.
4. **Physical iPhone evidence.** Signing and access to the real device are
   needed before claiming background capture, battery, Bluetooth, or locked-
   screen behavior; they do not block thin-client or server-side work.
