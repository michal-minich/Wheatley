# LSC Camera Eyes

Status: local image POC verified on 2026-08-20. This is an integration
knowledge base and operating note, not yet an implemented Wheatley feature.

## Decision summary

Wheatley can use the camera as a local network eye without the original LSC
application. The first verified path is a local RTSP stream enabled by the
exact-model SD-card boot package:

```text
rtsp://192.168.50.240:554/main_ch
```

FFmpeg can pull one JPEG from that stream. The current best first integration
is to make Wheatley's existing `capture_photo` capability use a camera adapter
or capture command. A later continuous-eye worker should keep one RTSP
connection open and expose only deliberately requested, fresh frames to the
model; the model should not receive every video frame.

No Wheatley code was changed during this POC.

## Camera identity

The physical labels and verified package identify the device as:

- Brand: LSC Smart Connect, sold by Action.
- Article: `3215672.2`.
- Model marking: `SI C26101`.
- Hardware family: Anyka `AK3918AV130` according to the community hardware
  investigation and the package README.
- Package firmware target: `V6.2802.61_BUNDLE`.
- Camera output: nominal 1920×1080.
- Wi-Fi: 2.4 GHz 802.11b/g/n, WPA/WPA2.
- Bluetooth: present for normal app pairing.
- Storage: microSD, labelled up to 128 GB.
- USB-C: power/charging only from macOS's perspective; it did not appear as a
  USB webcam, USB network device, disk, or video capture device.
- PTZ: the exact package documents `ptz_support = 0`; treat this unit as a
  fixed camera with no pan/tilt motor API.

The label matters. The older LSC `3215672` hardware and the newer `.1`/`.2`
hardware are not interchangeable for firmware or SD packages. Never apply a
Thingino image or another camera hack just because the outer product name
looks similar.

## Current physical setup

The exact community `3215672.2` SD package is installed on the camera's card.
The card was reformatted from exFAT to FAT32 and the package was copied to the
root. The card must remain inserted for the local services to exist; removing
it returns the camera to its ordinary stock/app behavior.

The current local network settings are:

```text
SSID:       configured privately in _ak39_factory.ini
IP:         192.168.50.240
Netmask:    255.255.255.0
Gateway:    192.168.50.1
MAC:        E8:2D:79:40:E8:8B
```

The router displayed a DHCP entry named `IPCamera` at `192.168.50.151`, but
the active camera endpoint was `192.168.50.240`. The static address therefore
currently wins over the router's stale/secondary lease display. Future setup
should use either a router reservation by MAC or one explicit static address,
then verify the address by probing it.

## How the local path works

The stock LSC/Tuya firmware normally keeps the useful camera stream behind the
LSC/Tuya application and cloud path. The community package uses an SD-card
boot hijack and the camera's own native RTSP implementation. It also overlays
supporting services:

- `hack.sh` is run from the SD card during boot.
- `_ak39_factory.ini` supplies the station Wi-Fi configuration and activates
  the factory-mode path.
- The native camera process serves the RTSP stream.
- `monvifd` provides an ONVIF description/discovery bridge.
- `lighttpd` provides a small authenticated status web UI.
- Telnet gives a root shell for inspection and recovery.

This is not a flash replacement. The first POC did not write camera flash.
It is still third-party code with root access and should remain on a trusted
LAN only.

## Verified services and endpoints

| Surface | Address | Verified behavior | Wheatley use |
| --- | --- | --- | --- |
| RTSP | `rtsp://CAMERA_IP:554/main_ch` | Native H.264/AAC stream; no RTSP authentication was required in the POC | Primary image/video source |
| HTTP | `http://CAMERA_IP/` | `lighttpd`; Digest auth; redirects to HTTPS after authentication | Operator diagnostics only |
| HTTPS | `https://CAMERA_IP/` | Self-signed certificate; Digest auth; status dashboard | Operator diagnostics only |
| Status CGI | `https://CAMERA_IP/status.cgi` | JSON containing uptime, IP, memory, load, SD use, raw temperature field, and service flags | Health check, not model content |
| ONVIF | `http://CAMERA_IP:8081/onvif/device_service` | ONVIF/WS-Discovery bridge supplied by the package | Optional NVR discovery; not needed for first Wheatley slice |
| Telnet | `CAMERA_IP:23` | Root shell supplied by the package | Maintenance only; disable or firewall later |
| FTP | package reports `ftpd_running=1` | Not needed for the live image path; not independently used in the POC | Avoid unless recording retrieval is required |

The package's initial web credentials are the published defaults `root` /
`anyka`. Change them before treating the camera as a durable household
service. HTTP/HTTPS uses Digest authentication; a plain `curl -u` request is
not sufficient, while `curl --digest -u ...` is.

The ONVIF service is secondary. A direct GET to its root is not a meaningful
ONVIF test because ONVIF expects SOAP. During the POC one slash variant
redirected to an incorrect private address, so Wheatley should use the direct
RTSP URL and not depend on ONVIF discovery until that advertisement is tested
with a real ONVIF client.

## Verified media contract

`ffprobe` reported the following from the live RTSP endpoint:

### Video

- Codec: H.264 / AVC, Main profile.
- Size: 1920×1080, 16:9.
- Pixel format: `yuvj420p`, progressive, 8-bit.
- Sample aspect ratio: 1:1.
- RTSP stream metadata advertises 25 fps but also reports approximately
  14.99 fps as the time-base rate.
- A ten-second live read produced 144 decoded frames, approximately 14–15
  actual frames per second. Treat this as a 15 fps camera until a later
  firmware/configuration change proves otherwise.
- `ffprobe` did not expose a reliable bitrate. Do not build a bitrate contract
  from the current stream metadata.

### Audio

- Codec: AAC-LC.
- Sample rate: 8000 Hz.
- Channels: mono.
- Audio is available in the RTSP stream but is not needed for a still-image
  eye. Wheatley should omit audio from the first image capture command.

### Timing

Measured from the Mac on the local LAN, including FFmpeg startup and waiting
for a usable frame:

- Ordinary one-shot FFmpeg capture: about 2.6–3.0 seconds.
- Tuned one-shot capture using small probe parameters and low-delay flags:
  about 1.0–1.2 seconds in two runs, with one run at about 1.95 seconds.
- A persistent RTSP reader should reduce request latency further because it
  can always hold a recent decoded frame. This is the preferred long-term
  design for Wheatley eyes.
- The first usable frame may wait for a keyframe. Do not treat a short empty
  read as camera failure; retry within a bounded capture deadline.

The stream has unusual timestamp behavior. A ten-second read produced FFmpeg
non-monotonic-DTS warnings while still decoding successfully. Wheatley should
use decoded frame freshness and wall-clock capture time, not assume perfect
monotonic media timestamps.

## Capture commands

### Inspect the stream

```bash
ffprobe \
  -hide_banner \
  -rtsp_transport udp \
  -timeout 5000000 \
  -show_streams \
  'rtsp://192.168.50.240:554/main_ch'
```

### Capture one JPEG

This is the currently verified tuned form. `-update 1` makes a single output
file explicit; `-map 0:v:0` prevents audio from affecting the image path.

```bash
ffmpeg \
  -hide_banner \
  -loglevel error \
  -y \
  -rtsp_transport udp \
  -fflags nobuffer \
  -flags low_delay \
  -probesize 32768 \
  -analyzeduration 100000 \
  -i 'rtsp://192.168.50.240:554/main_ch' \
  -map 0:v:0 \
  -frames:v 1 \
  -q:v 3 \
  -update 1 \
  /tmp/wheatley-camera.jpg
```

The POC was captured as a 1920×1080 JPEG. `-q:v 3` is a practical high-quality
JPEG setting, not a camera quality control; Wheatley can choose a smaller
model-facing image after capture if the selected vision model benefits from
lower pixels or faster upload.

### TCP fallback

UDP is the preferred transport for this camera's package. TCP also decoded a
five-second test successfully on the current LAN, so Wheatley should retry
with TCP when UDP is unavailable:

```bash
ffmpeg \
  -hide_banner \
  -loglevel error \
  -y \
  -rtsp_transport tcp \
  -timeout 5000000 \
  -i 'rtsp://192.168.50.240:554/main_ch' \
  -map 0:v:0 \
  -frames:v 1 \
  -q:v 3 \
  -update 1 \
  /tmp/wheatley-camera.jpg
```

The community package notes that some longer RTSP-over-TCP recording tests
stalled while UDP worked. That is why the integration default should remain
UDP with a bounded TCP fallback, not TCP-only.

### Continuous local preview

For a human diagnostic only:

```bash
ffplay -rtsp_transport udp 'rtsp://192.168.50.240:554/main_ch'
```

Do not give the model a continuous video stream by default. Sample or request
individual frames according to the conversation and vision policy.

## Camera settings and controls

### Known capabilities

The product packaging and manual describe 1080p video, night vision, a
microphone, speaker/two-way audio, motion detection, and microSD recording.
The SD package exposes the native stream and diagnostic services.

### Not currently exposed

No reliable local API or package control path was found for:

- Shutter speed.
- ISO or manual gain.
- Aperture.
- Focus control.
- White-balance control.
- Exposure compensation.
- Night-vision mode switching.
- IR intensity.
- Motion-sensitivity changes.
- Speaker output or microphone gain through a stable Wheatley-facing API.
- Pan, tilt, or zoom; this unit has no PTZ motor according to the package.

### Date/time stamp (OSD)

The current RTSP image contains a visible date/time stamp in the top-left
corner. This is an OSD overlay rendered by the camera before the frame reaches
RTSP; it is part of the pixels, not removable JPEG metadata or a Wheatley UI
decoration.

Current answer: there is no verified local command to ask this camera to show
or hide the stamp. The SD package's internal configuration contains an
`osd_time`-related setting, but the package investigation reports that changing
the config file did not change the live overlay. The native process appears to
receive this kind of setting through runtime IPC, probably the same control
path used by the Tuya/LSC application, rather than reliably reading the static
file. The community ONVIF bridge is a description/discovery layer and is not a
proven OSD-control API.

For Wheatley, treat the timestamp as currently always present. Do not crop or
paint it out silently: the timestamp is useful evidence, and masking it would
alter the camera image. If the product experience requires a clean image, the
next investigation should be an explicit, reversible control probe through
the camera's native IPC or the original app's local traffic. A post-processing
mask is a fallback only after the maintainer accepts the loss of image content and the
risk of hiding a useful clock signal.

The clock itself should be validated before using the overlay as evidence. The
package attempts timezone/NTP setup, but Wheatley should record both the frame
capture wall-clock and the visible camera timestamp rather than assuming they
are identical.

Treat exposure, focus, white balance, and night vision as camera-owned
automatic ISP behavior. Do not invent shutter/ISO controls in Wheatley. If a
future serial or native IPC investigation finds a stable control interface,
add it as a separate capability with explicit device-specific semantics.

The package includes an internal hardware settings file with video profiles,
but this is boot-overlay implementation detail rather than a safe product API.
It also documents that the RTSP service exposes only `/main_ch`; the internal
sub-stream profiles are not available as a second RTSP URL. The package's OSD
time overlay was not reliably controllable through the config file.

## Finding the camera again

Prefer a stable address. In order of preference:

1. Keep the explicit static address and verify it is outside the router's DHCP
   pool.
2. Create a DHCP reservation for MAC `E8:2D:79:40:E8:8B` and remove the static
   address from the SD config.
3. Use the router's client list by MAC/hostname. Do not trust only the name
   `IPCamera`; the router showed `.151` while the working static endpoint was
   `.240`.
4. Probe the known camera ports on the local subnet if the address is lost:
   `23`, `80`, `443`, `554`, and `8081`. Port 554 plus a successful RTSP
   `DESCRIBE` is the decisive identity test.

Do not scan or expose the camera from the public internet. The local endpoint
has root Telnet and an authenticated web server specifically because of the
SD package.

## Failure and recovery guide

### Blue LED keeps blinking

For LSC cameras, blinking blue indicates connection/pairing activity rather
than a ready local stream. Check the card, the exact SSID/password, 2.4 GHz
compatibility, and the active IP. The camera may be reachable at its static
address even when the router's DHCP display is confusing.

### Camera is not reachable

Power-cycle with the SD card inserted, wait 60–120 seconds, check the router,
then ping and probe both the configured static address and the latest lease.
If the card is removed, the local RTSP/HTTP/Telnet services disappear by
design.

### RTSP cannot open

Try `/main_ch` exactly, port 554, UDP first, then TCP. Wait for a keyframe and
allow at least five seconds for the bounded probe. Check that the camera and
Mac are on the same LAN and that client isolation is disabled.

### Card stops booting the package

Remove the card and power-cycle to return to stock camera behavior. Keep a
copy of the known-good FAT32 card contents. Do not flash the camera unless a
separate recovery plan, firmware backup, and human approval exist.

## Wheatley integration design

### First vertical slice

Reuse the existing `capture_photo` tool contract and add a thin network-camera
capture adapter at the client/server edge:

1. Resolve the selected profile's camera endpoint.
2. Open the configured RTSP URL with FFmpeg.
3. Read one video frame with UDP and a bounded TCP retry.
4. Validate that the output is a JPEG, has a positive size, and is younger than
   the capture deadline.
5. Store/upload it through the existing image artifact path.
6. Return source, capture time, resolution, transport, and latency as tool
   details while sending the image to the vision model.

The first implementation may use `WHEATLEY_CAPTURE_PHOTO_COMMAND` as a
contained experiment, but the durable design should not hide a network camera
inside an arbitrary shell string.

### Continuous eyes later

A dedicated camera worker should own one RTSP reader and a bounded recent-frame
buffer. It should expose:

- `capture_latest_frame(max_age_ms)` for an explicit fresh image request;
- optional `capture_frame_at_or_after(...)` for a short observation window;
- health state with last packet, last decoded frame, transport, and failure;
- bounded reconnect and UDP/TCP fallback;
- no persistent recording unless the user explicitly enables it.

The model should receive a still image plus factual metadata, not a hidden
stream of frames. Motion-triggered observation, scene comparison, and scheduled
eyes checks should be later policy built on this mechanism, not embedded in
the RTSP adapter.

### Suggested profile settings

The eventual profile-owned settings should be explicit and small:

```json
{
  "eyes": {
    "camera": {
      "enabled": false,
      "name": "room",
      "rtsp_url": "rtsp://192.168.50.240:554/main_ch",
      "transport": "udp",
      "tcp_fallback": true,
      "capture_timeout_ms": 8000,
      "max_frame_age_ms": 3000,
      "model_max_long_edge_px": 1280
    }
  }
}
```

This is a design example, not an active Wheatley schema. Camera credentials,
if a future firmware exposes them, must not be placed in model-visible prompt
files or ordinary readable conversation memory.

## Security and privacy

### What changed: firmware versus SD overlay

The camera does **not** currently contain a newly flashed custom firmware
image. The original flash remains in place. However, this is more than a
configuration-only change: the FAT32 card contains a boot hijack, shell
scripts, a replacement password file, custom `lighttpd` and ONVIF binaries,
supporting libraries, and configuration overlays. Those files run as root and
add services while the card is inserted. Removing the card returns the camera
to its stock boot path.

This distinction matters: the setup is reversible by removing the card, but
the active camera is still running third-party root-level code.

### Current risk verdict

There is no evidence from the POC that the camera is actively spying beyond
its intended camera behavior. There is also no basis to claim that a cheap
Tuya/LSC camera is trustworthy merely because the local RTSP image works. The
current setup should be treated as an **experimental IoT device with a
meaningful LAN risk**, not as a hardened security appliance.

The current POC exposes or enables:

- Root Telnet on port 23.
- Authenticated HTTP/HTTPS management on ports 80/443, initially using the
  package's published default credentials.
- ONVIF management/discovery on port 8081.
- FTP reported as running by the status service.
- RTSP on port 554 without authentication in the verified capture. Any device
  that can reach that port can potentially view the camera.
- Third-party binaries and scripts that have not received an independent
  security audit.

The local RTSP path means Wheatley can read the stream directly without using
the cloud for that read. It does **not** prove that the stock Tuya/LSC process
has stopped making outbound connections. The SD package was designed to add
local services while retaining the stock camera base; assume cloud traffic is
possible until egress is observed or blocked. The LSC privacy policy confirms
that the app/platform processes device and network metadata and refers users
to Tuya's platform privacy processing.

### Minimum hardening before durable use

1. Put the camera on a dedicated IoT SSID/VLAN. It must allow Wheatley's Mac
   to reach the camera, but it should not be a general trusted household LAN.
2. Block all inbound WAN access and disable router port forwarding/UPnP for the
   camera. Prefer blocking camera-to-internet egress as well; allow only local
   NTP if the visible clock needs synchronization.
3. Change the package's default root and web credentials. Do this before the
   camera is reachable by other household devices. Verify that port 23 is no
   longer using the published default, then consider disabling Telnet entirely
   in the SD package after local recovery has been proven.
4. Restrict ports 23, 80, 443, and 8081 to the Mac or a small management host.
   Treat port 554 as a read-only camera ACL: allow only the future Wheatley
   camera worker and explicitly approved viewers.
5. Keep the SD card package archived and review any future replacement before
   putting it into the camera. Do not flash firmware as part of this eyes
   project.
6. If the Wi-Fi password has been copied into any shared, public, or
   machine-readable place outside the private home setup, rotate it.

The first Wheatley implementation should therefore run on the trusted local
host, use the camera only through RTSP, avoid Telnet/HTTP/ONVIF during normal
operation, and make camera use visible and disable-able.

- Keep the camera and its RTSP/Telnet/HTTP ports on a trusted home LAN or
  isolated camera VLAN.
- Change the package's default root/web credentials before long-term use.
- Do not forward ports from the router to the camera.
- Treat every captured frame as private household media.
- Store frames only when the user requests an artifact or durable recording.
- Make camera use visible in Wheatley activity and retain a clear enable/disable
  setting.
- Keep the original app/cloud path out of the first integration; local RTSP is
  sufficient for eyes.

## Evidence and sources

### Machine-verified on 2026-08-20

- Router/Mac LAN: camera endpoint `192.168.50.240` answered ping.
- Open ports: 23, 80, 443, 554, 8081.
- RTSP `OPTIONS`: `200 OK`, server `rtsp_demo`, methods OPTIONS, DESCRIBE,
  SETUP, PLAY, PAUSE, TEARDOWN.
- `ffprobe`: H.264 Main 1920×1080 plus AAC-LC 8 kHz mono.
- Ten-second decode: 144 frames, approximately 14–15 fps observed.
- One-shot JPEG: 1920×1080, successful.
- The JPEG visibly includes the camera-rendered date/time OSD in the top-left;
  no working local OSD on/off control has been verified.
- Tuned one-shot startup/capture: approximately 1.0–1.2 seconds in two runs,
  one 1.95-second run; ordinary command was approximately 2.6–3.0 seconds.
- HTTPS status JSON: web, ONVIF bridge, Telnet, and FTP service flags reported
  running; raw temperature field was present but its units were not adopted as
  a contract.

### External references

- [LSC Smart Connect manual linked to the purchased product](https://manuals.plus/asin/B097DNWVR5)
  — 2.4 GHz, QR pairing, 1080p, night vision, audio, and microSD product
  behavior.
- [Exact LSC 3215672 Anyka hardware discussion and SD package](https://github.com/themactep/thingino-firmware/discussions/1043)
  — article revision, Anyka hardware findings, package link, RTSP path, and
  community limitations.
- [LSC 3215672 hardware wiki](https://github.com/themactep/thingino-firmware/wiki/Camera:-LSC-3215672)
  — warning that the older plain `3215672` and newer `.1`/`.2` revisions use
  different hardware.
- [LSC Smart Connect privacy policy](https://qin.tuyaus.com/app-agreement/en/13009/v1.0.3/1/smart/app/package/13009/privacyUrl_1641877719641.html)
  — the app/platform's stated collection of device and network metadata and
  reference to Tuya platform processing.

Community package behavior is not manufacturer support. Treat the local probe
and this document's machine-verified measurements as the current authority for
this particular camera, and re-test after any package, camera, or network
change.
