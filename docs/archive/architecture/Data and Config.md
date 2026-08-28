# Data and configuration

Wheatley uses distinct roots so public source and private state do not become
mixed.

| Root | Default | Contents | Git |
| --- | --- | --- | --- |
| repository | checkout | source, scripts, examples | tracked |
| app data | `app-data/` | models, tools, environments, temporary state | ignored |
| resources | `app-data/resources/` | prompts, default config, Pi extension, audio | tracked (`!` exceptions) |
| Wheatley home | `app-data/user/` | active config and profiles | ignored |

Resources always live under the app-data root as `resources/`. Override
`WHEATLEY_APP_DATA_ROOT` and the resources path follows as
`$WHEATLEY_APP_DATA_ROOT/resources`.

The home may be moved to iCloud Drive, another synchronized folder, or a
normal local directory. Consider the privacy and conflict behavior of the
chosen sync service: session files can contain complete conversations.

## Bootstrap behavior

`scripts/install/setup.sh` creates, but never overwrites:

- `$WHEATLEY_CONFIG_PATH` from `app-data/resources/config.default.json`;
- `$WHEATLEY_PROFILES_ROOT/wheatley` from
  `examples/profiles/wheatley/`.

The tracked files are templates, not active state. Edit the private copies.

## Environment overrides

Launch scripts source `wheatley.local.env` when it exists. The file is ignored
by Git. Supported path overrides are:

```bash
WHEATLEY_APP_DATA_ROOT="$HOME/.local/share/wheatley"
WHEATLEY_HOME="$HOME/.wheatley"
WHEATLEY_CONFIG_PATH="$WHEATLEY_HOME/config.json"
WHEATLEY_PROFILES_ROOT="$WHEATLEY_HOME/Profiles"
```

`WHEATLEY_HOME` is a convenience default for the config and profiles paths;
either child path can be overridden independently.

Normal Pi file work defaults to `Profiles/<profile>/files`. A run profile may
instead map selected profiles to independent machine-local workspaces through
`server.agent_workspace_roots`. The tracked local profile maps Primary from:

```bash
WHEATLEY_PRIMARY_WORKSPACE_ROOT="/path/to/external-workspace"
```

An empty value leaves Primary on its profile files root. A configured workspace
must exist and contain `WHEATLEY.md`; Wheatley injects that file explicitly and
starts Pi with context-file discovery disabled, so an external coding-agent
`AGENTS.md` is not loaded. Pi's existing session header snapshots the selected
cwd: resumed conversations keep their original workspace when configuration
changes, while new conversations use the new mapping. Profile documents,
memory, history, and media remain under `WHEATLEY_PROFILES_ROOT`.

Codex delegation is off unless its trusted workspace is set:

```bash
WHEATLEY_CODEX_WORKSPACE_ROOT="/path/to/a/trusted/workspace"
# Optional override; the default is inside WHEATLEY_APP_DATA_ROOT.
WHEATLEY_CODEX_SOCKET="$WHEATLEY_APP_DATA_ROOT/wheatley-codexd.sock"
```

The workspace is where delegated Codex work may read and write. Association,
observed events, and final results are stored inside each profile session.
Install the independent worker with `scripts/codex-worker/install-local.sh`.
On macOS it installs a minimal runtime under
`~/Library/Application Support/Wheatley/codex-worker`, supervises it with the
user LaunchAgent `dev.wheatley.codexd`, and restricts the Unix socket
to its owner (`0600`). Rerun the installer after rebuilding the worker.

Paired appliance history synchronization requires both the explicit
`synced_hybrid` run profile and an upstream Wheatley API:

```bash
WHEATLEY_SYNC_UPSTREAM_API_BASE="http://server.local:8765/api"
scripts/server/hybrid.sh
```

To place Conversation on that paired authority, also set the same API base and
use the remote launcher:

```bash
WHEATLEY_CONVERSATION_REMOTE_API_BASE="http://server.local:8765/api"
scripts/server/remote.sh
```

Conversation and profile sync must resolve to the same normalized authority;
startup rejects mismatches. Remote placement does not invoke local Pi, prompt
prewarm, or session auto-memory.

The interval is the required `server.sync.interval_seconds` value in the JSON
run profile (30 seconds in the inherited hybrid profile). The upstream is expected
to expose the same trusted Wheatley API and profile IDs. This is a trusted-LAN
boundary; do not expose it directly to the public internet.

## Profile layout

Each directory directly under `Profiles/` is a profile. A minimal profile
contains:

```text
Profiles/wheatley/
  config.json
  system.md
  user.md
  memory.md
```

Runtime-created session, transcript, Pi, tool, media, and memory-management
files remain inside the profile directory. They should be treated as private.

When Wheatley sends hidden context in addition to the visible request, the
turn stores the exact provider-bound Pi RPC user message in `model-input.json`.
This applies to the first turn in a Pi session and to scheduled turns with
private scheduler context; ordinary later requests do not duplicate their
already-visible text. The browser projects `Model context` only for the first Pi
turn in a session. Later scheduled turns remain single `Scheduled task` tool
items; their details expose the exact canonical Pi user-message event and report
one Pi prompt RPC/user message. The scheduler snapshot's repeated
`injected_prompt` audit copy is not projected as another input. Older turns
recover the same exact message from canonical `pi_session.jsonl` history.

Accepted user spoken prompts are durable profile data. Transfer must be
lossless or at least 32 kbit/s Opus quality; Profile Runtime always stores the
normalized profile artifact as 32 kbit/s `user.opus`, matching current behavior.
A thin/offline device retains unacknowledged recordings durably. Generated
assistant speech is derived output, not profile history; temporary speech files
should be removed after use and swept after a crash/startup.

Live Voice first stages the normalized Opus and a small server-authored accepted
manifest under `Profiles/<profile>/files/_staged/user-audio/`. The manifest is
submission-specific and contains the accepted transcript/policy, exact audio
metadata, byte count, and SHA-256, not a trusted stored filesystem path. It is
written before `transcript_accepted`, supports exact download and idempotent HTTP
commit after a lost WebSocket, and Conversation then moves the Opus into the
turn. A paired receiver derives its own staging path, caps the upload at 64 MiB,
and validates bytes, digest, and Ogg/Opus decoding before publishing the same
sidecar.

For paired offline appliances, the server holds the complete profile history.
The implemented foundation refreshes the server's latest complete session into
the appliance and keeps a durable acknowledgement outbox. Synchronization copies completed
turns through the server API using their existing relative timestamp paths; it
does not make the profile directory a concurrent shared filesystem. A rare
same-second session collision is allowed to merge. Existing `session.json` and
`pi_session.jsonl` win, another Pi log is preserved under a numbered filename,
and Pi JSONL is never reconstructed. See
[Runtime Roles and Deployment](Runtime%20Roles%20and%20Deployment.md#profile-history-synchronization).

Before a remote Conversation call, the same Profile sync owner first ACKs prior
local turns and hands off the exact `session.json`, including for a new zero-turn
session. Accepted audio is imported by canonical submission identity and hash.
After execution the appliance downloads/imports only the referenced terminal
turn and allowlisted artifacts before terminal delivery. This exact-turn path is
separate from ordinary latest-session refresh so another device's newer session
cannot be substituted.

Acknowledgement state is machine-local under:

```text
app-data/device-data/profile-sync/outbox/<profile>/<session timestamp>/
```

It is not cache and must survive restart. The profile history remains the source
payload, so a complete turn created before the first sync attempt is recovered
by scanning history. After a successful refresh, the device stores the
acknowledged configuration and profile-document snapshot at:

```text
app-data/device-data/profile-sync/replica/<profile>/snapshot.json
```

Older fully exportable sessions are removed only when all ready turns/Pi state
are acknowledged and there is no pending marker. The newest two, incomplete,
pending, and unacknowledged sessions are retained. The snapshot includes
individually hashed `system.md`, `user.md`, `memory.md`, and `memory_auto.md`.
In `synced_hybrid`, those server-authoritative documents are atomically exposed
through `Profiles/<profile>/profile_replica_documents.json` only after local
exportable work is acknowledged. `standalone_local` does not enable that
overlay and continues to use its ordinary local profile documents.

The D console's uncertain text submissions are separate device-local state:

```text
app-data/console-client/outbox/<profile>/<device>/<submission>/
```

Each entry retains its complete request, submission ID, replay cursor, and
optional `user.opus` until a terminal Conversation event. Accepted console
voice uses the same directory owner but stores only accepted artifact identity,
canonical text, start-pinned policy, and a nonterminal replay cursor. The exact
32 kbit/s Opus and manifest remain on the accepting daemon; terminal delivery
deletes the metadata entry directly.

Browser/Tauri accepted voice uses WebView IndexedDB database
`wheatley-origin-outbox-v1`, store `accepted_voice`. An entry contains only the
accepted artifact reference, canonical request facts, and nonterminal replay
cursor. The normalized Opus remains in Profile Runtime, so the browser does not
download or cache another recording. Startup, online recovery, and profile
selection replay the HTTP commit; terminal delivery deletes the entry without
first persisting the terminal cursor. Browser and console recovery both assume
the configured API authority is the same daemon that announced acceptance.

## Configuration guidance

Start from the generated config and change one subsystem at a time. Target
product configuration remains one validated document but is grouped by its
owning subsystem: persona/conversation, memory, tools, voice/listening,
audio/output, and media. Node endpoints, paths, secrets, and resource limits
remain node-local; permissions, calibration, cache, and presentation choices
remain device-local. In particular:

- keep file, shell, camera, and Codex tools disabled until needed;
- use `session.prompt_prewarm_enabled` to enable or disable hidden Pi prompt
  warm-up runs for every profile that inherits the app config;
- `pi.image_long_edge_px` bounds only the transient image sent to Pi/LLM while
  the exact uploaded original remains the durable turn artifact. The default is
  `1024`; use `0` when a profile needs the original resolution for detailed
  text or inspection;
- update `memory.models` to models actually available through Pi;
- voice paths are relative to the app-data root by default;
- live endpoint silence is `clients.web.speech_commit_delay_seconds` in the shared
  app `config.json`; both clients send it on live start as `silence_seconds`;
  HTTP accessors are `GET` and `PUT /api/config/clients/:client_id`;
  browser output recovery delay is required `clients.web.output_recovery_ms`;
  thinking-music fade timings are required
  `clients.web.thinking_music_fade_in_ms` / `thinking_music_fade_out_ms`;
- thinking-music rotation is server-owned under
  `profiles.<id>.thinking_music_index` in the same app `config.json`; clients
  take the next track through `GET /api/profiles/:profile_id/thinking-music`;
- `profiles.<id>.play_music` is the browser/Tauri preference for a persistent
  ordinary-chat soundtrack. It begins when a chat opens or the switch is
  enabled, pauses for microphone capture, and resumes when recording or speech
  playback finishes. It does not govern continuous live voice chat, whose
  existing server music directives remain authoritative. Automatic or manually
  selected answer/reasoning speech replaces ordinary-chat music only when its
  first audible buffer starts, so network and TTS preparation do not create a
  silent gap;
- live preview segmentation, adaptive VAD floors, session-resume audio
  overrides, draft-endpoint stability, and final-transcript selection policy
  live under structured `audio` sections in the shared app/profile
  `config.json` (`vad`, `endpoint`, `partial_transcript`, `preview`,
  `session_resume`, `draft_endpoint`, `final_selection`), not hardcoded in
  server code;
- use `scripts/install/check.sh` after moving any root;
- keep provider credentials in Pi's own private configuration, never in this
  repository.

`ProfileRuntime.resolveSession` is now the single in-process boundary for
reading merged app/profile product configuration. It resolves the active
language and gives runtime consumers an immutable-by-interface snapshot;
Voice/STT/TTS, Conversation settings, startup, and tool checks do not read
effective profile properties independently. Client settings mutation and the
remaining durable history writes still use their existing storage adapters and
will move behind narrower Profile Runtime ports only when the corresponding
real caller is extracted. The complete ownership model is in
[Runtime Roles and Deployment](Runtime%20Roles%20and%20Deployment.md).
