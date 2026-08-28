# Session Queue Discovery

Status: implementation baseline, 2026-08-21.

## Ownership

The local D server owns admission and execution for local Conversation
placement. A remote Conversation placement continues to send execution to its
remote D server; the queue must be created and mutated at that execution owner,
not in the browser or in the HTTP request task. Pi remains an external
execution dependency and does not get a second queue.

The new `SessionQueueStore` owns one atomic `queue.json` per session. The
`SessionQueue` aggregate owns sequence, revision, idempotency, and legal state
transitions. Existing `HistoryStore` turn files remain detailed turn records;
`presentation.jsonl` remains the ordered observer projection.

## Queue representation

The canonical queue file is intentionally small:

```json
{
  "schema_version": 1,
  "session_id": "2026/08/21/12_00_00",
  "revision": 4,
  "next_sequence": 3,
  "items": [
    {
      "id": "device-1",
      "session_id": "2026/08/21/12_00_00",
      "sequence": 1,
      "kind": "user",
      "source": "text",
      "device_id": "browser-a",
      "submitted_at": "2026-08-21T12:00:00.000000Z",
      "state": "ready",
      "text": "hello",
      "model": "pi:test",
      "reasoning_mode": "off",
      "language": "en"
    }
  ]
}
```

An admission request has a stable ID and immutable fingerprint. Reusing the ID
with the same fingerprint returns the canonical item; a different fingerprint
is rejected. A store mutation validates and atomically publishes the next
revision while holding the session storage lock. No external Pi/STT work is
started before the relevant durable transition.

## Current integration boundaries

- Text admission enters `ConversationRuntime` through `ConversationPort.run`.
- Live voice currently performs final STT before calling that port. The queue
  integration moves reservation to the endpoint boundary and uses the same
  stable submission ID when preparation completes.
- Scheduled work enters through `Scheduler` and must use an ordinary queue item,
  preserving its barrier semantics.
- The dispatcher claims the earliest ready non-terminal item and leaves
  preparing items blocking. Pi loss before the external call leaves `ready`;
  loss after that boundary becomes `interrupted`.
- Queue lifecycle events are emitted only after queue publication. Clients
  continue to use presentation/Conversation details for rendering, with queue
  state added as the canonical admission projection.

## Capability boundary

The currently bundled Pi adapter exposes execution and steering, but no
separate context-prefill operation. Exactly-once Model context is therefore
owned by the first real Pi turn, rather than a bootstrap marker or fake hidden
user turn.

## Verification baseline

Before this change, accepted order started after final STT, process-local lanes
were the executable ordering authority, and startup failed pending/running
turns. Existing server and client checks pass on the starting revision; the
queue work must replace those authorities without migrating live profiles.
