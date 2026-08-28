#!/usr/bin/env python3
"""Exercise segmented live drafts through the real server and console client."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import socket
import subprocess
import time
import urllib.request


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-audio", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--pi-command", type=Path, required=True,
                        help="Executable Pi-compatible test double")
    args = parser.parse_args()

    repo = args.repo_root.resolve()
    source = args.source_audio.resolve()
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = args.output_root.resolve() / run_id
    run.mkdir(parents=True)
    if not source.is_file():
        raise SystemExit(f"Missing source audio: {source}")

    server_binary = repo / "server/wheatleyd/wheatleyd"
    console_binary = repo / "server/wheatleyd/wheatley"
    default_config = repo / "app-data/resources/config.default.json"
    pi_command = args.pi_command.resolve()
    for required in (server_binary, console_binary, default_config, pi_command):
        if not required.exists():
            raise SystemExit(f"Missing required artifact: {required}")

    profiles = run / "runtime/profiles"
    profile = profiles / "segmented-e2e"
    profile.mkdir(parents=True)
    for name in ("system.md", "user.md"):
        shutil.copyfile(repo / "examples/profiles/wheatley" / name, profile / name)
    (profile / "config.json").write_text(json.dumps({
        "audio": {
            "endpoint": {
                "max_wait_seconds": 120,
                "max_utterance_seconds": 180,
            },
            "partial_transcript": {
                "interval_seconds": 0.5,
                "min_audio_seconds": 0.2,
            },
        }
    }, indent=2) + "\n")

    config = json.loads(default_config.read_text())
    config["pi"]["command"] = str(pi_command)
    config_path = run / "config.json"
    config_path.write_text(json.dumps(config, indent=2) + "\n")

    port = free_port()
    run_profile = {
        "version": 1,
        "shared": {
            "api": {"listen_host": "127.0.0.1", "client_host": "127.0.0.1", "port": port},
            "app_data_root": str(repo / "app-data"),
        },
        "server": {
            "config": str(config_path),
            "profiles_root": str(profiles),
            "codex_workspace_root": "",
            "codex_socket": "",
            "cors_origin": "",
        },
        "web": {"open_browser": False},
        "console": {
            "command": "voice",
            "profile": "segmented-e2e",
            "device_id": "console-segmented-e2e",
            "language": "en",
            "load_memory": False,
            "speak": False,
            "speech_interrupt": False,
            "turns": 1,
            "audio_input": f"file:{source}",
            "tts_playback_command": "",
            "audio": {
                "format": "opus",
                "bitrate": 32000,
                "frame_ms": 20,
                "application": "audio",
                "complexity": 3,
                "container": "ogg-opus",
                "simulate_upload_kbps": 0,
            },
            "client_tools": {"once": False, "dry_run": False, "poll_ms": 500, "idle_timeout_seconds": 0},
        },
    }
    run_profile_path = run / "run-profile.json"
    run_profile_path.write_text(json.dumps(run_profile, indent=2) + "\n")

    server_log = run / "server.log"
    console_log = run / "console.log"
    server_handle = server_log.open("w")
    server = subprocess.Popen(
        [str(server_binary), str(run_profile_path)], cwd=repo,
        stdout=server_handle, stderr=subprocess.STDOUT,
    )
    try:
        wait_for_health(port, server)
        started = time.perf_counter()
        with console_log.open("w") as handle:
            completed = subprocess.run(
                [str(console_binary), str(run_profile_path)], cwd=repo,
                stdout=handle, stderr=subprocess.STDOUT, timeout=240,
            )
        console_wall_ms = round((time.perf_counter() - started) * 1000)
        if completed.returncode:
            raise SystemExit(f"Console exited {completed.returncode}; see {console_log}")
    finally:
        stop_process(server)
        server_handle.close()

    turns = sorted(profiles.glob("segmented-e2e/sessions/*/*/*/*/turns/*/turn.json"))
    if len(turns) != 1:
        raise SystemExit(f"Expected one saved turn, found {len(turns)}; see {run}")
    turn_path = turns[0]
    turn = json.loads(turn_path.read_text())
    stt = turn["metrics"]["stt"]
    draft = stt["draft"]
    final = stt["final"]
    runs = draft["runs"]
    applied = [item for item in runs if item.get("applied")]
    stabilized = [item for item in applied if item.get("stabilized")]
    positive_windows = [item for item in applied if float(item.get("window_start_seconds", 0)) > 0]
    stable_counts = [int(item.get("stable_prefix_words", 0)) for item in applied]
    console_text = console_log.read_text(errors="replace")

    checks = {
        "console_exit_zero": completed.returncode == 0,
        "preview_runs_present": len(runs) > 0,
        "segmentation_exercised": int(draft.get("split_count", 0)) > 0,
        "stabilized_run_recorded": bool(stabilized),
        "post_split_window_recorded": bool(positive_windows),
        "stable_prefix_monotonic": stable_counts == sorted(stable_counts),
        "window_below_full_final_audio": float(draft.get("maximum_window_audio_seconds", 0)) < float(final.get("audio_seconds", 0)),
        "full_final_model_used": final.get("source") == "final_stt" and "large-v3" in str(final.get("model", "")),
        "fake_pi_answer_received": "Persistent Whisper backend E2E passed." in console_text,
    }
    result = {
        "run_id": run_id,
        "source_audio": str(source),
        "console_wall_ms": console_wall_ms,
        "turn_json": str(turn_path),
        "draft": {
            "runs": len(runs),
            "applied_runs": len(applied),
            "split_count": draft.get("split_count"),
            "stable_prefix_words": draft.get("stable_prefix_words"),
            "total_window_audio_seconds": draft.get("total_window_audio_seconds"),
            "maximum_window_audio_seconds": draft.get("maximum_window_audio_seconds"),
            "positive_window_start_runs": len(positive_windows),
            "boundary_kinds": sorted({item.get("boundary_kind") for item in stabilized if item.get("boundary_kind")}),
        },
        "final": {
            "source": final.get("source"),
            "model": final.get("model"),
            "audio_seconds": final.get("audio_seconds"),
            "duration_ms": final.get("duration_ms"),
        },
        "checks": checks,
        "passed": all(checks.values()),
    }
    (run / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    (run / "summary.md").write_text(markdown(result))
    if not result["passed"]:
        raise SystemExit(f"E2E checks failed: {json.dumps(checks, sort_keys=True)}; see {run}")
    print(run / "results.json")
    print(run / "summary.md")
    print(json.dumps(result, indent=2))
    return 0


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_for_health(port: int, process: subprocess.Popen) -> None:
    url = f"http://127.0.0.1:{port}/api/health"
    for _ in range(600):
        if process.poll() is not None:
            raise SystemExit(f"Server exited {process.returncode} before becoming healthy")
        try:
            with urllib.request.urlopen(url, timeout=0.25) as response:
                if response.status == 200:
                    return
        except Exception:
            time.sleep(0.1)
    raise SystemExit("Server did not become healthy within 60 seconds")


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def markdown(result: dict) -> str:
    draft = result["draft"]
    final = result["final"]
    return "\n".join([
        "# Segmented draft end-to-end result", "",
        f"- Passed: `{str(result['passed']).lower()}`",
        f"- Source audio: `{result['source_audio']}`",
        f"- Console wall time: `{result['console_wall_ms']} ms`",
        f"- Draft runs/splits: `{draft['runs']}` / `{draft['split_count']}`",
        f"- Draft maximum window: `{draft['maximum_window_audio_seconds']} s`",
        f"- Post-split draft runs: `{draft['positive_window_start_runs']}`",
        f"- Final: `{final['model']}`, `{final['audio_seconds']} s`, `{final['duration_ms']} ms`",
        f"- Saved turn: `{result['turn_json']}`", "",
        "## Checks", "",
        *[f"- `{name}`: `{str(value).lower()}`" for name, value in result["checks"].items()], "",
    ])


if __name__ == "__main__":
    raise SystemExit(main())
