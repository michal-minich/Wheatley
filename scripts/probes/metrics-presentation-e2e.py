#!/usr/bin/env python3
"""Exercise turn metrics and block durations through the real Wheatley clients."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import time
import urllib.request


ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--output-root", type=Path, default=Path("output/metrics-e2e"))
    parser.add_argument("--serve", action="store_true",
                        help="Keep the isolated server running for browser inspection.")
    args = parser.parse_args()
    repo = args.repo_root.resolve()
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = (repo / args.output_root / run_id).resolve()
    run.mkdir(parents=True)
    profile_id = "metrics-e2e"
    profiles = run / "profiles"
    profile = profiles / profile_id
    profile.mkdir(parents=True)
    (profile / "files").mkdir()
    for name in ("system.md", "user.md"):
        shutil.copyfile(repo / "examples/profiles/wheatley" / name, profile / name)
    shutil.copyfile(repo / "examples/profiles/wheatley/config.json", profile / "config.json")
    (profile / "memory.md").write_text("\n")
    (profile / "memory_auto.md").write_text("# Metrics E2E memory\n")

    config = json.loads((repo / "app-data/resources/config.default.json").read_text())
    config["pi"]["command"] = str(repo / "scripts/probes/fake-pi-rpc.py")
    config["session"]["prompt_prewarm_enabled"] = False
    config["memory"]["auto_enabled"] = False
    config["tools"]["available"]["generate_image"] = False
    config["clients"]["web"]["last_used_profile_id"] = profile_id
    config["profiles"] = {profile_id: {
        "thinking_music_index": 0,
        "accent": "sky",
        "auto_speak": False,
        "play_music": False,
        "keep_microphone_on": False,
        "reasoning_mode": "low",
        "activity_pane_open": True,
        "show_thinking": True,
        "show_compacted_context": False,
        "language": "en",
        "model": "lmstudio/unsloth/qwen3.8-27b",
    }}
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
            "codex_socket": str(run / "codex-worker.sock"),
            "cors_origin": "http://127.0.0.1:5189" if args.serve else "",
            "deployment": {"composition": "standalone_local"},
            "conversation": {"placement": "local", "remote_api_base": ""},
            "sync": {"upstream_api_base": "", "interval_seconds": 30},
        },
        "web": {"open_browser": False},
        "console": {
            "command": "chat",
            "profile": profile_id,
            "device_id": "console-metrics-e2e",
            "language": "en",
            "load_memory": False,
            "speak": False,
            "speech_interrupt": False,
            "speech_interrupt_phrases": ["stop speaking", "stop"],
            "turns": 0,
            "audio_input": "",
            "tts_playback_command": "",
            "audio": {
                "format": "opus", "bitrate": 32000, "frame_ms": 20,
                "application": "audio", "complexity": 3, "container": "ogg-opus",
                "simulate_upload_kbps": 0,
            },
            "client_tools": {"once": False, "dry_run": False, "poll_ms": 500,
                             "idle_timeout_seconds": 0},
        },
    }
    run_profile_path = run / "run-profile.json"
    run_profile_path.write_text(json.dumps(run_profile, indent=2) + "\n")
    environment = os.environ.copy()
    environment.update({
        "WHEATLEY_FAKE_PI_DELAY_SECONDS": "0.05",
        "WHEATLEY_FAKE_PI_THINKING_PARTS": "2",
        "WHEATLEY_FAKE_PI_THINKING_INTERVAL_SECONDS": "0.05",
        "WHEATLEY_FAKE_PI_TOOL": "1",
        "WHEATLEY_FAKE_PI_TOOL_DELAY_SECONDS": "0.34",
        "WHEATLEY_FAKE_PI_GENERATION_INTERVAL_SECONDS": "0.05",
    })
    server_log = (run / "server.log").open("w")
    server = subprocess.Popen(
        [str(repo / "server/wheatleyd/wheatleyd"), str(run_profile_path)],
        cwd=repo, env=environment, stdout=server_log, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        wait_for_health(port, server)
        session_id = start_session(port, profile_id)
        metadata = {
            "run_root": str(run),
            "port": port,
            "profile_id": profile_id,
            "session_id": session_id,
            "run_profile": str(run_profile_path),
        }
        (run / "runtime.json").write_text(json.dumps(metadata, indent=2) + "\n")
        if args.serve:
            print(json.dumps(metadata), flush=True)
            try:
                while server.poll() is None:
                    time.sleep(0.25)
            except KeyboardInterrupt:
                return 0
            return server.returncode or 0

        completed = subprocess.run(
            [str(repo / "server/wheatleyd/wheatley"), str(run_profile_path)],
            cwd=repo,
            input="METRICS_PRESENTATION_E2E\n\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
        )
        (run / "console.raw.log").write_text(completed.stdout)
        clean = ANSI.sub("", completed.stdout)
        (run / "console.log").write_text(clean)
        checks = {
            "console_exit_zero": completed.returncode == 0,
            "localized_model_context": (
                "metrics-e2e>I'm reading my initializing instructions" in clean
            ),
            "no_space_after_profile_prefix": "metrics-e2e>Synthetic" in clean,
            "thinking_duration": re.search(
                r"metrics-e2e>durable thought 1\. durable thought 2\.\s+"
                r"\d+(?:ms|\.\d+s|s)", clean,
            ) is not None,
            "tool_duration": re.search(
                r"metrics-e2e>I'm searching for `abc`\. \d+(?:ms|\.\d+s|s)", clean,
            ) is not None,
            "response_duration": re.search(
                r"metrics-e2e>Synthetic multi-turn response completed\. \d+(?:ms|\.\d+s|s)",
                clean,
            ) is not None,
            "metrics_line": re.search(
                r"metrics-e2e>Context 42K / 128K \(33%\) · 847 tokens · [0-9.]+ tokens/s · ",
                clean,
            ) is not None,
            "metrics_line_is_gray": re.search(
                r"\x1b\[90mmetrics-e2e>Context 42K / 128K \(33%\) · 847 tokens · "
                r"[0-9.]+ tokens/s · [^\x1b]+\x1b\[0m",
                completed.stdout,
            ) is not None,
        }
        result = {**metadata, "checks": checks, "passed": all(checks.values())}
        (run / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        return 0 if result["passed"] else 1
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGTERM)
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait(timeout=5)
        server_log.close()


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_for_health(port: int, server: subprocess.Popen) -> None:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise RuntimeError(f"Server exited {server.returncode} before health")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=0.3):
                return
        except Exception:
            time.sleep(0.05)
    raise RuntimeError("Server did not become healthy")


def start_session(port: int, profile_id: str) -> str:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/profiles/{profile_id}/startup/stream",
        data=json.dumps({
            "language": "en", "mode": "chat", "resume_session_id": "",
            "model": "lmstudio/unsloth/qwen3.8-27b",
        }).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        name = "message"
        for raw in response:
            line = raw.decode().rstrip("\r\n")
            if line.startswith("event:"):
                name = line[6:].strip()
            elif line.startswith("data:") and name == "done":
                return str(json.loads(line[5:].strip())["session_id"])
    raise RuntimeError("Startup stream ended without a session")


if __name__ == "__main__":
    raise SystemExit(main())
