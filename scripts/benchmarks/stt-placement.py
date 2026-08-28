#!/usr/bin/env python3
"""Compare Wheatley's exact preview and final STT workloads locally and remotely."""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import statistics
import tempfile
import time
from pathlib import Path
from types import ModuleType


def main() -> None:
    args = parse_args()
    segmented = load_module(args.repo_root / "scripts/benchmarks/segmented-draft.py", "segmented_draft")
    final_reuse = load_module(
        args.repo_root / "scripts/benchmarks/final-model-draft-reuse.py", "final_model_draft_reuse"
    )
    candidates = segmented.candidates_from_profiles(args.profiles_root)
    preview_samples = segmented.select_samples(candidates)
    final_samples = final_reuse.select_samples(final_reuse.candidates_from_profiles(args.profiles_root))
    if not preview_samples or not final_samples:
        raise RuntimeError("No suitable historical Wheatley voice samples were found")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="wheatley-stt-placement-") as temp_text:
        temp = Path(temp_text)
        (temp / "preview").mkdir()
        prepared = segmented.prepare_samples(preview_samples, args.ffmpeg, temp / "preview")
        preview = benchmark_preview(segmented, prepared, args.whisper_server, args.preview_model,
                                    args.remote_preview)
        final = benchmark_final(segmented, final_reuse, final_samples, args.ffmpeg, temp / "final",
                                args.whisper_server, args.final_model, args.remote_final)

    payload = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "local_machine": machine_description(),
        "remote_preview": args.remote_preview,
        "remote_final": args.remote_final,
        "preview": preview,
        "final": final,
    }
    args.output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"preview": preview["comparison"], "final": final["comparison"]}, indent=2))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--profiles-root", type=Path, required=True)
    parser.add_argument("--whisper-server", type=Path, required=True)
    parser.add_argument("--preview-model", type=Path, required=True)
    parser.add_argument("--final-model", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--remote-preview", required=True)
    parser.add_argument("--remote-final", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def benchmark_preview(
    module: ModuleType,
    samples: list[dict[str, object]],
    server: Path,
    model: Path,
    remote: str,
) -> dict[str, object]:
    reference = {"timed_text": []}
    rows = []
    with module.whisper_server(server, model) as local:
        warm = module.wav_bytes(samples[0]["frames"][: 16_000 * 2])
        module.transcribe(warm, local, "en", 1, -1, False, "")
        module.transcribe(warm, remote, "en", 1, -1, False, "")
        for index, sample in enumerate(samples):
            if index % 2:
                remote_result = module.replay_segmented(sample, reference, remote)
                local_result = module.replay_segmented(sample, reference, local)
                order = ["remote", "local"]
            else:
                local_result = module.replay_segmented(sample, reference, local)
                remote_result = module.replay_segmented(sample, reference, remote)
                order = ["local", "remote"]
            rows.append({
                "sample": sample["sample"],
                "audio_seconds": sample["duration_seconds"],
                "order": order,
                "local": compact_preview(local_result),
                "remote": compact_preview(remote_result),
                "normalized_transcript_equal": normalize(local_result["latest"]) == normalize(remote_result["latest"]),
            })
            print(f"preview sample {index + 1}/{len(samples)}", flush=True)
    local_runs = [run for row in rows for run in row["local"]["runs"]]
    remote_runs = [run for row in rows for run in row["remote"]["runs"]]
    return {
        "method": "historical segmented preview replay; same PCM windows and small-model settings",
        "samples": rows,
        "local": run_summary(local_runs),
        "remote": run_summary(remote_runs),
        "comparison": compare(run_summary(local_runs), run_summary(remote_runs), rows),
    }


def benchmark_final(
    segmented: ModuleType,
    final_reuse: ModuleType,
    samples: list[dict[str, object]],
    ffmpeg: Path,
    root: Path,
    server: Path,
    model: Path,
    remote: str,
) -> dict[str, object]:
    root.mkdir(parents=True, exist_ok=True)
    wavs = []
    for index, sample in enumerate(samples, start=1):
        wav = root / f"{index}.wav"
        final_reuse.convert(ffmpeg, Path(sample["audio"]), wav, None)
        wavs.append((sample, wav))
    rows = []
    with segmented.whisper_server(server, model) as local:
        warm = wavs[0][1].read_bytes()
        segmented.transcribe(warm, local, "en", 3, 0, False, "")
        segmented.transcribe(warm, remote, "en", 3, 0, False, "")
        for index, (sample, wav) in enumerate(wavs):
            audio = wav.read_bytes()
            if index % 2:
                remote_result = segmented.transcribe(audio, remote, "en", 3, 0, False, "")
                local_result = segmented.transcribe(audio, local, "en", 3, 0, False, "")
                order = ["remote", "local"]
            else:
                local_result = segmented.transcribe(audio, local, "en", 3, 0, False, "")
                remote_result = segmented.transcribe(audio, remote, "en", 3, 0, False, "")
                order = ["local", "remote"]
            rows.append({
                "sample": index + 1,
                "audio_seconds": sample["duration_seconds"],
                "order": order,
                "local": local_result,
                "remote": remote_result,
                "normalized_transcript_equal": normalize(local_result["text"]) == normalize(remote_result["text"]),
            })
            print(f"final sample {index + 1}/{len(wavs)}", flush=True)
    local_summary = duration_summary([int(row["local"]["inference_ms"]) for row in rows])
    remote_summary = duration_summary([int(row["remote"]["inference_ms"]) for row in rows])
    return {
        "method": "full historical utterances; same PCM and large-v3 settings",
        "samples": rows,
        "local": local_summary,
        "remote": remote_summary,
        "comparison": compare(local_summary, remote_summary, rows),
    }


def compact_preview(result: dict[str, object]) -> dict[str, object]:
    return {"runs": result["runs"], "latest": result["latest"], "split_count": len(result["splits"])}


def run_summary(runs: list[dict[str, object]]) -> dict[str, object]:
    result = duration_summary([int(run["inference_ms"]) for run in runs])
    result["input_audio_seconds"] = round(sum(float(run["window_seconds"]) for run in runs), 3)
    return result


def duration_summary(values: list[int]) -> dict[str, object]:
    ordered = sorted(values)
    return {
        "count": len(values),
        "total_ms": sum(values),
        "mean_ms": round(statistics.mean(values), 1),
        "median_ms": round(statistics.median(values), 1),
        "p95_ms": ordered[max(0, math.ceil(len(ordered) * .95) - 1)],
        "min_ms": min(values),
        "max_ms": max(values),
    }


def compare(local: dict[str, object], remote: dict[str, object], rows: list[dict[str, object]]) -> dict[str, object]:
    local_mean = float(local["mean_ms"])
    remote_mean = float(remote["mean_ms"])
    return {
        "remote_minus_local_mean_ms": round(remote_mean - local_mean, 1),
        "remote_speedup_percent": round((local_mean - remote_mean) / local_mean * 100, 1),
        "all_normalized_transcripts_equal": all(bool(row["normalized_transcript_equal"]) for row in rows),
    }


def normalize(text: object) -> str:
    return " ".join(str(text).casefold().split())


def load_module(path: Path, name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load benchmark module: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def machine_description() -> str:
    import subprocess
    return subprocess.check_output(["uname", "-a"], text=True).strip()


if __name__ == "__main__":
    main()
