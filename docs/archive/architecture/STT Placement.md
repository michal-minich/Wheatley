# STT Placement

Wheatley can place preview and final Whisper inference independently. The
authoritative `wheatleyd` process still owns capture, VAD, draft assembly,
transcript acceptance, final selection, metrics, and persisted audio. A local
recognizer owns a child `whisper-server`; a remote recognizer sends the same
multipart WAV request directly to an already-running trusted-LAN
`whisper-server`.

The active placement is:

```text
primary Mac: wheatleyd -> HTTP PCM/WAV over LAN
remote Mac:              small Whisper    (preview, port 8792)
                         large-v3 Whisper (final, port 8791)
```

No authentication, discovery, proxy, or service wrapper is added. This is a
local trusted-network deployment. Health is `GET /health`; recognition is
`POST /inference`; Wheatley records the complete remote request duration as
the existing STT inference metric. A remote failure is visible and does not
silently change placement during the turn.

## Configuration

```json
{
  "stt": {
    "preview": {
      "type": "remote_whisper_cpp",
      "endpoint": "http://speech-server.local:8792",
      "model": "models/whisper/ggml-small.bin",
      "beam_size": 1,
      "max_context_tokens": -1
    },
    "final": {
      "type": "remote_whisper_cpp",
      "endpoint": "http://speech-server.local:8791",
      "model": "models/whisper/ggml-large-v3.bin",
      "beam_size": 3,
      "max_context_tokens": 0
    },
    "request_timeout_seconds": 600
  }
}
```

Both roles use the same recognizer API and request shape. Only lifecycle
differs: local starts and supervises the configured binary; remote calls the
configured fixed endpoint. The final installer assigns port 8791 and the
preview installer assigns port 8792.

## Deployment and evidence

`scripts/stt/install-remote.sh final` installs pinned whisper.cpp 1.8.6,
verifies the model checksum, and owns the final server through a user
LaunchAgent on the remote Mac. The generic `services/stt/run.sh` remains a thin
launcher around upstream `whisper-server`.

The 2026-08-13 placement replay used 595 real historical segmented-preview
requests and six full final utterances while Qwen3.6 27B Q4_K_M was resident at
131,072 context on the remote 64 GB M4 Pro:

| Workload | Primary Mac | Remote M4, including LAN | Difference |
| --- | ---: | ---: | ---: |
| Preview mean | 858 ms | 628 ms | Remote 27% faster |
| Preview P95 | 1,675 ms | 1,040 ms | Remote 38% faster |
| Final mean | 6.70 s | 3.40 s | Remote 49% faster |

Preview final text matched on seven of eight long samples; the eighth differed
only as `Clock ticking` versus `Clock clicks`. Final output differed in ordinary
Whisper wording/punctuation on five longer recordings despite byte-identical
model files, so placement must not be expected to produce byte-identical text
across different Apple generations/builds.

With Qwen, large-v3, and the temporary small worker loaded, system memory
pressure reported 43–57% free, swap stayed unchanged at 40.62 MiB, and the
large/small Whisper processes used about 3.8 GiB/1.0 GiB RSS after sustained
inference. Qwen and both Whisper services remain loaded/running.

The raw benchmark corpus is intentionally not included because it contains
private recorded speech; the aggregate measurements above are retained.
