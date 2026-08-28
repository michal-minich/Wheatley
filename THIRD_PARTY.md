# Third-party material

Wheatley uses third-party dependencies through DUB, npm, and pip. Their package
metadata and lock files record the selected versions. Each dependency remains
subject to its own license.

## Vendored code

`server/wheatleyd/vendor/miniaudio/` contains miniaudio. Its license and
upstream provenance are preserved beside the source in `LICENSE` and
`UPSTREAM.md`.

## Bundled media

The thinking-music tracks under
`app-data/resources/assets/audio/thinking-music/` are CC0 derivatives. Per-track
sources, authors, checksums, and requested attribution are preserved in that
directory's `LICENSE.md` and `manifest.json`.

The two listening chimes under `app-data/resources/assets/audio/chimes/` are project
assets.

## Optional local voice dependencies

The setup scripts install or use FFmpeg, whisper.cpp, uv, Piper, and
Supertonic. Their binaries, Python environments, voice models, and Whisper
models are not committed to this repository. They are downloaded into ignored
`app-data/` paths and remain governed by their respective upstream licenses and
model terms.

Review those terms before redistributing a prebuilt Wheatley bundle containing
the optional runtimes or models.

## Optional local image generation

The image-worker installer uses the PrismML Bonsai Image Demo pinned to commit
`9cf9d6e` and the Ternary Bonsai Image 4B MLX weights. They are downloaded into
ignored `app-data/image-generation/` paths and are not redistributed by this
repository. The demo, its dependencies, and the model remain subject to their
upstream licenses and model terms. FLUX.2 Klein 4B, from which Bonsai is
derived, is Apache-2.0; review the Bonsai model card and included upstream
license files before redistributing an appliance image.
