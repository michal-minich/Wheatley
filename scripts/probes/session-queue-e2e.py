#!/usr/bin/env python3
"""Deterministic SessionQueue E2E across API clients, restart, and console."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from uuid import uuid4


ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--output-root", type=Path, default=Path("output/session-queue-e2e"))
    args = parser.parse_args()

    repo = args.repo_root.resolve()
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = (repo / args.output_root / run_id).resolve()
    run.mkdir(parents=True)
    profile_id = "queue-e2e"
    profiles = run / "profiles"
    write_profile(repo, profiles / profile_id)
    config_path = write_config(repo, run, profile_id)
    port = free_port()
    run_profile = write_run_profile(repo, run, profiles, config_path, profile_id, port)
    trace_path = run / "fake-pi-trace.jsonl"
    server_log = run / "server.log"
    console_log = run / "console.log"
    server = None
    console = None
    results: dict[str, object] = {"run_id": run_id, "run_root": str(run), "checks": {}}
    checks: dict[str, bool] = results["checks"]  # type: ignore[assignment]

    try:
        server = start_server(repo, run_profile, trace_path, server_log)
        wait_for_health(port, server)
        base = f"http://127.0.0.1:{port}/api/profiles/{profile_id}"
        session_id, startup_events = start_session(base)
        results["session_id"] = session_id
        results["startup_events"] = startup_events
        startup_presentation = get_json(
            f"{base}/presentation?session_id={urllib.parse.quote(session_id, safe='')}"
        )
        checks["model_context_bootstrap_event"] = any(
            entry.get("kind") == "bootstrap" and entry.get("item_id") == "model-context"
            for entry in startup_presentation["entries"]
        )

        warmup = unique("resume-anchor")
        warmup_run = start_text(
            base,
            session_id,
            warmup,
            f"QUEUE_E2E_RESUME_ANCHOR {warmup}",
            "browser-a",
        )
        join_run(warmup_run, 30)
        wait_queue_empty(base, session_id, 10)

        think = unique("think-override")
        think_text = f"Think I should inspect this queue {think}"
        think_reservation = {
            "id": think,
            "session_id": session_id,
            "kind": "user",
            "source": "browser_text",
            "device_id": "browser-a",
            "submitted_at": now_iso(),
            "text": "",
            "model": "lmstudio/unsloth/qwen3.8-27b",
            "reasoning_mode": "off",
            "language": "en",
            "artifact_reference": "",
            "preparation_source": "final_transcript",
            "fingerprint": f"e2e:{think}",
            "ready": False,
            "preparation_deadline_at": (
                datetime.now(timezone.utc) + timedelta(minutes=5)
            ).isoformat().replace("+00:00", "Z"),
            "load_memory": False,
        }
        post_json(f"{base}/queue/reserve", think_reservation)
        think_run = start_text(base, session_id, think, think_text, "browser-a")
        join_run(think_run, 30)
        wait_queue_empty(base, session_id, 10)

        after_think = unique("after-think")
        after_think_run = start_text(
            base,
            session_id,
            after_think,
            f"Normal turn after the override {after_think}",
            "browser-a",
        )
        join_run(after_think_run, 30)
        wait_queue_empty(base, session_id, 10)
        checks["prepared_think_is_one_turn_highest_reasoning"] = (
            turn_reasoning_mode(profiles / profile_id, think) == "xhigh"
            and turn_reasoning_mode(profiles / profile_id, after_think) == "off"
            and json.loads(config_path.read_text())["profiles"][profile_id]["reasoning_mode"]
            == "off"
        )

        rejected = unique("rejected-preparation")
        rejected_reservation = dict(think_reservation)
        rejected_reservation.update({
            "id": rejected,
            "submitted_at": now_iso(),
            "model": "lmstudio/ornith-1.5-35b-a3b",
            "fingerprint": f"e2e:{rejected}",
        })
        post_json(f"{base}/queue/reserve", rejected_reservation)
        rejected_run = start_text(
            base,
            session_id,
            rejected,
            f"Rejected prepared policy {rejected}",
            "browser-a",
        )
        join_run(rejected_run, 10)
        after_rejected = unique("after-rejected")
        after_rejected_run = start_text(
            base,
            session_id,
            after_rejected,
            f"Queue continues after rejected admission {after_rejected}",
            "browser-a",
        )
        join_run(after_rejected_run, 30)
        wait_queue_empty(base, session_id, 10)
        checks["rejected_preparation_does_not_block_fifo"] = (
            projected_queue_state(base, session_id, rejected) == "failed"
            and turn_status(profiles / profile_id, after_rejected) == "completed"
        )

        console = start_console(repo, run_profile, console_log)
        console.stdin.write("yes\n")
        console.stdin.flush()
        wait_for_file_text(console_log, "you>", 20)
        checks["console_model_context_before_prompt"] = ordered_text(
            clean_text(console_log), "Model context", "you>"
        )

        first = unique("first")
        second = unique("cancel")
        third = unique("third")
        first_text = f"QUEUE_E2E_FIRST {first}"
        second_text = f"QUEUE_E2E_CANCEL {second}"
        third_text = f"QUEUE_E2E_THIRD {third}"
        first_run = start_text(base, session_id, first, first_text, "browser-a")
        wait_queue_state(base, session_id, first, "running", 10)
        second_run = start_text(base, session_id, second, second_text, "browser-b")
        wait_queue_state(base, session_id, second, "ready", 10)
        third_run = start_text(base, session_id, third, third_text, "browser-a")
        snapshot = wait_queue_items(base, session_id, [first, second, third], 10)
        by_id = {item["id"]: item for item in snapshot["items"]}
        checks["immutable_multi_client_sequence"] = [
            by_id[first]["sequence"], by_id[second]["sequence"], by_id[third]["sequence"]
        ] == sorted([
            by_id[first]["sequence"], by_id[second]["sequence"], by_id[third]["sequence"]
        ])
        cancelled = post_json(f"{base}/queue/{second}/cancel", {"session_id": session_id})
        checks["queued_cancel_confirmed"] = (
            cancelled["changed"] is True and cancelled["item"]["state"] == "cancelled"
        )
        repeated = post_json(f"{base}/queue/{second}/cancel", {"session_id": session_id})
        checks["queued_cancel_idempotent"] = (
            repeated["changed"] is False and repeated["item"]["state"] == "cancelled"
        )
        join_run(first_run, 30)
        join_run(second_run, 30, allow_error=True)
        join_run(third_run, 30)
        wait_queue_empty(base, session_id, 10)
        order = trace_marker_order(trace_path, [first, second, third])
        checks["pi_order_excludes_cancelled"] = order == [first, third]

        fourth = unique("running-cancel")
        fourth_text = f"QUEUE_E2E_RUNNING_CANCEL {fourth}"
        fourth_run = start_text(base, session_id, fourth, fourth_text, "browser-b")
        wait_queue_state(base, session_id, fourth, "running", 10)
        status, _ = request_json(
            f"{base}/queue/{fourth}/cancel", {"session_id": session_id}, expected=None
        )
        checks["running_cancel_rejected"] = status == 409
        join_run(fourth_run, 30)
        wait_queue_empty(base, session_id, 10)

        preparing = unique("preparing")
        ready = unique("ready-after-restart")
        preparing_text = ""
        reservation = {
            "id": preparing,
            "session_id": session_id,
            "kind": "user",
            "source": "voice",
            "device_id": "browser-voice",
            "submitted_at": now_iso(),
            "text": preparing_text,
            "model": "lmstudio/unsloth/qwen3.8-27b",
            "reasoning_mode": "off",
            "language": "en",
            "artifact_reference": "staged:e2e.opus",
            "preparation_source": "final_stt",
            "fingerprint": f"e2e:{preparing}",
            "ready": False,
            "preparation_deadline_at": (
                datetime.now(timezone.utc) + timedelta(minutes=5)
            ).isoformat().replace("+00:00", "Z"),
            "load_memory": False,
        }
        prepared_mutation = post_json(f"{base}/queue/reserve", reservation)
        checks["preparing_reserved_and_projected"] = (
            prepared_mutation["item"]["state"] == "preparing"
        )
        ready_text = f"QUEUE_E2E_READY_AFTER_RESTART {ready}"
        ready_run = start_text(base, session_id, ready, ready_text, "browser-a")
        blocked = wait_queue_items(base, session_id, [preparing, ready], 10)
        blocked_by_id = {item["id"]: item for item in blocked["items"]}
        checks["preparing_blocks_later_ready"] = (
            blocked_by_id[preparing]["state"] == "preparing"
            and blocked_by_id[ready]["state"] == "ready"
            and blocked_by_id[preparing]["sequence"] < blocked_by_id[ready]["sequence"]
        )
        wait_for_file_text(console_log, "Voice message", 10)
        kill_server(server)
        server = start_server(repo, run_profile, trace_path, server_log, append=True)
        wait_for_health(port, server)
        join_run(ready_run, 10, allow_error=True)
        wait_turn_status(profiles / profile_id, ready, "completed", 30)
        wait_queue_empty(base, session_id, 15)
        checks["restart_fails_preparing_and_runs_ready"] = (
            projected_queue_state(base, session_id, preparing) == "failed"
            and turn_status(profiles / profile_id, ready) == "completed"
            and ready in trace_marker_order(trace_path, [ready])
        )
        wait_for_file_text(console_log, "Queued message failed", 15)
        checks["console_observed_preparing_failure"] = preparing_text in clean_text(
            console_log
        ) or "Voice message" in clean_text(console_log)

        running = unique("running-restart")
        running_text = f"QUEUE_E2E_RUNNING_RESTART {running}"
        running_run = start_text(base, session_id, running, running_text, "browser-b")
        wait_queue_state(base, session_id, running, "running", 10)
        wait_for_trace(trace_path, running, 10)
        kill_server(server)
        server = start_server(repo, run_profile, trace_path, server_log, append=True)
        wait_for_health(port, server)
        join_run(running_run, 10, allow_error=True)
        wait_turn_status(profiles / profile_id, running, "failed", 20)
        wait_queue_empty(base, session_id, 15)
        checks["running_restart_interrupted_without_retry"] = (
            projected_queue_state(base, session_id, running) == "interrupted"
            and turn_status(profiles / profile_id, running) == "failed"
            and trace_marker_order(trace_path, [running]).count(running) == 1
        )
        wait_for_file_text(console_log, "Queued message interrupted", 15)
        checks["console_observed_running_interruption"] = running_text in clean_text(
            console_log
        )

        before_restart = queue_hashes(profiles)
        stop_server(server)
        server = start_server(repo, run_profile, trace_path, server_log, append=True)
        wait_for_health(port, server)
        after_restart = queue_hashes(profiles)
        checks["canonical_restart_is_idempotent"] = before_restart == after_restart
        checks["recent_sessions_regression"] = any(
            item["session_id"] == session_id for item in get_json(f"{base}/recent-sessions")
        )
        checks["session_history_loads"] = len(get_json(
            f"{base}/session-turns?session_id={urllib.parse.quote(session_id, safe='')}"
        )) >= 5

        wait_for_file_text(console_log, third_text, 15)
        wait_for_file_text(console_log, "Queued message cancelled", 15)
        console_text = clean_text(console_log)
        checks["console_observed_external_queue"] = all(
            marker in console_text for marker in (first_text, second_text, third_text)
        )
        checks["console_observed_cancel"] = second_text in console_text and (
            "Queued message cancelled" in console_text
        )
        checks["console_reconnected_after_server_restart"] = ready_text in console_text
        checks["daemon_survived_all_scenarios"] = server.poll() is None

        results["trace_order"] = trace_marker_order(
            trace_path, [first, second, third, fourth, ready, running]
        )
        results["queue_hashes_before_restart"] = before_restart
        results["queue_hashes_after_restart"] = after_restart
        results["passed"] = all(checks.values())
        write_results(run, results)
        if not results["passed"]:
            failed = sorted(name for name, passed in checks.items() if not passed)
            raise AssertionError(f"Session queue E2E failed: {failed}; see {run}")
        print(run / "results.json")
        print(json.dumps(results, indent=2))
        return 0
    finally:
        if console is not None:
            stop_console(console)
        if server is not None:
            stop_server(server)
        if "passed" not in results:
            results["passed"] = False
            write_results(run, results)


def write_profile(repo: Path, profile: Path) -> None:
    profile.mkdir(parents=True)
    (profile / "files").mkdir()
    shutil.copyfile(repo / "examples/profiles/wheatley/system.md", profile / "system.md")
    shutil.copyfile(repo / "examples/profiles/wheatley/user.md", profile / "user.md")
    (profile / "memory.md").write_text("\n")
    (profile / "memory_auto.md").write_text("# Queue E2E memory\n")
    shutil.copyfile(repo / "examples/profiles/wheatley/config.json", profile / "config.json")


def write_config(repo: Path, run: Path, profile_id: str) -> Path:
    config = json.loads((repo / "app-data/resources/config.default.json").read_text())
    config["pi"]["command"] = str(repo / "scripts/probes/fake-pi-rpc.py")
    config["session"]["prompt_prewarm_enabled"] = False
    config["memory"]["auto_enabled"] = False
    config["tools"]["available"]["generate_image"] = False
    config["clients"]["web"]["last_used_profile_id"] = profile_id
    config["profiles"] = {
        profile_id: {
            "thinking_music_index": 0,
            "accent": "sky",
            "auto_speak": True,
            "play_music": False,
            "keep_microphone_on": False,
            "reasoning_mode": "off",
            "activity_pane_open": False,
            "show_thinking": True,
            "show_compacted_context": False,
            "language": "en",
            "model": "lmstudio/unsloth/qwen3.8-27b",
        }
    }
    path = run / "config.json"
    path.write_text(json.dumps(config, indent=2) + "\n")
    return path


def write_run_profile(
    repo: Path, run: Path, profiles: Path, config: Path, profile_id: str, port: int
) -> Path:
    value = {
        "version": 1,
        "shared": {
            "api": {"listen_host": "127.0.0.1", "client_host": "127.0.0.1", "port": port},
            "app_data_root": str(repo / "app-data"),
        },
        "server": {
            "config": str(config),
            "profiles_root": str(profiles),
            "codex_workspace_root": "",
            "codex_socket": str(run / "codex-worker.sock"),
            "cors_origin": "",
            "deployment": {"composition": "standalone_local"},
            "conversation": {"placement": "local", "remote_api_base": ""},
            "sync": {"upstream_api_base": "", "interval_seconds": 30},
        },
        "web": {"open_browser": False},
        "console": {
            "command": "chat",
            "profile": profile_id,
            "device_id": "console-queue-e2e",
            "language": "en",
            "load_memory": False,
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
    path = run / "run-profile.json"
    path.write_text(json.dumps(value, indent=2) + "\n")
    return path


def start_server(
    repo: Path, run_profile: Path, trace: Path, log: Path, append: bool = False
) -> subprocess.Popen:
    environment = os.environ.copy()
    environment["WHEATLEY_FAKE_PI_DELAY_SECONDS"] = "1.5"
    environment["WHEATLEY_FAKE_PI_TRACE"] = str(trace)
    handle = log.open("a" if append else "w")
    process = subprocess.Popen(
        [str(repo / "server/wheatleyd/wheatleyd"), str(run_profile)],
        cwd=repo, env=environment, stdout=handle, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    process._queue_e2e_log_handle = handle  # type: ignore[attr-defined]
    return process


def start_console(repo: Path, run_profile: Path, log: Path) -> subprocess.Popen:
    handle = log.open("w")
    process = subprocess.Popen(
        [str(repo / "server/wheatleyd/wheatley"), str(run_profile)],
        cwd=repo, stdin=subprocess.PIPE, stdout=handle, stderr=subprocess.STDOUT,
        text=True, bufsize=1,
    )
    process._queue_e2e_log_handle = handle  # type: ignore[attr-defined]
    return process


def stop_console(process: subprocess.Popen) -> None:
    if process.poll() is None:
        try:
            process.stdin.write("\n")
            process.stdin.flush()
            process.wait(timeout=8)
        except Exception:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    close_process_log(process)


def kill_server(process: subprocess.Popen) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
    close_process_log(process)


def stop_server(process: subprocess.Popen) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
    close_process_log(process)


def close_process_log(process: subprocess.Popen) -> None:
    handle = getattr(process, "_queue_e2e_log_handle", None)
    if handle is not None and not handle.closed:
        handle.close()


def start_session(base: str) -> tuple[str, list[dict[str, str]]]:
    events = request_sse(f"{base}/startup/stream", {
        "language": "en", "mode": "chat", "resume_session_id": "",
        "model": "lmstudio/unsloth/qwen3.8-27b",
    })
    done = next(json.loads(event["data"]) for event in events if event["name"] == "done")
    return done["session_id"], events


def start_text(base: str, session_id: str, submission_id: str, text: str, device: str) -> dict:
    result: dict[str, object] = {"events": []}

    def run() -> None:
        try:
            result["events"] = request_sse(f"{base}/turns/text/stream", {
                "session_id": session_id,
                "text": text,
                "submission_id": submission_id,
                "device_id": device,
                "language": "en",
                "source": "browser_text",
                "load_memory": False,
                "reasoning_mode": "off",
                "model": "lmstudio/unsloth/qwen3.8-27b",
                "after_sequence": 0,
            }, timeout=60)
        except Exception as error:  # expected when a queued request is cancelled or server is killed
            result["error"] = repr(error)

    thread = threading.Thread(target=run, name=f"queue-e2e-{submission_id}", daemon=True)
    result["thread"] = thread
    thread.start()
    return result


def join_run(result: dict, timeout: float, allow_error: bool = False) -> None:
    thread: threading.Thread = result["thread"]  # type: ignore[assignment]
    thread.join(timeout)
    if thread.is_alive():
        raise AssertionError(f"Text request did not finish: {thread.name}")
    if not allow_error and "error" in result:
        raise AssertionError(f"Text request failed: {result['error']}")


def request_sse(url: str, payload: dict, timeout: float = 30) -> list[dict[str, str]]:
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    events: list[dict[str, str]] = []
    with urllib.request.urlopen(request, timeout=timeout) as response:
        name = "message"
        data: list[str] = []
        for raw in response:
            line = raw.decode().rstrip("\r\n")
            if not line:
                if data:
                    events.append({"name": name, "data": "\n".join(data)})
                name, data = "message", []
            elif line.startswith("event:"):
                name = line[6:].strip()
            elif line.startswith("data:"):
                data.append(line[5:].lstrip())
        if data:
            events.append({"name": name, "data": "\n".join(data)})
    return events


def get_json(url: str):
    status, value = request_json(url, None, expected=200)
    assert status == 200
    return value


def post_json(url: str, payload: dict):
    status, value = request_json(url, payload, expected=200)
    assert status == 200
    return value


def request_json(url: str, payload: dict | None, expected: int | None) -> tuple[int, object]:
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"} if data is not None else {},
        method="POST" if data is not None else "GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            status = response.status
            body = response.read().decode()
    except urllib.error.HTTPError as error:
        status = error.code
        body = error.read().decode()
    if expected is not None and status != expected:
        raise AssertionError(f"HTTP {status} from {url}: {body}")
    return status, json.loads(body) if body else {}


def wait_for_health(port: int, process: subprocess.Popen) -> None:
    url = f"http://127.0.0.1:{port}/api/health"
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"Server exited {process.returncode} before health")
        try:
            with urllib.request.urlopen(url, timeout=0.3) as response:
                if response.status == 200:
                    return
        except Exception:
            time.sleep(0.05)
    raise AssertionError("Server did not become healthy")


def queue_snapshot(base: str, session_id: str) -> dict:
    return get_json(f"{base}/queue?session_id={urllib.parse.quote(session_id, safe='')}")


def wait_queue_state(base: str, session_id: str, item_id: str, state: str, timeout: float) -> dict:
    return wait_until(timeout, lambda: next(
        (item for item in queue_snapshot(base, session_id)["items"]
         if item["id"] == item_id and item["state"] == state), None
    ), f"queue item {item_id}={state}")


def wait_queue_items(base: str, session_id: str, item_ids: list[str], timeout: float) -> dict:
    expected = set(item_ids)

    def check():
        snapshot = queue_snapshot(base, session_id)
        return snapshot if expected.issubset({item["id"] for item in snapshot["items"]}) else None

    return wait_until(timeout, check, f"queue items {item_ids}")


def wait_queue_empty(base: str, session_id: str, timeout: float) -> None:
    wait_until(timeout, lambda: not queue_snapshot(base, session_id)["items"], "empty queue")


def projected_queue_state(base: str, session_id: str, item_id: str) -> str:
    presentation = get_json(
        f"{base}/presentation?session_id={urllib.parse.quote(session_id, safe='')}"
    )
    for entry in reversed(presentation["entries"]):
        if entry.get("source") != "queue" or entry.get("item_id") != item_id:
            continue
        payload = entry["payload"]
        if isinstance(payload, str):
            payload = json.loads(payload)
        return payload["item"]["state"]
    return ""


def wait_turn_status(profile: Path, submission_id: str, status: str, timeout: float) -> None:
    wait_until(timeout, lambda: turn_status(profile, submission_id) == status,
               f"turn {submission_id}={status}")


def turn_status(profile: Path, submission_id: str) -> str:
    record = turn_record(profile, submission_id)
    return record.get("status", "") if record else ""


def turn_reasoning_mode(profile: Path, submission_id: str) -> str:
    record = turn_record(profile, submission_id)
    return record.get("reasoning_mode", "") if record else ""


def turn_record(profile: Path, submission_id: str) -> dict:
    for path in profile.glob("sessions/*/*/*/*/turns/*/turn.json"):
        value = json.loads(path.read_text())
        if value.get("submission_id") == submission_id:
            return value
    return {}


def trace_marker_order(path: Path, markers: list[str]) -> list[str]:
    if not path.exists():
        return []
    result: list[str] = []
    for line in path.read_text().splitlines():
        prompt = json.loads(line)["prompt"]
        for marker in markers:
            if marker in prompt:
                result.append(marker)
                break
    return result


def wait_for_trace(path: Path, marker: str, timeout: float) -> None:
    wait_until(timeout, lambda: marker in trace_marker_order(path, [marker]),
               f"Pi receipt {marker}")


def queue_hashes(profiles: Path) -> dict[str, str]:
    return {
        str(path.relative_to(profiles)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(profiles.glob("**/queue.json"))
    }


def wait_until(timeout: float, check, label: str):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = check()
            if value:
                return value
        except Exception as error:
            last_error = error
        time.sleep(0.05)
    raise AssertionError(f"Timed out waiting for {label}; last error: {last_error}")


def wait_for_file_text(path: Path, text: str, timeout: float) -> None:
    wait_until(timeout, lambda: path.exists() and text in clean_text(path), f"{text!r} in {path}")


def clean_text(path: Path) -> str:
    return ANSI.sub("", path.read_text(errors="replace")).replace("\r", "")


def ordered_text(value: str, first: str, second: str) -> bool:
    return first in value and second in value and value.index(first) < value.index(second)


def write_results(run: Path, results: dict) -> None:
    (run / "results.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")


def unique(prefix: str) -> str:
    return f"{prefix}-{uuid4()}"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


if __name__ == "__main__":
    raise SystemExit(main())
