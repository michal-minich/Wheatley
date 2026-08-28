# Portable Local Hardware

Last researched: 2026-08-20.

> Update, 2026-08-27: the rejection below applies to preserving Wheatley's
> full current Mac-class draft/final voice stack and model-quality floor. The maintainer
> has now chosen to investigate a deliberately reduced, console-only Pi 5 16 GB
> appliance using a fast MoE LLM and one rolling speech recognizer. That distinct
> design and its unresolved hardware gates are in
> [Raspberry Pi 5 Offline Deployment](Raspberry%20Pi%205%20Offline%20Deployment.md).

## Decision

Do **not** buy the offered Jetson Xavier NX 16 GB for €800 unless it is a
very cheap, complete experimental system and its short remaining life does not
matter. Xavier NX is a 2019-generation platform; its developer kit is already
end-of-life and NVIDIA's LPDDR4 supply notice makes July 2027 the last expected
shipment for the 8/16 GB modules. It has 21 dense INT8 TOPS, 59.7 GB/s memory
bandwidth, and 10--20 W modes.

For a self-contained, battery-powered English Wheatley that keeps the current
draft STT, final STT, Piper, Pi/Wheatley, and a useful local LLM loaded, the
smallest credible embedded target remains **Jetson Orin NX 16 GB** on a
complete carrier/SSD/cooling kit. It is not new-new (introduced 2023), but is
current, supported through January 2032, has 16 GB LPDDR5 / 102 GB/s, 8 modern
Arm CPU cores, 100 TOPS, and 10--25 W power modes. It is roughly five times
Xavier NX on NVIDIA's comparable INT8 measure.

But the model-speed gate matters more than a theoretical fit: **8 tok/s is
Wheatley's minimum acceptable generation speed, and 4B is borderline useful
quality.** That rejects the cheap all-local Pi route. An Orin NX can make 4B
pleasantly quick; a 9B is still a fragile short-context PoC and Qwen3.8 27B
cannot fit.

The recommended portable Wheatley computer now is a used **M2 MacBook Air,
16 GB** at about **€700**. It has a real battery, quiet sustained operation,
display, camera, speakers, microphone, keyboard/trackpad, and a known-good
Wheatley/Metal environment. It is also a normal computer: the maintainer can work on
it and Wheatley can take native screenshots. The 16 GB ceiling keeps it in the
small-model class, but this is materially better value and a much more complete
first portable appliance than an €800 Xavier or a pile of separate box parts.

The eventual boxed Wheatley should therefore be a **network-only Lyra-class
client**: local microphone/speaker, buttons/lights/display and simple audio
transport, paired to the M2 or another trusted local server for current
Whisper, Pi, LLM, profiles and memory. It must fail visibly when its paired
server is unavailable; it should not pretend to be a degraded independent
assistant.

## Actual current Wheatley memory budget

This uses the deployed English configuration: `whisper.cpp` `small` with
beam 1 for live drafts; independent full-recording `large-v3` with beam 3 for
the final; Piper `en_GB-alan-medium`; the D `wheatleyd` server; and Pi/Node as
the agent/provider adapter. The two Whisper workers deliberately remain loaded
because draft and final quality/latency are separate product requirements.

| Resident part | Measured or safe allocation | Why it is there |
|---|---:|---|
| Whisper `small` draft server | **1.0 GiB measured RSS** | Live rolling draft. |
| Whisper `large-v3` final server | **3.8 GiB measured RSS** | One authoritative full-recording final. |
| Piper English and temporary WAV/Opus work | 0.1--0.3 GiB | Model is small; synthesis is brief, not a permanent giant worker. |
| Wheatley D server, Pi/Node, VAD, FFmpeg, audio buffers, history | 0.3--0.8 GiB | The idle D daemon itself is only about 21 MiB RSS here; this reserves real turn work. |
| Linux, CUDA/graphics allocation, drivers, networking, filesystem working set | 1.5--2.5 GiB | Do not budget this away on a unified-memory Jetson. |
| **Voice appliance subtotal before its LLM** | **6.7--8.4 GiB** | About 8 GiB is the honest planning number. |

The Whisper figures are not estimates: with both services warm beside the
resident Qwen on the remote machine, observed RSS was about 1.0 GiB (`small`) plus 3.8 GiB
(`large-v3`). A 16 GB device therefore has only roughly 7--9 GiB left before
an LLM, and it needs some free memory to avoid swap/allocator failure.

| Local LLM choice | Weight file | Reserve including runtime/KV | Result with the voice subtotal |
|---|---:|---:|---|
| Qwen3.5 2B Q4/Q5 | about 1.1--1.5 GiB | 2--3 GiB | Comfortable; likely less capable than wanted for an interesting companion. |
| Qwen3.5 4B Q4_K_M | about 2.7--3.0 GiB | **4.5--6.5 GiB** at a modest 8--16K context | Recommended starting point; leaves only 1--4 GiB margin, so prove it under the real voice load. |
| Qwen3.5 9B Q4 | about 5.1--6.2 GiB | 7.5--10 GiB | Sometimes loads, but leaves too little margin for concurrent final STT, long context, vision, or CUDA workspace. |
| Qwen3 8B Q4_K_M | 5.0 GiB | 7.5--9 GiB | Same practical verdict as 9B. |
| Qwen3.8 27B Q4/Q5 | about 17--21 GiB weights alone | over 20 GiB | Impossible on 16 GB. |

The final-STT and LLM stages do not normally need heavy GPU compute at exactly
the same instant, but both model allocations remain resident. “They run one
after the other” cannot make a 9B setup reliable unless the application starts
unloading/reloading models, which would undermine the fast conversational
turn-taking we want.

NVIDIA's current TensorRT-Edge-LLM benchmark makes the speed case for Orin NX
clear, but also validates the caution: Qwen3.5 4B INT4 generated 26.2 tok/s
and occupied 6,093 MB of GPU memory on an Orin NX 16 GB; Qwen3 8B INT4
generated 18.6 tok/s and occupied 8,210 MB. Those are optimized standalone
benchmarks with a short prompt, not a guarantee for Pi, concurrent Whisper,
or a long Wheatley session. They show why 4B is the sensible real build and
why 8B/9B is a test rather than the purchase premise.

## Hardware shortlist

| Choice | Honest role | Local stack verdict | Power / battery |
|---|---|---|---|
| **Jetson Orin NX 16 GB** | Recommended embedded box | Full English stack + Qwen 4B Q4. CUDA makes Whisper/llama.cpp practical; carrier gives NVMe, USB audio/camera, GPIO. Buy a complete kit, not a loose module. | 10--25 W module mode; plan **30--35 W** for a real active box including NVMe, fan, Wi-Fi, mic/speaker amp. |
| Jetson Xavier NX 16 GB, €800 | Only a cheap learning prototype | Technically can fit Qwen 4B, but substantially slower and nearing end of supply. It is poor value against Orin NX. | 10--20 W module mode; perhaps 20--28 W complete. |
| Jetson Orin Nano Super 8 GB | Voice/vision edge node or remote-LLM client | Not sufficient for the current persistent `small` + `large-v3` + useful LLM composition. It is attractive around €300, but would require remote final STT/LLM or model unloading. | 7--25 W. |
| Raspberry Pi 5 16 GB | Cheap shell, controls, and audio client | Memory can fit a small LLM but there is no comparable general CUDA acceleration. Do not expect pleasantly quick `large-v3` plus LLM. Hailo does not turn it into a general Whisper/llama.cpp GPU. | About 8--15 W real box; excellent battery, wrong performance class. |
| Intel N150, 16/32 GB | x86 hybrid/offline fallback | Easy software target, but CPU-only local `large-v3` and LLM make the interaction slow. Existing Wheatley design calls it an unmeasured offline/hybrid reference, not a proven fully local appliance. | About 10--18 W complete; very good battery, limited inference. |
| Ryzen 7840U/8840U mini PC, **32 GB** | Value all-local prototype | Enough RAM for a 9B Q4 with the speech stack and conventional Linux. Its GPU path is less appliance-like/CUDA-friendly than Orin, so benchmark before committing enclosure work. | Roughly 20--35 W active; an inexpensive 65 W USB-C PD power bank can run it. |
| **16 GB MacBook Air M2 (used, ~€700)** | **Recommended portable Wheatley computer** | Complete personal computer and known-good Wheatley/Metal target: work, screenshots, display/camera/speakers/mic and battery in one quiet machine. Same small-model ceiling as above. | Built-in ~50 Wh-class battery and exceptionally quiet. |

Raspberry Pi 5 and N150 have a place as thin/hybrid Wheatley bodies. They are
not the machine to buy in the hope that “16 GB RAM” alone makes the present
local voice-and-LLM configuration fluent.

## Raspberry Pi 5 16 GB: corrected measured picture

The Pi is better than a toy, but its four CPU cores and no general inference
GPU make **generation**, not RAM capacity, the limit. The best reproducible
2026 Pi 5/16 GB `llama.cpp` measurements below use four CPU threads, NVMe,
active cooling/no throttling, and `pp512` / `tg128`. `pp512` is a small
512-token prompt, not a long Wheatley history.

| Model | Quant | Prefill | Generation | Meaning |
|---|---|---:|---:|---|
| TinyLlama 1.1B | Q4_K_M | 61.8 tok/s | 11.1 tok/s | Fluent enough, but weak companion reasoning. |
| Llama 3.2 1B | Q4_K_M | 72.9 tok/s | 10.8 tok/s | The practical quick local tier. |
| Qwen3.5 2B | Q4 | — | **~8 tok/s** | Best credible fully-local Pi first trial; normal short answers are acceptable. |
| Llama 3.2 3B | Q4_K_M | 26.7 tok/s | 4.4 tok/s | A visible wait before a useful answer. |
| Qwen3.5 4B | Q8_0 | 31.0 tok/s | 2.42 tok/s | Direct measurement. A Q4 version should be roughly **3--4 tok/s**, not 5--8. |
| Qwen3.5 9B | Q8_0 | 18.2 tok/s | 1.36 tok/s | Fits only as an exercise; too slow. |
| Qwen3.5 35B-A3B custom 2-bit | 11.38 GiB | 30.85 tok/s | 4.53 tok/s | Impressively capable/slow LLM-only experiment; 16K context consumes ~13 GB, leaving no room for current local Whisper. |

The 2B Q4 result is an independent Pi report rather than the exact same
benchmark recipe; all other rows are deliberately retained with their actual
reported quant rather than pretending they are one clean league table. The
most important direct result is Qwen3.5 4B Q8's 2.42 tok/s. Q4 reduces its
memory traffic, so 3--4 tok/s is a reasonable inference, but it still will not
feel like a quick voice companion.

The current full Wheatley voice composition is the decisive obstacle. Current
Wheatley keeps `small` plus full `large-v3` Whisper warm (about 4.8 GiB RSS
measured elsewhere); Pi 5 CPU evidence says even `small` is below real time
and `large-v3` is materially slower again. Pi can run Piper easily, but it
cannot make the existing final-STT + 4B LLM experience fast. A change to
Whisper `turbo`, Parakeet, a remote final STT, or unloading/reloading models
would be a new product decision and must be measured for English names and
real primary-profile speech—not silently assumed equivalent.

The first route is now rejected: 2B at about 8 tok/s reaches the speed floor
but misses the 4B useful-quality floor; 4B misses the speed floor. The
worthwhile Pi/Lyra route is therefore a **network-only physical Wheatley
body**: local audio, display, buttons, lights, camera/control and battery;
paired over trusted LAN to the M2 Air or another local server for final STT,
LLM, Pi, profile and memory. This delivers the desired physical object cheaply
without giving it a fake, frustrating degraded local brain.

## Battery design

Use watt-hours, not a power-bank's misleading mAh rating. A 99 Wh USB-C PD
bank is the largest normally accepted in hand luggage. Allow about 85% usable
energy after DC conversion:

| Complete-box draw | 99 Wh pack useful energy (~84 Wh) | 200 Wh LiFePO4/DC pack useful energy (~170 Wh) |
|---:|---:|---:|
| 15 W (Pi/N150-like) | ~5.6 h | ~11 h |
| 25 W (light Orin) | ~3.4 h | ~6.8 h |
| 35 W (Orin active speech/LLM, the planning target) | **~2.4 h** | **~4.9 h** |

For Orin, select a carrier with a documented DC input, then use either (a) a
USB-C PD power bank plus a correctly rated 20 V PD trigger cable, or (b) a
protected 4S Li-ion/LiFePO4 pack with a proper 5 V/19 V regulator. Do not
power the board, microphone array, speaker amplifier, and NVMe from an
unrated hobby boost board. A 100 Wh bank plus a small 5--10 Ah battery module
is a reasonable 2--5-hour talking box; it is noticeable but still much smaller
and cheaper than making a laptop-class GPU battery system.

## Purchase gate

Before enclosure, camera, or battery work, test a **complete Orin NX 16 GB
kit** with NVMe and active cooling for one afternoon:

1. Run the exact current English `small` and `large-v3` Whisper services,
   Piper, Wheatley, Pi, and Qwen3.5 4B Q4 concurrently; record RSS/VRAM,
   swap, cold/warm start, Whisper real-time factor, and LLM first-token and
   token/s rates.
2. Repeat the real primary-profile voice scripts: one long dictation while draft STT
   runs, endpoint/final STT, then a 100--200 word spoken answer. It must not
   swap or thermally throttle after 30 minutes.
3. Only then try Qwen3.5 9B at the intended context. Treat any swap, OOM, or
   awkward response latency as a “no”, not a tuning puzzle.

If the 4B experience is not good enough, skip incremental Xavier/Orin-Nano
experiments and move straight to a **32 GB** portable machine. More RAM is the
real next step; a 16 GB Xavier is not.

## Sources

- [NVIDIA Jetson product lifecycle](https://developer.nvidia.com/embedded/lifecycle)
- [NVIDIA's 2026 Xavier NX supply/EOL notice](https://forums.developer.nvidia.com/t/jetson-product-eol-updates/370056)
- [Orin NX 16 GB specifications and 10--25 W / 100 TOPS claim](https://developer.nvidia.com/blog/?p=59836)
- [Orin NX architecture/memory configuration](https://developer.nvidia.com/blog/develop-for-all-six-nvidia-jetson-orin-modules-with-the-power-of-one-developer-kit/)
- [Orin Nano Super specifications](https://www.nvidia.com/en-gb/autonomous-machines/embedded-systems/jetson-orin/nano-super-developer-kit/)
- [Raspberry Pi 5 16 GB product brief](https://datasheets.raspberrypi.com/rpi5/raspberry-pi-5-product-brief.pdf)
- [Qwen3.5 4B GGUF sizes](https://huggingface.co/mradermacher/Qwen3.5-4B-GGUF) and [Qwen3.5 9B GGUF sizes](https://huggingface.co/TheStageAI/Qwen3.5-9B-GGUF)
- [NVIDIA TensorRT-Edge-LLM Orin NX benchmarks](https://github.com/NVIDIA/TensorRT-Edge-LLM/blob/main/docs/source/user_guide/performance/performance-benchmarks.md)
- [Reproducible Pi 5 16 GB `llama.cpp` 1B/3B/8B results](https://github.com/davidscarth/edge-ai-study/blob/main/RASPI5.md)
- [Pi 5 Qwen3.5 2B/4B/9B and long-context results](https://www.reddit.com/r/LocalLLaMA/comments/1sdcdno/benchmarks_of_gemma4_and_multiple_others_on/)
- [Pi-optimized Qwen3.5 35B-A3B experiment](https://huggingface.co/mtrpires/Qwen3.5-35B-A3B-IQK-RPi5-16GB)
- Wheatley's direct STT measurement: `docs/archive/architecture/STT Placement.md`.
