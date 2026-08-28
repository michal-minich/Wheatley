# Client Unification and Capability Placement

Status: superseded on 2026-08-05 by
[Runtime Roles and Deployment](Runtime%20Roles%20and%20Deployment.md). Retained as the
first-pass coupling audit and source map; do not implement its recommendation
or slice order directly.

It superseded the "one client orchestration core, two adapters" sketch at the
end of [Voice Turn Lifecycle](Voice%20Turn%20Lifecycle.md), because that sketch
assumed the assistant always runs on one machine. Its code inventory and
coupling findings remain useful input to the newer runtime plan.

## Why this exists

Two goals arrived together, and they constrain each other:

1. **Unify the clients.** Web and console impose materially different
   orchestration on the same server behavior. The same turn is presented,
   spoken, and timed differently by each.
2. **Make capabilities placeable.** A client should be able to run some
   capabilities locally — STT first, because continuous listening otherwise
   streams audio over the network all day — while still calling a central
   machine for Pi and history.

Goal 2 decides goal 1. If capabilities can sit next to the microphone, then the
turn-orchestration core cannot simply be moved into the central server, because
on a Raspberry Pi the core and the microphone are on the same box while Pi and
history are not.

## Shape audited before implementation

The counts and paths below are the 2026-08-05 baseline retained for comparison,
not the current implementation inventory. In particular, the former
`live_audio_turn.d` coordinator has since moved behind the composition-root-owned
`server/voice/runtime.d` and a tested semantic session state machine.

| Tree | Lines | Note |
| --- | --- | --- |
| `client/src/` (TypeScript) | 8,010 | plus a working Tauri shell for macOS and iOS |
| `client/console/**` (D) | 5,123 | built as a second binary from the `wheatleyd` package |
| `server/**` (D) | 18,551 | `live_audio_turn.d` alone is 994 lines |
| `common/**` (D) | 2,863 | shared by server and console; the web client shares none of it |

Facts that matter for the design:

- The server already owns all audio interpretation: VAD, endpointing, draft
  assembly, final STT, transcript selection, ignore/retry, persistence.
- `whisper.cpp` already runs as a **persistent `whisper-server` subprocess
  reached over HTTP on `127.0.0.1`**. STT is already network-addressable
  internally.
- Pi extensions already call back into Wheatley over HTTP through
  `WHEATLEY_API_BASE`. A distributed pattern already exists in the codebase.
- The server already **commands** one client output: `thinking_music
  {action, delay_ms}` on the live socket. Both clients obey it identically and
  that output has no parity bugs.

### Where output policy lives today

Four audible things, three different ownership models, differing per client:

| Output | Web policy owner | Console policy owner | Server directive? |
| --- | --- | --- | --- |
| Listening cues | browser (`BrowserLiveAudio`) | console (`voice/runner.d`) | no |
| Thinking music | **server** | **server** | **yes** |
| Answer speech | server (SSE segment URLs) | console (local segmenting + `POST /tts`) | half |
| Tool-progress speech | server (`feedProgress`) | console (`feedImmediate`) | half |
| Device recovery gate | browser (`BrowserOutputRecovery`) | nothing | no |

Everything that drifted is everything a client still decides for itself.

### Other measured coupling

- **Two full turn loops.** `ChatSession.#runLiveListening` plus
  `BrowserLiveAudio` (~1,300 lines TS) against `runConsoleVoice` plus
  `streamLiveAudioTurn` (~2,100 lines D). One state machine, written twice.
- **Two protocol decoders.** Console shares `common/api/live_audio_events.d`
  with the server; the browser hand-maintains `WheatleyJson.ts`.
- **Two TTS architectures.** Same `TtsSegmentBuffer` rules, run server-side for
  the browser and client-side for the console. This is the largest real
  divergence and the reason the two clients do not narrate the same turn.
- **`HistoryStore` is a god object**: roughly 100 public methods, imported by 24
  modules, and reached ad hoc from STT settings, TTS settings, turn pipelines,
  and Pi prompt building.
- **Profile config is never resolved at a boundary.** Six or more call sites
  re-read a flat property list through `store.effectiveConfigProperties`.
- **Console leaks into server internals** in three places:
  `speech/interrupt.d` and `audio/chimes.d` import `server.turns.audio.pcm16_wav`;
  `speech/streaming.d` imports `server.tts.segment_buffer`.

## Part 1 — Capability placement

### The unit that has to move is the Listener, not "STT"

Making the STT *endpoint* configurable is nearly free, and it does not achieve
the goal. If the orchestrator stays central and only whisper moves to the Pi,
audio travels device to server to Pi and back. The point of local recognition is
that audio never leaves the box.

VAD, endpointing, and draft assembly are all functions of the raw audio, so they
must sit wherever the audio sits. That makes one coherent unit:

```text
Listener
    in:   Listen(capture policy) / Stop
    out:  ListeningStarted, DraftChanged, EndpointReached,
          CandidateRejected, TranscriptAccepted{text, language, recording}
    needs: an audio device, a SpeechRecognizer, resolved profile settings,
           somewhere to put the recorded Opus
```

Today that unit is split across the client/server line in an incoherent way:
the client owns capture, the server owns everything after it. Making it one
owner is a simplification worth doing **even if nothing is ever deployed
remotely**.

Everything after `TranscriptAccepted` is a second unit:

```text
Conversation
    in:   AcceptedTranscript / TypedText
    out:  token, tool, reasoning, done, speech segments
    needs: Pi, history, memory, tools, config
```

### Target model: three roles, one binary

```text
Device shell            browser / Tauri webview / terminal
   |                    capture IO, output IO, presentation only
   |  device channel (WebSocket): directives down, device facts up
Voice node              VAD, endpoint, draft + final STT, turn conductor
   |                    owns cue / music / speech / capture policy
   |  conversation API (HTTP + SSE)
Conversation node       Pi, history, memory, tools, config
   |
Speech node             TTS synthesis
```

The conductor belongs to the **Voice node**, not to the central server, because
cues, half-duplex sequencing, and device recovery are all tied to capture
transitions. In the thin-browser deployment the Voice node happens to run on the
central server; on a Pi it runs next to the microphone. The device shell is thin
either way.

Deployments this produces:

| Deployment | Voice | Conversation | Speech | Audio over the network |
| --- | --- | --- | --- | --- |
| Today | server | server | server | continuously while listening |
| Edge listening (the goal) | Pi / laptop | Mac mini | either | none while listening |
| Fully local | one machine | same | same | none |
| Thin browser | server | server | server | continuously (unavoidable) |

Plain-browser use must keep working, so "Voice node runs remotely" stays a
first-class deployment, not a fallback.

### Placement variants

**P1 — One binary, roles plus routing config.** Recommended. The same
`wheatleyd` runs everywhere; a run profile names which roles this process hosts
and where to reach the others. Default is `roles: [voice, conversation, speech]`,
which is exactly today's behavior with zero change. A Pi box runs
`roles: [voice, speech]` with `conversation: http://macmini:8765`.

- For: no new packaging, no new build configs, no discovery layer. Run profiles
  already exist and already have a `shared` topology section. The default
  configuration stays a monolith, so nothing gets slower or more fragile until
  the maintainer actually deploys a second box.
- Against: the Pi build carries code it does not run. On a Pi 5 that is
  irrelevant; on something smaller it might not be.

**P2 — Separate binaries per role.** `wheatley-voice`, `wheatley-conversation`,
`wheatley-speech`, sharing a library package.

- For: smallest footprint per node; the dependency direction becomes
  compiler-enforced rather than conventional.
- Against: three build configurations, three release paths, and the shared code
  has to be extracted into a package before anything works. It buys deployment
  tidiness, not capability.

**P3 — Keep the monolith; make capability endpoint URLs configurable.** Point
Wheatley at a remote `whisper-server` or a remote TTS.

- For: almost free today, because whisper already speaks HTTP to localhost.
- Against: does not achieve local listening. Audio still crosses the network.
  Worth doing anyway as a small independent convenience, but it is not the goal.

**P4 — Capability mesh with discovery and a registry.** Rejected explicitly.
Every capability an independently addressable service with health, discovery,
and failover is a great deal of machinery for a family assistant with at most
three boxes. P1 gives the same placement freedom through one config section.

### Boundary variants

Independent of P1–P4: where do you cut?

**B1 — Cut at the Listener.** Recommended. One text-level boundary between
Voice and Conversation. Achieves the stated goal, and the boundary is a
simplification you want regardless.

**B2 — Cut at individual capabilities.** STT and TTS become remotely callable,
orchestrator stays central. Simplest. Achieves the goal for TTS but not for STT.

**B3 — Cut at both.** Listener boundary, plus placeable STT and TTS inside it.
Most flexible and most work. Reachable later from B1 without rework.

### What this costs, honestly

The Voice node needs resolved profile settings and somewhere to write the
recorded Opus, but not the whole `HistoryStore`. So B1 requires two extractions
that are worth doing on their own merits:

1. A **resolved profile settings object** produced once at the boundary,
   replacing ad hoc `effectiveConfigProperties` reads scattered through STT,
   TTS, live-audio, startup, and codex settings loaders.
2. An **artifact sink** port for the recorded user audio.

Two things are explicitly *not* movable and do not need to be:

- **Pi stays with Conversation.** It shares a session directory on disk, is
  driven by newline JSON RPC over stdin/stdout, and its extensions call back
  into the Wheatley API. It is a co-located agent, not a swappable backend.
- **`TurnSpeechStream` stays with Conversation**, because it follows the live
  token stream. It already emits segment URLs, so playback at a remote device
  works unchanged.

## Part 2 — Client unification

Placement resolves this question rather than competing with it.

Because the conductor lives on the Voice node, and the Voice node is D and can
be co-located with the device, the shared core **stays in D and needs no
rewrite**. The device shell stays thin in both TypeScript and D. Concretely:

- A rewrite of the console into TypeScript is off the table. It would mean
  writing 3–4k lines of new TS to delete 5.1k lines of working D — ffmpeg and
  Opus capture, native playback, terminal rendering, spoken session resume,
  speech interrupt, client-tools runner — and it would put the Listener in the
  one language that cannot host it on a headless box without adding Node.
- Retiring console voice is also off the table, since it is a permanent surface.

So the client work is: **the device shell obeys directives from its Voice node.**

```text
voice node -> device:  capture{start|stop}   cue{start|stop}
                       music{play|stop, delay_ms}
                       speech{segment url | stop}
                       draft{text}   transcript{text, language}
                       activity{token | tool | reasoning}
device -> voice node:  start / stop / configure / commit
                       device{capture_started, output_ready_at, capabilities}
```

Each shell implements three small adapters with the same names in both
languages — `CaptureAdapter`, `OutputAdapter`, `PresentationAdapter` — plus one
client-local `OutputArbiter` that serialises directives against the device
recovery deadline. The arbiter obeys policy; it does not choose it.

Intentional differences become **declared capabilities** in the start message
(`supports_opus`, `supports_spoken_interrupt`, `requires_output_recovery`,
`presents_recent_sessions`) rather than re-invented workflow trees. The console
keeps its spoken session resume, both audio transports, terminal presentation,
and optional spoken stop, as the completed product pass concluded.

Expected effect: the web shell sheds roughly 600 lines, the console shell
roughly 900, and the duplicated turn loop stops existing.

## Recommended combination

**P1 + B1 + directive-driven device shells**, executed as slices, with the
distribution machinery deferred until there is a second box.

The reasoning: every slice below is a simplification of today's single-process
code. None of them require a remote deployment to pay off. Placement then
becomes a config section rather than a project.

## Slice order

1. **Split the former `live_audio_turn.d`.** Separate the candidate/endpoint owner, the
   final-selection owner, and the turn-stream owner. No behavior change. This is
   a prerequisite; without it the conductor lands in a file that is already too
   big.
2. **Resolve profile settings at one boundary.** Produce one settings object per
   profile and language; delete the ad hoc property-list reads in the STT, TTS,
   live-audio, startup, and codex loaders. Independently valuable — it also
   fixes the "several configuration values are not their effective rules"
   finding from the lifecycle audit.
3. **Console adopts the server speech stream.** Delete client-side segmentation
   and `feedImmediate`; `ConsoleSpeechPlayback` becomes an enqueue-URL player
   mirroring `BrowserSpeechPlayer`. One TTS architecture, and the two clients
   finally narrate the same turn. Independently valuable even if nothing else
   happens.
4. **Add `OutputArbiter` to each shell** as pure mechanism: one owner for what
   is audible now, the recovery deadline, and cancel-on-capture-restart. Web
   collapses four `AudioContext`s toward one or two; console wraps its native
   players.
5. **Move cue policy to a `cue{kind}` directive**, shaped exactly like the
   existing `thinking_music` message. All three outputs then have one policy
   owner.
6. **Name the `Listener` owner** and give it the `TranscriptAccepted` contract,
   still in-process. This is the Voice/Conversation seam, drawn but not cut.
7. **Extract the conductor.** The candidate and turn state machine emits
   directives; the live socket becomes its transport. Both shells delete their
   loops.
8. **Only when a second box exists:** add role selection and routing to run
   profiles, plus the HTTP adapter for the Conversation boundary.
9. **Then** chase milliseconds, which is step 8 of the lifecycle document.

Slices 1–7 leave one process, one behavior, and roughly 1.5–2k fewer lines
across the two shells. Slice 8 is the only one that adds machinery, and by then
its shape is determined.

## What not to do now

- Do not build remote adapters, service discovery, or health checking before a
  second physical box exists.
- Do not split `HistoryStore` as a project in its own right. Extract only the
  two ports slice 2 and slice 6 actually need.
- Do not try to make Pi remote.
- Do not generate the TypeScript protocol types from D yet. Hand-maintained
  parsers plus one protocol document is proportionate at this size; revisit if
  drift actually bites.

## Independent decisions

None of these block or depend on the above:

1. **Console package boundary.** Either move `pcm16_wav` and `segment_buffer`
   into `common/` and keep one dub package, or split a protocol package plus a
   separate console package. The second makes the dependency direction
   enforceable rather than conventional.
2. **Client-tools runner** (`console/tools/runner.d`, 416 lines) is a tool
   executor sharing a binary with a chat client. It probably wants its own mode
   or binary.
3. **Speech interrupt** is console-only and contends for the single global
   preview STT worker. Promote it to a declared capability, keep it behind a
   flag, or delete it.
4. **Remote `whisper-server` address** as a config value (variant P3). Small,
   independent, and useful for testing before any role split exists.

## Source map

Beyond the map in [Voice Turn Lifecycle](Voice%20Turn%20Lifecycle.md):

- composition root: `server/wheatleyd/source/wheatley/server/app.d` and the
  `WheatleyApi` constructor
- persistent STT workers and the localhost whisper-server hop:
  `server/wheatleyd/source/wheatley/server/stt/whisper_cpp.d`
- ad hoc profile config resolution:
  `server/wheatleyd/source/wheatley/server/history/store/package.d`
  (`effectiveConfigProperties`) and each `*/runtime_settings.d`
- Pi process boundary and reverse HTTP callbacks:
  `server/wheatleyd/source/wheatley/server/turns/text/pi_worker.d` and
  `pi_invocation.d`
- run profiles and their `shared` topology section: `run-profiles/*.json`,
  `server/wheatleyd/source/wheatley/common/runtime/run_profile.d`
