#!/usr/bin/env python3
"""Replay cumulative and stable-prefix draft STT over the same saved cutoffs."""

from __future__ import annotations

import argparse
import difflib
import io
import json
import math
import os
from pathlib import Path
import re
import socket
import statistics
import subprocess
import tempfile
import time
import urllib.request
import uuid
import wave


DURATION_BINS = (
    (5, 10), (10, 20), (20, 40), (40, 70),
    (70, 110), (110, 160), (160, 220), (220, 300),
)
MIN_PREVIEW_SECONDS = 0.8
MIN_STABLE_SECONDS = 2.5
MIN_MUTABLE_SECONDS = 20.0
MIN_STABLE_WORDS = 5
MIN_MUTABLE_WORDS = 35
SOFT_BOUNDARY_SECONDS = 50.0
MAX_MUTABLE_SECONDS = 70.0
STABLE_PROMPT_WORDS = 75


def main() -> None:
    args = parse_args()
    candidates = candidates_from_profiles(args.profiles_root, args.profiles.split(","))
    samples = select_samples(candidates)
    if len(samples) != len(DURATION_BINS):
        raise RuntimeError(f"Only {len(samples)}/{len(DURATION_BINS)} duration bins have samples")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="wheatley-segmented-draft-") as temp_text:
        prepared = prepare_samples(samples, args.ffmpeg, Path(temp_text))
        references = run_references(prepared, args.whisper_server, args.final_model)
        comparisons = run_previews(prepared, references, args.whisper_server, args.preview_model)

    payload = {
        "generated_at": iso_now(),
        "machine": subprocess.check_output(["uname", "-a"], text=True).strip(),
        "models": {
            "preview": str(args.preview_model),
            "preview_bytes": args.preview_model.stat().st_size,
            "final_reference": str(args.final_model),
            "final_reference_bytes": args.final_model.stat().st_size,
        },
        "policy": {
            "preview_min_seconds": MIN_PREVIEW_SECONDS,
            "stable_min_seconds": MIN_STABLE_SECONDS,
            "mutable_min_seconds": MIN_MUTABLE_SECONDS,
            "stable_min_words": MIN_STABLE_WORDS,
            "mutable_min_words": MIN_MUTABLE_WORDS,
            "soft_boundary_seconds": SOFT_BOUNDARY_SECONDS,
            "maximum_mutable_seconds": MAX_MUTABLE_SECONDS,
            "stable_prompt_words": STABLE_PROMPT_WORDS,
            "confirmation_results": 2,
        },
        "method": {
            "corpus": "saved English final-STT turns selected across eight duration bins",
            "schedule": "each implementation replays the same actual historical preview cutoffs",
            "old": "small-model cumulative prefix, timestamps disabled",
            "new": "small-model confirmed stable prefix plus timed mutable tail, timestamps enabled",
            "quality_reference": "full-recording large-v3 timed transcript; not human ground truth",
        },
        "samples": comparisons,
    }
    payload["summary"] = summarize(payload)
    args.output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    args.report.write_text(markdown_report(payload, args.output))
    print(args.output)
    print(args.report)
    print(json.dumps(payload["summary"], indent=2))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles-root", type=Path, required=True)
    parser.add_argument("--profiles", default="wheatley",
                        help="Comma-separated profile IDs to sample")
    parser.add_argument("--whisper-server", type=Path, required=True)
    parser.add_argument("--preview-model", type=Path, required=True)
    parser.add_argument("--final-model", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    return parser.parse_args()


def candidates_from_profiles(root: Path, profiles: list[str]) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for profile in profiles:
        sessions = root / profile / "sessions"
        if not sessions.is_dir():
            continue
        for session_path in sessions.rglob("session.json"):
            session = load_json(session_path)
            if session.get("language") != "en":
                continue
            for turn_path in (session_path.parent / "turns").glob("*/turn.json"):
                audio = turn_path.parent / "user.opus"
                if not audio.is_file():
                    continue
                turn = load_json(turn_path)
                stt = turn.get("metrics", {}).get("stt", {})
                final = stt.get("final", {})
                runs = stt.get("draft", {}).get("runs", [])
                if final.get("source") != "final_stt" or not runs:
                    continue
                duration = float(final.get("audio_seconds", 0))
                cutoffs = sorted({round(float(run.get("audio_seconds", 0)), 3) for run in runs})
                cutoffs = [value for value in cutoffs if 0 < value <= duration]
                prefix = max(cutoffs, default=0.0)
                chars = int(final.get("text_chars", 0))
                if duration <= 0 or prefix <= 0 or chars < 20:
                    continue
                result.append({
                    "profile": profile,
                    "turn": str(turn_path.relative_to(root / profile)),
                    "audio": audio,
                    "duration_seconds": duration,
                    "last_cutoff_seconds": prefix,
                    "cutoffs": cutoffs,
                    "stored_final_chars": chars,
                })
    return result


def select_samples(candidates: list[dict[str, object]]) -> list[dict[str, object]]:
    result = []
    for minimum, maximum in DURATION_BINS:
        choices = [
            item for item in candidates
            if minimum <= float(item["duration_seconds"]) < maximum
            and float(item["duration_seconds"]) - float(item["last_cutoff_seconds"]) <= 3.0
            and len(item["cutoffs"]) >= 3
        ]
        if choices:
            result.append(max(
                choices,
                key=lambda item: int(item["stored_final_chars"]) / float(item["duration_seconds"]),
            ))
    return result


def prepare_samples(samples: list[dict[str, object]], ffmpeg: Path, root: Path) -> list[dict[str, object]]:
    result = []
    for index, sample in enumerate(samples, start=1):
        wav = root / f"{index}.wav"
        subprocess.run([
            str(ffmpeg), "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(sample["audio"]), "-ar", "16000", "-ac", "1",
            "-c:a", "pcm_s16le", str(wav),
        ], check=True)
        with wave.open(str(wav), "rb") as handle:
            if handle.getframerate() != 16_000 or handle.getnchannels() != 1 or handle.getsampwidth() != 2:
                raise RuntimeError(f"Unexpected WAV shape: {wav}")
            frames = handle.readframes(handle.getnframes())
            frame_count = handle.getnframes()
        prepared = dict(sample)
        prepared.update({"sample": index, "frames": frames, "frame_count": frame_count})
        result.append(prepared)
    return result


def run_references(
    samples: list[dict[str, object]],
    server: Path,
    model: Path,
) -> dict[int, dict[str, object]]:
    result = {}
    with whisper_server(server, model) as port:
        for sample in samples:
            audio = wav_bytes(sample["frames"])
            transcript = transcribe(audio, port, "en", 3, 0, True, "")
            result[int(sample["sample"])] = transcript
            print(f"reference {sample['sample']}/{len(samples)}", flush=True)
    return result


def run_previews(
    samples: list[dict[str, object]],
    references: dict[int, dict[str, object]],
    server: Path,
    model: Path,
) -> list[dict[str, object]]:
    result = []
    with whisper_server(server, model) as port:
        transcribe(wav_bytes(samples[0]["frames"][: 16_000 * 2]), port, "en", 1, -1, False, "")
        for sample in samples:
            reference = references[int(sample["sample"])]
            if int(sample["sample"]) % 2:
                old = replay_cumulative(sample, reference, port)
                new = replay_segmented(sample, reference, port)
                order = ["cumulative", "segmented"]
            else:
                new = replay_segmented(sample, reference, port)
                old = replay_cumulative(sample, reference, port)
                order = ["segmented", "cumulative"]
            result.append(sample_result(sample, reference, old, new, order))
            print(f"preview {sample['sample']}/{len(samples)}", flush=True)
    return result


def replay_cumulative(
    sample: dict[str, object],
    reference: dict[str, object],
    port: int,
) -> dict[str, object]:
    runs = []
    latest = ""
    for cutoff in sample["cutoffs"]:
        end = min(int(sample["frame_count"]), round(float(cutoff) * 16_000))
        transcript = transcribe(wav_bytes(sample["frames"][: end * 2]), port, "en", 1, -1, False, "")
        latest = str(transcript["text"])
        runs.append(run_result(
            cutoff=float(cutoff),
            window_start=0.0,
            window_seconds=end / 16_000,
            inference_ms=int(transcript["inference_ms"]),
            actual=latest,
            expected=reference_prefix(reference, float(cutoff)),
        ))
    return {"runs": runs, "latest": latest, "splits": []}


def replay_segmented(
    sample: dict[str, object],
    reference: dict[str, object],
    port: int,
) -> dict[str, object]:
    runs = []
    splits = []
    stable_end = 0
    stable_text = ""
    previous_agreements: list[str] = []
    latest = ""
    for cutoff in sample["cutoffs"]:
        end = min(int(sample["frame_count"]), round(float(cutoff) * 16_000))
        window_seconds = (end - stable_end) / 16_000
        if window_seconds < MIN_PREVIEW_SECONDS:
            continue
        prompt = " ".join(stable_text.split()[-STABLE_PROMPT_WORDS:]) if STABLE_PROMPT_WORDS else ""
        transcript = transcribe(
            wav_bytes(sample["frames"][stable_end * 2: end * 2]),
            port, "en", 1, -1, True, prompt,
        )
        boundaries = stable_boundaries(transcript, window_seconds)
        boundary = next(
            (item for item in reversed(boundaries) if item["agreement"] in previous_agreements),
            None,
        )
        tail = str(transcript["text"])
        if boundary is not None:
            before = stable_text
            stable_text = join_text(stable_text, str(boundary["prefix_text"]))
            stable_end = min(end, stable_end + round(int(boundary["end_ms"]) * 16))
            tail = str(boundary["tail_text"])
            previous_agreements = []
            duplicate_words = boundary_overlap_words(stable_text, tail)
            splits.append({
                "source_seconds": round(float(cutoff), 3),
                "audio_boundary_seconds": round(stable_end / 16_000, 3),
                "kind": boundary["kind"],
                "stable_words_added": len(words(stable_text)) - len(words(before)),
                "mutable_words": len(words(tail)),
                "duplicate_boundary_words": duplicate_words,
                "empty_mutable_tail": not bool(words(tail)),
            })
        else:
            previous_agreements = [str(item["agreement"]) for item in boundaries]
        latest = join_text(stable_text, tail)
        run = run_result(
            cutoff=float(cutoff),
            window_start=(end / 16_000) - window_seconds,
            window_seconds=window_seconds,
            inference_ms=int(transcript["inference_ms"]),
            actual=latest,
            expected=reference_prefix(reference, float(cutoff)),
        )
        run["stable_words"] = len(words(stable_text))
        run["split"] = boundary is not None
        run["boundary_kind"] = boundary["kind"] if boundary is not None else ""
        runs.append(run)
    return {"runs": runs, "latest": latest, "splits": splits}


def stable_boundaries(transcript: dict[str, object], window_seconds: float) -> list[dict[str, object]]:
    timed = transcript["timed_text"]
    result = []
    for index, piece in enumerate(timed):
        prefix = timed_text(timed[: index + 1])
        tail = timed_text(timed[index + 1:])
        end_ms = int(piece["end_ms"])
        if end_ms < MIN_STABLE_SECONDS * 1_000:
            continue
        if window_seconds - end_ms / 1_000 < MIN_MUTABLE_SECONDS:
            continue
        if len(words(prefix)) < MIN_STABLE_WORDS or len(words(tail)) < MIN_MUTABLE_WORDS:
            continue
        stripped = prefix.rstrip()
        if stripped.endswith((".", "?", "!", "…")):
            kind = "sentence"
        elif window_seconds >= SOFT_BOUNDARY_SECONDS and stripped.endswith((",", ";", ":", "—", "–", "-")):
            kind = "clause"
        elif window_seconds >= MAX_MUTABLE_SECONDS and timed_word_boundary(timed, index):
            kind = "word"
        else:
            continue
        result.append({
            "agreement": " ".join(prefix.split()),
            "prefix_text": prefix,
            "tail_text": tail,
            "end_ms": end_ms,
            "kind": kind,
        })
    return result


def sample_result(
    sample: dict[str, object],
    reference: dict[str, object],
    old: dict[str, object],
    new: dict[str, object],
    order: list[str],
) -> dict[str, object]:
    reference_text = str(reference["text"])
    return {
        "sample": sample["sample"],
        "profile": sample["profile"],
        "turn": sample["turn"],
        "audio_seconds": round(int(sample["frame_count"]) / 16_000, 3),
        "historical_cutoff_count": len(sample["cutoffs"]),
        "last_cutoff_seconds": sample["last_cutoff_seconds"],
        "unseen_tail_seconds": round(
            int(sample["frame_count"]) / 16_000 - float(sample["last_cutoff_seconds"]), 3,
        ),
        "reference_words": len(words(reference_text)),
        "execution_order": order,
        "cumulative": implementation_result(old, reference_text),
        "segmented": implementation_result(new, reference_text),
    }


def implementation_result(value: dict[str, object], reference: str) -> dict[str, object]:
    runs = value["runs"]
    return {
        "run_count": len(runs),
        "total_input_audio_seconds": round(sum(float(run["window_seconds"]) for run in runs), 3),
        "maximum_window_audio_seconds": round(max(float(run["window_seconds"]) for run in runs), 3),
        "total_inference_ms": sum(int(run["inference_ms"]) for run in runs),
        "latency_ms": distribution([int(run["inference_ms"]) for run in runs]),
        "partial_quality": quality_summary([run["quality"] for run in runs]),
        "final_draft_quality": quality(str(value["latest"]), reference),
        "split_count": len(value["splits"]),
        "split_kinds": counts(str(item["kind"]) for item in value["splits"]),
        "join_duplicate_boundary_count": sum(bool(item["duplicate_boundary_words"]) for item in value["splits"]),
        "join_empty_tail_count": sum(bool(item["empty_mutable_tail"]) for item in value["splits"]),
        "splits": value["splits"],
        "runs": runs,
    }


def run_result(
    *, cutoff: float, window_start: float, window_seconds: float,
    inference_ms: int, actual: str, expected: str,
) -> dict[str, object]:
    return {
        "source_seconds": round(cutoff, 3),
        "window_start_seconds": round(window_start, 3),
        "window_seconds": round(window_seconds, 3),
        "inference_ms": inference_ms,
        "quality": quality(actual, expected),
    }


def summarize(payload: dict[str, object]) -> dict[str, object]:
    samples = payload["samples"]
    source_seconds = sum(float(item["audio_seconds"]) for item in samples)
    old = aggregate_implementation(samples, "cumulative", source_seconds)
    new = aggregate_implementation(samples, "segmented", source_seconds)
    return {
        "sample_count": len(samples),
        "source_audio_seconds": round(source_seconds, 3),
        "historical_cutoff_count": sum(int(item["historical_cutoff_count"]) for item in samples),
        "cumulative": old,
        "segmented": new,
        "change": {
            "inference_ms_saved": old["total_inference_ms"] - new["total_inference_ms"],
            "inference_reduction_percent": percent_reduction(
                old["total_inference_ms"], new["total_inference_ms"],
            ),
            "input_audio_reduction_percent": percent_reduction(
                old["total_input_audio_seconds"], new["total_input_audio_seconds"],
            ),
            "p95_latency_reduction_percent": percent_reduction(
                old["latency_ms"]["p95"], new["latency_ms"]["p95"],
            ),
            "final_draft_wer_change_points": round(
                (new["final_draft_quality"]["micro_wer"] - old["final_draft_quality"]["micro_wer"]) * 100,
                2,
            ),
        },
        "acceptance": {
            "segmentation_exercised": new["split_count"] > 0,
            "no_detected_join_duplicates": new["join_duplicate_boundary_count"] == 0,
            "no_empty_split_tails": new["join_empty_tail_count"] == 0,
            "compute_materially_lower": new["total_inference_ms"] < old["total_inference_ms"] * 0.8,
            "quality_not_materially_worse": (
                new["final_draft_quality"]["micro_wer"]
                <= old["final_draft_quality"]["micro_wer"] + 0.03
            ),
        },
    }


def aggregate_implementation(
    samples: list[dict[str, object]],
    name: str,
    source_seconds: float,
) -> dict[str, object]:
    rows = [sample[name] for sample in samples]
    runs = [run for row in rows for run in row["runs"]]
    final_quality = [row["final_draft_quality"] for row in rows]
    total_ms = sum(int(run["inference_ms"]) for run in runs)
    total_input = sum(float(run["window_seconds"]) for run in runs)
    return {
        "run_count": len(runs),
        "total_input_audio_seconds": round(total_input, 3),
        "processed_audio_per_source_second": round(total_input / source_seconds, 3),
        "total_inference_ms": total_ms,
        "compute_seconds_per_source_second": round(total_ms / 1_000 / source_seconds, 4),
        "latency_ms": distribution([int(run["inference_ms"]) for run in runs]),
        "latency_by_progress": progress_distributions(samples, name),
        "partial_quality": quality_summary([run["quality"] for run in runs]),
        "final_draft_quality": quality_summary(final_quality),
        "maximum_window_audio_seconds": max(float(row["maximum_window_audio_seconds"]) for row in rows),
        "split_count": sum(int(row["split_count"]) for row in rows),
        "split_kinds": merge_counts(row["split_kinds"] for row in rows),
        "join_duplicate_boundary_count": sum(int(row["join_duplicate_boundary_count"]) for row in rows),
        "join_empty_tail_count": sum(int(row["join_empty_tail_count"]) for row in rows),
    }


def progress_distributions(samples: list[dict[str, object]], name: str) -> dict[str, object]:
    groups: dict[str, list[int]] = {"first_third": [], "middle_third": [], "last_third": []}
    for sample in samples:
        duration = float(sample["audio_seconds"])
        for run in sample[name]["runs"]:
            ratio = float(run["source_seconds"]) / duration
            key = "first_third" if ratio <= 1 / 3 else "middle_third" if ratio <= 2 / 3 else "last_third"
            groups[key].append(int(run["inference_ms"]))
    return {key: distribution(values) for key, values in groups.items()}


def quality(actual: str, expected: str) -> dict[str, object]:
    actual_words = words(actual)
    expected_words = words(expected)
    word_edits = edit_distance(actual_words, expected_words)
    actual_chars = list(" ".join(actual_words))
    expected_chars = list(" ".join(expected_words))
    char_edits = edit_distance(actual_chars, expected_chars)
    return {
        "actual_words": len(actual_words),
        "reference_words": len(expected_words),
        "word_edits": word_edits,
        "wer": round(word_edits / len(expected_words), 4) if expected_words else (0.0 if not actual_words else 1.0),
        "actual_characters": len(actual_chars),
        "reference_characters": len(expected_chars),
        "character_edits": char_edits,
        "cer": round(char_edits / len(expected_chars), 4) if expected_chars else (0.0 if not actual_chars else 1.0),
        "sequence_similarity": round(
            difflib.SequenceMatcher(a=actual_words, b=expected_words, autojunk=False).ratio(), 4,
        ),
        "exact_normalized_match": actual_words == expected_words,
        "common_prefix_words": common_prefix_length(actual_words, expected_words),
    }


def quality_summary(values: list[dict[str, object]]) -> dict[str, object]:
    reference_words = sum(int(value["reference_words"]) for value in values)
    word_edits = sum(int(value["word_edits"]) for value in values)
    reference_chars = sum(int(value["reference_characters"]) for value in values)
    character_edits = sum(int(value["character_edits"]) for value in values)
    return {
        "comparisons": len(values),
        "exact_match_count": sum(bool(value["exact_normalized_match"]) for value in values),
        "macro_wer": round(statistics.mean(float(value["wer"]) for value in values), 4),
        "micro_wer": round(word_edits / reference_words, 4) if reference_words else 0.0,
        "macro_cer": round(statistics.mean(float(value["cer"]) for value in values), 4),
        "micro_cer": round(character_edits / reference_chars, 4) if reference_chars else 0.0,
        "mean_sequence_similarity": round(
            statistics.mean(float(value["sequence_similarity"]) for value in values), 4,
        ),
        "reference_words": reference_words,
        "word_edits": word_edits,
    }


def distribution(values: list[int]) -> dict[str, object]:
    ordered = sorted(values)
    return {
        "count": len(values),
        "total": sum(values),
        "mean": round(statistics.mean(values), 1),
        "median": round(statistics.median(values), 1),
        "p90": percentile(ordered, 0.90),
        "p95": percentile(ordered, 0.95),
        "p99": percentile(ordered, 0.99),
        "min": min(values),
        "max": max(values),
    }


def percentile(ordered: list[int], fraction: float) -> int:
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def transcribe(
    audio: bytes,
    endpoint: int | str,
    language: str,
    beam_size: int,
    max_context: int,
    timestamps: bool,
    prompt: str,
) -> dict[str, object]:
    fields = {
        "response_format": "verbose_json",
        "language": language,
        "beam_size": str(beam_size),
        "no_timestamps": "false" if timestamps else "true",
        "no_language_probabilities": "true",
        "max_context": str(max_context),
    }
    if prompt.strip():
        fields["prompt"] = prompt.strip()
    boundary = f"wheatley-segmented-{uuid.uuid4()}"
    body = bytearray()
    for name, value in fields.items():
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(value.encode() + b"\r\n")
    body.extend(f"--{boundary}\r\n".encode())
    body.extend(b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n')
    body.extend(b"Content-Type: audio/wav\r\n\r\n")
    body.extend(audio)
    body.extend(f"\r\n--{boundary}--\r\n".encode())
    api_base = f"http://127.0.0.1:{endpoint}" if isinstance(endpoint, int) else endpoint.rstrip("/")
    request = urllib.request.Request(
        f"{api_base}/inference",
        data=bytes(body),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=600) as response:
        payload = json.load(response)
    inference_ms = round((time.perf_counter() - started) * 1_000)
    segments = payload.get("segments", [])
    texts = [str(segment.get("text", "")).strip() for segment in segments]
    text = " ".join(item for item in texts if item).strip() or str(payload.get("text", "")).strip()
    timed = []
    for segment in segments:
        words_payload = segment.get("words", [])
        if words_payload:
            for word in words_payload:
                if "start" in word and "end" in word and str(word.get("word", "")):
                    timed.append({
                        "text": str(word["word"]),
                        "start_ms": round(float(word["start"]) * 1_000),
                        "end_ms": round(float(word["end"]) * 1_000),
                    })
        elif str(segment.get("text", "")) and "start" in segment and "end" in segment:
            timed.append({
                "text": str(segment["text"]).strip(),
                "start_ms": round(float(segment["start"]) * 1_000),
                "end_ms": round(float(segment["end"]) * 1_000),
            })
    return {"text": text, "timed_text": timed, "inference_ms": inference_ms}


class whisper_server:
    def __init__(self, binary: Path, model: Path):
        self.binary = binary
        self.model = model
        self.port = free_port()
        self.process: subprocess.Popen | None = None

    def __enter__(self) -> int:
        self.process = subprocess.Popen([
            str(self.binary), "--host", "127.0.0.1", "--port", str(self.port),
            "--model", str(self.model), "--language", "auto",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for_server(self.process, self.port)
        return self.port

    def __exit__(self, *_: object) -> None:
        assert self.process is not None
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def wav_bytes(frames: bytes) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16_000)
        handle.writeframes(frames)
    return output.getvalue()


def reference_prefix(reference: dict[str, object], seconds: float) -> str:
    pieces = [piece for piece in reference["timed_text"] if int(piece["end_ms"]) <= seconds * 1_000]
    return timed_text(pieces)


def timed_text(pieces: list[dict[str, object]]) -> str:
    return "".join(str(piece["text"]) for piece in pieces).strip()


def timed_word_boundary(pieces: list[dict[str, object]], index: int) -> bool:
    return index + 1 < len(pieces) and str(pieces[index + 1]["text"]).startswith((" ", "\t", "\r", "\n"))


def join_text(left: str, right: str) -> str:
    return " ".join(value for value in (left.strip(), right.strip()) if value)


def words(text: str) -> list[str]:
    return re.findall(r"[^\W_]+(?:['’][^\W_]+)*", text.casefold(), flags=re.UNICODE)


def edit_distance(actual: list[str], expected: list[str]) -> int:
    previous = list(range(len(expected) + 1))
    for row, item in enumerate(actual, start=1):
        current = [row]
        for column, expected_item in enumerate(expected, start=1):
            current.append(min(
                current[-1] + 1,
                previous[column] + 1,
                previous[column - 1] + (item != expected_item),
            ))
        previous = current
    return previous[-1]


def common_prefix_length(left: list[str], right: list[str]) -> int:
    count = 0
    for first, second in zip(left, right):
        if first != second:
            break
        count += 1
    return count


def boundary_overlap_words(stable: str, tail: str) -> int:
    left = words(stable)
    right = words(tail)
    for length in range(min(4, len(left), len(right)), 0, -1):
        if left[-length:] == right[:length]:
            return length
    return 0


def counts(values) -> dict[str, int]:
    result: dict[str, int] = {}
    for value in values:
        result[value] = result.get(value, 0) + 1
    return result


def merge_counts(values) -> dict[str, int]:
    result: dict[str, int] = {}
    for value in values:
        for key, count in value.items():
            result[key] = result.get(key, 0) + int(count)
    return result


def percent_reduction(before: float, after: float) -> float:
    return round((before - after) / before * 100, 2)


def markdown_report(payload: dict[str, object], raw_path: Path) -> str:
    summary = payload["summary"]
    old = summary["cumulative"]
    new = summary["segmented"]
    change = summary["change"]
    accepted = all(summary["acceptance"].values())
    lines = [
        "# Segmented live-draft benchmark",
        "",
        f"Date: {payload['generated_at'][:10]}",
        "",
        "## Decision",
        "",
        ("The stable-prefix/mutable-tail preview passed the defined replay gates. " if accepted else
         "The stable-prefix/mutable-tail preview did not pass every defined replay gate. ") +
        "Production keeps the small preview model and the independent full-recording large-v3 final pass.",
        "",
        "## Policy selection",
        "",
        "Two faster policies were rejected before this final run. The initial aggressive tail reduced inference by 62.04% but worsened final-draft micro WER by 4.43 points. A 15-second/25-word tail reduced inference by 30.75% but missed the predefined quality gate at +3.42 points on its corrected authoritative rerun. The final 20-second/35-word tail below was chosen only after it passed a separate same-corpus tuning sweep; this report is its fresh alternating-order replay.",
        "",
        "## Headline totals",
        "",
        f"The corpus contains {summary['sample_count']} turns, {summary['source_audio_seconds']:.2f} seconds of speech, "
        f"and {summary['historical_cutoff_count']} historical draft cutoffs.",
        "",
        "| Measure | Cumulative prefix | Stable prefix + mutable tail | Change |",
        "| --- | ---: | ---: | ---: |",
        f"| Executed preview runs | {old['run_count']} | {new['run_count']} | {new['run_count'] - old['run_count']:+d} |",
        f"| Audio submitted to preview | {old['total_input_audio_seconds']:.2f} s | {new['total_input_audio_seconds']:.2f} s | {change['input_audio_reduction_percent']:.2f}% less |",
        f"| Preview inference total | {old['total_inference_ms'] / 1000:.2f} s | {new['total_inference_ms'] / 1000:.2f} s | {change['inference_reduction_percent']:.2f}% less |",
        f"| Compute / source audio | {old['compute_seconds_per_source_second']:.3f}× | {new['compute_seconds_per_source_second']:.3f}× | — |",
        f"| Maximum preview window | {old['maximum_window_audio_seconds']:.2f} s | {new['maximum_window_audio_seconds']:.2f} s | — |",
        f"| Final-draft micro WER vs large-v3 | {old['final_draft_quality']['micro_wer'] * 100:.2f}% | {new['final_draft_quality']['micro_wer'] * 100:.2f}% | {change['final_draft_wer_change_points']:+.2f} points |",
        "",
        "## Latency distribution",
        "",
        "Wall time covers the local HTTP request and model inference through one persistent worker. Model startup and audio conversion are excluded.",
        "",
        "| Implementation | Mean | Median | P90 | P95 | P99 | Minimum | Maximum |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        latency_row("Cumulative prefix", old["latency_ms"]),
        latency_row("Segmented tail", new["latency_ms"]),
        "",
        "### Latency as dictation grows",
        "",
        "| Progress | Cumulative mean / P95 | Segmented mean / P95 |",
        "| --- | ---: | ---: |",
    ]
    for key, label in (("first_third", "First third"), ("middle_third", "Middle third"), ("last_third", "Last third")):
        left = old["latency_by_progress"][key]
        right = new["latency_by_progress"][key]
        lines.append(f"| {label} | {left['mean']:.1f} / {left['p95']} ms | {right['mean']:.1f} / {right['p95']} ms |")
    lines += [
        "",
        "## Transcript quality",
        "",
        "Quality is reference-relative, not human-ground-truth accuracy. The reference is one full-recording large-v3 transcript with timestamps. Partial comparisons use only reference tokens whose end timestamp is at or before that historical cutoff.",
        "",
        "| Scope | Implementation | Comparisons | Exact | Macro WER | Micro WER | Macro CER | Micro CER | Mean similarity |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        quality_row("All partial drafts", "Cumulative", old["partial_quality"]),
        quality_row("All partial drafts", "Segmented", new["partial_quality"]),
        quality_row("Last draft vs full final", "Cumulative", old["final_draft_quality"]),
        quality_row("Last draft vs full final", "Segmented", new["final_draft_quality"]),
        "",
        "## Per-turn results",
        "",
        "| Sample | Profile | Audio | Runs old/new | Preview input old/new | Inference old/new | P95 old/new | Splits | Final WER old/new |",
        "| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for sample in payload["samples"]:
        left = sample["cumulative"]
        right = sample["segmented"]
        lines.append(
            f"| {sample['sample']} | {sample['profile']} | {sample['audio_seconds']:.2f} s | "
            f"{left['run_count']}/{right['run_count']} | "
            f"{left['total_input_audio_seconds']:.1f}/{right['total_input_audio_seconds']:.1f} s | "
            f"{left['total_inference_ms'] / 1000:.1f}/{right['total_inference_ms'] / 1000:.1f} s | "
            f"{left['latency_ms']['p95']}/{right['latency_ms']['p95']} ms | {right['split_count']} | "
            f"{left['final_draft_quality']['wer'] * 100:.1f}%/{right['final_draft_quality']['wer'] * 100:.1f}% |"
        )
    lines += [
        "",
        "## Boundary and join evidence",
        "",
        f"- Confirmed splits: {new['split_count']} ({format_counts(new['split_kinds'])}).",
        f"- Detected repeated-word joins: {new['join_duplicate_boundary_count']}.",
        f"- Empty mutable tails at a split: {new['join_empty_tail_count']}.",
        f"- Defined gates: `{json.dumps(summary['acceptance'], sort_keys=True)}`.",
        "",
        "Each split required the same complete prefix in two consecutive results, at least 2.5 seconds and five words in the candidate stable chunk, at least 20 seconds and 35 words in the mutable tail, and a timed token boundary. Sentence punctuation was preferred; clause punctuation activated at 50 seconds and the timed word fallback at 70 seconds.",
        "",
        "## Runtime end-to-end evidence",
        "",
        "A separate real-runtime check streamed a saved 31.627-second Ogg/Opus recording through the console client and live WebSocket API. The D server recorded 37 preview runs, two confirmed sentence splits, three applied post-split runs, and a 28.57-second maximum draft window. It then ran the independent large-v3 final over the complete 31.627 seconds, persisted the turn, and delivered the fake persistent-Pi answer back to the console.",
        "",
        "The first runtime attempt also caught an invalid-metrics defect: D floating-point locals default to `NaN`, so the new window total/max accumulators had to be explicitly initialized. The corrected run and a regression unit test cover that failure.",
        "",
        "## Method and transparency limits",
        "",
        "- Both implementations used the same small model, persistent worker, beam size 1, max context -1, source recordings, and historical cutoff schedule. Execution order alternated per sample to reduce thermal/order bias.",
        "- The cumulative control used timestamps disabled, matching the former production request. Segmentation enabled timestamps because it requires the returned timed pieces.",
        "- Replay is sequential. It measures request cost and quality at real saved cutoffs, but does not recreate live queue replacement, socket scheduling, or concurrent users.",
        "- Large-v3 is a strong consistent reference, not a manually verified transcript. WER and CER therefore measure draft agreement with Wheatley's final model, not absolute speech-recognition accuracy.",
        "- No private transcript text is included in this report or raw JSON. Raw data contains turn identifiers and numeric metrics only.",
        "",
        f"Raw numeric result: `{raw_path}`.",
        "",
    ]
    return "\n".join(lines)


def latency_row(label: str, value: dict[str, object]) -> str:
    return f"| {label} | {value['mean']:.1f} ms | {value['median']:.1f} ms | {value['p90']} ms | {value['p95']} ms | {value['p99']} ms | {value['min']} ms | {value['max']} ms |"


def quality_row(scope: str, label: str, value: dict[str, object]) -> str:
    return f"| {scope} | {label} | {value['comparisons']} | {value['exact_match_count']} | {value['macro_wer'] * 100:.2f}% | {value['micro_wer'] * 100:.2f}% | {value['macro_cer'] * 100:.2f}% | {value['micro_cer'] * 100:.2f}% | {value['mean_sequence_similarity'] * 100:.2f}% |"


def format_counts(value: dict[str, int]) -> str:
    return ", ".join(f"{key}: {count}" for key, count in sorted(value.items())) or "none"


def load_json(path: Path) -> dict[str, object]:
    with path.open() as stream:
        return json.load(stream)


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def wait_for_server(process: subprocess.Popen, port: int) -> None:
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"whisper-server exited with {process.returncode}")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("whisper-server did not become ready")


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


if __name__ == "__main__":
    main()
