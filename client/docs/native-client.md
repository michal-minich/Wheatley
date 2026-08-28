# Native thin client

This documents the current thin Tauri deployment. Thin is a valid long-term
target: Wheatley's Tauri application may continue to package the existing
TypeScript browser UI and call the same remote API for all product behavior.
It does not bundle `wheatleyd`, D code, models, profile data, Pi, or agent tools.
All durable runtime behavior remains on the computer running the Wheatley
server.

A future thin client may still own small device-local concerns that do not
duplicate assistant policy: audio IO, a bounded lazy cache for stable-code
thinking-music assets, and durable staging of accepted user audio transferred
as lossless or at least 32 kbit/s Opus until the server acknowledges it and
stores normalized 32 kbit/s `user.opus`. Generated assistant speech remains
disposable and should be deleted after playback/cancellation or startup
recovery. These behaviors are not implemented by the current shell. The current
ownership and deployment boundary is in
[System Contract](../../docs/specs/System%20Contract.md).

## Network contract

- Set `WHEATLEY_NATIVE_API_BASE` to the trusted-LAN server, for example
  `http://wheatley-server.local:8765/api`.
- HTTP, SSE, generated audio, thinking music, listening chimes, and live-audio
  WebSockets all resolve through the same client endpoint owner
- The server must run in trusted-LAN mode; this has no authentication and must
  not be exposed outside a trusted home network
- `scripts/server/lan.sh` allows the production Apple Tauri origin by default.
- The shipped Tauri CSP permits `127.0.0.1:8765` and `.local` hostnames on port
  `8765`. Add a different trusted host explicitly before building if needed.

Start the server:

```sh
WHEATLEY_TRUSTED_LAN=yes scripts/server/lan.sh
```

## Builds

From `client/`:

```sh
export WHEATLEY_NATIVE_API_BASE=http://wheatley-server.local:8765/api
npm run native:mac:build
npm run native:ios:init
npm run native:ios:build:simulator
npm run native:ios:build:device:unsigned
APPLE_DEVELOPMENT_TEAM=<team-id> npm run native:ios:build:device
```

The unsigned device command verifies the real ARM64 `iphoneos` target and
creates `src-tauri/gen/apple/build/wheatley-client_iOS.xcarchive`; it cannot be
installed. A physical iPhone build additionally requires an Apple development
team, signing identity, device pairing, and provisioning in Xcode. The
generated iOS project remains client-only; its Rust library contains only
Tauri startup.
