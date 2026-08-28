# Session Queue Verification

Status: independent audit and correction pass, 2026-08-21.

## Audit result

The Luna commit series established the queue domain and dispatcher, but the
first implementation still had several contract gaps. This pass fixed them in
code rather than treating the earlier verification note as evidence:

1. Live voice now reserves its immutable sequence at the endpoint transition,
   before FFmpeg Opus encoding and final STT. The timestamp is the server's
   endpoint/submit time, not final-transcript completion time.
2. Queue operations travel with Conversation placement. Local and remote modes
   no longer create competing queue owners; snapshot, reservation, preparation,
   cancellation, and compaction are proxied to the selected authority.
3. Queue lifecycle mutations are durable presentation entries and are sent
   directly on the shared session stream. Browser and console restore those
   entries after reconnect, including a preparing voice placeholder and a
   terminal cancellation/failure.
4. Terminal prefixes compact only after the terminal projection is durable.
   Completed turn history owns results; queue sequence remains monotonic and
   may contain gaps after terminal handoff.
5. Confirmed cancellation closes the associated pending history turn without
   manufacturing a Pi failure. Repeated cancellation remains harmless through
   the durable queue lifecycle projection even after active-queue compaction.
6. Migration now imports only genuinely active pending/running work. Completed,
   failed, and stopped history does not become queue work, and startup removes
   terminal history records produced by the first queue migrator without
   renumbering surviving items.
7. The browser resets queue revision between sessions, creates queue-only voice
   bubbles, reconciles them with the later canonical turn, and sorts the queue
   tail by server sequence. Cancelled bubbles are disabled/gray. The console
   announces external preparing/ready items immediately and deduplicates the
   later accepted event.
8. A pre-reserved voice item must retain its source, device, model, reasoning,
   language, and memory policy. Dormant admission-barrier code was removed and
   the remaining short mutex is named for its actual role: atomic admission.
9. Live migration exposed two history-reader defects: older valid turns may
   omit `metrics`, and session-level Pi metadata was reparsed for every turn
   while each session query reloaded the entire profile. Missing/legacy metrics
   now mean no reasoning-duration data, session reads are scoped and cached,
   and migration/recovery completes before the HTTP listener is exposed.
10. Real console voice testing exposed a daemon-dispatch audio bug: recovered
    `user.opus` was moved onto itself during final persistence, deleting the
    accepted artifact and leaving the queue item running. Audio attachment is
    now idempotent; the exact cross-thread recovery case has regression coverage.
11. The console's local-submission registry was accidentally thread-local even
    though its observer reads it from a background thread. It is now one
    mutex-protected process-wide registry, eliminating the observed native
    `SIGSEGV` and restoring clean answer rendering and exit.
12. Local Whisper shutdown no longer enters an unbounded process wait after the
    event loop begins stopping. Graceful server shutdown is bounded and was
    exercised after loading both preview and final Whisper models.

## Machine verification

From `server/wheatleyd` after the corrections:

- `dub test --config=debug` — 108 modules passed;
- `dub build --config=debug` — passed;
- `dub build --config=console` — passed.

From `client`:

- `npm run check` — lint, typecheck, and production build passed; Vite
  transformed 138 modules;
- `npm run native:client:build` — native-target typecheck and build passed;
  Vite transformed 138 modules.

The D tests cover queue transitions, immutable order, preparation blocking and
deadline expiry, idempotent reservation, serialization, terminal compaction,
migration filtering, remote placement delegation, and restart-dispatch
building blocks. They now also cover legacy absent/null/non-object metrics.
Static client checks cover the expanded queue/presentation contracts.
Both Python probes compile and `git diff --check` is clean.

The reusable deterministic probe
`scripts/probes/session-queue-e2e.py` passed all 20 checks. It covers immutable
multi-client order, queued cancellation and idempotence, claim/cancel conflict,
preparing barriers, preparing and running restart semantics, no Pi delivery for
cancelled work, canonical queue hashes across restart, history/recent-session
loading, console replay and reconnection, Model context ordering, and daemon
survival. Latest evidence:
`output/session-queue-e2e/20260821T205636Z/results.json`.

A separate real-media console pass used the saved `no.wav` fixture through the
actual Opus upload, preview Whisper, final Whisper, endpoint reservation, fake
Pi RPC, streamed console answer, TTS preparation, history save, and queue
compaction. It exited zero, printed `Synthetic multi-turn response completed.`,
left the queue empty, and retained the 3,699-byte `user.opus`; the terminal turn
is `output/session-queue-e2e/20260821T203122Z/profiles/queue-e2e/sessions/2026/08/21/20_55_38`.

The corrected local LAN daemon was started against the live supported sessions,
completed migration, and was restarted again from the canonical queues. A fresh
browser load restored the full profile/recent-session UI without startup errors;
two browser clients restored the same session, Model context, turns, cancellation,
and interrupted failure. The server-unavailable screen remained visible when
the API was intentionally down, and the home/history view recovered after the
daemon returned. Startup exceptions now print their full trace instead of hiding
the failing subsystem behind a one-line message.

## Remaining gates

- Live supported profiles have now passed the migration and restart path on the
  local LAN daemon. The old history reader still acts as the migration oracle;
  a controlled isolated-copy comparison and final one-reader cutover remain
  separate cleanup work.
- Restarted `preparing` voice work is made explicitly terminal and cannot block
  later work. Re-running final STT from the staged Opus artifact is not yet
  implemented.
- Remote placement still needs a paired two-daemon integration pass beyond the
  delegation unit coverage. The local deterministic matrix and real local voice
  path are complete.
- Microphone endpoint timing, chime timing, physical TTS silence for Model
  context, and acoustic behavior remain human/device checks.

Within those explicit boundaries, the code now matches the approved simple
model: one ordered active queue, one running item, one placement-aware owner,
and STT/Pi/TTS/presentation as separate concerns.
