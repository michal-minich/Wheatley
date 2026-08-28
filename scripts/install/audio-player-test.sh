#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"
app_data_root="$WHEATLEY_APP_DATA_ROOT"

case "$(uname -s)" in
  Darwin) os="macos" ;;
  Linux) os="linux" ;;
  *) echo "[audio-player-test] unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64) arch="x86_64" ;;
  *) echo "[audio-player-test] unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

"$script_dir/audio-player.sh"
player="$app_data_root/tools/$os-$arch/bin/wheatley-audio-player"
ffmpeg="$app_data_root/tools/$os-$arch/bin/ffmpeg"
if [[ ! -x "$ffmpeg" ]]; then
  ffmpeg="$(command -v ffmpeg)"
fi

temporary="$(mktemp -d "${TMPDIR:-/tmp}/wheatley-audio-player.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
input="$temporary/input.wav"
output="$temporary/output.wav"
loop_input="$temporary/loop.mp3"

"$ffmpeg" -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=440:sample_rate=16000:duration=2" \
  -filter:a "volume=0.5" \
  -c:a pcm_s16le \
  "$input"

"$ffmpeg" -hide_banner -loglevel error -y \
  -i "$input" \
  -c:a libmp3lame -b:a 96k \
  "$loop_input"

result="$($player --render "$output" "$input" 500 1500)"
paused="$(printf '%s' "$result" | sed -E 's/.*"paused_cursor_frames":([0-9]+).*/\1/')"
resumed="$(printf '%s' "$result" | sed -E 's/.*"resumed_cursor_frames":([0-9]+).*/\1/')"
decoded="$(printf '%s' "$result" | sed -E 's/.*"decoded_frames":([0-9]+).*/\1/')"
rendered="$(printf '%s' "$result" | sed -E 's/.*"output_frames":([0-9]+).*/\1/')"
maximum_delta="$(printf '%s' "$result" | sed -E 's/.*"max_sample_delta":([0-9.]+).*/\1/')"

[[ "$paused" == "$resumed" ]]
[[ "$decoded" == "32000" ]]
((rendered >= 49000 && rendered <= 50000))
awk -v delta="$maximum_delta" 'BEGIN { exit !(delta < 0.05) }'

"$player" --null "$input" &
pid=$!
sleep 0.3
kill -URG "$pid"
sleep 0.6
kill -0 "$pid"
kill -CONT "$pid"
wait "$pid"

"$player" --null "$input" &
pid=$!
sleep 0.3
kill -TERM "$pid"
wait "$pid"

# Pause/resume can arrive immediately after spawn. Their default signal actions
# must remain harmless even if the helper has not installed its handlers yet.
race_pids=()
for _ in {1..12}; do
  "$player" --null "$input" &
  pid=$!
  kill -URG "$pid"
  kill -CONT "$pid"
  race_pids+=("$pid")
done
for pid in "${race_pids[@]}"; do
  wait "$pid"
done

WHEATLEY_AUDIO_PLAYER_BACKEND=null "$player" --loop --gain 0.2 "$loop_input" &
pid=$!
sleep 2.3
kill -0 "$pid"
kill -TERM "$pid"
wait "$pid"

echo "[audio-player-test] cursor preserved at frame $paused"
echo "[audio-player-test] maximum sample delta $maximum_delta"
echo "[audio-player-test] pause/resume and graceful stop passed"
echo "[audio-player-test] immediate-command startup race passed"
echo "[audio-player-test] quiet looping playback passed"
