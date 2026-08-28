# Raspberry Pi 5 Offline Deployment

Last researched: 2026-08-27.

## Outcome

Build a self-contained, headless Wheatley on a **Raspberry Pi 5 with 16 GB
RAM**, active cooling, and NVMe storage. It should keep its LLM and one
multilingual speech recognizer resident, run the existing console client, keep
separate local profiles and files for multiple people, use local tools while
offline, add web search when Wi-Fi is available, and use Bluetooth or USB
audio. The already-proved LSC Wi-Fi camera becomes the next, separately gated
vision slice.

This is a deliberately smaller Pi deployment profile, not the full Mac-class
voice stack described in [Portable Local Hardware](Portable%20Local%20Hardware.md).
The old `small`-draft plus `large-v3`-final Whisper pair is replaced by one
rolling recognizer. The local LLM is also much smaller than Wheatley's current
Qwen deployment.

The install instructions below are concrete, but the complete first install
has **three required Wheatley code/config changes** that do not exist on
2026-08-27:

1. a single-worker `latest_draft` STT acceptance policy that does not run the
   current final recognizer after endpointing;
2. a Pi-specific configuration and release run profile, including one Pi agent
   run at a time;
3. a `llama.cpp` provider entry whose LFM reasoning and tool-call behavior has
   passed the real Pi acceptance matrix.

Do not deploy by setting both current STT roles to the same model. Wheatley owns
two independent worker slots, so that would still load or contact two logical
workers and still perform the post-endpoint final request.

## Decision

Use this first resident stack:

| Role | First choice | Resident allocation | Why |
| --- | --- | ---: | --- |
| Agent LLM | LiquidAI `LFM2.5-8B-A1B` official `Q4_K_M` GGUF | roughly 6–7 GB including modest KV/runtime state | 8.3B total but 1.5B active MoE; specifically tuned for assistants, tools, and edge inference |
| Speech recognition | multilingual Whisper `base-q5_1`, greedy/beam 1 | comfortably below 0.3 GB | one fast rolling model; English and Slovak require the multilingual model, never `.en` |
| Agent/tool runtime | Wheatley + Pi/Node | roughly 0.3–0.8 GB | existing profiles, local files, Bash, web search, memory, and queue ownership |
| Speech output | Piper, English first; benchmark Slovak Piper against current Supertonic | roughly 0.1–0.3 GB during use | smallest proven CPU path |
| OS, audio, networking, filesystem cache | Raspberry Pi OS Lite 64-bit | roughly 1.5–2.5 GB | honest operating margin |
| Later visual observer | `LFM2.5-VL-1.6B` Q4 plus Q8 projector | about 1.31 GB of files plus runtime state | small image/OCR sidecar for LSC frames |

The initial non-vision total should land around **9–11 GB resident**, leaving a
real margin inside 16 GB. This is a planning estimate, not a Pi measurement.
The deployment fails acceptance if it swaps under the sustained mixed workload.

### Why LFM2.5-8B-A1B

[Liquid's official model card](https://huggingface.co/LiquidAI/LFM2.5-8B-A1B)
describes a text-only 8.3B-total/1.5B-active model with 24 layers, 128K native
context, explicit reasoning, and function calling. The official
[Q4_K_M GGUF](https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-GGUF) is 5.16 GB
and has direct `llama.cpp` support. Liquid recommends temperature `0.2`,
`top_k=80`, and repetition penalty `1.05`.

This is the strongest plausible first hypothesis, not a measured Pi result.
Liquid's published CPU claims are not Raspberry Pi 5 measurements, and its
listed languages do not include Slovak. English/Slovak conversational quality,
tool syntax, thinking overhead, time to first token, and decode speed are
therefore hard gates on the actual device.

Liquid also publishes a 328M DSpark speculative drafter and reports about 2.5×
speed-up with SGLang. Do not include it in the first Pi build: that result does
not establish the same gain in the CPU `llama.cpp` path. It is also unrelated
to Wheatley's rolling **speech** draft; the two kinds of drafting solve
different problems.

The first fallback is
[`LFM2.5-2.6B`](https://huggingface.co/LiquidAI/LFM2.5-2.6B), a 2.69B text
model Liquid positions for agentic workloads and under 2.5 GB runtime memory.
It has official GGUF support and a broader listed language set, but still does
not list Slovak and is a pure reasoning model that always thinks before
answering. It is a worthwhile measured challenger if the MoE's full-weight
memory traffic or thinking behavior disappoints on Pi; its vendor AMD/Apple
throughput does not predict Pi speed.

### Vision: sidecar, not a giant vision MoE

The original concern that Liquid has no vision model is now outdated. Liquid
has official small VLMs:

| Candidate | Composition | Context/languages | Official Q4 + projector files | Pi role |
| --- | --- | --- | ---: | --- |
| [`LFM2.5-VL-1.6B`](https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B) | about 1.2B language backbone + 400M SigLIP2 vision encoder | 32K, 8 listed languages | about 1.31 GB | recommended camera/OCR sidecar |
| [`LFM2.5-VL-3B`](https://huggingface.co/LiquidAI/LFM2.5-VL-3B) | about 2.6B language backbone + 400M SigLIP2 | 32K, 16 listed languages | about 2.26 GB | quality challenger only if memory and latency remain healthy |

Neither is MoE. That is acceptable: a credible vision MoE with a larger total
parameter count is a poor fit beside an always-resident LLM, Whisper, and the
rest of Wheatley in 16 GB. Use the 1.6B VLM to turn a selected camera frame into
a short factual description/OCR result, then give that text to the stronger
LFM2.5-8B agent. Do not move the entire conversation and tool loop to the
weaker VLM.

The alternative single-model experiment is
[`Gemma 4 E2B`](https://huggingface.co/google/gemma-4-E2B), which accepts text,
images, and audio and supports function calling. A public reproducible
[Pi 5 benchmark](https://github.com/geisten/geistlib/blob/main/benchmark/results/PI5.md)
reports roughly 36–39 prompt tokens/s and a best decode result near 6.8
tokens/s for its Q4_K_M build on a 4 GB Pi 5 with four threads. It is worth one
comparison run, but it misses Wheatley's established 8 tokens/s floor and is a
less attractive agent brain than the LFM text model plus visual sidecar.

## Runtime shape

```text
USB/Bluetooth microphone
        |
        v
console client -- 16 kHz mono audio --> wheatleyd (127.0.0.1:8765)
                                          |         |
                                          |         +--> Piper --> local speaker/headset
                                          |
                                          +--> always-warm whisper-server (127.0.0.1:8792)
                                          |      rolling bounded multilingual draft
                                          |
                                          +--> Pi coding agent (one run at a time)
                                                     |
                                                     +--> llama-server (127.0.0.1:8080)
                                                     +--> profile workspace files
                                                     +--> read/write/edit/Bash/memory
                                                     +--> web search/fetch when online

Next slice only:
LSC RTSP --> persistent frame worker --> vision llama-server (127.0.0.1:8081)
                                            --> description/OCR --> main Pi turn
```

All three HTTP servers bind to `127.0.0.1`. Wi-Fi is for outbound search and
the camera LAN, not for exposing the unauthenticated Wheatley, Whisper, or LLM
APIs. Use SSH for administration.

One daemon serves every profile. Each person gets a separate profile directory
and console device ID. On this CPU, `pi.max_concurrent_runs` is `1`; simultaneous
messages stay in Wheatley's durable queue instead of running competing model
decodes.

## Hardware and firmware

Required:

- Raspberry Pi 5 16 GB;
- official 27 W USB-C power supply or an equivalently reliable supply;
- active cooler or a good fan case;
- NVMe SSD and PCIe adapter/HAT for OS, model weights, histories, and profiles;
- Ethernet for first setup if convenient, then 5 GHz Wi-Fi;
- a USB microphone/speaker or USB audio dongle for the reliable baseline.

Bluetooth can be added, but duplex headset mode uses the lower-quality HFP/HSP
profile. The safest conversational arrangement is a USB microphone plus
Bluetooth output, or a USB headset. Bluetooth pairing, route restoration after
boot, acoustic echo, and physical volume remain human checks.

Use Raspberry Pi Imager to install **Raspberry Pi OS Lite, 64-bit** to NVMe.
In Imager's customisation screen set:

- hostname `wheatley-pi`;
- a non-default administrator account with SSH public-key login;
- Wi-Fi SSID/password and country;
- timezone `Europe/Bratislava`;
- SSH enabled, password authentication disabled when key login is proven.

Raspberry Pi's current headless, Wi-Fi, Bluetooth, and audio configuration is
documented in the official
[configuration guide](https://www.raspberrypi.com/documentation/computers/configuration.html).

After the first login:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y \
  build-essential cmake ninja-build git curl jq ffmpeg lsof tmux \
  libopenblas-dev libssl-dev pkg-config python3 python3-venv python3-pip \
  pipewire pipewire-pulse wireplumber bluez pulseaudio-utils
sudo reboot
```

Then prove cooling and storage before installing models:

```bash
uname -m
findmnt /
vcgencmd measure_temp
vcgencmd get_throttled
free -h
```

Expected architecture is `aarch64`; the root filesystem should be on NVMe.
`get_throttled=0x0` is the clean starting state. Do not use swap to make a
model combination appear to fit.

## Dedicated runtime user and directories

Run Wheatley as an unprivileged account. Pi's Bash tool inherits OS
permissions, so the Unix user boundary is the real filesystem safety boundary.
Do not put this account in `sudo` or grant it broad home-directory access.

```bash
sudo useradd --create-home --shell /bin/bash wheatley
sudo usermod -aG audio,video,bluetooth wheatley
sudo install -d -o wheatley -g wheatley /srv/wheatley
sudo install -d -o wheatley -g wheatley /srv/wheatley/models
sudo loginctl enable-linger wheatley
sudo -iu wheatley
```

Use that last command for Wheatley-owned checkout, model, and build work. Return
to the administrator shell for the explicitly `sudo` machine-install commands
below; the `wheatley` account itself deliberately cannot run them.

Proposed durable layout:

```text
/srv/wheatley/repo/                  Wheatley checkout
/srv/wheatley/app-data/              private config, queues, sessions, tools
/srv/wheatley/profiles/<profile>/    separate profile instructions and files
/srv/wheatley/models/llm/            main GGUF
/srv/wheatley/models/whisper/        one multilingual Whisper model
/srv/wheatley/models/vision/         later VLM and projector
```

Back up `app-data` and `profiles`; model files can be re-downloaded. Keep
individual profile directories mode `0700` when users should not browse one
another's data. Wheatley's shared daemon can still access all of them as the
service account, so this is application separation rather than hostile-user
isolation.

## Install Node, Wheatley, and Pi

Use the current Node 24 LTS ARM64 binary. Pin the exact version and verify its
published checksum instead of piping an installer into the shell. At the time
of this research the latest 24.x release is `v24.20.0`; check the official
[Node 24 release directory](https://nodejs.org/download/release/latest-v24.x/)
before installing and record the actual version in the deployment log.

Example for `v24.20.0`:

```bash
cd /tmp
curl -fLO https://nodejs.org/download/release/v24.20.0/node-v24.20.0-linux-arm64.tar.xz
curl -fLO https://nodejs.org/download/release/v24.20.0/SHASUMS256.txt
grep ' node-v24.20.0-linux-arm64.tar.xz$' SHASUMS256.txt | sha256sum -c -
sudo tar -xJf node-v24.20.0-linux-arm64.tar.xz -C /opt
sudo ln -sfn /opt/node-v24.20.0-linux-arm64 /opt/node-lts
```

Add `/opt/node-lts/bin` to the runtime environment, clone Wheatley, and use
its bootstrap without the current `--voice` option:

```bash
export PATH=/opt/node-lts/bin:$PATH
git clone https://github.com/michal-minich/Wheatley.git /srv/wheatley/repo
cd /srv/wheatley/repo
cp wheatley.env.example wheatley.local.env
```

Set these private paths in `wheatley.local.env`:

```bash
WHEATLEY_APP_DATA_ROOT="/srv/wheatley/app-data"
WHEATLEY_PROFILES_ROOT="/srv/wheatley/profiles"
```

Then bootstrap:

```bash
scripts/install/setup.sh
```

That installs Wheatley's pinned Pi coding agent (`0.83.0`), its private Pi web
extension, D toolchain, Node packages, and current binaries. The current setup
also builds the browser and debug D configurations; the Pi production slice
must add and test explicit release daemon and console builds. Do not assume the
debug bootstrap binaries are the final appliance binaries.

The D installer currently pins LDC `1.42.0`, for which an official Linux ARM64
archive exists. If automatic installation fails, use the same version from the
[official LDC release](https://github.com/ldc-developers/ldc/releases/tag/v1.42.0)
and keep it under Wheatley's local toolchain directory rather than changing the
machine-wide compiler.

## Compile `llama.cpp` for Pi CPU

Start with CPU plus OpenBLAS. Vulkan adds another variable without first proving
a useful end-to-end gain for this workload.

```bash
cd /srv/wheatley
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
git rev-parse HEAD | tee /srv/wheatley/llama-cpp.commit
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=OpenBLAS
cmake --build build --target llama-server llama-cli llama-bench -j 4
```

The recorded commit is part of the deployment. After the first successful
acceptance run, pin that commit in the provisioning script. Upgrading
`llama.cpp` is a measured model/runtime change, not routine unattended package
maintenance. The upstream [server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
is authoritative for flags, tool templates, prompt caching, and its still
experimental multimodal path.

Download the official model without storing a Hugging Face token:

```bash
mkdir -p /srv/wheatley/models/llm
cd /srv/wheatley/models/llm
curl -fL --continue-at - \
  -o LFM2.5-8B-A1B-Q4_K_M.gguf \
  'https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-GGUF/resolve/main/LFM2.5-8B-A1B-Q4_K_M.gguf'
sha256sum LFM2.5-8B-A1B-Q4_K_M.gguf | tee LFM2.5-8B-A1B-Q4_K_M.gguf.sha256.local
```

The local checksum records exactly what was accepted. Before automating future
machines, compare it with the publisher's current file metadata and pin it in
the provisioner.

First server command:

```bash
/srv/wheatley/llama.cpp/build/bin/llama-server \
  --host 127.0.0.1 --port 8080 \
  --model /srv/wheatley/models/llm/LFM2.5-8B-A1B-Q4_K_M.gguf \
  --threads 4 --threads-batch 4 \
  --ctx-size 8192 --parallel 1 \
  --batch-size 512 --ubatch-size 128 \
  --jinja --cache-prompt --cache-reuse 256
```

Keep `--parallel 1`. Start with 8K context even though the model supports 128K:
long KV state and prompt processing are exactly what the Pi cannot afford.
Benchmark `--flash-attn on` and off rather than assuming either. The server's
built-in filesystem tools are not enabled; Pi remains the sole tool-policy and
execution owner.

Register the server in Pi as an OpenAI-compatible local provider. The initial
model entry should advertise text input, 8192 context, at most 512 output
tokens, zero cost, no developer role, and no usage-in-stream requirement.
Preserve Liquid's Jinja tool template. Whether Pi should expose a selectable
reasoning mode cannot be decided from metadata: LFM emits explicit chain of
thought, and the exact `llama.cpp`/Pi channel behavior must be observed. Fail
acceptance if thought text leaks into normal output or forces unacceptable
spoken latency.

Pi reads custom providers from `~/.pi/agent/models.json`. First query
`http://127.0.0.1:8080/v1/models` and use its exact returned ID. For the command
above it should be the GGUF basename, yielding this candidate configuration:

```json
{
  "providers": {
    "pi-local-lfm": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "local-no-auth",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "supportsUsageInStreaming": false,
        "maxTokensField": "max_tokens"
      },
      "models": [
        {
          "id": "LFM2.5-8B-A1B-Q4_K_M.gguf",
          "name": "LFM2.5 8B A1B Pi Q4",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 8192,
          "maxTokens": 512,
          "cost": {
            "input": 0,
            "output": 0,
            "cacheRead": 0,
            "cacheWrite": 0
          }
        }
      ]
    }
  }
}
```

`reasoning: true` tells Pi to preserve a separate reasoning channel if the
server supplies one; `supportsReasoningEffort: false` prevents Pi from sending
an unsupported OpenAI control parameter. If the live stream does not separate
reasoning from answer text, stop and correct the provider/template boundary.
Do not merely relabel the model `reasoning: false`, because that would make Pi
treat leaked chain of thought as ordinary answer and TTS material.

## Compile one multilingual `whisper.cpp` worker

The official [Whisper model table](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md)
lists multilingual base at 142 MiB, small at 466 MiB, large-v3 at 2.9 GiB, and
large-v3-turbo at 1.5 GiB before quantization. The current Mac-oriented final
model is therefore not the Pi baseline.

Build the same way as `llama.cpp` and pin the accepted commit:

```bash
cd /srv/wheatley
git clone https://github.com/ggml-org/whisper.cpp.git
cd whisper.cpp
git rev-parse HEAD | tee /srv/wheatley/whisper-cpp.commit
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=OpenBLAS
cmake --build build --target whisper-server whisper-cli whisper-bench -j 4
mkdir -p /srv/wheatley/models/whisper
./models/download-ggml-model.sh base-q5_1 /srv/wheatley/models/whisper
```

Do not use `base.en-q5_1`; the `.en` model cannot meet the Slovak requirement.
The exact downloaded filename should be confirmed by the script and recorded
in the private Wheatley configuration.

Start one fixed server and let Wheatley use it as a
`remote_whisper_cpp` recognizer even though it is on the same machine:

```bash
/srv/wheatley/whisper.cpp/build/bin/whisper-server \
  --host 127.0.0.1 --port 8792 \
  --model /srv/wheatley/models/whisper/ggml-base-q5_1.bin \
  --threads 4
```

Run `whisper-server --help` against the pinned binary before making the service
unit; flag spellings can change upstream. The important contract is a resident
server at `http://127.0.0.1:8792`, with health at `/health` and inference at
`/inference`. Wheatley already supports that protocol.

After the new `latest_draft` policy exists, its STT role should resemble:

```json
{
  "stt": {
    "acceptance_policy": "latest_draft",
    "preview": {
      "type": "remote_whisper_cpp",
      "endpoint": "http://127.0.0.1:8792",
      "model": "models/whisper/ggml-base-q5_1.bin",
      "beam_size": 1,
      "max_context_tokens": -1
    },
    "request_timeout_seconds": 120
  }
}
```

This JSON is a target contract, not a currently accepted config shape.

## Install lightweight speech output

Expose the pinned Whisper build while running Wheatley's audio installer so it
can link the compiled tools and create the pinned Piper/Supertonic Python
environment:

```bash
cd /srv/wheatley/repo
export PATH=/srv/wheatley/whisper.cpp/build/bin:$PATH
scripts/install/audio.sh
```

Do **not** run the current `scripts/install/models.sh english` on the Pi: it
unconditionally downloads both full `small` and `large-v3` Whisper files. Until
that installer gains a Pi model set, download only the two small Piper voices
directly through its already-pinned Python environment:

```bash
/srv/wheatley/app-data/environments/tts/bin/python -m piper.download_voices \
  --data-dir /srv/wheatley/app-data/models/piper \
  en_GB-alan-medium sk_SK-lili-medium
sha256sum /srv/wheatley/app-data/models/piper/*.onnx*
```

The private Pi config should switch Slovak from today's Supertonic default to
Piper `sk_SK-lili-medium` for the first constrained build. Benchmark the two on
the real device and retain Supertonic only if its audible improvement justifies
its CPU, memory, and startup cost. English stays on Piper
`en_GB-alan-medium`. Preserve the accepted voice-file hashes in provisioning.

## Rolling speech policy and timing

There is no display, but continuous draft inference still matters: it spends
recognition time while the person is speaking so little or none remains after
silence. At the endpoint Wheatley accepts the newest **complete successful**
rolling result. It does not transcribe the full recording again.

Use these first measurements, not hard-coded truth:

```json
{
  "audio": {
    "partial_transcript": {
      "interval_seconds": 1.5,
      "min_audio_seconds": 0.8
    },
    "preview": {
      "stable_min_audio_seconds": 2.5,
      "mutable_min_audio_seconds": 6.0,
      "stable_min_words": 5,
      "mutable_min_words": 10,
      "soft_boundary_window_seconds": 9.0,
      "max_mutable_window_seconds": 12.0,
      "stable_prompt_words": 32,
      "voice_grace_seconds": 2.5
    },
    "endpoint": {
      "trailing_silence_keep_seconds": 1.0,
      "trailing_silence_keep_cap_seconds": 2.0
    }
  },
  "clients": {
    "web": {
      "speech_commit_delay_seconds": 3
    }
  }
}
```

The client preference is still named `web` in today's shared config even when
the console consumes it. Its current validated range is an integer from 1 to
12 seconds.

Tune from real English and Slovak recordings:

1. Save representative clean, normal-room, and far-field samples, including
   profile-specific names, domain vocabulary, corrections, and mixed-language terms.
2. Measure inference for 8, 12, and 16 second rolling windows with the LLM
   resident and generating, not on an idle speech-only machine.
3. Keep the largest window whose P95 Whisper request time is at most about 70%
   of the rolling interval. If requests overlap or queue, the interval is too
   short or the model/window is too large.
4. Set the interval near `1.5 × P95 inference`, clamped initially to 1.0–2.5
   seconds. This leaves roughly one-third of each interval for capture,
   scheduling jitter, and competing LLM work.
5. Set commit delay to at least `interval + P95 inference + 0.25 s`, rounded up
   to the supported whole second. Three seconds is only a starting hypothesis.
6. Target P95 endpoint-to-authoritative-transcript time below 500 ms when the
   newest rolling request has completed.

If multilingual base misses important speech, benchmark `small-q5_1` in the
same single-worker design. Keep it only if name/vocabulary accuracy improves
materially and P95 stays inside the rolling budget. Do not restore a second
larger final worker by default; that recreates both resident memory and
post-endpoint latency.

Manual submit and spoken `submit` should wait for or trigger one last bounded
mutable-window request when the current draft does not include the captured
tail. They should never cause a full-recording second-model transcription.
Persist the original Opus/WAV artifact so a failed transcript can still be
inspected and future model changes can be replayed.

## Multiple profiles and local tools

Create each profile through the normal Wheatley layout, starting from the
generic example rather than copying personal profile contents into the image:

```bash
cp -R /srv/wheatley/repo/examples/profiles/wheatley /srv/wheatley/profiles/primary
cp -R /srv/wheatley/repo/examples/profiles/wheatley /srv/wheatley/profiles/secondary
chmod -R go-rwx /srv/wheatley/profiles/primary /srv/wheatley/profiles/secondary
```

Give each profile:

- its own `system.md`, `config.json`, `files/`, sessions, memory, model
  preference, language, and console device ID;
- only the personal material intentionally copied to that device;
- a normal workspace path of `files`, so read/write/edit operations land in
  that profile by default.

Pi should expose the existing small surface: `read`, `write`, `edit`, `bash`,
`remember`, `web_search`, and `fetch_content`; later add `capture_photo`.
Wheatley invokes Pi from the selected profile workspace and uses approval mode,
but Bash can still reach everything the service account can reach. The device
must have no secrets or unrelated mounts that those profiles should not access.

Web search works opportunistically over Wi-Fi through Wheatley's pinned Pi web
extension. Offline search/fetch failures must be visible tool failures; local
conversation, files, memory, STT, TTS, and Bash continue. Do not dynamically
rewrite model or tool configuration when Wi-Fi comes and goes.

Create one console run profile per person by copying `run-profiles/local.json`
and changing at least:

```json
{
  "console": {
    "command": "voice",
    "profile": "secondary",
    "device_id": "pi-console-secondary",
    "language": "en",
    "load_memory": true
  }
}
```

Run only one foreground console on a single microphone at a time. Other people
can use separate terminals or later physical profile buttons, while Wheatley's
server queue preserves admission order.

## Bluetooth and console audio

Raspberry Pi OS Lite may need PipeWire installed explicitly, as above. Check
the audio server in the service user's session:

```bash
systemctl --user status pipewire pipewire-pulse wireplumber
pactl info
pactl list short sources
pactl list short sinks
```

Pair a device interactively:

```bash
bluetoothctl
power on
agent on
default-agent
scan on
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
connect AA:BB:CC:DD:EE:FF
quit
```

Select and persist the desired source/sink with `wpctl` or `pactl`. For a
headset microphone choose an HFP/HSP card profile; A2DP is output-quality only.
Then prove Wheatley's actual Linux capture path, which uses FFmpeg's Pulse
interface through PipeWire compatibility:

```bash
ffmpeg -f pulse -i default -t 5 -ac 1 -ar 16000 /tmp/wheatley-mic.wav
ffplay -nodisp -autoexit /tmp/wheatley-mic.wav
```

If a route does not return after reboot, add a small user service that connects
the trusted Bluetooth MAC and selects the named source/sink after WirePlumber.
Do not hide route failure by silently recording a different microphone.

## User services

Use `systemd --user` so Wheatley and the console share the logged-in/lingering
PipeWire session. Put units in `/home/wheatley/.config/systemd/user/`.

`wheatley-llm.service`:

```ini
[Unit]
Description=Wheatley local LLM
After=network.target

[Service]
ExecStart=/srv/wheatley/llama.cpp/build/bin/llama-server --host 127.0.0.1 --port 8080 --model /srv/wheatley/models/llm/LFM2.5-8B-A1B-Q4_K_M.gguf --threads 4 --threads-batch 4 --ctx-size 8192 --parallel 1 --batch-size 512 --ubatch-size 128 --jinja --cache-prompt --cache-reuse 256
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
```

`wheatley-stt.service`:

```ini
[Unit]
Description=Wheatley rolling speech recognizer
After=network.target

[Service]
ExecStart=/srv/wheatley/whisper.cpp/build/bin/whisper-server --host 127.0.0.1 --port 8792 --model /srv/wheatley/models/whisper/ggml-base-q5_1.bin --threads 4
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
```

`wheatleyd.service` should run the release binary or a release-specific launcher,
not `dub run`, with explicit environment and private paths:

```ini
[Unit]
Description=Wheatley server
After=wheatley-llm.service wheatley-stt.service pipewire.service
Requires=wheatley-llm.service wheatley-stt.service

[Service]
WorkingDirectory=/srv/wheatley/repo
Environment=PATH=/opt/node-lts/bin:/srv/wheatley/app-data/toolchains/dlang/bin:/usr/local/bin:/usr/bin:/bin
Environment=WHEATLEY_APP_DATA_ROOT=/srv/wheatley/app-data
Environment=WHEATLEY_PROFILES_ROOT=/srv/wheatley/profiles
ExecStart=/srv/wheatley/repo/server/wheatleyd/wheatleyd /srv/wheatley/repo/run-profiles/pi-local.json
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
```

The actual LDC path and release binary path must be taken from the accepted
build; do not copy the illustrative path blindly. Add a separate console user
service only after microphone routing is reliable. During bring-up, run the
console inside `tmux` so crashes and logs remain obvious.

Enable and inspect:

```bash
systemctl --user daemon-reload
systemctl --user enable --now wheatley-llm wheatley-stt wheatleyd
systemctl --user status wheatley-llm wheatley-stt wheatleyd
journalctl --user -u wheatley-llm -u wheatley-stt -u wheatleyd -f
```

Service `Restart=on-failure` is for crashes. Invalid config, missing models,
and tool/provider incompatibility should remain explicit boot failures, not
trigger fallback to a remote model.

## Benchmark and acceptance matrix

### LLM in isolation

Record kernel, firmware, temperature, throttling, `llama.cpp` commit, model
checksum, flags, RSS, and wall power. Run at least:

```bash
/srv/wheatley/llama.cpp/build/bin/llama-bench \
  -m /srv/wheatley/models/llm/LFM2.5-8B-A1B-Q4_K_M.gguf \
  -p 512,2048,4096 -n 128 -t 3,4
```

Then use the actual server and Pi prompts. Pass gates:

- warm decode at least **8 tokens/s**;
- warm time to first visible answer token under 3 seconds around 2K prompt and
  under 6 seconds around 4K prompt;
- no unbounded explicit thinking before ordinary spoken answers;
- reliable structured calls for read, write, edit, Bash, web search, and a
  two-tool sequence;
- clean error behavior offline;
- useful English and Slovak replies, names, Minecraft vocabulary, and profile
  instruction following;
- no thermal throttling after 30 minutes of repeated tool turns.

Spoken ordinary answers should normally be prompted toward 80–160 tokens even
though the provider cap is 512. If LFM misses 8 tokens/s or its compulsory
reasoning makes voice latency poor, tuning is not a substitute for choosing a
different model. Compare, in this order:

1. `LFM2.5-2.6B` Q4 as the smaller agentic challenger;
2. `LFM2.5-1.2B-Instruct` as the fast non-thinking text floor;
3. Gemma 4 E2B Q4 as the one-model multimodal alternative;
4. another measured small multilingual instruct model only if it improves the
   complete tool/voice test, not just `llama-bench`.

### Speech under contention

Measure base-q5_1 and small-q5_1 against the saved bilingual corpus while:

- the LLM is idle but resident;
- the LLM is decoding a long answer;
- Piper is speaking;
- a web fetch is active;
- the system is hot after 30 minutes.

Record real-time factor, request P50/P95/max, transcript error categories,
endpoint-to-accepted latency, missed names, and peak RSS. Pass when rolling
requests never build an unbounded queue, P95 fits the timing rule above, and
final accepted text is usable without a second transcription.

### Whole appliance

Pass all of these before calling it deployed:

- boot from power-off to LLM/STT/Wheatley healthy without a desktop session;
- both models are genuinely resident before the first human turn, or are
  explicitly prewarmed by health probes;
- 50 mixed voice/text turns across at least two profiles;
- one queued turn from each profile while `max_concurrent_runs=1`;
- local read/write/edit/Bash and profile separation;
- web search online, then visible failure with Wi-Fi disabled, while local
  conversation continues;
- Bluetooth or USB route survives reboot; physical mic, chime, interruption,
  echo, TTS volume, and Slovak pronunciation checked by the intended users;
- `free -h` shows no active swap and `vcgencmd get_throttled` remains clean;
- abrupt reboot recovers durable sessions/queue according to Wheatley's current
  contract;
- services listen only on loopback.

Useful checks:

```bash
ss -ltnp
free -h
ps -eo pid,rss,pcpu,comm,args --sort=-rss | head -n 20
vcgencmd measure_temp
vcgencmd get_throttled
curl -fsS http://127.0.0.1:8792/health
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8765/api/health
```

Confirm the precise Wheatley health path from the accepted release; the final
command is illustrative if the API contract changes.

## LSC camera next slice

Do this only after the text/voice appliance passes. The verified camera path is
already recorded in [LSC Camera Eyes](LSC%20Camera%20Eyes.md):

```text
rtsp://192.168.50.240:554/main_ch
```

The camera exposes H.264 at 1920×1080 and about 15 fps. The one-shot PoC took
about 1–2 seconds, so the appliance should keep one persistent RTSP reader and
retain only the newest frame. On `capture_photo`:

1. select the newest sufficiently recent frame;
2. downscale to a bounded long edge, initially 768–1024 px;
3. send that one JPEG plus a narrow observation prompt to the 1.6B vision
   server on `127.0.0.1:8081`;
4. return its short factual description/OCR and the preserved image artifact to
   Pi;
5. let the main 8B LFM decide and use tools from text.

Compile no new runtime: the same accepted `llama.cpp` build supports the
projector with `--mmproj`, though upstream calls multimodal support experimental.
Download the official Q4 model and Q8 projector only when implementing this
slice. Keep the LSC device on a trusted isolated LAN; its PoC configuration is
not an Internet-facing security boundary.

If the main LFM plus Whisper plus 1.6B vision sidecar swaps or throttles, the
camera worker may load the VLM on demand as an explicit slower mode. Do not
silently evict the main conversational LLM.

## Implementation order

1. Add the single-worker `latest_draft` STT policy and deterministic tests for
   automatic endpoint, manual submit, spoken submit, in-flight last draft,
   recognizer failure, and queue reservation ordering.
2. Add a Pi release composition, checked sample config, release builds, and
   systemd templates. Keep APIs on loopback and `max_concurrent_runs=1`.
3. Install the Pi without camera or Bluetooth; benchmark LFM and both Whisper
   candidates using USB audio.
4. Freeze the accepted commits, hashes, model, timing, and provider config in a
   reproducible provisioner.
5. Add and physically verify Bluetooth routing.
6. Add the persistent LSC frame worker and 1.6B vision-description adapter.

The first hardware session decides the model and timings. The architecture
should stay fixed unless those measurements disprove it.

## Source notes

- Liquid model facts and usage: [LFM2.5-8B-A1B](https://huggingface.co/LiquidAI/LFM2.5-8B-A1B),
  [official GGUF](https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-GGUF),
  [VL-1.6B](https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B), and
  [VL-3B](https://huggingface.co/LiquidAI/LFM2.5-VL-3B).
- Inference runtime contracts: [`llama.cpp` server](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md),
  [`llama.cpp` multimodal](https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md),
  and [`whisper.cpp` models](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md).
- Hardware setup: [Raspberry Pi configuration documentation](https://www.raspberrypi.com/documentation/computers/configuration.html).
- Comparison evidence: [Gemma 4 E2B model card](https://huggingface.co/google/gemma-4-E2B)
  and [Geist Pi 5 benchmark](https://github.com/geisten/geistlib/blob/main/benchmark/results/PI5.md).
