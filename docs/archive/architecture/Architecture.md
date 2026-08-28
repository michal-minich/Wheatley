# Architecture

Wheatley separates versioned application resources from private runtime data.
This document describes the current implementation. The accepted direction
for portable, hybrid, and fully offline deployments lives in
[Runtime Roles and Deployment](Runtime%20Roles%20and%20Deployment.md). Its
synchronized-session foundation, active Profile Runtime replica, unified
semantic Conversation event stream, in-process Conversation/Agent Runtime
boundary, browser/console playback reporting, remote Conversation placement,
and browser/Tauri plus console accepted-voice recovery are implemented; broader
capability placement is still incremental.

The same system is shown through ownership, dependency, deployment, transport,
state, and recovery views in [Architecture Diagrams](Architecture%20Diagrams.md).

```text
browser or console client
          |
          v
   wheatleyd HTTP API
     |      |      |
     |      |      +--> Unix socket --> launchd wheatley-codexd
     |      |                           --> continuous Codex App Server
     |      +---------> profiles, sessions, memory, presentation journal
     +--> ConversationPort --> local Pi CLI --> configured model provider
                         +--> paired wheatleyd Conversation API --> Pi CLI

voice input --> FFmpeg/Opus --> wheatleyd --> local or trusted-LAN whisper.cpp
assistant text --> Piper or Supertonic --> client playback
```

## Components

`server/wheatleyd` is the authoritative D runtime. Its `ConversationRuntime`
owns accepted-turn validation, session ordering, cancellation, agent
invocation, terminal persistence, and semantic response completion. It receives
an injected `AgentRuntime`; the current `PiAgentRuntime` adapter owns Pi
prompt/context assembly, the persistent worker registry, Pi invocation, and
Pi-specific failure evidence. The composition remains direct and in-process.
The daemon also owns API validation, speech processing, the session-local Codex
association/cache, and the durable presentation journal.

The independent `wheatley-codexd` user service owns one continuous Codex App
Server child and survives `wheatleyd`, browser, and console restarts. Each
Wheatley session is permanently paired with at most one native Codex thread;
later work creates turns in that thread and an active turn is steered in place.
`wheatleyd` uses a private Unix socket only for acknowledged dispatch and
status. Codex summaries, tools, and final answers are a durable, unspoken human
presentation lane; Pi receives only generic send acknowledgement and explicit
`codex_status` output.

Preview and final speech recognition share one `WhisperCppWorkers` port but
resolve separately to local or remote adapters. Local adapters supervise a
persistent child server on loopback. Remote adapters send the identical
multipart PCM WAV request to a fixed HTTP endpoint and include LAN/server time
in the normal STT metric; they do not own the remote process or retry on a
different placement. The active layout is the remote-Mac small preview and
large-v3 final on separate ports. Details and measurements are in
[STT Placement](STT%20Placement.md).

`client` is a TypeScript browser interface. During development, Vite proxies
its `/api` traffic to wheatleyd. Live endpoint silence comes from
`clients.web.speech_commit_delay_seconds` in the shared app config on start; changing
the delay during dictation updates the active utterance over the WebSocket.

Browser voice is half-duplex. Microphone acquisition begins concurrently with
the start cue, while endpoint teardown, the stop cue, final STT, and model work
do not wait for one another. Stopping the microphone begins a short quiet
Bluetooth recovery window shared by thinking music and speech. Audio may
download and decode during that window, but playback waits only for its
unelapsed remainder. Normal final STT and model work therefore absorb the
window without added latency. This avoids actively prolonging HFP, but Firefox
may still bind its first post-microphone output to HFP even after the quiet
window; Chrome/Chromium or a native playback owner is required when guaranteed
first-word A2DP quality matters. Automatic speech excludes the transient
thinking-status phrase. Thinking music starts at the audio endpoint for a
reasoning turn. A normal turn schedules it after the server-configured response
delay (five seconds by default) once response processing begins, and the first
response token cancels that schedule.

Voice lifecycle output now uses a single typed `voice_event` envelope shared by
browser and console. Its closed variants distinguish listening start/retry,
candidate rejection, audio/speech evidence, preview change, endpoint reached,
accepted transcript, resume choice, and failure. Localized message text is
presentation only. `WheatleyApi` composes one `VoiceRuntime`; its guarded
`VoiceSessionCoordinator` owns candidate/retry, endpoint, final transcription,
accepted transcript, response, and terminal transitions. Browser and console
capture are device adapters. One `BrowserAudioRuntime` and one
`ConsoleAudioRuntime` now arbitrate local cues, thinking music, speech, capture
cancellation, recovery, and console spoken interruption above the existing
WebAudio/native-process adapters. Thinking music remains a separate semantic
output directive. Browser/Tauri answer/reasoning WebAudio and console automatic
answer speech report queue/start/terminal facts through a narrow HTTP contract
into a process-local Voice speaking registry, with ordered bounded retries off
the audio path and stale-state reconciliation. Physical route/capture facts
remain the speaking-state seam.

The live endpoint accepts either the configured energy-silence interval or a
conservative stable-draft fallback. The latter requires both unchanged preview
text and no strong speech for at least four seconds (or the configured interval
when longer). Every automatic endpoint proceeds only when the latest normalized
draft contains meaningful text; an annotation-only or punctuation-only draft
is ignored and listening continues. Explicit client stop remains a force-submit.
Saved audio metrics identify `silence`, `draft_stable`, `client_stop`, or
`max_duration` as `endpoint_reason`.

The D console configuration produces the `wheatley` command used by the chat,
voice, one-shot, and local client-tool launchers.

`resources` contains immutable runtime inputs that belong to a release:
default configuration, prompt templates, UI audio, and the explicitly loaded
Pi extension. It always lives at `app-data/resources/`.

`app-data` contains replaceable machine-local dependencies and temporary
state: model files, Python environments, helper binaries, and build artifacts.
It is ignored by Git except for the tracked `resources/` subtree.

The private Wheatley home contains durable user data: `config.json` and
`Profiles/`. It defaults to `app-data/user`, but can live anywhere through
environment variables.

`AppConfigStore` exclusively owns the shared `config.json` path, mutation
mutex, client/voice configuration, and thinking-music rotation state.
`HistoryProfileDocuments` owns profile-root prompts, memory, and profile
`config.json`; `HistoryStore` owns the current filesystem history adapter.
`ProfileRuntime.resolveSession` is the only runtime consumer that combines app
and profile properties. It resolves profile/language policy once and hands an
immutable-by-interface `ResolvedSessionConfig` to Conversation, Voice/STT,
TTS, startup, and tool-policy adapters. The next role slices will narrow
durable history operations behind the same owner when real callers are moved.

Conversation output has one transport-independent `ConversationEvent` model:
`status`, `assistant_delta`, `reasoning`, `tool`, `completed`, and `failed`.
One in-process stream assigns profile/session identity, the canonical stored
turn ID, timestamp, and sequence. Text and uploaded-audio HTTP responses encode
it as the `conversation` SSE event; live audio wraps the identical envelope in
the `conversation_event` WebSocket message. Browser and console clients verify
identity and gap-free ordering. Before delivery, every event is flushed to the
turn-local `conversation.events.jsonl`. Required `submission_id` maps retries
to one canonical turn; `after_sequence` resumes the journal, accepted payload
reuse is validated, and terminal writes are fenced by the persisted execution
claim. An interrupted nonterminal claim becomes an ordered `ambiguous` failure
and is not rerun automatically.

For accepted live speech, the server first writes the exact selected audio as a
normalized 32 kbit/s staged `user.opus`. `transcript_accepted` exposes its
stable `runtime-user-audio:<submission_id>` key after a server-authored accepted
manifest is atomic. The manifest pins the accepted request policy and exact
audio byte count/SHA-256 before the acceptance event. Conversation moves that
same artifact into the terminal turn. A scoped download plus idempotent HTTP SSE
commit recovers a lost post-acceptance WebSocket from the manifest and
Conversation journal. Browser/Tauri persists a metadata-only IndexedDB outbox
before commit and drains it at startup/online/profile selection; it does not
duplicate the Opus. Console live voice persists the same accepted facts in its
filesystem outbox and drains them before a new capture, also without a second
audio copy.

## Paired appliance synchronization

The explicit `synced_hybrid` run profile requires
`WHEATLEY_SYNC_UPSTREAM_API_BASE`; `standalone_local` rejects it. The same
`wheatleyd` binary then runs a small periodic profile-sync loop. Completed turns are recovered
from durable history, uploaded to the upstream server through a fixed multipart
endpoint, and acknowledged under
`app-data/device-data/profile-sync/outbox/`. Voice turns are not exportable
until their required `user.opus` exists. A process restart therefore recovers
both unacknowledged turns and acknowledgement state without a second database.

The server imports by the existing relative session and turn timestamp paths.
An exact turn-path retry is a no-op; existing `session.json` and primary
`pi_session.jsonl` win, a different Pi log is preserved with a numbered name,
and each imported prompt enters automatic-memory todo once. After local uploads
succeed, the appliance downloads the server's latest complete-session manifest
and its allowlisted files, then merges missing turns into local history.
Exact local turn paths are filtered before file download, so periodic sync does
not repeatedly transfer old Markdown, JSON, or Opus audio.

After refresh, the appliance stores a SHA-256-versioned snapshot containing
effective configuration and the four server-authoritative profile documents:
`system.md`, `user.md`, `memory.md`, and `memory_auto.md`. It activates those
documents atomically only after locally exportable turns/Pi state are
acknowledged, then prunes only older fully exportable sessions with no pending
outbox work. The newest two sessions plus incomplete or unacknowledged work are
retained. With no upstream configured, Wheatley keeps its fully standalone,
local-document-authoritative behavior and performs no synchronization.

The same sync owner exposes `RemoteTurnSyncGate` around remote Conversation.
Under the periodic sync mutex it acknowledges all prior local work, rejects
incomplete/pending turns or another accepted staged prompt, and ensures the
exact session exists upstream even with zero turns. Accepted Opus is transferred
through a SHA-256/size/codec-validated idempotent import. Exact session/turn
routes materialize the selected terminal turn locally before the terminal event;
they never use latest-session selection. Repetition is idempotent, and remote
Conversation/sync configuration must use one authority.

Console text also has a separate device submission outbox. It persists the
request and replay cursor before/while streaming and replays pending entries on
restart. Console accepted voice reuses that filesystem owner for metadata and
its nonterminal replay cursor; Browser/Tauri uses a metadata-only accepted-voice
IndexedDB outbox. Both persist before the fast WebSocket commit and recover
through HTTP SSE before new capture. Neither client duplicates the server-owned
Opus or attempts to replay pre-acceptance capture.

All current execution callers address `ConversationPort`. The composition root
selects local or remote once. The remote HTTP port runs the sync gate, validates
the common SSE stream, proxies stop, projects semantic events into local TTS,
and imports exact terminal history. Remote placement requires `synced_hybrid`
and the same upstream authority as profile sync. It skips local Pi/prewarm/
session auto-memory and never silently falls back; upstream session-boundary
auto-memory remains a documented limitation.

## Provider boundary

Wheatley keeps one Pi RPC subprocess alive per active chat session and consumes
Pi's structured event stream. Consecutive turns reuse that worker; a changed
model/runtime configuration or a failed worker causes a clean restart from the
canonical persisted Pi session. Pi owns provider authentication, provider
adapters, model discovery, and the persisted model conversation. Wheatley adds
profile context, memory, voice handling, UI state, per-turn reasoning settings,
and a constrained effective tool list.

LM Studio through an OpenAI-compatible local endpoint is the tested provider.
Other Pi-supported configurations are intended to work but have not yet been
verified by this project.

## Trust boundary

The current API is a local trusted-process boundary, not a multi-user service.
Profile IDs separate data for organization but do not provide authorization.
See [SECURITY.md](../../../SECURITY.md).
