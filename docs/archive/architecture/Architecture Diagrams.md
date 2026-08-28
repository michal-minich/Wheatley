# Architecture Diagrams

These diagrams are a visual companion to
[Architecture](Architecture.md),
[Runtime Roles and Deployment](Runtime%20Roles%20and%20Deployment.md), and
[Voice Turn Lifecycle](Voice%20Turn%20Lifecycle.md). They describe the current
implemented boundaries unless a caption explicitly says **target**.

The diagrams use conservative Mermaid syntax. Obsidian renders Mermaid code
blocks directly. Current VS Code renders them in the built-in Markdown preview;
use **Markdown: Open Preview to the Side** (`Cmd+K V` on macOS). On an older VS
Code release, the former `Markdown Preview Mermaid Support` extension provides
the same view.

The arrows show use or data flow, not an instruction to deploy every box as a
service. Solid arrows are calls or durable data movement. Dashed arrows are
events, observations, or selected implementations.

## 1. System at a glance

This is the ownership model. The default D runtime places most of these boxes
in one process; browser and console Audio Runtimes live beside their speakers.

```mermaid
flowchart LR
    Shell[Device Shell<br/>browser, Tauri, console, headless]
    Profile[Profile Runtime<br/>config, sessions, memory, artifacts]
    Conversation[Conversation Runtime<br/>accepted turns and ordered events]
    Voice[Voice Runtime<br/>listen, endpoint, STT, acceptance]
    Audio[Audio Runtime<br/>cues, music, narration, playback policy]
    DeviceAudio[DeviceAudio<br/>microphone, speaker, OS route]
    Agent[Agent Runtime<br/>Pi adapter today]
    STT[Speech recognizer<br/>Whisper today]
    TTS[Speech synthesizer<br/>Piper / Supertonic]
    Store[(Profile filesystem)]

    Shell -->|profile and history intent| Profile
    Shell -->|typed turn| Conversation
    Shell -->|voice intent| Voice

    Voice -->|accepted transcript and ArtifactRef| Conversation
    Voice -->|capture and output intent| Audio
    Conversation -->|commit and context| Profile
    Conversation -->|run or cancel| Agent
    Voice -->|preview and final transcript| STT
    Audio -->|speech items| TTS
    Audio -->|play, stop, route recovery| DeviceAudio
    DeviceAudio -->|captured frames and route facts| Voice
    Profile --> Store

    Profile -.->|resolved state and history| Shell
    Conversation -.->|status, reasoning, tool, token, terminal| Shell
    Voice -.->|listening, draft, endpoint, accepted, failed| Shell
    Conversation -.->|semantic narration content| Audio
    Audio -.->|playback observations| Voice
```

The important ownership rules are:

- Profile Runtime is the only canonical writer of user state.
- Voice accepts speech; Conversation does not own microphone policy.
- Conversation emits meaning, not playback files.
- Audio Runtime owns what may be audible on its device.
- Platform code adapts IO but does not recreate product policy.

## 2. Dependency direction inside `wheatleyd`

`WheatleyApi` is the composition root. Callers depend on the small
`ConversationPort`; startup chooses exactly one implementation. The ordinary
local composition uses direct typed calls rather than loopback HTTP.

```mermaid
flowchart TB
    subgraph Edge[Transport edge]
        Routes[HTTP, SSE and WebSocket routes]
    end

    subgraph Composition[Composition root]
        Api[WheatleyApi]
        Choice{conversation placement}
    end

    subgraph Roles[Runtime roles and ports]
        Profile[ProfileRuntime]
        Voice[VoiceRuntime]
        Port[ConversationPort]
        Local[ConversationRuntime]
        Remote[RemoteConversationHttpPort]
        AgentPort[AgentRuntime]
        PiAdapter[PiAgentRuntime]
    end

    subgraph Technical[Technical adapters]
        History[HistoryStore and RuntimeFiles]
        Whisper[WhisperCppWorkers]
        SyncGate[RemoteTurnSyncGate]
        Peer[RemoteConversationHttpPeer]
        Pi[Persistent Pi RPC worker]
        Provider[Configured model provider]
    end

    Api --> Profile
    Api --> Voice
    Api --> Choice
    Choice -. local .-> Local
    Choice -. remote .-> Remote

    Routes --> Profile
    Routes --> Voice
    Routes --> Port
    Voice --> Profile
    Voice --> Port
    Local -. implements .-> Port
    Remote -. implements .-> Port

    Profile --> History
    Voice --> Whisper
    Local --> Profile
    Local --> AgentPort
    PiAdapter -. implements .-> AgentPort
    PiAdapter --> Pi
    Pi --> Provider
    Remote --> SyncGate
    Remote --> Peer
    SyncGate --> Profile
```

The port isolates a real placement choice. Profile, Voice, and local
Conversation remain direct concrete collaborators; they are not wrapped merely
to make the graph look layered.

## 3. Current deployment shapes

### 3.1 Standalone local appliance

This is the fully local shape for a Mac, Pi 5, or N150-class machine. The whole
product can work without the server or WAN when its configured provider and
models are local.

```mermaid
flowchart LR
    subgraph Device[Standalone machine]
        Shell[Browser, console or local shell]
        Audio[Device Audio Runtime]
        Daemon[wheatleyd<br/>Profile + Voice + Conversation]
        Profile[(Authoritative local profile)]
        Whisper[Local Whisper]
        TTS[Local Piper / Supertonic]
        Pi[Local Pi]
        Model[Local model provider]

        Shell <-->|HTTP, SSE, WebSocket| Daemon
        Shell --> Audio
        Daemon --> Profile
        Daemon --> Whisper
        Daemon --> TTS
        Daemon --> Pi
        Pi --> Model
    end
```

### 3.2 Synced hybrid with remote Conversation

The appliance keeps capture, Whisper, speech, playback, and a bounded profile
replica local. It synchronizes history and sends accepted Conversation work to
one paired authority. A network failure is visible; this composition never
runs local Pi as an unannounced mid-turn fallback.

```mermaid
flowchart LR
    subgraph Appliance[Hybrid appliance]
        DeviceShell[Shell and DeviceAudio]
        LocalVoice[Local Voice + Whisper]
        LocalAudio[Local Audio + TTS]
        RemotePort[RemoteConversationHttpPort]
        Replica[(Last-session profile replica<br/>and durable outboxes)]

        DeviceShell --> LocalVoice
        LocalVoice --> RemotePort
        RemotePort --> Replica
        LocalVoice --> LocalAudio
    end

    subgraph Server[Paired server authority]
        ServerApi[wheatleyd API]
        FullProfile[(Complete profile archive)]
        Conversation[ConversationRuntime]
        Pi[Pi + configured provider]

        ServerApi --> FullProfile
        ServerApi --> Conversation
        Conversation --> Pi
    end

    RemotePort <-->|Conversation SSE and stop| ServerApi
    Replica <-->|exact turn sync and profile snapshot| ServerApi
    LocalAudio -. local narration projection .-> DeviceShell
```

### 3.3 Thin browser or Tauri client

This is the intended initial iOS composition. The client owns platform audio,
presentation, a bounded music cache, and accepted-turn metadata. The server
owns Profile, Whisper, Conversation, Pi, and the configured Wheatley voice.

```mermaid
flowchart LR
    subgraph Client[Browser / Tauri device]
        UI[Chat and voice shell]
        DeviceAudio[WebAudio / native audio session]
        MediaCache[(Music cache<br/>code + hash)]
        AcceptedOutbox[(Accepted-voice metadata outbox)]

        UI --> DeviceAudio
        UI --> MediaCache
        UI --> AcceptedOutbox
    end

    subgraph Runtime[Remote wheatleyd]
        Api[HTTP + SSE + live WebSocket]
        Voice[Voice Runtime + Whisper]
        Profile[(Complete profile and 32 kbit/s user Opus)]
        Conversation[Conversation + Pi + model provider]
        TTS[Piper / Supertonic<br/>disposable Ogg/Opus]

        Api --> Voice
        Api --> Profile
        Api --> Conversation
        Api --> TTS
    end

    UI <-->|chat, history, lifecycle and events| Api
    DeviceAudio -->|16 kHz mono PCM today| Api
    Api -->|16 to 32 kbit/s assistant speech| DeviceAudio
    Api -->|stable music reference and bytes on miss| MediaCache
    AcceptedOutbox -->|HTTP SSE commit recovery| Api
```

## 4. Transport responsibilities

Transport follows the actual interaction shape. It is not a universal internal
bus.

```mermaid
flowchart LR
    Shell[Device Shell]
    Json[HTTP JSON<br/>bounded request and response]
    Sse[HTTP + SSE<br/>replayable ordered server stream]
    Ws[WebSocket<br/>live bidirectional voice session]
    Bytes[HTTP bytes / multipart<br/>artifacts and complete turns]
    Api[wheatleyd edge]
    Roles[Typed runtime calls]

    Shell -->|config, history, TTS request, stop| Json
    Shell -->|typed turn, startup, accepted retry| Sse
    Shell <-->|audio frames, control, voice and Conversation events| Ws
    Shell <-->|Opus, music, files, synchronization| Bytes

    Json --> Api
    Sse --> Api
    Ws --> Api
    Bytes --> Api
    Api --> Roles
```

- **Direct typed calls:** default between roles in one process.
- **WebSocket:** microphone frames and interactive voice control before and
  during one live session; it also carries the common Conversation envelope.
- **SSE:** one-way ordered output that benefits from an HTTP request body and a
  durable replay cursor, including text turns and accepted-voice recovery.
- **HTTP JSON:** bounded commands and snapshots.
- **HTTP bytes or multipart:** potentially large media and sync artifacts;
  normal events never contain base64 blobs.

## 5. Voice lifecycle state machine

This is server Voice coordination. Capture and playback adapters react to these
states but do not invent their own acceptance policy.

```mermaid
stateDiagram-v2
    [*] --> Starting
    Starting --> Listening: ready
    Listening --> Listening: candidate rejected / retry
    Listening --> EndpointReached: silence, stable draft, explicit send, max duration
    EndpointReached --> FinalTranscription
    FinalTranscription --> Listening: empty or rejected candidate
    FinalTranscription --> TranscriptAccepted: durable Opus and manifest ready
    TranscriptAccepted --> ResponsePending: client metadata persisted and exact commit received
    ResponsePending --> ResponseStreaming: first Conversation event
    ResponseStreaming --> Completed: terminal completed event
    ResponsePending --> Failed: terminal failed event
    ResponseStreaming --> Failed: terminal failed event
    Listening --> Cancelled
    EndpointReached --> Cancelled
    FinalTranscription --> Failed
    Completed --> [*]
    Failed --> [*]
    Cancelled --> [*]
```

`EndpointReached` is not yet an accepted user turn. Acceptance occurs only
after the selected audio is normalized and its exact manifest is durable.

## 6. Accepted voice turn and crash recovery

The accepting daemon owns the only durable user-audio copy. The client outbox
contains metadata and a replay cursor, not another PCM or Opus recording.

```mermaid
sequenceDiagram
    participant Client as Browser / Tauri / console
    participant Outbox as Client accepted outbox
    participant Voice as wheatleyd Voice Runtime
    participant STT as Whisper
    participant Profile as Profile Runtime
    participant Conv as Conversation Runtime
    participant Agent as Pi Agent Runtime

    Client->>Voice: WebSocket start + microphone frames
    Voice->>STT: preview and final transcription
    STT-->>Voice: final transcript
    Voice->>Profile: normalize selected audio to 32 kbit/s Opus
    Voice->>Profile: atomically write accepted manifest
    Profile-->>Voice: artifact ID, byte count, SHA-256
    Voice-->>Client: transcript_accepted + artifact ID
    Client->>Outbox: persist transcript, artifact, start policy, cursor 0
    Outbox-->>Client: durable
    Client->>Voice: commit exact start-pinned model and reasoning
    Voice->>Conv: accepted request + UserAudioArtifactRecord
    Conv->>Profile: publish fenced submission before execution
    Conv->>Agent: run
    Agent-->>Conv: semantic status, reasoning, tool and token events
    Conv->>Profile: append each event before delivery
    Conv-->>Client: sequenced Conversation events
    Client->>Outbox: checkpoint nonterminal sequence

    alt WebSocket reaches terminal
        Conv->>Profile: commit terminal turn with user.opus
        Conv-->>Client: completed or failed
        Client->>Outbox: delete entry directly
    else Connection is lost after acceptance
        Note over Client,Outbox: Entry remains with last nonterminal cursor
        Client->>Outbox: list pending on startup / reconnect
        Client->>Voice: HTTP accepted commit + after_sequence
        Voice->>Profile: load exact accepted manifest
        Voice->>Conv: same submission, replay or finish once
        Conv-->>Client: remaining SSE Conversation events
        Client->>Outbox: checkpoint nonterminal sequences
        Conv-->>Client: terminal event
        Client->>Outbox: delete entry directly
    end
```

If the connection fails before `transcript_accepted`, the capture is retried;
Wheatley does not splice or pretend to replay an uncertain live recording.

## 7. Remote Conversation handoff

The local terminal event is deliberately delayed until the exact remote turn
and artifacts have been materialized locally.

```mermaid
sequenceDiagram
    participant Caller as Local Voice / HTTP turn caller
    participant Port as RemoteConversationHttpPort
    participant Gate as RemoteTurnSyncGate
    participant LocalProfile as Local Profile Runtime
    participant UpApi as Upstream wheatleyd API
    participant UpProfile as Upstream Profile Runtime
    participant UpConv as Upstream Conversation Runtime
    participant Pi as Upstream Pi / provider
    participant Audio as Local narration / TTS projection

    Caller->>Port: run accepted turn
    Port->>Gate: prepare exact profile + session + submission
    Gate->>LocalProfile: inspect prior exportable and pending work
    Gate->>UpApi: upload and acknowledge prior complete turns
    Gate->>UpApi: ensure exact session exists, including zero-turn session
    opt Accepted voice turn
        Gate->>UpApi: import exact Opus + canonical artifact metadata
        UpApi->>UpProfile: validate size, SHA-256 and Ogg/Opus, then publish once
    end
    Gate-->>Port: handoff permitted

    Port->>UpApi: text or accepted-voice commit request
    UpApi->>UpConv: same canonical submission
    UpConv->>UpProfile: persist fence and event journal
    UpConv->>Pi: run
    Pi-->>UpConv: semantic events
    UpConv-->>Port: validated SSE Conversation events
    Port-->>Audio: project narration and speech locally
    Port-->>Caller: nonterminal semantic events

    UpConv->>UpProfile: terminal commit
    UpConv-->>Port: terminal event pending local exposure
    Port->>Gate: materialize exact named terminal turn
    Gate->>UpApi: exact session / exact turn manifest and files
    Gate->>LocalProfile: idempotent local import
    LocalProfile-->>Gate: exact terminal durable
    Gate-->>Port: materialized
    Port-->>Caller: terminal event

    Note over Port,Pi: Network or validation failure is visible, and local Pi is never started as a mid-turn fallback.
```

## 8. Paired-appliance history synchronization

Synchronization copies complete immutable work; it never mounts one live
iCloud profile as a multi-writer filesystem.

```mermaid
sequenceDiagram
    participant Sync as Appliance profile-sync loop
    participant Mutex as Shared sync mutex
    participant Local as Local history + ACK outbox
    participant Server as Server import / snapshot API
    participant Full as Server Profile Runtime

    Sync->>Mutex: acquire
    Sync->>Local: scan complete exportable turns
    Local-->>Sync: exact session/turn paths + files

    loop Each unacknowledged complete turn
        Sync->>Local: persist pending ACK marker
        Sync->>Server: multipart exact turn import
        Server->>Full: validate and atomically import missing turn
        Full->>Full: append user prompt to memory todo once
        Full-->>Server: imported or exact retry no-op
        Server-->>Sync: durable acknowledgement
        Sync->>Local: record ACK
    end

    Sync->>Local: verify all exportable local work acknowledged
    Sync->>Server: request latest complete-session manifest
    Server-->>Sync: allowlisted missing files and profile snapshot
    Sync->>Local: merge missing turns by timestamp path
    Sync->>Local: atomically activate config + profile documents
    Sync->>Local: prune only safe older acknowledged sessions
    Sync->>Mutex: release

    Note over Mutex,Server: Remote-turn preparation uses the same mutex, so periodic sync and handoff cannot race.
```

The intentionally simple collision rule is first-file-wins. A rare same-second
session collision may merge; the first session/Pi files stay authoritative and
a different Pi log is preserved as `pi_session_2.jsonl` rather than rebuilt.

## 9. Data ownership and retention

```mermaid
flowchart TB
    subgraph Release[Versioned release data]
        Resources[resources/<br/>prompts, translations, chimes, media manifest]
    end

    subgraph Machine[Replaceable machine-local data]
        Models[app-data/models/<br/>STT, TTS, local model assets]
        Cache[app-data/cache/media/<br/>bounded music cache]
        Runtime[app-data/runtime/<br/>temporary agent, voice, speech and audio state]
    end

    subgraph Device[Durable device-local data]
        Settings[device-data/settings/<br/>permissions and calibration]
        SubmitOutbox[device-data/outbox/<br/>unacknowledged commands and metadata]
        SyncOutbox[profile-sync outbox<br/>durable ACK state]
    end

    subgraph User[Durable user data]
        Profile[Profiles/profile/<br/>documents, memory and sessions]
        Session[session directory]
        Turn[turn directory<br/>turn.json, events, tools, user.opus, artifacts]
        Profile --> Session --> Turn
    end

    ProfileRuntime[Profile Runtime] --> Profile
    AudioRuntime[Audio Runtime] --> Cache
    VoiceRuntime[Voice Runtime] --> Runtime
    DeviceShell[Device Shell] --> Settings
    DeviceShell --> SubmitOutbox
    ProfileSync[Profile sync owner] --> SyncOutbox
    Resources -. read only .-> ProfileRuntime
    Models -. replaceable adapter input .-> VoiceRuntime
```

Only `Profiles/` is canonical user history. Device outboxes are durable until
acknowledged but are not a second profile authority. Caches and generated
assistant speech are disposable; accepted user speech is not.

## Reading order

For a quick orientation, read diagrams 1, 3.2, and 6. For implementation work,
use diagram 2 to find dependency direction, diagram 4 to choose a transport,
and the relevant sequence before changing a boundary. The prose documents and
code remain authoritative when a diagram becomes stale.
