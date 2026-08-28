# Image Tools and Instruction Editor

Status: implemented; preset policy updated 2026-08-12.

## Outcome

Wheatley now has three related but independently useful capabilities:

1. Pi can generate an image through one locally installed image model. The
   result is a durable artifact of the current turn, appears in browser/Tauri,
   and is reported as a file path by the console. Pi selects a configurable
   low/medium/high quality preset and square/portrait/landscape composition from
   the user's intent.
2. A vision-capable Pi model can search specifically for web images and inspect
   only the smallest useful result set, normally one image and at most two for
   an ordinary comparison.
3. The home screen opens a full-screen editor for the active profile's system,
   user, manual-memory, and automatic-memory documents and Wheatley's three
   runtime prompt templates. Save publishes the whole valid edit; cancel
   discards it.

This document deliberately separates facts, assumptions, and remaining
uncertainties. It records the implemented contracts, measured behavior, and
immediate follow-up work rather than only the original proposal.

## Known facts

### Current Wheatley

- `wheatleyd` owns Conversation execution, canonical turn folders, profile
  documents, and history. Pi owns model interaction and tool decisions. The
  browser is a thin presentation and local-interaction client.
- Browser image input already preserves the original image in the turn, serves
  it through a turn URL, restores it from history, and renders a clickable
  preview. The console safely resumes such sessions without attempting terminal
  image rendering.
- A completed turn retains tool metadata and first-class generated-image
  artifacts. Artifact events stream in Conversation order, restore from
  history, and render as assistant-side transcript items.
- Click-to-open image links use chat-relative, human-facing URLs. Storage and
  transport coordinates must not appear in links shown to people. Within each
  chat, images are numbered independently by type and in conversation order:
  `/chat/<profile>/<session>/generated-image/01` for generated images and
  `/chat/<profile>/<session>/search-image/01` for retained image-search
  results. The server resolves those friendly coordinates to the validated
  canonical artifact; internal `/api/profiles/...` URLs remain transport-only.
- User-uploaded images retain their complete original filename and extension:
  `/chat/<profile>/<session>/image/1/actual%20name.jpg`. The unpadded number is
  only the image-upload order within the chat, while the filename is the
  retained resource identity. A later upload uses `2` even when its filename is
  different; repeated filenames therefore remain unambiguous too. Uploaded
  images alone expose alt/hover text, using that exact original filename and
  extension. Generated, searched, captured, tool-detail, and decorative images
  use empty alt text and no filename tooltip because their visible surrounding
  text already supplies the useful context.
- Pi's Wheatley extension now provides a distinct `image_search` tool alongside
  text `web_search` and `fetch_content`. It uses Brave Image Search and exposes
  only the selected, validated images to a vision-capable model. Each selected
  JPEG/PNG is also persisted as `images/web-NN.*` plus hashed provenance
  metadata inside the canonical turn before the tool returns.
- The chosen Pi model's `vision` capability is already known to Wheatley. The
  current catalog includes both vision and text-only models.
- Profile-owned editable documents already live under
  `Profiles/<profile>/`: `system.md`, `user.md`, `memory.md`, and generated
  `memory_auto.md`.
- These runtime templates are tracked release bootstrap resources, copied once
  when missing, and read at runtime only from `$WHEATLEY_HOME/prompts/`:

  | File | Runtime use |
  | --- | --- |
  | `pi-turn-context.md` | Stable Wheatley/Pi context, tool routing, and injected profile blocks |
  | `pi-turn-request.md` | Per-turn context/request wrapper |
  | `session-auto-memory.md` | Complete automatic-memory rebuild instruction |

- `scripts/install/setup.sh` creates private configuration, profile data, and
  missing prompt templates without overwriting existing user edits.
- `InstructionDocuments` is the single seven-document load/save boundary.
  Profile storage remains profile-owned; the home prompt store owns the three
  app-wide runtime templates used by Pi and automatic memory.
- The live topology is split already: the current D `wheatleyd` listens on
  the maintainer's Mac, while Pi reaches LM Studio at
  `http://speech-server.local:1234/v1`. `remote-mac` is a 64 GB Apple M4 Pro
  and currently runs LM Studio but not `wheatleyd`.
- The legacy Python tree is `/opt/wheatley-legacy`.
  `/opt/wheatley` is the fresh D Wheatley deployment. Clean release
  snapshots can be copied over the fast LAN instead of fetched over slow Wi-Fi.
- The official Bonsai Image Demo is installed at upstream pin `9cf9d6e` below
  ignored `app-data/image-generation/`. The LAN-supplied Xcode/Metal toolchain,
  Python environment, model weights, launchd service, authentication token, and
  warm worker are installed and operational on `remote-mac`.
- Development also occurs on a 16 GB M1 Pro MacBook, but remote generation on
  the M4 Pro is the selected normal topology. A co-located local adapter remains
  a useful architectural seam, not a required first deployment.
### External model and search facts

- Bonsai Image 4B is derived from FLUX.2 Klein 4B and is released in binary and
  ternary low-bit variants for MLX on Apple silicon. PrismML publishes a local
  setup script and a one-shot CLI, while recommending a warm local process when
  repeated generation should avoid model-load and first-shape compilation cost.
  [Announcement](https://prismml.com/news/bonsai-image-4b),
  [repository and CLI](https://github.com/PrismML-Eng/Bonsai-image-demo).
- PrismML's Ternary Bonsai model card specifies FlowMatchEuler, four inference
  steps, guidance `1.0`, and shift `3.0`. It explicitly says the model is
  designed for four steps: more steps do not significantly improve quality and
  may introduce artifacts. Native resolution is `1024×1024`; `512×512` is the
  quick-preview path. [Ternary Bonsai model
  card](https://huggingface.co/prism-ml/bonsai-image-ternary-4B-mlx-2bit).
- The current demo CLI accepts each dimension from 256 through 2048 in multiples
  of 16. Its documented fast/quality pairs are `512×512`/`1024×1024` for
  square, `624×416`/`1248×832` for landscape, and
  `416×624`/`832×1248` for portrait. The model card more conservatively promises
  arbitrary multiples of 32; the initial Wheatley presets use only dimensions
  the pinned demo explicitly supports and recommends. [Demo CLI
  parser](https://github.com/PrismML-Eng/Bonsai-image-demo/blob/main/scripts/generate.py).
- FLUX.2 Klein 4B itself is Apache-2.0, four-step distilled, and supports both
  text-to-image and image editing. The official implementation targets CUDA;
  Apple-silicon execution is available through MLX implementations such as
  MFLUX and the third-party native Swift `Flux2CLI`.
  [Official model](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B),
  [official inference repository](https://github.com/black-forest-labs/flux2),
  [Swift MLX CLI](https://github.com/VincentGourbin/flux-2-swift-mlx).
- Z-Image-Turbo is an Apache-2.0 6B, eight-step text-to-image model with
  strong photorealism, English/Chinese text rendering, and public human-ranking
  evidence. It has a direct MFLUX command on Apple silicon and a
  `stable-diffusion.cpp` path, but no trustworthy published M1/M4 timing for the
  exact CLI configuration considered here.
  [Official repository](https://github.com/Tongyi-MAI/Z-Image),
  [MFLUX](https://github.com/filipstrand/mflux),
  [`stable-diffusion.cpp` guide](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/z_image.md).
- Brave exposes Image Search as a distinct API endpoint. It returns thumbnail
  and original URLs, source-page metadata, dimensions when known, and strict
  SafeSearch by default. The API permits requesting as few as one result even
  though its general default is 50. [Brave Image Search
  reference](https://api-dashboard.search.brave.com/api-reference/images/image_search).

## Assumptions for the first implementation

These are design choices, not discovered requirements:

1. **One generated image per tool call.** Batches and galleries can follow real
   use; they should not shape the first contract.
2. **Text-to-image first.** Editing, inpainting, reference images, LoRAs, and
   upscaling are explicitly later even if the selected model supports them.
3. **Ternary Bonsai Image 4B is selected.** The maintainer has chosen the MLX ternary
   variant for the first implementation. There is no remaining model-selection
   gate and no runtime fallback to another generator.
4. **Generation policy and model execution are separately placeable.** The
   `ImageGenerationRuntime` module lives beside Conversation in the authoritative
   `wheatleyd`; the Bonsai MLX worker runs on `remote-mac`. The local runtime owns
   tool policy and the resulting turn artifact, while the remote worker owns
   only model execution.
5. **Generated images are part of history.** They are not temporary tool UI and
   are retained with the turn unless the turn is deleted.
6. **Web image search is a separate `image_search` tool.** A normal
   `web_search` remains text research; the distinct name makes model capability,
   result count, safety, and image payload explicit.
7. **Web reference images are also turn artifacts.** Selected thumbnails and
   source metadata are kept so a restored conversation shows what the model
   actually inspected. They are labelled as web references, not as generated or
   user-owned work.
8. **Strict SafeSearch is fixed for Wheatley.** The family product has no first
   implementation need for an off switch.
9. **Runtime templates are app-wide user data.** They belong under
   `$WHEATLEY_HOME/prompts/`; profile-specific documents remain under the active
   profile. A server connected remotely edits the server's canonical data.
10. **Save then close.** The editor's checkmark validates, saves, and returns to
    Home. The X returns to Home without writing. No autosave is added.
11. **Edits affect the next applicable operation.** Profile and Pi prompt edits
    affect the next turn; the auto-memory template affects the next memory
    rebuild. An already running turn keeps its accepted prompt/config snapshot.
12. **Quality means a configured resolution preset.** `low`, `medium`, and
    `high` select dimensions; all three retain Bonsai's recommended four-step
    inference recipe. Wheatley does not pretend extra steps are higher quality.
13. **Pi chooses semantic aspect.** The tool exposes only `square`, `portrait`,
    and `landscape`. Pi follows an explicit user choice; otherwise it chooses
    the natural composition from the request. The runtime, not Pi, resolves the
    aspect and quality names to pixels.

## Decisions and remaining uncertainties

### Decisions now settled

- The model is **Ternary Bonsai Image 4B for MLX**.
- Normal and uncertain requests use **medium**, now at the former high/native
  dimensions. Explicit speed/draft intent uses **low**; explicit
  quality/finality intent uses **high**, now at the worker's 2048 px dimension
  limit. Low remains unchanged.
- Low-preset wording controls resolution only. Selection-only terms such as
  `draft` and `low quality` are omitted from the visual prompt so they do not
  ask Bonsai to make the image itself look unfinished. Positive quality/detail/
  polish wording may remain because it can improve the generated result.
- Pi selects **square**, **portrait**, or **landscape** semantically unless the
  user explicitly selects one.
- Pixel dimensions live in `config.json`; they are not prompt policy.

### Deployment decision now settled

- The M4 Pro worker is a persistent warm service. A remote API that starts the
  model afresh for every request would preserve one-shot cold-start cost while
  adding network overhead, so `one_shot` is no longer an implementation mode.
- The current D `wheatleyd` remains the single Conversation, configuration,
  history, and artifact authority. Do not deploy a second full server merely to
  place image inference.
- The upstream Bonsai repository is a pinned runtime installation, not a Git
  submodule of Wheatley. Model weights and its Python environment remain remote
  operational data, not versioned product source.

### Measured implementation facts

- The authenticated warm worker is reproducible from the pinned checkout and
  runs as a user launchd service on `remote-mac` with one bounded execution lane.
- A cold low-square request, including worker/model startup, took `102.07 s`.
  Under the original matrix, warm requests measured `7.63–7.71 s` at the
  unchanged low sizes, `14.81–15.67 s` at the retired midpoint sizes, and
  `27.50–27.74 s` at the sizes now used by medium. All nine original outputs
  had the exact configured dimensions. The new 2048-edge high sizes are not yet
  measured.
- Real semantic routing selected medium landscape for an ordinary landscape
  request, high portrait for an explicitly high-quality portrait request, and
  low square for a quick low-quality draft under the original preset matrix.
  The routing policy is unchanged; only the medium/high dimensions and prompt
  treatment changed on 2026-08-12.
- Real Gemma and Qwen3.6 35B A3B vision paths each accepted one validated image
  returned by `image_search`, described it, and cited its source page. In the
  final Qwen test the selected JFrog PNG and metadata were present in the turn,
  their SHA-256 matched, history restored the same image, and clicking it opened
  Wheatley's full stored file in a separate tab.
- A multi-document instruction save is prevalidated, staged adjacent to each
  destination, serialized by one mutation lock, and rolled back if publication
  fails. Absolute crash atomicity across independently configured filesystems
  remains intentionally out of scope.

### Remaining uncertainties

- Peak unified-memory use and performance while LM Studio is under sustained,
  concurrent production load were not profiled. The worker serializes image
  requests to bound this risk.
- Brave storage rights depend on the configured account plan. Wheatley stores
  each selected image as a canonical turn file plus provenance metadata needed
  for restoration; the account owner should confirm that this retention is
  permitted before broad use.
- Image quality is subjective. The preset dimensions and measured latency are
  facts, but the maintainer still needs to judge whether low/medium/high provide the
  desired speed-detail trade-off on ordinary family prompts.
- The new maximum high presets have not yet been timed or visually judged. The
  model is optimized around its 1024/native range, so 2048 dimensions express
  the maintainer's deliberate maximum setting rather than an evidence-backed promise of
  proportional detail improvement.
- The server is the canonical instruction owner. A future independently writable
  offline appliance would need an explicit sync/conflict policy; v1 does not
  silently edit an ignored replica.

## Local image model comparison

The numbers below are useful for direction, not a universal leaderboard. The
Bonsai/FLUX scores come from PrismML's same evaluation table; Z-Image's ranking
uses a different human-preference system and must not be compared numerically.
Mac timings depend strongly on chip, resolution, step count, quantization,
runner, cold/warm state, and VAE.

| Candidate | Mac path | Published footprint / memory | Published speed evidence | Quality evidence | Fit for Wheatley |
| --- | --- | --- | --- | --- | --- |
| **Ternary Bonsai Image 4B** | PrismML MLX fork; `generate.sh` or warm local service | 1.21 GB transformer; 3.88 GB deployment payload; mean-active 1.96 GB at 512 and 2.38 GB at 1024 | On a 48 GB M4 Pro: 5.78 ± 0.08 s at 512×512 and 24.26 ± 0.24 s at 1024×1024, four steps | GenEval 0.723, HPSv3 12.22, DPG-Bench 0.851; reported 95% composite retention versus full Klein | **Selected.** Very low contention with Wheatley's LLM and a direct CLI, with a modest quality cost. |
| Binary Bonsai Image 4B | Same | 0.93 GB transformer; 3.42 GB payload; mean-active 1.50 GB at 512 and 1.95 GB at 1024 | Same family claim; no separate variant timing published | 0.671 / 11.15 / 0.822; 88% composite retention | Use only if the M1 Pro or concurrent LLM load makes ternary memory materially problematic. The quality loss buys little on a 64 GB server. |
| **FLUX.2 Klein 4B** | MFLUX, native Swift `Flux2CLI`, or `stable-diffusion.cpp` | Full-precision transformer 7.75 GB; PrismML measured 11.74 GB mean-active at 512 and 14.39 GB at 1024 | Swift project reports about 26 s for its 4B default, without enough hardware detail for a direct comparison; BFL's sub-second claim is for modern discrete GPUs | 0.819 / 12.84 / 0.853 in the same PrismML table; unified generation and editing | Best second probe if Bonsai quality fails. Better headroom for future editing, but much more shared-memory pressure. |
| **Z-Image-Turbo 6B** | One MFLUX CLI command or `sd-cli` with GGUF | Official repo says it fits 16 GB GPU-class devices; quantized GGUF can fit lower, depending on offload | Eight inference evaluations; sub-second is H800 evidence, not Mac evidence | Official project reported #1 open-source position in its Dec. 2025 Artificial Analysis snapshot; particularly strong realism and text | Strong alternative, but today its exact Mac latency/memory evidence is weaker than Bonsai's and v1 is generation-only. |
| SDXL / SDXL-Turbo family | Core ML or `stable-diffusion.cpp` CLI | Mature and broadly runnable; model/quantization dependent | Mature Apple paths, including Apple's older Core ML benchmarks | The SDXL baseline in PrismML's table scores 0.300 / 10.05 / 0.740, materially below Bonsai | Operational fallback, not a good new quality target in 2026. |

### Selected implementation model

Install **Ternary Bonsai Image 4B**. Its decisive advantage is not merely
six-second preview generation: it leaves roughly 10–12 GB more active unified
memory than full Klein in PrismML's measurements. That makes it less likely to
disrupt the local language model serving the same Wheatley turn.

Define one narrow generator capability and one Bonsai adapter. Do not build a
multi-model registry or retain speculative fallback paths. The comparison table
remains research context, not an implementation menu.

## Image generation design

### User and agent behavior

- Pi receives a `generate_image` tool when the profile enables it and the
  server's configured generator is healthy.
- The tool contract is:

  ```text
  generate_image(prompt, aspect, quality?, seed?)
  ```

  `prompt` and `aspect` are required. `aspect` is `square`, `portrait`, or
  `landscape`. `quality` is `low`, `medium`, or `high` and defaults to `medium`
  at the runtime boundary. `seed` is optional. Pi cannot pass raw width, height,
  step count, guidance, or model identity.
- Pi must respect an explicit requested aspect. Otherwise it chooses the
  natural composition and intended use of the requested image; it should not
  ask a follow-up merely because orientation was omitted.
- Quality selection is governed by this instruction in the editable Agent
  template:

  > For `generate_image`, use `low` only when the user asks for low quality or
  > prioritizes speed or a disposable draft—for example quick, quickly, fast,
  > draft, preview, rough, or temporary. Use `high` when the user asks for high,
  > best, better, good, or otherwise emphasized quality, detail, polish, or a
  > final result. Use `medium` for ordinary requests, ambiguous wording, or
  > conflicting signals. Treat negative fidelity/speed wording only as a preset
  > signal and omit it from the visual prompt unless it describes visible image
  > content; positive quality/detail/polish wording may remain. Respect an
  > explicit square, portrait, or landscape request; otherwise choose the
  > aspect that naturally fits the requested composition and intended use. Pass
  > only the semantic preset names; never calculate image dimensions yourself.

  “Quality” on its own is affirmative quality intent and therefore selects
  `high`. In the absence of such intent, `medium` is deliberately normal.
- One call produces one image. Pi should not generate several alternatives
  unless the user asks for several, in which case it makes separate calls.
- The tool reports progress as image generation, not as generic tool use.
- As soon as generation starts, the browser renders a gray-gradient placeholder
  and the actual generation prompt in an assistant artifact bubble. The event
  carries the resolved preset width and height, so the placeholder reserves the
  exact final frame instead of guessing from orientation.
- On success, the browser adds the image to the assistant side of the main
  transcript in that reserved frame as soon as its durable artifact event
  arrives. Click opens the
  original. The generation prompt appears beneath it in tool/thinking typography,
  and the bubble has independent Speak and Copy actions from its placeholder
  state onward. Pending Copy uses the known prompt directly; pending Speak uses
  the profile's direct TTS path and retains play/stop state when the placeholder
  becomes the canonical artifact. Reload/history restore the same image and
  actions.
- Model-visible tool success is the path-free sentence `Image generated
  successfully.` This avoids prompting the LLM to echo a local path; the web UI
  does not filter or rewrite genuine assistant text.
- The console independently prints the canonical artifact path and continues
  with Pi's path-free text response. Speech reads the response/prompt, never the
  artifact path. The terminal does not attempt image graphics.
- Cancellation closes/cancels the remote request and publishes no final image.
  The worker may finish the already-running MLX kernel, but its result is
  discarded and no partial file enters the canonical turn.
- No hosted fallback is attempted. If the configured worker is unhealthy, the
  tool is not advertised; if it fails after invocation, the tool fails visibly.

### Ownership and flow

```text
Primary Mac                                            remote-mac (M4 Pro)

Pi generate_image tool
        |
        v
Wheatley tool API
        |
        v
ImageGenerationRuntime
        |
        v
RemoteImageGeneratorHttpPort -- trusted LAN + token --> Image Worker
        ^                                                   |
        |                                                   v
        +------------------------ PNG bytes -------- warm Ternary Bonsai MLX
        |
        v
staged output -> current turn/images/generated-01.png
        |
        +-> durable artifact event/history -> browser image
        |
        +-> canonical file path -> console
```

`ImageGenerationRuntime` owns semantic validation, preset resolution,
availability, timeout/cancellation, staging, and publication into the accepted
turn. `ImageGeneratorPort` is its narrow execution dependency. The selected
`RemoteImageGeneratorHttpPort` sends already-resolved prompt/dimensions/seed and
accepts PNG bytes; it does not know profiles, sessions, turns, tools, or UI.
Conversation/history owns the durable artifact and its ordered event. The
browser only renders the provided artifact view.

The worker owns one host-wide generation lane. Its Apple unified memory and GPU
are shared with LM Studio on `remote-mac`; parallel image jobs would add
contention before Wheatley has a use case requiring them.

### Module and deployment boundary

The recent Wheatley modularization should be used directly:

```text
server/wheatleyd/source/wheatley/server/image_generation/
  types.d                 semantic request/result types
  port.d                  ImageGeneratorPort
  runtime.d               policy, presets, cancellation, publication handoff
  remote_http_port.d      selected LAN adapter

services/image-worker/
  small authenticated Python service around the pinned Bonsai MLX pipeline
```

This is one product capability with two sides of one port, not two Wheatley
servers. A future `LocalBonsaiImageGenerator` can implement the same port when
model execution is co-located, without changing Pi, Conversation, history, or
the clients. Do not split or deploy the full Conversation server for this.

The remote worker has deliberately small scope:

- `GET /health` reports ready/busy and the fixed model revision;
- `POST /v1/generate` accepts prompt, resolved width/height, seed, and a request
  ID, then returns raw `image/png` bytes;
- one request executes at a time; excess requests wait in a small bounded queue
  or receive a busy response;
- the worker validates dimensions and request size again, fixes inference at
  four steps, and always uses Ternary Bonsai MLX;
- a bearer token comes from a mode-`0600` remote environment file and the local
  `WHEATLEY_IMAGE_API_TOKEN`; no secret is stored in `config.json`;
- the worker keeps the pipeline warm but stores no Wheatley history. Temporary
  output is removed after response completion or failure.

Do not expose the upstream demo service directly. Its current `serve.sh` starts
an unnecessary Next.js frontend and its local backend wrapper deliberately
strips authentication. The Wheatley worker should import the pinned pipeline
code and expose only the contract above.

### Artifact contract

Use the existing canonical turn rather than Pi's profile `files/` workspace:

```text
Profiles/<profile>/<YYYY>/<MM>/<DD>/<session>/turns/<turn>/
  turn.json
  turn.md
  tools.json
  images/
    generated-01.png
```

The generated-image sidecar currently includes:

- stable artifact/item ID;
- kind `generated_image`;
- filename and media type;
- exact byte count and SHA-256;
- requested quality/aspect, resolved width/height, seed, and original generation
  prompt;
- the derived authorized URL used by clients.

The producing tool call and timestamp remain available in `tools.json` and the
Conversation event log rather than being duplicated in the sidecar. The fixed
model revision is exposed by worker health and deployment state.

Do not persist an absolute host path or base64 copy. HTTP derives an authorized
turn URL from identity and filename. Pi/tool details may contain the same small
metadata object, but the file and its turn artifact record are canonical.

The semantic Conversation stream has a first-class artifact event rather than
hiding the main product result inside a tool-detail JSON document. The same
event streams, persists in `conversation.events.jsonl`, and restores as an
ordered transcript item. This seam can later carry generated documents or other
assistant files without making image policy generic prematurely.

### Installation and configuration

- Add a re-runnable remote installer/deployer with explicit host and root. The
  selected deployment is:

  ```text
  /opt/wheatley/
    services/image-worker/                 tracked worker source
    app-data/toolchains/Xcode.app/         LAN-supplied build prerequisite
    app-data/image-generation/
      bonsai-image-demo/                   pinned upstream checkout
        .venv/
        vendor/
        models/bonsai-image-4B-ternary-mlx/
        logs/
  ```

  Tracked worker code and ignored runtime payloads are therefore separated in a
  normal fresh Wheatley deployment, while everything remains under the exact
  parent requested by the maintainer.
- Pin the upstream Bonsai demo commit and its Python dependency lock. The slow
  Wi-Fi path must be resumable and idempotent: reuse partial/cache downloads,
  never download the same model to a temporary second tree, preserve a durable
  install log, and make rerunning the installer continue rather than restart.
- Install the worker as a user `launchd` service on `remote-mac`; keep the fixed
  Ternary Bonsai model warm and restart it after failure/login. The current
  repository may be deployed as one clean checkout, but only the image worker
  process runs there; the D Conversation server remains on the maintainer's Mac.
- Record code and weight licenses in `THIRD_PARTY.md`.
- Add required configuration only when `tools.available.generate_image` is
  true. Fail startup if enabled configuration points to a missing install or an
  invalid/incomplete preset matrix. Initial defaults:

  ```json
  {
    "image_generation": {
      "endpoint": "http://speech-server.local:8790",
      "request_timeout_seconds": 600,
      "presets": {
        "low": {
          "square": { "width": 512, "height": 512 },
          "landscape": { "width": 624, "height": 416 },
          "portrait": { "width": 416, "height": 624 }
        },
        "medium": {
          "square": { "width": 1024, "height": 1024 },
          "landscape": { "width": 1248, "height": 832 },
          "portrait": { "width": 832, "height": 1248 }
        },
        "high": {
          "square": { "width": 2048, "height": 2048 },
          "landscape": { "width": 2048, "height": 1376 },
          "portrait": { "width": 1376, "height": 2048 }
        }
      }
    }
  }
  ```

  `adapter`, `variant`, and `execution` are intentionally absent. There is one
  supported path: the remote Bonsai image port, Ternary MLX, and a persistent
  warm worker. These are code/deployment facts, not user choices. `endpoint`
  remains configuration because placement is environment-specific.

  Low is PrismML's recommended fast size and remains unchanged. Medium uses the
  former high/native sizes (`1024×1024`, `1248×832`, `832×1248`). High uses
  `2048×2048` or a 2048 px long edge with a multiple-of-32 near-3:2 companion
  dimension. All nine values are configuration, so they can be tuned without
  changing the Pi tool schema or instruction. Validate each dimension against
  the pinned demo (`256–2048`, multiple of 16), positive area, known keys only,
  and landscape/portrait orientation. Keep Bonsai's four-step recipe
  adapter-owned.
- Keep one code path. Do not add `try local CLI, then remote worker, then cloud`
  logic. A future co-located adapter is an explicit deployment choice, never a
  per-request fallback.

## Web image search design

### Why a distinct tool

`web_search` answers a textual research question and may inspect several
sources. `image_search` asks for visual grounding and returns image content to
a vision model. Combining them would make ordinary search unexpectedly large,
make image capability implicit, and obscure the user's request to see rather
than merely read about something.

The first implementation should use Brave's dedicated Image Search endpoint
because Wheatley already uses the same configured Brave credential source.
Prefer contributing/reusing the credential and request mechanism in
`pi-web-access`; do not copy a secret into Wheatley configuration or edit
installed `node_modules` in place. If an upstream extension cannot be extended
cleanly, add one tracked Wheatley Pi extension module with the same environment
credential source and no persisted secret.

### Tool policy

Proposed input:

```text
image_search(query, count?)
```

- `query` is required.
- `count` defaults to 1 and is bounded to 1–3.
- Wheatley's runtime asks Brave for a slightly larger ranked candidate set so a
  broken or unsupported image does not force a second search, but it downloads
  and exposes only the requested minimum.
- Strict SafeSearch, bounded download bytes, image media-type validation,
  timeout, redirect/SSRF protection, and decompression/pixel limits are fixed
  boundary policy.
- Each selected result returns the image to the vision model plus title,
  source-page URL, original-image URL, dimensions when known, and a clear
  `web_reference` label.
- Use Brave's proxied approximately 500 px thumbnail for normal visual
  identification. Fetch the original only when the user explicitly needs fine
  detail and the source permits it.
- Only advertise the tool to a vision-capable model. A text-only model must not
  claim it saw an image; it should ask the user to select a vision model when
  visual inspection is necessary.

Add this instruction to the editable Pi context template:

> Use `image_search` only when visual appearance matters. Inspect the minimum
> useful number: normally one representative image; two only to compare or
> disambiguate; more only when the user explicitly asks for a set.

This is both a prompt rule and a tool default. Prompting alone is too weak;
default 1 and maximum 3 make the intended behavior the easy behavior.

### Presentation and retention

Each successful image-search activity bubble shows the selected images as a
usefully sized horizontal carousel with spacing, rounded corners, uncropped
`contain` rendering, and a visible title. The rounded frame contains only
the image; the title is a separate element below it, using the same shared frame
and text primitives, 9 px spacing, and 12.5 px text treatment as generated
images and their prompts. Search-engine resolution and download boilerplate are
removed from the visible title. Clicking the image opens Wheatley's full stored
turn file in a separate tab; clicking its title opens the source page. Overflow
scrolls horizontally. The expanded thought/tool pane renders the same evidence.
The completed tool result is persisted before its end event is published, and
the event carries the canonical turn identity through every browser transport,
so the active bubble loads the carousel as soon as search finishes. Reloading
history repeats the same detail lookup only as recovery, not as the normal path.

The tool name inside a collapsed activity bubble is an independent link-like
button that opens Tool Details. Clicking reasoning text or empty bubble space
continues to toggle the thought/tool sidebar. This prevents the two navigation
targets from competing.

Only selected images appear; ranked candidates rejected for type, size, safety,
or download failure are neither sent to the model nor shown. Generated images
remain main-transcript artifacts, while web references remain tool evidence.
Before a successful tool result returns, each selected JPEG/PNG is decoded and
revalidated at the D boundary, atomically written as `web-NN.png/jpg`, and
paired with title, source/original URLs, dimensions, size, and SHA-256 metadata.
Tool details retain the authorized relative turn URL; restored history reloads
the same canonical file and source metadata. Brave plan retention rights remain
an operational check.

## Instruction editor design

### Canonical data

After this change, tracked `app-data/resources/prompts/` files are bootstrap
defaults only. `scripts/install/setup.sh` copies missing files, without
overwriting edits, to:

```text
$WHEATLEY_HOME/
  config.json
  prompts/
    pi-turn-context.md
    pi-turn-request.md
    session-auto-memory.md
  Profiles/
    <profile>/
      system.md
      user.md
      memory.md
      memory_auto.md
```

Runtime reads only the private home copies and fails fast when a required
runtime template is absent or invalid. There is no resource fallback because
that would create two live owners and could make an apparent UI save ineffective.
Running setup after an upgrade creates newly introduced missing files but never
merges a new default over an edited file. A later explicit “compare/reset to
default” feature can solve upgrades if real use requires it.

Create one `InstructionDocuments` owner above the existing profile-document
storage. It loads and saves the exact seven editable documents while delegating
profile paths to the profile owner and app-wide prompt paths to a small home
prompt store. Pi prompt assembly and automatic-memory generation receive those
templates from this owner instead of reopening resource files.

### Tabs and friendly names

| Tab | File | Scope | Note |
| --- | --- | --- | --- |
| System | `system.md` | active profile | Assistant identity and non-negotiable profile behavior |
| User | `user.md` | active profile | Standing user preferences and instructions |
| Memory | `memory.md` | active profile | Manually maintained durable memory |
| Auto memory | `memory_auto.md` | active profile | Generated memory; the next memory rebuild may rewrite it |
| Agent | `pi-turn-context.md` | app-wide | Wheatley/Pi runtime and tool-routing context |
| Turn | `pi-turn-request.md` | app-wide | Wrapper around current context and request |
| Memory rules | `session-auto-memory.md` | app-wide | Rules and template for rebuilding automatic memory |

### UI behavior

- Home has one `...` menu. Its language entries and muted-gray
  instruction/notebook entry use the same decorator size and button language;
  Instructions opens the editor for the currently selected profile.
- The editor occupies the full app content area. One top row contains a new
  standalone SVG checkmark on the far left, all seven tabs in the center, and a
  properly centered SVG X on the far right.
- The checkmark saves every edited document in one request, then returns Home.
  Its enabled surface is the same ordinary quiet button as X; it becomes
  partially transparent while disabled during loading/saving or when nothing
  changed. `Cmd/Ctrl+S` invokes the same action.
- X discards all local modifications and returns Home. `Escape` invokes the
  same action. It does not show a second confirmation because cancel is the
  explicit meaning of the control.
- A reusable segmented-tabs component preserves the existing quiet-button
  surface while joining adjacent borders with no gaps: the first button rounds
  only its left corners, middle buttons have square corners, and the last rounds
  only its right corners. The selected tab uses the same stronger accent fill,
  border, and text treatment as the selected numbered silence-delay button. One
  reusable, ARIA-driven toggle-selection treatment now covers selected tabs and
  pressed buttons. For checked menu items, only the icon/decorator receives that
  treatment; the row and its label remain visually unchanged. The tab row can
  scroll horizontally on a narrow viewport.
- One rounded textarea fills the remaining screen, retains ordinary Markdown
  text exactly, uses a readable monospace font, and keeps its own scroll
  position per tab. No Markdown preview or formatting toolbar is added.
- The editor does not repeat `Profile: …` or add a second profile selector.
  Profile switching remains on Home.
- Textarea left/right spacing matches the action buttons, and its bottom inset
  matches the same screen edge spacing.
- Validation errors remain on the editor without losing typed text and identify
  the friendly tab and missing requirement.
- `Auto memory` carries a quiet note that the memory process may replace it.

### API and validation

One profile-scoped endpoint loads the seven-document editor snapshot and one
saves it. Although three files are app-wide, the profile identity makes the UI
intent and authority explicit.

The save boundary:

1. validates the complete request before any write;
2. requires all three runtime templates to be nonempty;
3. preserves the exact existing required placeholder sets for Agent, Turn, and
   Memory rules;
4. allows profile documents to be empty because that is already valid runtime
   state;
5. stages every output adjacent to its destination;
6. holds one instruction-document mutation lock while replacing the files;
7. returns the freshly loaded canonical snapshot.

The UI does not choose file paths, merge documents, or write through Tauri. The
server remains the owner on browser, Tauri, and remote clients.

## Implementation record and immediate next steps

### Delivered

1. Private instructions are bootstrapped without overwrite, runtime reads use
   only private data, and the seven-document editor saves through one validated
   server transaction boundary.
2. The generated-image vertical slice is complete: modular D policy/runtime,
   authenticated remote port, warm one-lane Python/MLX worker, Pi tool,
   configuration, durable turn artifact, semantic event, history restore,
   authorized file route, browser/Tauri presentation, speech/copy actions, and
   console path output.
3. A generation tool-start event carries only safe presentation metadata:
   prompt, semantic preset, and resolved width/height. The web transcript
   immediately reserves that exact frame with a gray gradient and prompt, then
   replaces it in place with the PNG. A real `624×416` low-landscape run measured
   zero change in frame `x`, `y`, width, or height.
4. Visual web grounding is complete: separate vision-only `image_search`,
   strict SafeSearch, one-result default, two-result comparison behavior,
   maximum three, bounded JPEG/PNG validation, SSRF/redirect defenses, model
   image content, canonical hashed `web-NN` turn artifacts, source metadata,
   restored uncropped bubble carousel, independent full-image/source links, and
   Tool Details.
5. The refined editor has one header row, no duplicate profile label, reusable
   connected toggle tabs, standalone check/X SVGs, and one 16 px edge inset.
   Save uses the ordinary button surface at opacity `1` when enabled and `0.45`
   when disabled. Browser measurement confirms both action edges match textarea
   edges exactly, each SVG center equals its button center, the middle tab radius
   is `0`, and only the group's outer corners are rounded.

### Immediate operational next steps

1. The maintainer should judge a small varied prompt sheet and adjust only preset
   dimensions if the measured speed/detail balance feels wrong.
2. Confirm the configured Brave plan permits retaining the selected image data
   contained in canonical turn history.
3. When promoting this checkout, transfer the current code snapshot to
   `/opt/wheatley` over the fast LAN and rerun the idempotent worker
   deploy script; model weights and the existing environment remain in place.
4. Profile peak unified memory during simultaneous heavy LM Studio use only if
   real workloads show contention; the serialized worker is the current guard.

## Scope now and not now

### In scope

- One local text-to-image model and one result per call.
- Configurable low/medium/high resolution presets across square, portrait, and
  landscape; optional seed.
- Durable generated-image turn artifacts and inline UI.
- Brave-backed visual image search for vision models with minimal result count.
- Seven-document full-screen editor and private runtime-template ownership.
- Browser/Tauri behavior and console path presentation.

### Not now

- Cloud image generation or fallback providers.
- Multiple selectable image models in the Wheatley UI.
- Image editing, masks, inpainting/outpainting, reference-image generation,
  LoRAs, training, upscaling, or galleries.
- Generating several candidates automatically and asking another model to rank
  them.
- A general artifact-management UI.
- Markdown preview, diffs, version history, reset-to-default, or per-document
  save in the instruction editor.
- Synchronizing app-wide runtime prompt templates to offline appliances.
- Rendering images in the D terminal.

## Acceptance and maintainer checks

### Machine-verifiable

- A generated PNG exists inside the accepted turn before its artifact event,
  and API/download/history bytes have the same SHA-256.
- Browser/Tauri restores and opens the generated image; console prints the
  canonical path.
- While generation runs, prompt and resolved dimensions produce a reserved
  gray placeholder; replacing it with the final PNG changes none of its frame
  coordinates, dimensions, or action-toolbar structure. Pending prompt Copy and
  Speak are usable before the PNG exists.
- Cancellation and failure leave no published artifact and no orphan staged
  file.
- Omitted quality resolves to medium. Requests for quick/fast/draft/preview
  resolve to low; ordinary or unclear requests resolve to medium; requests for
  quality/high/best/detailed/polished/final output resolve to high.
- Low-resolution selection wording does not enter the visual prompt when it is
  only about generation speed/fidelity. Positive high-quality wording may
  remain; genuine visible concepts such as a rough pencil texture are retained.
- An explicit square/portrait/landscape request is preserved. When it is absent,
  Pi supplies one semantically suitable aspect rather than asking for pixels;
  the adapter resolves exactly the configured dimensions.
- All nine default preset/aspect combinations resolve to valid configured
  dimensions at four inference steps. The former nine-preset matrix generated
  its exact dimensions remotely; the new maximum high matrix remains to be run.
  Invalid, missing, transposed, or out-of-range preset entries fail
  configuration validation.
- One ordinary `image_search` exposes exactly one image to Pi; a comparison
  request exposes exactly two; the tool cannot expose more than three.
- Image search is absent for text-only models and strict SafeSearch is fixed.
- Every exposed search image exists as a signature/dimension/size/hash-validated
  `web-NN.png/jpg` turn artifact with provenance metadata before the tool
  succeeds. Restored history serves the same bytes through an authorized URL.
- Search previews use uncropped contain rendering. The image link opens the
  stored full image in a separate tab; the cleaned title link opens the
  source page and does not append resolution text.
- Setup creates missing private prompt templates and never overwrites edited
  ones.
- Runtime no longer reads live prompt templates from release resources.
- Cancel writes zero files. A valid save changes all intended documents; an
  invalid save changes none and preserves editor text.
- Instruction action and textarea edges share one integer inset, and each SVG's
  measured center equals its button center.
- Saved Agent/Turn templates affect the next Pi request and saved Memory rules
  affect the next automatic-memory run.

### Maintainer checks

1. Judge the unchanged low, former-high medium, and new maximum high
   speed-detail trade-off; adjust only the `config.json` dimension mappings if
   necessary.
2. Try ordinary, quick-draft, and quality-focused requests and confirm the
   resulting preset feels natural without naming it every time.
3. Try requests with explicit and implicit composition and confirm Pi chooses
   square/portrait/landscape naturally without unnecessary follow-up questions.
4. Judge the full-screen editor's visual calm, tab names, textarea density, and
   whether check-left/X-right feels obvious.
5. Try one natural request such as “find one image of a capybara so you know
   what it looks like” and confirm Wheatley does not turn it into an unnecessary
   gallery or lengthy research task.
