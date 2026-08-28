# Screen Capture Tool

Status: implemented and end-to-end verified, 2026-08-13.

## Outcome

Any user profile can ask Wheatley to “look at my screen,” “look at this app,” or
“take a screenshot.” Wheatley captures one fresh image on the client that
submitted that turn, gives a suitably sized lossless PNG to the selected vision
model, and saves the full PNG with the accepted turn as
`images/screenshot-01.png`.

The feature is the client-mediated `capture_screen` tool beside
`capture_photo`. It never captures the Wheatley server computer or silently
routes to another connected client.

## Tool contract

```json
{
  "name": "capture_screen",
  "description": "Capture the current app or display from the exact Wheatley client handling this turn.",
  "parameters": {
    "type": "object",
    "properties": {
      "scope": {
        "type": "string",
        "enum": ["active_window", "active_display"],
        "default": "active_window"
      }
    },
    "additionalProperties": false
  }
}
```

Typical call:

```json
{
  "name": "capture_screen",
  "arguments": { "scope": "active_window" }
}
```

Client selection, display IDs, pixel dimensions, encoding, and timeout are not
model choices. `active_window` means the current app; `active_display` means
the display containing it. The tool is available only with a vision model and
a compatible capture capability advertised by the exact originating client.

The result contains a short text part and an actual PNG image part for Pi. Tool
details retain the client, scope, full dimensions, scale, full PNG URL, and
model-rendition URL.

## Configuration and resizing

```json
{
  "tools": {
    "available": {
      "capture_screen": true
    }
  },
  "screen_capture": {
    "model_pixels_per_logical_pixel": 1.0,
    "model_max_long_edge_px": 2560
  }
}
```

The full frame is always retained. Only the model rendition is reduced. The
capturing client reports the target dimensions, using the target
window/display's UI scale as the main text-size proxy and the single 2560 px
long-edge ceiling. The server renders that exact size from the full PNG only
when Pi or the verification link requests it; the temporary file is removed
immediately. The calculation preserves aspect ratio and never upscales:

```text
ui_scale = physical pixels / logical UI units
scale = min(1, model_pixels_per_logical_pixel / ui_scale,
               model_max_long_edge_px / long_edge)
```

Examples with the default configuration:

| Full capture | UI scale | Model PNG |
| --- | ---: | ---: |
| `1920×1080` | 100% | `1920×1080` |
| `1920×1200` | 100% | `1920×1200` |
| `3840×2160` | 100–150% | `2560×1440` |
| `3840×2160` | 200% | `1920×1080` |
| `3024×1964` | 200% | `1512×982` |

Browser canvas resizing uses high-quality interpolation. Console resizing uses
the bundled FFmpeg with one Lanczos pass and stripped metadata. Both outputs
remain PNG; JPEG is not used because lossy edges can damage small interface
text. The provider ultimately decodes the PNG into model-specific visual
patches/tokens, so decoded dimensions—not PNG file compression—are the main
inference cost.

## Client behavior

### Web

The web UI has an explicit **Share screen with Wheatley** control backed by
`navigator.mediaDevices.getDisplayMedia()`. A tool call never opens the browser
chooser. While the user-authorized track is live and has valid video dimensions,
the tab advertises the selected or inferred scope:

- `window` or `browser` → `active_window`
- `monitor` → `active_display`

When `displaySurface` and `screenPixelRatio` are present, Wheatley uses them
directly. Firefox and Safari may omit those optional settings despite delivering
a usable full-size frame. Wheatley then infers display-versus-window from the
captured frame and browser display geometry, derives scale from physical versus
CSS dimensions when they agree, and otherwise conservatively uses
`devicePixelRatio` or `1`. It still retains every pixel the browser delivers and
applies the 2560 px model ceiling.

Starting a share from a text-only model automatically selects the first
available vision model, just as the screen request itself requires vision.
Selecting a text-only model while sharing stops and withdraws the share.
Stopping the share, ending the track, changing profile, or closing the tab also
withdraws the capability. This follows the
[Screen Capture specification](https://www.w3.org/TR/screen-capture/) and
[MDN `getDisplayMedia()` guidance](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getDisplayMedia).

### Console

Ordinary console chat and voice host the client-tool loop concurrently; no
second process or special command is required. Console configuration accepts
an optional vision-capable `model` for new sessions.

- macOS captures the foreground window or active display with the local
  `screencapture` path and reads Retina scale locally.
- Windows captures the foreground HWND or its monitor through local PowerShell,
  Win32 bounds/DPI, and `System.Drawing`.
- `WHEATLEY_CAPTURE_SCREEN_COMMAND` remains an explicit local integration hook.

The deterministic console dry-run capture is used for repeatable end-to-end
tests without depending on operating-system recording permission.

## Storage, presentation, and sound

The client uploads one full-resolution `screen_capture` PNG plus the model
target dimensions. On successful completion the server validates and promotes
the full artifact into the accepted turn. Pi fetches an on-demand lossless PNG
at those exact dimensions and returns it as image content in the same tool
result. The reduced rendition is temporary and is never retained as a second
screen-capture artifact.

The web transcript displays the canonical full PNG inline at the tool position
using the same responsive image frame and click-to-open behavior as generated
images. Reloaded history restores that same turn image; it never substitutes
the smaller model rendition. The shared turn-image endpoint recognizes strict
`screenshot-NN.png` names and validates the retained metadata, relative path,
byte count, and SHA-256 before serving the PNG.

The click-to-open address is intentionally a product URL rather than the raw
artifact endpoint: `/chat/<profile>/<session>/screenshot/01`. Screenshot
numbers are ordered across the chat, independent of per-turn storage
filenames. Keep future visible image links short, readable, chat-relative, and
free of encoded turn paths, query parameters, API hierarchy, and storage
details. Generated and searched images follow the sibling `generated-image/NN`
and `search-image/NN` routes.

When a screenshot was reduced for the model, its small `Screen capture`
caption becomes visibly linked only on hover or keyboard focus. It opens
`/chat/<profile>/<session>/screenshot/01/model` in a new tab, where the server
computes the same exact-size PNG on demand with no cache or retained derivative.
The caption is plain text when the full PNG was already small enough and the
model therefore received it without reduction.

Immediately after a fresh frame is acquired, the capturing client plays the
bundled `assets/audio/chimes/capture.wav` camera-confirmation cue. It is the
original 120 ms shutter recording expanded at half tempo, preserving its pitch
and character while extending its audible duration to about 213 ms. The same
cue is used by `capture_photo`. It has an independent one-shot audio lane, so
thinking music, ordinary music, and speech are not stopped or advanced.

## Agent instruction

> When the user asks you to look at their screen or app, or take a screenshot,
> call `capture_screen`. Use `active_window` for the current app and
> `active_display` for the whole screen.

## Verification

- Web: a mocked full-detail `3024×1964`, 200%-scale share produced a
  `1512×982` model PNG; the vision model read both lines in the frame. The
  `3024×1964` PNG appeared inline, survived history reload from its canonical
  turn URL, and stopping sharing withdrew the web capability.
- Firefox/Safari compatibility: a Firefox run deliberately omitted
  `displaySurface`, `resizeMode`, and `screenPixelRatio`. Sharing from Primary
  automatically changed Ornith to Qwen, advertised the inferred scope, retained
  the `3024×1964` PNG, produced a `1492×969` model PNG, and the model read both
  expected lines. Re-selecting Ornith stopped sharing and withdrew capability.
- Console: a normal text-chat process advertised both scopes, a vision model
  called `capture_screen`, the same process executed it, the model described
  the returned dry-run PNG, and the console printed the canonical
  `images/screenshot-01.png` turn path.
- Automated: web lint, TypeScript, production build, D console build, Pi
  extension tests, and all D unit-test modules pass.
