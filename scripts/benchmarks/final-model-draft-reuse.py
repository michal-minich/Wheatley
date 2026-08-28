#!/usr/bin/env python3
"""Compare a last cumulative large-v3 draft with full-recording large-v3 STT."""

from __future__ import annotations

import argparse
import difflib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import urllib.request
import uuid


DURATION_BINS = ((2, 8), (8, 20), (20, 45), (45, 90), (90, 150), (150, 240))


def main() -> None:
    args = parse_args()
    candidates = candidates_from_profiles(args.profiles_root, args.profiles.split(","))
    samples = select_samples(candidates)
    if len(samples) < len(DURATION_BINS):
        raise RuntimeError(f"Only {len(samples)} suitable English samples were found.")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    port = available_port()
    command = [
        str(args.whisper_server), "--host", "127.0.0.1", "--port", str(port),
        "--model", str(args.model), "--language", "auto",
    ]
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for_server(process, port)
        results = run_samples(samples, args.ffmpeg, port)
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    payload = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "model": str(args.model),
        "beam_size": 3,
        "max_context": 0,
        "method": "large-v3 on the last actual cumulative-preview prefix versus full audio",
        "samples": results,
        "summary": summarize(results),
    }
    args.output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(payload["summary"], indent=2))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profiles-root", type=Path, required=True)
    parser.add_argument("--profiles", default="wheatley",
                        help="Comma-separated profile IDs to sample")
    parser.add_argument("--whisper-server", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def candidates_from_profiles(
    profiles_root: Path,
    profiles: list[str],
) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for profile_id in profiles:
        sessions = profiles_root / profile_id / "sessions"
        if not sessions.is_dir():
            continue
        for session_json in sessions.rglob("session.json"):
            session = load_json(session_json)
            if session.get("language") != "en":
                continue
            for turn_json in (session_json.parent / "turns").glob("*/turn.json"):
                audio = turn_json.parent / "user.opus"
                if not audio.is_file():
                    continue
                turn = load_json(turn_json)
                stt = turn.get("metrics", {}).get("stt", {})
                final = stt.get("final", {})
                runs = stt.get("draft", {}).get("runs", [])
                if final.get("source") != "final_stt" or not runs:
                    continue
                duration = float(final.get("audio_seconds", 0))
                chars = int(final.get("text_chars", 0))
                prefix = max(float(run.get("audio_seconds", 0)) for run in runs)
                if duration <= 0 or chars < 20 or prefix <= 0 or prefix > duration:
                    continue
                result.append({
                    "profile": profile_id,
                    "turn": str(turn_json.relative_to(profiles_root / profile_id)),
                    "audio": audio,
                    "duration_seconds": duration,
                    "draft_prefix_seconds": prefix,
                    "stored_final_chars": chars,
                    "preview_run_count": len(runs),
                    "preview_audio_seconds_total": sum(
                        float(run.get("audio_seconds", 0)) for run in runs
                    ),
                })
    return result


def select_samples(candidates: list[dict[str, object]]) -> list[dict[str, object]]:
    selected = []
    for minimum, maximum in DURATION_BINS:
        choices = [
            item for item in candidates
            if minimum <= float(item["duration_seconds"]) < maximum
            and float(item["duration_seconds"]) - float(item["draft_prefix_seconds"]) <= 3.0
        ]
        if not choices:
            continue
        selected.append(max(
            choices,
            key=lambda item: int(item["stored_final_chars"]) / float(item["duration_seconds"]),
        ))
    return selected


def run_samples(
    samples: list[dict[str, object]],
    ffmpeg: Path,
    port: int,
) -> list[dict[str, object]]:
    results = []
    with tempfile.TemporaryDirectory(prefix="wheatley-draft-benchmark-") as temp_text:
        temp = Path(temp_text)
        for index, sample in enumerate(samples, start=1):
            prefix_wav = temp / f"{index}-prefix.wav"
            full_wav = temp / f"{index}-full.wav"
            convert(ffmpeg, Path(sample["audio"]), prefix_wav, float(sample["draft_prefix_seconds"]))
            convert(ffmpeg, Path(sample["audio"]), full_wav, None)
            prefix = transcribe(prefix_wav, port)
            final = transcribe(full_wav, port)
            prefix_words = normalized_words(prefix["text"])
            final_words = normalized_words(final["text"])
            projected_drafting_ms = round(
                int(prefix["inference_ms"])
                * float(sample["preview_audio_seconds_total"])
                / float(sample["draft_prefix_seconds"]),
            )
            results.append({
                "sample": index,
                "profile": sample["profile"],
                "turn": sample["turn"],
                "duration_seconds": sample["duration_seconds"],
                "draft_prefix_seconds": sample["draft_prefix_seconds"],
                "unseen_tail_seconds": round(
                    float(sample["duration_seconds"]) - float(sample["draft_prefix_seconds"]), 3,
                ),
                "preview_run_count": sample["preview_run_count"],
                "projected_large_drafting_ms": projected_drafting_ms,
                "draft_chars": len(prefix["text"]),
                "final_chars": len(final["text"]),
                "draft_inference_ms": prefix["inference_ms"],
                "full_inference_ms": final["inference_ms"],
                "exact_normalized_match": prefix_words == final_words,
                "word_error_rate": round(word_error_rate(prefix_words, final_words), 4),
                "sequence_similarity": round(sequence_similarity(prefix_words, final_words), 4),
                "common_prefix_words": common_prefix_length(prefix_words, final_words),
                "draft_words": len(prefix_words),
                "final_words": len(final_words),
            })
            print(f"sample {index}/{len(samples)} complete", flush=True)
    return results


def convert(ffmpeg: Path, source: Path, target: Path, seconds: float | None) -> None:
    command = [str(ffmpeg), "-hide_banner", "-loglevel", "error", "-y", "-i", str(source)]
    if seconds is not None:
        command.extend(["-t", f"{seconds:.3f}"])
    command.extend(["-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(target)])
    subprocess.run(command, check=True)


def transcribe(path: Path, port: int) -> dict[str, object]:
    boundary = f"wheatley-benchmark-{uuid.uuid4()}"
    fields = {
        "response_format": "verbose_json",
        "language": "en",
        "beam_size": "3",
        "no_timestamps": "true",
        "no_language_probabilities": "true",
        "max_context": "0",
    }
    body = bytearray()
    for name, value in fields.items():
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(value.encode() + b"\r\n")
    body.extend(f"--{boundary}\r\n".encode())
    body.extend(b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n')
    body.extend(b"Content-Type: audio/wav\r\n\r\n")
    body.extend(path.read_bytes())
    body.extend(f"\r\n--{boundary}--\r\n".encode())
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/inference",
        data=bytes(body),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=180) as response:
        payload = json.load(response)
    segments = payload.get("segments", [])
    text = " ".join(str(segment.get("text", "")).strip() for segment in segments).strip()
    if not text:
        text = str(payload.get("text", "")).strip()
    return {"text": text, "inference_ms": round((time.monotonic() - started) * 1000)}


def normalized_words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def word_error_rate(actual: list[str], expected: list[str]) -> float:
    if not expected:
        return 0.0 if not actual else 1.0
    previous = list(range(len(expected) + 1))
    for row, word in enumerate(actual, start=1):
        current = [row]
        for column, expected_word in enumerate(expected, start=1):
            current.append(min(
                current[-1] + 1,
                previous[column] + 1,
                previous[column - 1] + (word != expected_word),
            ))
        previous = current
    return previous[-1] / len(expected)


def sequence_similarity(actual: list[str], expected: list[str]) -> float:
    return difflib.SequenceMatcher(a=actual, b=expected, autojunk=False).ratio()


def common_prefix_length(first: list[str], second: list[str]) -> int:
    count = 0
    for left, right in zip(first, second):
        if left != right:
            break
        count += 1
    return count


def summarize(results: list[dict[str, object]]) -> dict[str, object]:
    count = len(results)
    return {
        "sample_count": count,
        "exact_match_count": sum(bool(item["exact_normalized_match"]) for item in results),
        "mean_word_error_rate": round(sum(float(item["word_error_rate"]) for item in results) / count, 4),
        "mean_sequence_similarity": round(
            sum(float(item["sequence_similarity"]) for item in results) / count,
            4,
        ),
        "total_draft_inference_ms": sum(int(item["draft_inference_ms"]) for item in results),
        "total_full_inference_ms": sum(int(item["full_inference_ms"]) for item in results),
        "projected_total_large_drafting_ms": sum(
            int(item["projected_large_drafting_ms"]) for item in results
        ),
    }


def load_json(path: Path) -> dict[str, object]:
    with path.open() as stream:
        return json.load(stream)


def available_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def wait_for_server(process: subprocess.Popen[bytes], port: int) -> None:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"whisper-server exited with {process.returncode}")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("whisper-server did not become ready")


if __name__ == "__main__":
    main()
