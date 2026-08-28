# Voice Turn Lifecycle

This is the living implementation map for Wheatley's voice behavior. It keeps
the current flow, accepted target lifecycle, delivered ownership slices, and
remaining gaps together so architectural refactors do not leave voice behavior
implicit.

Snapshot reviewed: 2026-08-05. The synchronized-session foundation and active
Profile Runtime replica, shared Conversation event stream,
Conversation/Agent Runtime ownership boundary, server-side durable submission/
replay contract, typed Voice protocol, server Voice coordinator, device Audio
Runtime, stable music cache, compressed disposable TTS, crash-durable live
prompt handoff, accepted-audio artifact identity, browser/Tauri accepted-voice
recovery, console accepted-voice recovery, remote Conversation placement, and
browser/console playback acknowledgements are implemented. The runtime code
remains the source of truth if this document and an implementation checkpoint
differ.

The current product behavior lives in
[Product Behavior](../../specs/Product%20Behavior.md); the structural direction
captured with this snapshot lives in
[Runtime Roles and Deployment](Runtime%20Roles%20and%20Deployment.md). The proposal
sections below preserve the voice-specific backlog at that point in time.

## Implementation ledger

### Delivered: resolved voice-session configuration boundary

`ProfileRuntime.resolveSession` now reads and merges app/profile product
configuration once for a selected profile and language and returns an
immutable-by-interface `ResolvedSessionConfig`. The live-audio WebSocket
resolves this snapshot once after its start message, before candidate capture.
Listener, preview/final STT, session-resume recognition, and response-music
delay settings are all derived from that same snapshot for the socket's life.
Uploaded-audio STT, spoken-interrupt STT, TTS, startup, Conversation settings,
and Codex tool policy use the same boundary for their own interaction.

That slice changed configuration ownership, not the voice state machine:

- it removes direct `effectiveConfigProperties` reads from Voice/STT/TTS and
  all other runtime consumers;
- it freezes profile/language product policy for a live capture connection,
  while the explicit client `configure` command can still change only the
  candidate silence delay;
- live reasoning/model policy is pinned at start so the accepted manifest can
  be durable before `transcript_accepted`; output ownership remains separate.
  `VoiceRuntime` was introduced by the later coordinator slice below.

Typed lifecycle states/events, the server coordinator, device-local output
arbitration, browser/Tauri answer/reasoning playback acknowledgements, and
console automatic-answer playback acknowledgements are delivered. Physical
route/capture acknowledgements remain a later slice.

### Delivered: one ordered Conversation event stream on SSE and WebSocket

Conversation response output no longer travels as parallel stringly event
vocabularies (`token`, `tool`, `reasoning`, `status`, `done`) in each transport.
Conversation Runtime and its Pi adapter emit typed `ConversationEvent` variants:

```text
status | assistant_delta | reasoning | tool | artifact | completed | failed
```

One `ConversationEventStream` assigns the profile/session identity, canonical
stored turn ID, timestamp, and a gap-free sequence beginning at one. SSE emits
one `conversation` event whose data is the common envelope. The live-audio
WebSocket emits the identical envelope under message type
`conversation_event`. Browser and console adapters verify profile/session,
stable turn identity, and the next exact sequence before dispatching typed
payloads. A runtime failure is now an ordered terminal `failed` event rather
than a separate transport-only error vocabulary. Voice capture/listening,
transcript, thinking-music, and device error messages remain voice protocol
events because they are not Conversation output.

Generated-image `artifact` events use that same contract on typed text,
recorded audio, and live-audio WebSocket turns. Every browser path resolves the
authorized resource URL and hands the artifact to the same in-place transcript
bubble replacement; live audio must not classify a successful artifact as an
unsupported Voice event.

The accepted-turn coordinator is now explicitly `ConversationRuntime` and its
Pi worker implementation is injected through `AgentRuntime`; voice submits the
same domain request by direct call as HTTP text/audio. This makes response
events durable and ready for direct or remote Conversation placement. A live
start now carries required `submission_id` and `after_sequence`; browser and
console currently start at zero. Once the transcript is accepted, the same
server contract persists the accepted payload, execution claim, and events as
text/uploaded audio. An interrupted accepted turn is failed visibly rather than
silently invoking Pi again. This does not resume pre-acceptance microphone
audio. Console text has a durable submission/cursor outbox, and browser/Tauri
and console live voice now have the accepted-voice outboxes described below.
`response start` is still derived from the first semantic `status` event.

### Delivered: typed Voice lifecycle event vocabulary

Capture and transcript lifecycle output now uses one closed `VoiceEventKind`
domain vocabulary and one WebSocket message type, `voice_event`:

```text
ready
listening_started | listening_retry | candidate_rejected
audio_receiving | speech_detected | preview_changed
transcript_draft_selected | endpoint_reached | transcript_accepted
session_resume_choice | failed
```

Server response helpers accept enum values rather than arbitrary lifecycle
strings. Browser and D console parse the common envelope and exhaustively
dispatch the same variants. In particular, a rejected candidate and a reached
endpoint are explicit facts; clients no longer infer them from the former
`listening_ignored` and `endpoint_detected` transport shapes. English/localized
message copy remains payload presentation, not control flow.

`thinking_music` deliberately remains a separate output directive until Audio
Runtime owns narration and audible policy. That ownership is now delivered by
the device-local arbiter slice below; Conversation output remains the separate
common `conversation_event`.

### Delivered: server Voice Runtime coordinator

`WheatleyApi` now constructs one `VoiceRuntime` beside `ProfileRuntime` and
`ConversationRuntime`; the WebSocket route delegates the entire session to it.
The former transport/turn function and its policy helpers moved out of the HTTP
and generic audio-turn namespace. `VoiceRuntime` directly owns resolved capture
policy, candidate/retry loops, endpoint and final-transcript selection, commit,
durable user-audio handoff, and the accepted call into Conversation Runtime.

Each session has one `VoiceSessionCoordinator` with guarded semantic phases:

```text
starting -> listening -> endpoint_reached -> transcribing_final
         -> transcript_accepted -> response_pending -> response_streaming
         -> completed | cancelled | failed
candidate rejection returns endpoint/final work to listening
```

Conversation events advance response pending/streaming/terminal state through
that coordinator. Illegal transitions fail immediately and the state table is
unit-tested, including reject/retry and failed response paths. Browser and
console capture remain device adapters reacting to semantic requests. Browser/
Tauri automatic speech and console automatic answer speech report observed
playback into Voice; route/capture acknowledgements remain pending. Exact local
output cancellation is owned by the Audio Runtime slice below.

### Delivered: device-local Audio Runtime arbitration

Browser/Tauri now composes one `BrowserAudioRuntime`. It is the only object that
owns the listening-chime, thinking-music, streamed speech/user-audio, and shared
output-recovery adapters. `ChatSession` sends semantic music commands to it;
`ChatSpeech` uses it as its speech-output port; live capture requests cues and
capture/release transitions through it. Beginning capture cancels local speech
and thinking music, a delayed music request cannot become audible while capture
is active, and speech/music use the same post-microphone recovery owner.

The console composition root similarly creates one `ConsoleAudioRuntime` for
text or voice mode. It owns cues, thinking music, streaming answer/tool speech,
startup/session-resume speech, and the optional spoken-interrupt monitor. Its
tested state keeps cues allowed during capture, rejects speech/music start while
capturing, cancels conflicting output when capture restarts, and deliberately
allows the existing thinking-music plus tool-progress speech overlap until the
server sends the stop directive before answer speech.

This delivers local arbitration above the current WebAudio/native-process
adapters. Browser/Tauri answer/reasoning speech and console native automatic
answer speech now report observed lifecycle through the playback contract
described below. Route/capture acknowledgements remain unwired, and narration
content is not yet unified. Browser/Tauri uses the stable cached
`MediaAssetRef` contract described below; the console still uses its
temporary-file adapter until a bounded filesystem cache is needed.

### Delivered: observed browser/Tauri and console playback lifecycle

Automatic answer and reasoning speech reports `queued`, `started`, `finished`,
`cancelled`, or `failed` using a stable output ID. `started` is emitted only
after WebAudio starts the first source; fetch, decode, and start failures become
`failed`. A narrow HTTP endpoint canonicalizes the referenced turn and feeds a
process-local registry owned by `VoiceRuntime`. Duplicate retries are
idempotent, and a newly queued output for the same session/adapter retires stale
state left by a lost terminal event. Browser delivery preserves event order and
makes three bounded attempts.

This is observed speaking state, not a durable audit log. Registry state is
lost on daemon restart and delivery may still fail after its bounded attempts.
The current browser has one synthesized-output owner per session/adapter, which
is the reconciliation assumption. Console automatic answer speech uses one
per-output serial delivery worker off the TTS/playback path, two bounded
attempts per fact, and drops later facts when a predecessor cannot be delivered.
Its `started` fact follows the first successful native-process launch. Console
tool/system speech, music, chimes, user-recording playback, durable reporting,
and physical route/capture events are outside these slices.

### Delivered: stable thinking-music asset references and browser cache

The server no longer returns selected MP3 bytes from the rotation endpoint.
`GET /profiles/:profile_id/thinking-music` returns `{asset, title, gain_db}` where
`asset` is the common `MediaAssetRef`:

```text
{ code, revision, media_type, size_bytes, sha256, url }
```

`code` is the explicit human-readable manifest catalog key, never its rotation
ordinal. `revision` changes when catalog content is intentionally replaced;
`sha256` and `size_bytes` describe the exact bytes. The separately routed
immutable asset URL supplies those bytes over ordinary HTTP.
`title` is the manifest-owned friendly track name used by client presentation;
it is never inferred from the asset code or filename.

`BrowserThinkingMusicCache` stores browser/Tauri source media in Cache Storage
by `code + sha256`, verifies byte count and SHA-256 for both downloads and cache
hits, and removes least-recently-used entries above 64 MB. This cache is only
for reusable music: generated assistant speech remains disposable, and user
speech remains durable 32 kbit/s Opus profile history. The D console consumes
the same reference but keeps its existing one-file temporary playback path;
its appliance filesystem cache is intentionally not part of this slice.

### Delivered: crash-durable live prompt acceptance and terminal cleanup

Accepted live PCM is now normalized synchronously to 32 kbit/s Opus in a
profile-local durable staging path before `transcript_accepted` is emitted. On
commit, Conversation moves that file into the turn directory before publishing
`turn.json`, so a terminal turn requiring user audio cannot race an asynchronous
attachment or survive without `user.opus`. The former in-memory/background
attachment path and its competing `turn.json` metrics write were removed.

The `transcript_accepted` payload also carries the stable
`runtime-user-audio:<submission_id>` key for that exact staged artifact. Before
the event is emitted, Voice atomically writes a submission-specific accepted
manifest containing the server-established transcript/start facts, pinned
reasoning/model policy, complete audio metadata, byte count, and SHA-256, but
never a trusted persisted path. A scoped GET serves only an
audio file with a matching accepted manifest. If the WebSocket or daemon is
lost after acceptance, a narrow HTTP SSE commit reconstructs the same canonical
`audio_live` request from that manifest, uses Conversation submission/event
replay, and still works after the first commit has moved `user.opus` into its
turn. Continuous raw microphone capture is not treated as exactly replayable.
Browser/Tauri persists a metadata-only IndexedDB entry before sending the fast
WebSocket commit. It stores no PCM or Opus copy, checkpoints only nonterminal
events, treats terminal as the deletion acknowledgement, and drains pending
entries sequentially at startup, reconnect, and profile selection through the
HTTP SSE commit. This avoids the unrecoverable terminal-cursor crash window.
Checkpoint is an atomic IndexedDB read/write transaction. If another browser
view receives terminal first and deletes the origin-shared entry, a slower
stream treats the missing entry as an already completed acknowledgement and
continues without recreating it.
Console live voice now uses the same contract in its filesystem outbox. It
persists the accepted artifact identity, canonical transcript, exact
start-pinned policy, and cursor before presentation callbacks or the WebSocket
commit. Direct WebSocket and HTTP recovery validate ready/profile/session,
stable turn identity, exact sequence, and nested completed-turn identity.
Only nonterminal events advance the cursor; terminal directly deletes the
entry. Recovery runs before a new capture and fails closed while retained work
cannot be drained. Both clients assume the same API authority that announced
acceptance remains selected; endpoint switching with pending metadata is not a
supported recovery case.

Browser capture release now emits one idempotent local release notification on
endpoint, cancellation, failure, and settlement, which always clears Audio
Runtime's capture guard. Typed text sent through the live route now enters
`response_pending` before it observes Conversation events. Disposable generated
assistant Opus files are swept at daemon startup in addition to their normal
consume/cancel deletion.

The daemon starts under an explicit `standalone_local` or `synced_hybrid`
deployment composition and independently selects local or remote Conversation
once. Voice capture, Whisper STT, Audio Runtime, and configured Wheatley TTS
remain local to this daemon; only accepted Conversation execution moves.
The read-only offline readiness probe checks local prerequisites and health but
does not satisfy the physical WAN-disabled end-to-end voice gate.
Conversation callers now address an explicit `ConversationPort` selected once
at startup. Remote placement runs the Profile-owned exact-session/turn gate,
uploads accepted normalized Opus through an idempotent hash/size/codec-validated
multipart boundary, streams the common Conversation SSE events, proxies stop,
and projects answer/reasoning/tool speech into the local narration registry.
The exact terminal turn and artifacts are imported before terminal exposure.
It never changes placement or falls back mid-turn. Remote startup deliberately
skips local Pi availability, prompt prewarm, and session auto-memory; upstream
session-boundary auto-memory/prewarm remains unavailable until there is a narrow
exact-session preparation command rather than reuse of the UI startup stream.

## Why this exists

The following inventory records the pre-refactor baseline. The implementation
ledger above is authoritative for delivered ownership: server Voice
coordination and client-local Audio arbitration are no longer distributed in
the way this baseline describes, while platform capture/playback adapters and
narration-content policy still differ.

Voice behavior is currently distributed across:

- the browser session coordinator and four browser audio owners;
- the console voice loop, native capture, native playback, and optional speech
  interrupt monitor;
- the shared live-audio WebSocket server;
- preview and final STT policy;
- the Pi turn runtime and its streamed events;
- two different streaming-TTS orchestration paths;
- configuration text that is sometimes presentation and sometimes effectively
  control flow.

The result works, but a complete turn cannot be understood from one owner. The
same concepts—listening, endpoint, retry, thinking, response start, speech, and
stop—are inferred independently in multiple places. This makes collisions and
latency regressions likely after small local changes.

## Executive findings

1. **The server owns audio interpretation and final turn acceptance.** It owns
   VAD, draft scheduling, endpoint selection, final STT, draft-versus-final
   selection, ignore/retry, persistence, and Pi invocation.

2. **The clients own physical capture and output, but also duplicate workflow
   policy.** Both decide when cues, music, and speech should start. The browser
   uses event types plus local flags; the console also uses exact English status
   strings.

3. **There are two client trees, not two profile behaviors.** Profiles select
   language, model, tools, voice, and server thresholds. Web and console then
   impose materially different orchestration on those settings.

4. **Browser output has three independent owners.** Listening chimes have one
   `AudioContext`; thinking music has another; speech has another. Music and
   speech share `BrowserOutputRecovery`, but chimes do not. Capture has a fourth
   context and closes independently.

5. **Bluetooth accounts for much of the reported roughness; the post-submit
   shriek is not present on the Mac's built-in microphone and speakers.** The
   browser stop cue still plays immediately after microphone release, outside
   the 2.5-second recovery gate, and its WAV ends at a non-zero sample. Keep it
   as a Yealink/device-specific hypothesis, not a current application-wide
   defect or an early implementation priority.

6. **Retry after an ignored final is the clearest workflow collision.** Both
   clients may start thinking music at the endpoint before final STT decides
   whether the candidate is accepted. If the server rejects it and resumes
   listening, console music can keep playing into the new capture. Browser
   music can become suspended, resume during capture, or be impossible to
   schedule correctly for the retried candidate.

7. **Several configuration values are not their effective rules.** Normal
   preview transcription has hard-coded floors of 0.8 seconds despite default
   config values of 0.5 and 0.2 seconds. Browser and console endpoint delay both
   come from shared `clients.web.speech_commit_delay_seconds` on live start. Remaining
   client-specific audio policy lives under `clients.web.*` (output recovery and
   thinking-music fades).

8. **The two TTS paths share segmentation code but not content or timing
   policy.** Browser auto-speech speaks answer content only. Console speech also
   injects canned tool-progress phrases. Browser and console therefore do not
   audibly present the same turn.

9. **Draft display and speech acceptance are now intentionally separate.** Both
   clients receive the same complete assembled small-model draft—confirmed
   stable prefix plus mutable tail—including sound annotations. The shared
   server removes paired `[...]`, `(...)`, `*...*`, and `**...**` spans
   before endpoint or commit policy. Only empty cleaned text is currently rejected;
   the former English phrase list remains commented out, so `okay` and `thank
   you` are treated as possible real speech.

10. **Recognized short speech no longer falls into the four-second fallback.**
    Recent saved turns showed normal endpoint lag of about one second, but
    `Debris?`, `Okay, next.`, and `And one more.` accumulated only 0.32–0.44
    VAD voice seconds against the 0.45-second minimum and therefore waited
    4.35–4.50 seconds. A meaningful cleaned draft now supplies the missing
    speech evidence and uses the configured silence delay; ambiguous/noisy
    cases retain the conservative stable-draft path.

## Vocabulary

```text
candidate
    One attempt to capture an utterance inside a live WebSocket.
    A candidate may be discarded and listening may continue.

endpoint
    The moment capture is stopped for a candidate because of energy silence,
    stable draft, explicit client stop, or maximum duration.

display draft / preview
    Full assembled small-model transcription sent to live UI: an immutable
    confirmed prefix plus the current mutable tail, including sound annotations
    and phrases that may later be rejected.

speech draft
    Display draft after paired sound/action annotations are removed and common
    silence hallucinations are rejected. Used for early resume choice,
    stable-draft endpointing, and limited final fallback.

final transcript
    Large-model transcription produced after an endpoint.

accepted transcript
    The text selected after comparing final STT, accepted draft, typed text,
    endpoint reason, voice evidence, and final coverage.

commit
    Client acknowledgement after displaying the accepted transcript. It
    carries the final model and reasoning choice. Pi does not start before it.

response start
    Currently inferred from the first Conversation `status` event, normally
    code `api_text_pi_started`; it is not a dedicated voice event.
```

## Canonical configuration ownership

The server flattens the application config and then the profile config through
`AppConfigStore` plus profile-root documents. Profile values override
application values. Browser UI and voice timing prefs live in the same app
`config.json` (`voice`, `clients.<id>`, `profiles.<id>`) via `/api/config/*`
and do not use a separate local store.

Current release defaults relevant to voice are:

```pseudo
SERVER_AUDIO_DEFAULTS = {
    sample_rate:                    16_000,       // fixed in code
    channels:                       1,            // fixed in code
    vad_threshold:                  0.010,
    min_speech_seconds:             0.45,
    silence_seconds:                from speech_commit_delay_seconds on start,
    max_wait_seconds:               30.0,
    pre_roll_seconds:               0.25,
    trailing_silence_keep_seconds:  1.0,
    max_utterance_seconds:          600.0,
    partial_transcript_interval:    0.5,
    partial_transcript_min_audio:   0.2,
}

BROWSER_DEFAULTS = {
    audio_transport:                pcm_s16le_16k_mono_20ms,
    socket_drop_threshold:          256 KiB bufferedAmount,
    speech_commit_delay_seconds:    clients.web.speech_commit_delay_seconds, // on live start
    output_recovery_ms:             clients.web.output_recovery_ms,     // 2_500
    thinking_music_fade_in_ms:      clients.web.thinking_music_fade_in_ms,
    thinking_music_fade_out_ms:     clients.web.thinking_music_fade_out_ms,
    normal_music_delay_ms:          runtime.response_music_delay_ms,    // 5_000
    auto_speak_for_new_profile:     false,
}

CONSOLE_DEFAULTS = {
    audio_transport:                pcm_s16le,     // launchers commonly choose Opus
    endpoint_delay:                 clients.web.speech_commit_delay_seconds from config.json,
    normal_music_delay_ms:          5_000,
    speech:                         enabled,
    speech_interrupt:               disabled,
    playback_prebuffer_chunks:      2,
    playback_prebuffer_max_wait:    0.35 seconds,
}
```

Language chooses STT language and TTS overrides. In the default config:

```pseudo
if language == "en":
    STT language = "en"
    TTS = Piper, Daniel, en_GB-alan-medium
    Piper length_scale = 0.85

if language == "sk":
    STT language = "sk"
    TTS = Supertonic, M2
    Supertonic speed = 0.95
    Supertonic steps = 12
```

Relevant owners:

- merge and profile values: `server/history/store` and
  `server/profiles/config_properties.d`;
- audio settings: `server/turns/audio/live_audio_settings.d`;
- STT settings: `server/stt/runtime_settings.d`;
- TTS settings: `server/tts/runtime_settings.d`;
- shared voice and client config in app `config.json`:
  `/api/config/clients/:client_id`, `/api/config/clients/:id`, and browser adapter
  `client/src/app/ClientConfig.ts`;
- console flags/environment: `client/console/config.d`.

## Shared server tree

Both clients use the same live-audio WebSocket and the same turn runtime.

```pseudo
function live_audio_socket(route_profile, websocket):
    start = REQUIRE_FIRST_TEXT_FRAME_IS_START_REQUEST()
    session = BEGIN_ACTIVE_SESSION_USE(route_profile, start.session_id)

    settings = LOAD_MERGED_PROFILE_AUDIO_STT_SETTINGS(
        profile = route_profile,
        requested_language = start.language,
    )
    if purpose == turn:
        settings.silence_seconds = start.silence_seconds  // speech_commit_delay_seconds

    if start.purpose == SESSION_RESUME:
        settings = OVERRIDE_FOR_SHORT_YES_NO_CHOICE(settings)

    decoder = CREATE_DECODER(start.audio)

    EMIT ready(
        preview_model = settings.preview_stt.model,
        configured_silence_seconds = settings.silence_seconds,
    )
    EMIT status(kind=listening_started, message=localized speech.live.listeningStarted)

    if purpose != SESSION_RESUME:
        prompt_prewarm = MAYBE_START_PREWARM(...)
        // Current defaults disable it.

    while websocket.connected:
        candidate = NEW_CANDIDATE_STATE(settings)
        draft = NEW_PREVIEW_TRANSCRIBER(settings, shared_whisper_workers)

        while not candidate_ended:
            incoming = POLL_OR_RECEIVE(250 ms)

            if incoming.configure:
                REQUIRE silence_seconds is integer 1..12
                candidate.SET_SILENCE_SECONDS(incoming.silence_seconds)
                continue

            if incoming.stop:
                decoded = decoder.FINISH()
                ACCEPT_DECODED_AUDIO(decoded)
                finish_requested = true
                break

            if incoming.audio:
                decoded = decoder.ACCEPT(incoming.bytes)
                ACCEPT_DECODED_AUDIO(decoded)

            if poll_timeout:
                decoded = decoder.DRAIN()
                ACCEPT_DECODED_AUDIO(decoded)

            // ACCEPT_DECODED_AUDIO performs, in order:
            // 1. VAD/sample accumulation
            // 2. first receiving/speech statuses
            // 3. preview job submission
            // 4. completed-preview polling and emission
            // 5. no-speech timeout check

            if purpose == SESSION_RESUME and speech_draft maps clearly to YES or NO:
                EMIT endpoint(kind=endpoint_detected, message="Session choice detected.")
                EMIT session_resume_choice(choice, speech_draft)
                RETURN

            if purpose != SESSION_RESUME and STABLE_DRAFT_ENDPOINT_REACHED():
                endpoint_reason = DRAFT_STABLE
                break

            if candidate.energy_endpoint_reached:
                endpoint_reason = candidate.maximum_duration
                    ? MAX_DURATION
                    : SILENCE
                break

            if candidate.no_speech_timeout:
                EMIT listening("No speech detected; still listening.")
                DISCARD_CANDIDATE_AND_CONTINUE_OUTER_LOOP

        if websocket disconnected:
            RETURN

        draft.SEAL()                       // pending results are no longer accepted
        accepted_speech_draft = draft.accepted_text

        if no captured samples and start.text exists:
            EMIT endpoint("Listening stopped; typed prompt will be sent.")
            EMIT final_transcript(text="", user_text=start.text)
            STREAM_TEXT_TURN_WITH_START_POLICY()
            RETURN

        if no captured samples:
            EMIT error("No live speech was captured.")
            RETURN

        EMIT endpoint(message_for(endpoint_reason))
        endpoint_time = NOW()
        final_samples = candidate.samples_through_trailing_silence_limit

        if purpose == SESSION_RESUME:
            preview_result = SMALL_STT(final_samples)
            choice = MAP_TO_YES_NO(preview_result)
            if choice == UNCLEAR:
                final_result = LARGE_STT(final_samples)
                choice = MAP_TO_YES_NO(final_result)
            EMIT session_resume_choice(choice, transcript)
            RETURN

        final = LARGE_FINAL_STT(final_samples, prompt=start.text)
        selected = SELECT_FINAL_TRANSCRIPT(
            final,
            accepted_speech_draft,
            typed_text=start.text,
            candidate.voice_seconds,
            final_audio_seconds,
        )

        if selected.used_draft:
            EMIT listening(explanation_of_fallback)

        if selected.ignore:
            EMIT listening("Ignored unclear speech; still listening.")
            DISCARD_CANDIDATE_AND_CONTINUE_OUTER_LOOP

        EMIT final_transcript(
            transcript_text = selected.transcript,
            user_text = selected.combined_user_text,
            language = final.language,
        )

        commit = WAIT_FOR_CLIENT_COMMIT()
        // stop/configure messages are ignored while waiting for commit.

        BEGIN_PERSISTING_USER_PCM_AS_OPUS_ASYNC()
        STREAM_TEXT_TURN(
            text = selected.combined_user_text,
            model = commit.model,
            reasoning = commit.reasoning_mode,
            started_at = endpoint_time,
            accepted_turn_start = endpoint_time,
        )
        RETURN
```

### Server VAD rules

The VAD is block RMS, not a separate model.

```pseudo
start_threshold = max(
    0.001,
    config.vad_threshold,             // default 0.010
    0.020,
    noise_floor * 2.5 if known,
)

if speech has started and noise floor is not known:
    continue_threshold = max(0.001, config.vad_threshold)
else:
    continue_threshold = max(
        0.001,
        config.vad_threshold * 0.6,
        0.006,
        noise_floor * 1.35 if known,
    )

block_is_voice = block_rms >= current_threshold

if first voice block:
    started = true
    prepend up to pre_roll_seconds of previous non-voice audio

if voice block:
    voice_seconds += complete_block_duration
    last_voice_sample = end_of_block
    last_voice_monotonic_time = now

energy_endpoint =
    started
    and has_last_voice
    and voice_seconds >= min_speech_seconds
    and silence_since_last_voice >= current_silence_seconds

maximum_duration_endpoint =
    started
    and utterance_duration >= max_utterance_seconds
```

Consequences:

- Voice duration is the sum of complete blocks classified as voice; it is not
  the continuous span from first to last voice.
- The default minimum is 0.45 seconds. A real short utterance can produce a
  visible draft yet never satisfy the energy endpoint. A meaningful cleaned
  speech draft now permits the transcript-backed short-speech endpoint below.
- Changing the browser delay while speaking immediately changes the active
  candidate and can make `endpointReached` true on the next check.
- Saved final samples retain:

  ```pseudo
  max(
      trailing_silence_keep_seconds,
      min(current_silence_seconds, 2.0),
  )
  ```

  after the last voice frame. The selected endpoint delay therefore also
  changes how much trailing audio reaches final STT, up to two seconds.

### Draft scheduling and acceptance

Normal live draft settings have code floors that override smaller config
values:

```pseudo
NORMAL_PREVIEW_INTERVAL = max(0.8, configured_interval)
NORMAL_PREVIEW_MIN_AUDIO = max(0.8, configured_min_audio)
PREVIEW_VOICE_GRACE = max(2.0, trailing_silence_keep_seconds)

SESSION_RESUME_PREVIEW_INTERVAL = max(0.2, configured_interval)
SESSION_RESUME_PREVIEW_MIN_AUDIO = max(0.15, configured_min_audio)
```

A preview job is eligible only if:

```pseudo
candidate has mutable preview samples after stable_end_sample
and current_silence <= preview_voice_grace
and mutable_preview_audio >= effective_min_audio
and preview_end_sample != last_submitted_end_sample
and effective_interval elapsed since last submission
```

Only the newest pending job is retained by one candidate transcriber. An
in-flight job is not cancelled. All candidates and clients share one persistent
small-model server worker, so actual model inference is globally serialized.

The preview worker transcribes only the mutable audio window from
`stable_end_sample` through the newest submitted sample. It asks Whisper for
timed text pieces and supplies at most the last 75 stable words as context. The
first preview therefore covers the utterance so far; after a confirmed split,
earlier audio is never submitted to draft STT again.

A boundary can move into the immutable prefix only when all of these hold:

```pseudo
candidate stable chunk >= 2.5 seconds and >= 5 words
remaining mutable tail >= 20 seconds and >= 35 words
same whitespace-normalized complete prefix appears in two consecutive
    applied preview results
boundary is a returned timed-text boundary

prefer sentence punctuation: . ? ! …
after a 50-second mutable window, also allow: , ; : — – -
after a 70-second mutable window, allow a timed word boundary
```

The returned boundary time advances `stable_end_sample`; it is never derived
from a character ratio, and the cut is never made inside a returned word/token.
Confirmation can let the observed window exceed a threshold by one or more
preview intervals. The stable prefix remains unchanged for the rest of the
candidate while only the tail can be revised.

Each completed preview produces two independently changed values:

```pseudo
raw_mutable_tail = trim(raw_whisper_text)
display_text = trim(join(stable_prefix, raw_mutable_tail))
speech_text = trim(collapse_whitespace(remove_paired_annotations(display_text)))

remove_paired_annotations removes:
    [ ... ]
    ( ... )
    * ... *
    ** ... **

if display_text changed exactly:
    emit the complete display_text to both web and console draft UI

if normalized speech_text changed
and speech_text is not empty:
    accept the complete speech_text for endpoint, resume choice, and final fallback
```

Both clients continue to receive one complete preview string; neither client
must reconstruct or merge segments. Final STT remains independent: after the
endpoint, large-v3 receives the complete accepted recording, regardless of how
many draft splits occurred.

Only complete pairs are removed; an unmatched opener is preserved. Removing a
span inserts a word boundary, then all whitespace is collapsed. Thus
`Hello [door opens] there` becomes `Hello there`, while
`[playing music] *clears throat* (click)` becomes empty and cannot count as
speech. A later annotation-only preview does not erase the candidate's last
meaningful accepted speech draft.

After cleanup, only empty normalized text is currently classified as no
speech. The former English phrase block—`you`, `okay`, `thank you`, subtitle
credits, and similar—is retained as a comment beside
`isKnownNormalizedNoSpeechTranscript` but is disabled. Those words therefore
remain visible and may be accepted as real speech. `speechTextFromTranscript`
is the authoritative active cleanup rule.

### Transcript-backed endpoints

These are fallbacks beside energy silence, not part of `LiveAudioTurnState`.

A normal live turn also recognizes terminal `submit` as an explicit spoken
endpoint. Detection uses complete cleaned preview text, compares the final word
case-insensitively after trailing `.` and `!` are removed, and requires a
nonempty prompt before the command. The default
`audio.spoken_submit.confirmation_count` is `2`; only distinct completed preview
inferences count, while a nonmatching inference resets the count. On acceptance,
Voice records endpoint reason `spoken_submit`, removes the command from preview
fallback and final STT text, and otherwise follows the same final-transcription
and durable-turn path as client Submit. Session-resume recognition is excluded.

```pseudo
strong_voice_now = latest_block_rms >= current_start_threshold

remember time of:
    every strong voice block
    every newly accepted/changed speech draft

if accepted speech draft exists
and at least one strong voice block exists
and current block is not strong voice
and accumulated voice < min_speech_seconds
and time since last strong voice >= current_silence_seconds:
    endpoint reason = recognized_short_speech

otherwise:
    stable_for = max(4.0 seconds, current_silence_seconds)

stable_draft_endpoint =
    at least one accepted speech-draft change exists
    and at least one strong voice block exists
    and accumulated voice >= min_speech_seconds
    and current block is not strong voice
    and time since last draft change >= stable_for
    and time since last strong voice >= stable_for
```

The short-speech path treats cleaned STT as additional speech evidence, so a
valid one-word question does not wait four seconds merely because block RMS
counted 0.32 instead of 0.45 seconds. Annotation-only drafts never reach this path. Non-empty phrases such as
`thank you` currently do, because the former phrase filter is disabled. The stable path remains for cases where low HFP
background prevents ordinary energy silence.

Before any automatic endpoint proceeds to final STT, the latest displayed
draft is stripped of sound annotations and normalized. An empty result ignores
the candidate and continues listening. This shared gate covers energy silence,
recognized short speech, stable-draft fallback, and maximum duration. Explicit
client stop—Manual Submit—and session-resume recognition bypass it.

### Final STT and final-selection rules

The server owns two lazy persistent workers for its lifetime:

```pseudo
preview_worker:
    model = small
    one request at a time

final_worker:
    model = large-v3
    one request at a time

for either worker:
    fingerprint = server executable + model path
    start lazily on first request
    retry once after non-client/process failure
    replace if fingerprint changes
    stop during wheatleyd shutdown
```

Default normal final request:

```pseudo
language = requested language, otherwise auto-detected language
beam_size = 3
max_context = 0
timestamps = enabled
prompt = typed text, if the live start request contained any
```

Final selection is:

```pseudo
if audio_duration > 30 seconds
and final STT covered at least 5 seconds less than captured audio
and accepted speech draft has at least 4 words:
    use speech draft

else if accepted speech draft has >= 4 words
and (
    cleaned final is empty
    or (
        cleaned final has <= 3 words
        and draft has >= final_words + 4
        and (voice_seconds < 0.8 or voice/audio ratio < 0.15)
    )
):
    use speech draft

else if cleaned final is empty:
    ignore candidate and resume listening

else:
    use cleaned final
```

Final text passes through the same paired-annotation removal as drafts before
selection. Explicit client Send controls only the endpoint reason; it no longer
authorizes empty annotation text to commit. This keeps manual and automatic endpoints consistent.

Typed and audio text combine as:

```text
<typed text>

Audio transcript:
<selected transcript>
```

when both exist.

## Web client tree

The browser supports text and continuous live listening. Live listening owns
the cue/draft/endpoint/music/recovery path.

### Web startup and session

```pseudo
ChatApp.start:
    parallel load profiles + model catalog
    select saved available profile and model
    load profile startup state
    construct ChatRuntime and ChatSession
    open recent-chat home

new/resumed chat:
    POST startup stream(mode="chat", model=current_model)
    on opened:
        set session ID
        load saved turns if resumed
        phase = PREPARING
    startup system events:
        parsed by WheatleyApi for shape
        ignored for browser control flow
    on done:
        preparation_complete = true
        phase = READY
```

Browser startup does not ask a spoken yes/no resume question. It shows recent
sessions and lets the user choose one.

### Web continuous live listening

```pseudo
user presses live microphone:
    stop current speech
    unlock/prepare speech output if auto-speak is enabled
    preload listening cues
    prepare thinking music and register its context for output recovery
    live_mode = true

    while live_mode and same profile/session generation:
        create local provisional turn ID
        snapshot:
            profile, session, device, language,
            requested reasoning mode, current model

        phase = REQUESTING_LIVE_MICROPHONE
        open WebSocket

        on socket open:
            SEND start(
                PCM16, 16 kHz, mono, 20 ms,
                load_memory=true,
                purpose="turn",
                prewarm_existing_session=true,
            )
            SEND configure(browser_global_delay_1_to_12_seconds)

        on ready:
            do nothing

        on listening_started/listening_retry/candidate_rejected voice event:
            if ignored: remove visible draft
            if capture not already active:
                FIRE_AND_FORGET start cue
                REQUEST getUserMedia immediately
                create capture AudioContext + AudioWorklet
                connect worklet through zero-gain node to destination
                send PCM frames while:
                    socket open
                    and socket.bufferedAmount < 256 KiB
                otherwise silently drop that frame
                after capture resolves:
                    suspend registered speech/music output contexts
                    phase = LIVE_LISTENING

        on preview transcript:
            update temporary user draft bubble

        user presses Send while listening:
            phase = LIVE_TRANSCRIBING
            synchronously stop media tracks and disconnect capture graph
            begin capture AudioContext.close(), do not await it
            start 2.5-second speech/music recovery deadline
            FIRE_AND_FORGET stop cue
            SEND stop command

        on server endpoint:
            listening = false
            synchronously stop media tracks and disconnect capture graph
            begin capture AudioContext.close(), do not await it
            start 2.5-second speech/music recovery deadline
            if initially requested reasoning is ON:
                request music now
            phase = LIVE_TRANSCRIBING
            FIRE_AND_FORGET stop cue if not already played

        on final transcript:
            choose user_text when non-empty, otherwise transcript text
            replace temporary draft with committed user message
            keep the model and reasoning mode captured at live start
            phase = STREAMING
            durably persist accepted metadata in IndexedDB
            SEND commit(start model, start reasoning)

        on first text-turn status event:
            mark response_started
            if effective reasoning OFF:
                schedule music for the server-provided response delay
            if auto-speak:
                begin answer speech stream for provisional turn ID

        on first or later assistant token:
            fade music out over 0.2 seconds / cancel pending music
            append token to transcript

        on tool:
            update activity/tool presentation
            do not stop music
            feed short spoken_message into automatic speech

        on reasoning:
            update reasoning presentation

        on done:
            stop music
            finalize turn and replace provisional ID with stored ID
            wait until automatic speech becomes idle
            start the next live-listening candidate/turn
```

### Browser cue behavior

Browser cues use unmodified release WAVs through a dedicated context:

```pseudo
prepare:
    resume then suspend cue AudioContext
    fetch/decode start and stop buffers

play:
    resume cue AudioContext
    increment active playback count
    play raw AudioBuffer to destination
    when source ends:
        decrement active playback count
        if no other cue is active:
            suspend cue AudioContext immediately
```

Important details:

- The start cue and microphone acquisition now begin concurrently. The cue can
  continue after microphone frames are already being transmitted.
- This overlap is intentional product behavior: the user may speak immediately
  and over the cue. Console alignment should preserve the same latency property
  instead of waiting for its padded cue to finish.
- Start and stop cues can overlap if an endpoint arrives unusually quickly.
- Cues are not registered with `BrowserOutputRecovery`.
- The stop cue therefore plays during the Bluetooth recovery window rather
  than after it.
- Cue playback errors are logged but never fail the turn.

### Browser output recovery, music, and speech

Speech and music share one recovery object, but retain separate contexts and
players.

```pseudo
on capture start:
    clear prior recovery window
    suspend all registered speech/music contexts

on local microphone track release:
    recovery.ready_at = now + 2_500 ms
    suspend all registered speech/music contexts

before music or speech source start:
    fetch and decode may happen immediately
    wait only for remaining recovery time
    if recovery window changed while waiting:
        recursively evaluate the newest window
    resume that output context
```

Music policy:

```pseudo
reasoning turn:
    request looping music at endpoint

normal turn:
    on first text-turn status, request music after server-configured delay

first assistant token:
    cancel delayed music or fade active music to zero over 0.2 seconds

track selection:
    per-profile round-robin index at profiles.<id>.thinking_music_index
    return MediaAssetRef { code, revision, media_type, size_bytes, sha256, url }
    browser verifies and Cache-Storage-caches by code + sha256 (64 MB LRU)
    manifest master gain + per-track gain
    fade in/out from clients.web.thinking_music_fade_*_ms
```

Automatic speech policy:

```pseudo
start speech request on first text-turn status, before answer text exists
source = answer
include_reasoning_status = false

server waits for active or stored answer source
server segments answer deltas
server synthesizes segments sequentially
browser fetches and decodes segment files sequentially
browser queues decoded buffers and plays them serially
each buffer may start only after output recovery allows it
```

The shared segmenter emits:

```pseudo
first segment:
    first sentence boundary after >= 6 words
    otherwise first clause boundary after >= 6 words

following segments:
    sentence/newline boundary after >= 14 words

on completion:
    flush all remaining text as one final segment
```

Before TTS, Wheatley strips double asterisks and paired single-asterisk emphasis
markers whose opening and closing markers touch their content. Unpaired,
escaped, list-bullet, and spaced multiplication asterisks remain. It also strips
Markdown heading markers at line starts, trims, and collapses three or more
trailing full stops to one. It does not generally convert Markdown to natural
speech.

### Returned assistant speech

Each automatic-speech segment still travels as an ordinary temporary HTTP
artifact reference. The configured Piper or Supertonic voice synthesizes a
server-temporary WAV, which is encoded as Ogg/Opus at the resolved
`tts.assistant_opus_bitrate_kbps` (24 kbit/s by default; bounded 16–32) before
the browser/Tauri or console downloads it. Browser/Tauri decode that artifact
with their existing `AudioContext` player; the console gives an Opus-capable
playback command (ffplay by default) a disposable `.opus` file. The server deletes the artifact
after GET and the console removes its local temporary file after playback or
cancellation. This has no bearing on voice-input fidelity: an accepted spoken
prompt continues to be normalized and stored as 32 kbit/s `user.opus`.

### Web text turn

```pseudo
commit user text immediately
compute reasoning from toggle or leading "think"
start automatic answer speech stream immediately
stream Pi token/tool/reasoning events
no thinking music
```

## Console client tree

The console run profile selects `chat`, `voice`, or `client-tools`. The full
voice tree is below; text-mode differences follow it.

### Console voice startup and resume

```pseudo
resolve ffmpeg and playback helpers
construct native cue settings
construct native looping music player
print microphone and audio transport details
load profile startup state

if today's last session is resumable:
    repeat:
        write and synchronously speak configured resume prompt
        open a purpose=session_resume live WebSocket
        on semantic listening_started:
            start FFmpeg capture
            begin preview line and play the start cue concurrently
        server uses short-choice settings and preview-first yes/no mapping
        on semantic endpoint_detected:
            synchronously play padded stop cue
        if unclear:
            speak configured unclear prompt and repeat
        else choose resume/new

stream profile startup(mode="voice"):
    display model selection, tool list, and memory events
    speak memory-update-start asynchronously when speech is enabled
    do not speak normal model/tool startup messages
```

Session-resume server overrides are:

```pseudo
min_speech_seconds = 0.15
silence_seconds = 0.8
max_wait_seconds = 10
trailing_silence_keep_seconds = 0.3
max_utterance_seconds = 5
partial_transcript_interval_seconds = 0.2
partial_transcript_min_audio_seconds = 0.15
short_choice_recognition = true
```

Configured yes/no words and alternate answers are language-specific. The
default English negative alternates deliberately include common Whisper
confusions such as `now` and `know`.

### Console continuous voice turn

```pseudo
while requested turn count is unlimited or not reached:
    provisional turn ID = console-audio-live-UUID
    request policy = {
        session, profile, device, language,
        load_memory,
        reasoning_mode = startup session reasoning mode,
        model = empty -> server/session model,
        audio = launcher-selected PCM or Ogg/Opus,
        prewarm_existing_session = true only for first resumed turn,
    }

    create streaming speaker now
    open live WebSocket and SEND start

    on ready:
        ignore

    on semantic listening_started:
        start FFmpeg capture
        print listening notice and play padded start cue concurrently

    on other retry-listening status:
        if capture is absent, start capture immediately
        call status handler after capture starts

    FFmpeg capture:
        PCM: raw 16 kHz mono chunks sized by frame_ms
        Opus: libopus, selected bitrate/frame/complexity, Ogg pages flushed
        send every produced chunk over WebSocket
        optional test throttle

    on preview:
        render temporary line unless [BLANK_AUDIO] or any wrapped []/() marker

    on endpoint:
        synchronously stop and join FFmpeg capture
        mark user stop time
        synchronously play padded stop cue
        if request reasoning was ON:
            start native looping music

    on final transcript:
        choose user_text else transcript
        render final unless empty or exactly [BLANK_AUDIO]
        keep the reasoning/model policy pinned in the live start
        durably persist accepted metadata in the console outbox
        create optional speech-interrupt monitor
        client library SENDS commit(request.reasoning, request.model)

    on first text-turn status after final:
        if non-reasoning and music not scheduled:
            schedule native music for server-provided response delay

    on token:
        stop music immediately
        print streamed answer
        feed token into client-side TTS segmenter

    on tool start:
        display tool progress
        choose spoken_message when present, otherwise display message
        feed that canned phrase immediately into TTS queue
        do not stop music

    on reasoning event:
        current voice runner installs no handler

    on done:
        stop music
        if no streamed tokens but final assistant text exists:
            display/feed final assistant text
        finish TTS input and block until preparation/playback tasks finish
        stop speech-interrupt monitor
        post capture/TTS/client timing metrics best-effort
        proceed to next voice turn
```

### Console cue behavior

Console uses the same source WAVs but creates a temporary padded WAV for every
playback:

```pseudo
start cue = 0.50 s silence + 0.36 s cue + 0.00 s trailing silence
stop cue  = 0.12 s silence + 0.46 s cue + 0.24 s trailing silence
```

Playback is synchronous. Cue errors are swallowed. The start cue ends before
capture starts, and the stop cue ends before endpoint handling continues. This
is the opposite of the browser's concurrent cue policy.

### Console thinking music and speech

Music is a native child process (`wheatley-audio-player`, or FFplay on
Windows), not part of speech playback. `playAfter` is a detached task guarded
by a generation counter; `stop` invalidates delayed requests and kills the
active player.

Console streaming speech uses the same `TtsSegmentBuffer` as browser speech but
a different pipeline:

```pseudo
tokens and canned tool phrases
    -> client-side segment buffer
    -> one prepare task calls POST /tts sequentially
    -> prepared-file queue
    -> one playback task
    -> native playback owner

playback waits for 2 prepared chunks when possible,
but no more than 0.35 seconds before starting.
```

Tool phrases bypass the segment buffer through `feedImmediate`; each becomes a
standalone synthesized chunk. Music and speech are separate processes and may
play simultaneously.

### Optional console speech interrupt

The spoken stop monitor exists only when all are true:

```pseudo
console voice mode
and speech enabled
and --speech-interrupt / WHEATLEY_SPEECH_INTERRUPT=yes
and final transcript has been committed
```

Console run profiles configure enablement (`speech_interrupt`) and the required
`speech_interrupt_phrases` list. The default accepts `stop speaking`, `stop`,
and repetitions. Profile/language-resolved phrases remain future shared Voice
policy rather than a hardcoded monitor rule.

It opens a second FFmpeg microphone capture while assistant playback is
possible. During playback it:

1. calibrates playback leakage for 600 ms;
2. detects a sound onset from RMS thresholds;
3. pauses assistant playback;
4. requires persistent sound after five settling frames;
5. records until silence or four seconds maximum;
6. sends the candidate to the server's preview Whisper worker with a three
   second request timeout;
7. accepts `stop`, repetitions of `stop`, and `stop speaking` variants;
8. cancels speech and posts turn stop on a match, otherwise resumes playback.

This path shares the one global preview STT worker. Queue wait before acquiring
that worker is not bounded by the three-second HTTP request timeout.

### Console text

Console text does not use thinking music. A leading `think` enables reasoning
for that turn. Reasoning deltas print under the assistant-colored profile
prefix (`wheatley>`) with gray text—no separate `thinking>` label. Streamed answer
tokens and short tool-progress speech use the same console streaming speaker.

Non-streaming text waits for the final answer and synthesizes it as one file.

## Web versus console behavior matrix

| Concern | Web live | Console voice |
| --- | --- | --- |
| Capture | Browser AudioWorklet PCM only | FFmpeg PCM or Ogg/Opus |
| Backpressure | Silently drops frame above 256 KiB socket backlog | Sends all produced chunks; optional test throttle |
| Endpoint delay | Shared `speech_commit_delay_seconds` on live start as `silence_seconds` | Same preference on live start as `silence_seconds` |
| Start cue | Raw cue, fire-and-forget, overlaps capture | Padded native cue, overlaps already-started capture |
| Stop cue | Raw cue, fire-and-forget, bypasses output recovery | 0.12/0.24 s padded cue, blocking |
| Output recovery | 2.5 s gate for music and speech only | No shared recovery gate |
| Draft UI | Raw changed Whisper draft, including annotations and ignored phrases | Same raw changed Whisper draft; no extra marker filter |
| Final commit | Echoes the model/reasoning captured at live start after durable accepted-metadata persistence | Echoes the start-pinned reasoning/model after durable accepted-metadata persistence; empty model remains the session-selected sentinel |
| Reasoning music | Requested at endpoint | Requested at endpoint |
| Normal music | Server-configured delay after processing begins | Same server-configured delay |
| First token | Stops/fades music | Kills music process |
| Tool progress | Detailed visual event plus immediate short speech | Detailed visual event plus immediate short speech |
| Reasoning stream | Rendered | Printed under profile prefix with gray text |
| Automatic answer speech | Server-side speech stream follows active answer source | Client feeds streamed tokens into TTS |
| TTS segmenter | Shared, runs server-side | Shared, runs client-side |
| Turn-to-turn half duplex | Waits for browser speech idle | `speaker.finish()` blocks until playback ends |
| Spoken interruption | None | Optional second-mic local detector |
| Retry after ignored final | Restarts browser capture in same turn object | Restarts FFmpeg capture in same WebSocket |
| Startup resume | Recent-chat UI | Spoken yes/no mini voice session |

## Canned and status text: actual behavior

Not all text called a “message” has the same role.

| Category | Source | Web | Console voice | Console text |
| --- | --- | --- | --- | --- |
| Model selection | config + startup server | Parsed then ignored | Printed | Printed |
| Current tools | config + startup server | Parsed then ignored | Printed | Printed |
| Memory update start | config + startup server | Parsed then ignored | Printed and spoken asynchronously | Printed only |
| Memory update done/failed | config + startup server | Parsed then ignored | Printed | Printed |
| Resume prompt/unclear | config | Recent-chat UI instead | Printed and spoken | Printed text prompt |
| Runtime “I'm thinking.” | config + text-turn status | Not announced; semantic response state drives timing | Not spoken; music policy reacts | Not spoken |
| Reasoning “Wait, I'm thinking.” | config + speech registry | Explicitly excluded from all browser speech requests | Not used by console voice speaker | Not used |
| Tool progress | config + Pi event collector | Detailed display plus short spoken variant | Display + spoken variant synthesized | Display + spoken variant synthesized |
| Live listening/endpoint/retry | semantic server event kinds | Kinds control capture/retry | Same kinds control cues/music/preview | Not applicable |
| Errors | mostly hard-coded | Localized generic UI failure; detail in console log | Printed; selected connection failures retried | Printed |

The `reasoning.messages.wait` speech capability is currently dormant because
every browser `ChatSpeech` call passes `includeReasoningStatus=false`, while the
console uses its own TTS pipeline.

## Collision and irregular-case audit

### Resolved foundation — ignored candidate cancels response output

Current sequence:

```pseudo
endpoint
-> client stops capture and plays stop cue
-> reasoning client requests/starts music
-> final STT says known no-speech / unreliable with no safe draft
-> server emits "Ignored unclear speech; still listening."
-> same WebSocket starts another capture candidate
```

Both clients now stop pending or active thinking music on
`candidate_rejected` before capture restarts. The browser also clears the
per-candidate request guard so the next accepted endpoint can request music
normally; console clears its started/scheduled flags for the same reason.

### P0 — browser stop cue bypasses the only Bluetooth safety policy

The output recovery comment and architecture describe a quiet period after mic
release, but the stop cue is explicitly outside it. The actual invariant is:

```text
No speech or thinking music before recovery deadline.
Listening stop cue is allowed immediately.
```

That may be a valid product choice, but it means the browser is not actually
quiet after capture, and the first post-microphone output is always the cue.
Firefox/Yealink evidence says that first output is bound to HFP.

### Resolved foundation — one device-local output owner

`BrowserAudioRuntime` and `ConsoleAudioRuntime` now answer:

```text
What is allowed to be audible now?
Which output has priority?
What must be cancelled when capture restarts?
When may the device route recover?
```

The underlying chime, music, and speech adapters remain separate WebAudio or
native-process mechanisms, but capture/output transitions pass through one
local owner. Browser/Tauri answer/reasoning speech and console automatic answer
speech now report back into Voice; route/capture acknowledgements are pending.

### Accepted latency policy — start cue can enter browser capture

The browser begins cue playback and microphone acquisition concurrently. In a
measured run, capture began while the cue continued for hundreds of
milliseconds. Unlike console, browser capture can therefore transmit acoustic
or Bluetooth-loopback cue energy to VAD and preview STT.

This is intentional so the user can speak immediately and over the cue, and it
should be propagated to console. Possible outcomes still include false speech
start, contaminated noise-floor calibration, cue transcription, and reduced
usable pre-roll. Treat those as known trade-offs to observe, not as reasons to
serialize cue and capture without real failure evidence.

### P1 — noise-floor ownership is per candidate

There is no timed calibration pause. Every new `LiveAudioTurnState` begins
without a noise floor; the first sub-threshold block immediately seeds it and
later non-voice blocks update it. The browser concurrently starts capture and
the start cue, so cue leakage can become the first candidate's apparent
ambient floor. The value is discarded after that candidate and learned again
on the next turn.

The saved artifacts establish the 0.45-second minimum/four-second fallback as
the direct cause of the observed slow commits, but they do not store the
per-block RMS, threshold, or noise floor needed to prove calibration caused the
voice undercount. An empty cleaned draft is useful negative evidence, but its
complete assembled preview must not become the floor: it may contain a start
cue, missed real speech, and trailing silence. It should only authorize a
robust low-energy observation from known non-voice blocks. A later calibration redesign should therefore be scoped to
one session and input device, seeded from confirmed trailing non-voice after an
accepted turn, invalidated on device/route changes, and observable in metrics.

### Resolved foundation — semantic live-turn control flow

Examples:

```text
speech.live.listeningStarted
speech.live.listeningRetry
speech.live.listeningIgnored
speech.live.speechEndpointDetected
speech.live.listeningStoppedFinal
speech.live.listeningStoppedTyped
```

These localized messages remain useful presentation and diagnostic text, but no
longer decide client control flow. Both clients branch on semantic Voice event
kinds such as `listening_started`, `listening_retry`, `candidate_rejected`, and
`endpoint_reached`; copy can change without changing capture or music policy.
Owner: `app-data/resources/translations/{en,sk}.json` under `speech.live.*`.

### P1 — endpoint and response policy are split before acceptance

Music starts from the endpoint and guessed/requested reasoning mode. Final STT
and final transcript selection occur later. The client then sends the actual
commit policy. This gives one candidate three policy snapshots:

1. start-request reasoning/model;
2. client output behavior at endpoint;
3. committed reasoning/model after final transcript.

The browser can also change model/reasoning UI during the turn. Prompt prewarm,
music, final commit, and Pi can consequently act on different snapshots.

### P1 — silence-hallucination phrase filter is disabled

The former English list includes `you`, `okay`, `all right`, `let's go`,
`door opens`, `thank you`, `blank audio`, and subtitle-credit patterns, but it
is currently commented out. This avoids discarding plausible real utterances;
it also means any non-empty silence hallucination outside paired annotations
can become speech evidence and reach final STT.

### P2 — preview config is partly fictional

Default `partial_transcript_interval_seconds=0.5` and
`partial_transcript_min_audio_seconds=0.2` do not apply to normal turns because
both have 0.8-second code floors. The values apply differently in short-choice
resume mode. There is no resolved-settings output showing effective values.

### P2 — global persistent STT creates hidden cross-session queues

There is one preview worker and one final worker for the whole server. This is
efficient for model residency, but simultaneous profiles and background speech
interrupts serialize at those workers. Candidate-level cancellation does not
cancel an in-flight preview request, so a stale preview can delay the next
candidate or another session.

### P2 — browser backpressure loses audio silently

When `WebSocket.bufferedAmount >= 256 KiB`, a browser PCM frame is dropped with
no counter, status, retransmission, or saved client metric. Final STT may then
look unreliable for a reason not visible in turn artifacts. Console does not
use this drop policy.

### P2 — music and tool speech conflict in console

Tool start events feed an immediate canned TTS chunk, but do not stop thinking
music. Music and tool speech may therefore overlap through independent native
players. Browser avoids the overlap by not speaking tool progress at all, so
the two clients also differ semantically.

### P2 — reasoning policy differs by entry path

Browser and console text still support a leading one-turn `think`. Live voice
freezes reasoning and model when listening starts so the server can persist the
exact accepted manifest before `transcript_accepted`; neither client recomputes
policy from the later transcript. Restoring spoken one-turn `think` would need
one server-owned pre-acceptance policy resolution, included in the acceptance
event and echoed by clients, rather than independent client recomputation.

### P3 — small lifecycle leaks and unobservable transitions

- `BrowserLiveAudio` retains its last `activeTurn` reference after completion.
- Capture-context close is diagnostic only; no later transition waits for it.
- Cue playback is fire-and-forget and not part of turn completion.
- Browser client timing is logged only to the console diagnostic hook, unlike
  console metrics posted into turn artifacts.
- Preview worker failures are swallowed; the turn continues without an
  explicit degraded-state event.

## Post-speech shriek analysis

The post-submit shriek is not present with the Mac's built-in microphone and
speakers. This strengthens the conclusion that the general roughness is
primarily the Bluetooth HFP/A2DP transition already observed in CoreAudio. The
chain below is therefore a Yealink/device-specific stop-cue hypothesis, not an
application-wide defect or a reason to change the good built-in-audio path.

### Most likely chain

```pseudo
server emits endpoint_detected
-> BrowserLiveAudio.releaseCapture(true)
   -> disconnect source/worklet/silent output
   -> close worklet port
   -> stop microphone tracks synchronously
   -> start capture AudioContext.close asynchronously
   -> ChatSession marks 2.5-second speech/music recovery window
-> BrowserLiveAudio fires stop chime without awaiting it
-> BrowserListeningChimes resumes its independent AudioContext immediately
-> raw listening-stop.wav plays while Yealink/Firefox is still in HFP
-> source ends after 460 ms
-> latest code immediately suspends cue AudioContext
```

Evidence:

- The reported sound happens directly after speech commit, exactly when the
  stop cue runs.
- The cue is the only intentional audible output allowed at that time.
- The Firefox/Yealink investigation measured HFP teardown roughly 2.16 seconds
  after microphone release, so the complete 0.46-second cue is played in HFP.
- `listening-stop.wav` is PCM16 mono 44.1 kHz, duration 0.46 seconds, peak about
  -13.4 dBFS and RMS about -25.1 dBFS.
- Its final sample is 368/32768 (about -39 dBFS), not zero. Browser playback
  then ends the source and suspends the context. A discontinuity at the source
  boundary or device/context transition can produce a quiet click/chirp.
- The latest commit changed browser cues from a permanently running context to
  resume/play/suspend lifecycle and made endpoint cue handling fire-and-forget.
  The WAV itself did not change.

Assessment after the built-in-audio retest: **high confidence that Bluetooth
caused most of the roughness; no current reproduction of the shriek on built-in
audio; medium confidence that a Yealink-only recurrence is in the stop-cue
path; low-to-medium confidence in the precise non-zero-tail/context-suspend
mechanism until a cue-only A/B is run.**

### Less likely alternatives

1. **Capture `AudioContext.close()`:** timing matches, but its only destination
   connection is behind a zero-gain node and is disconnected before close.
2. **Thinking music:** it is gated until 2.5 seconds after release and therefore
   should not cause the immediate sound on an ordinary accepted turn.
3. **TTS:** answer speech begins much later, after final STT, Pi output, segment
   synthesis, and recovery.
4. **Persistent Whisper:** STT owns no speaker output. It can alter latency but
   cannot directly generate an immediate audible chirp.
5. **Start-cue/capture overlap:** real and risky, but its timing is at the start
   of speech rather than after commit.

The smallest later proof would be one physical browser A/B in which only stop
cue output is suppressed or replaced by guaranteed zero-tailed playback while
all other behavior stays identical. No such change is part of this analysis.

## Proposed simpler model

This is a design proposal for a later pass, not current behavior.

### One semantic turn state machine

```text
IDLE
  -> ARMING
  -> CAPTURING_CANDIDATE
  -> ENDPOINT_REACHED
  -> TRANSCRIBING_FINAL
       -> CANDIDATE_REJECTED -> ARMING
       -> TRANSCRIPT_ACCEPTED
  -> RESPONSE_PENDING
  -> RESPONSE_STREAMING
  -> SPEAKING
  -> IDLE

Any active state -> CANCELLING -> IDLE
Any active state -> FAILED -> IDLE
```

Important rule: `ENDPOINT_REACHED` is not yet an accepted user turn. Response
music, tool speech, and answer speech should be derived from
`TRANSCRIPT_ACCEPTED` / `RESPONSE_PENDING`, or explicitly cancelled as part of
`CANDIDATE_REJECTED`.

### Typed events, presentation text separately

```pseudo
event CandidateCaptureRequested { candidate_id }
event CandidateCaptureStarted   { candidate_id }
event CandidateDraftChanged     { candidate_id, display_text, speech_text? }
event CandidateEndpointReached  { candidate_id, reason }
event CandidateRejected         { candidate_id, reason }
event TranscriptAccepted        { candidate_id, turn_id, text, language }
event ResponseStarted           { turn_id, reasoning_mode, model }
event AssistantTextDelta        { turn_id, item_id, text }
event ToolStarted               { turn_id, tool, display_text, spoken_text? }
event ResponseCompleted         { turn_id, status }
```

Localized strings become payload for humans, never discriminators for client
control flow.

### One accepted policy snapshot

Define a single `TurnPolicy` at commit:

```pseudo
TurnPolicy = {
    model,
    reasoning_mode,
    speak_answer,
    speak_tool_progress,
    play_thinking_music,
    response_language,
}
```

Before final transcript, only `CapturePolicy` applies:

```pseudo
CapturePolicy = {
    transport,
    endpoint_delay,
    VAD thresholds,
    draft cadence,
    cue policy,
}
```

This prevents start-request, endpoint-output, and final-commit policy from
quietly diverging.

### One output arbiter per client

Both clients need one owner with adapter-specific playback underneath:

```pseudo
OutputArbiter owns:
    microphone_active
    recovery_deadline
    active_cue
    active_music
    active_speech

rules:
    capture start cancels/suspends every disallowed output
    candidate rejected cancels endpoint/response output
    cue priority and overlap are explicit
    music and speech overlap policy is explicit
    every output passes the same device-readiness gate unless explicitly exempt
    one transition records why output started/stopped
```

Web adapters would use WebAudio; console adapters would use native processes.
The policy and scenario names should remain shared.

### One client orchestration core, two adapters

The two clients need not share implementation language, but they can share the
same contract and transition table:

```text
VoiceClientCore
    CaptureAdapter
        BrowserPcmCapture
        ConsoleFfmpegPcmOrOpusCapture

    OutputAdapter
        BrowserWebAudioOutput
        ConsoleNativeOutput

    PresentationAdapter
        BrowserTranscriptAndActivity
        ConsoleLines
```

Differences should be declared capabilities (`supports_opus`,
`supports_spoken_interrupt`, `requires_output_recovery`) rather than recreated
workflow trees.

### One speech-content contract

Choose and document one of these intentionally:

```pseudo
ANSWER_ONLY
ANSWER_PLUS_TOOL_PROGRESS
ANSWER_PLUS_REASONING_STATUS_PLUS_TOOL_PROGRESS
```

Then apply it to both browser and console. The transport can carry structured
speech items; clients should not reconstruct different audible narratives from
unrelated event handlers.

### One resolved endpoint policy

The server should expose or save the effective policy used for each candidate:

```pseudo
ResolvedEndpointPolicy = {
    silence_seconds,
    min_speech_seconds,
    start_threshold_rule,
    continue_threshold_rule,
    preview_interval_seconds,
    preview_min_audio_seconds,
    stable_draft_seconds,
    trailing_silence_seconds,
}
```

If adaptive noise handling remains, its mutable state should have one explicit
owner separate from a candidate:

```pseudo
SessionInputNoise = {
    session_id,
    input_device,
    measured_after_accepted_turn,
    noise_floor_rms,
}
```

Never learn this value from audio overlapping a start cue. Reuse it only while
the session and input device are unchanged; otherwise fall back to fixed VAD
thresholds until a trustworthy trailing sample is available.

Browser-local adjustment can remain, but it should update one named field and
the saved resolved policy should show the result. Hard-coded floors should be
either promoted into the policy or removed.

## Voice implementation slices

Configuration ownership prerequisite: **implemented 2026-08-05** as described
in the implementation ledger. Delivered and remaining voice slices are tracked
below.

1. **Make Voice protocol states typed without changing behavior — delivered.**
   Conversation and Voice events use closed domain variants and common
   envelopes. One server `VoiceSessionCoordinator` now guards candidate,
   endpoint, final transcription, accepted transcript, response, retry, and
   terminal transitions. Device capture is an adapter; browser/Tauri and
   console automatic speech report observed speaking state, while physical
   route/capture acknowledgements remain.

2. **Add one output arbiter in each client — delivered.** Browser/Tauri and D
   console each construct one Audio Runtime above their existing platform
   adapters. Cues, music, speech, capture cancellation, recovery, and console
   spoken interruption route through it.

3. **Make candidate rejection an explicit transition — delivered for current
   output.** The typed Voice event returns the coordinator to listening, and
   each Audio Runtime cancels thinking music/local speech before recapture.

4. **Report client playback lifecycle — delivered for automatic speech.**
   WebAudio answer/reasoning and console native answer outputs report queue,
   observed start, and terminal facts into Voice with bounded off-path delivery
   and stale-state reconciliation.

5. **Recover every accepted client voice turn — delivered.** Browser/Tauri and
   console persist metadata and a nonterminal replay cursor before the fast
   WebSocket commit. They recover through the canonical HTTP SSE commit and
   delete only on terminal; the accepting daemon remains the sole owner of the
   durable normalized Opus and accepted manifest.

6. **Choose one cue/recovery policy.** Decide whether the stop cue is immediate,
   recovery-gated, device-independent, or removed. Apply zero-tail/fade rules at
   the audio boundary.

7. **Unify TTS content policy.** Decide whether tool progress is spoken and make
   browser/console agree.

8. **Collapse endpoint settings into one resolved contract.** Remove hidden
   floors or expose them as named fields. Keep browser adjustment as a clear
   override.

9. **Make adaptive noise state session/device-owned or remove it.** Seed it
   from confirmed trailing silence after an accepted turn, invalidate it on
   route changes, and save the effective floor/thresholds in turn metrics.

10. **Only then chase milliseconds.** Measure candidate-end to accepted
   transcript, accepted transcript to response start, response start to first
   token, first token to first TTS segment, and microphone release to first
   audible output under the simplified lifecycle.

## Scenario checks for a future refactor

```text
1. normal automatic endpoint, fast non-reasoning answer
2. normal automatic endpoint, slow non-reasoning answer -> delayed music
3. reasoning endpoint -> immediate music -> first token stops it
4. explicit Send before silence
5. no speech for max_wait -> keep listening without duplicate cue/output
6. recognized real speech below 0.45 VAD seconds -> selected silence delay
7. annotation-only draft -> no short-speech endpoint
8. annotation-only final -> reject candidate -> clean relisten
9. draft fallback because final is unreliable
10. long final coverage incomplete -> use draft
11. start cue while user speaks immediately
12. socket backpressure / dropped browser frames
13. cancel while capturing
14. cancel during final STT
15. cancel during Pi response
16. auto-speech disabled/enabled mid-turn
17. profile/model/reasoning change during capture
18. tool event before first answer token
19. multiple simultaneous profiles contending for preview/final workers
20. long dictation crosses sentence, clause, and timed-word draft boundaries;
    both clients receive the same complete assembled text and stable text never changes
21. final STT after draft splits still receives the complete accepted recording
22. ignored reasoning candidate followed by valid candidate
23. console spoken interrupt false onset, resume, and true stop
```

Each check should assert semantic state, capture ownership, audible-output
ownership, saved endpoint reason, selected transcript source, and final turn
status—not exact presentation strings.

## Source map

### Browser

- app composition: `client/src/app/ChatRuntime.ts`
- output arbiter: `client/src/audio/BrowserAudioRuntime.ts`
- session state and music/speech timing: `client/src/chat/ChatSession.ts`
- live WebSocket and cue/capture ordering: `client/src/audio/BrowserLiveAudio.ts`
- live PCM capture/backpressure: `client/src/audio/BrowserLiveAudioCapture.ts`
- listening cues: `client/src/audio/BrowserListeningChimes.ts`
- output recovery: `client/src/audio/BrowserOutputRecovery.ts`
- thinking music: `client/src/audio/BrowserThinkingMusic.ts`
- speech content/lifecycle: `client/src/chat/ChatSpeech.ts`
- WebAudio speech queue: `client/src/audio/BrowserSpeechPlayer.ts`
- API event mapping: `client/src/transport/WheatleyApi.ts`
- client config adapter over server `config.json`: `client/src/app/ClientConfig.ts`

### Console

- command/config selection: `server/wheatleyd/source/wheatley/client/console/config.d`
- output arbiter: `server/wheatleyd/source/wheatley/client/console/audio/runtime.d`
- output transition state: `server/wheatleyd/source/wheatley/client/console/audio/output_state.d`
- voice orchestration: `server/wheatleyd/source/wheatley/client/console/voice/runner.d`
- resume voice mini-session: `server/wheatleyd/source/wheatley/client/console/voice/session_resume.d`
- WebSocket event loop: `server/wheatleyd/source/wheatley/client/console/live/client.d`
- FFmpeg capture: `server/wheatleyd/source/wheatley/client/console/live/capture.d`
- padded cues: `server/wheatleyd/source/wheatley/client/console/audio/chimes.d`
- native thinking music: `server/wheatleyd/source/wheatley/client/console/audio/thinking_music.d`
- streaming TTS: `server/wheatleyd/source/wheatley/client/console/speech/streaming.d`
- spoken interrupt: `server/wheatleyd/source/wheatley/client/console/speech/interrupt.d`
- tool display/spoken selection: `server/wheatleyd/source/wheatley/client/console/tools/events.d`
- text-mode thinking behavior: `server/wheatleyd/source/wheatley/client/console/text/runner.d`

### Server

- live Voice orchestration, draft routing, and final selection: `server/wheatleyd/source/wheatley/server/voice/runtime.d`
- guarded semantic phase transitions: `server/wheatleyd/source/wheatley/server/voice/session_coordinator.d`
- VAD/sample state: `server/wheatleyd/source/wheatley/server/turns/audio/live_audio_state.d`
- draft worker and filters: `server/wheatleyd/source/wheatley/server/turns/audio/live_preview_transcriber.d`
- live settings: `server/wheatleyd/source/wheatley/server/turns/audio/live_audio_settings.d`
- final STT wrapper: `server/wheatleyd/source/wheatley/server/turns/audio/final_transcription.d`
- persistent Whisper workers: `server/wheatleyd/source/wheatley/server/stt/whisper_cpp.d`
- accepted turn boundary: `server/wheatleyd/source/wheatley/server/conversation/runtime.d`
- Pi events and tool progress: `server/wheatleyd/source/wheatley/server/turns/text/pi_events.d`
- canned tool text: `server/wheatleyd/source/wheatley/server/tools/progress.d`
- active speech sources: `server/wheatleyd/source/wheatley/server/tts/turn_speech_registry.d`
- browser speech streaming: `server/wheatleyd/source/wheatley/server/tts/turn_speech_stream.d`
- shared speech segmentation: `server/wheatleyd/source/wheatley/server/tts/segment_buffer.d`
- spoken-text normalization: `server/wheatleyd/source/wheatley/server/tts/spoken_text.d`
- profile startup/canned messages: `server/wheatleyd/source/wheatley/server/startup/profile_startup.d`
- release defaults: `app-data/resources/config.default.json`
- localized product copy: `app-data/resources/translations/{en,sk}.json`
