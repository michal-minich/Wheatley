#!/usr/bin/env python3
"""Migrate every Wheatley tools.json sidecar to wheatley.runtime_tools.v1.

Dry-run is the default. --apply writes the canonical sidecar atomically and
keeps the original changed file beside it as tools.legacy.json.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
from typing import Any


SCRIPT_PATH = Path(__file__).resolve()
WHEATLEY_ROOT = SCRIPT_PATH.parents[3]
CURRENT_SCHEMA = "wheatley.runtime_tools.v1"
DEFAULT_REPORT_DIR = WHEATLEY_ROOT / "app-data" / "wheatleyd" / "migration-reports"


def main() -> int:
    args = parse_args()
    profiles_root = args.profiles_root.resolve()
    report_dir = args.report_dir.resolve()
    paths = sorted(profiles_root.glob("*/sessions/**/turns/**/tools.json"))
    plans = [plan(path, profiles_root) for path in paths]
    failures = [item for item in plans if item["status"] == "invalid"]
    if failures:
        raise SystemExit("Migration preflight failed; no files were changed:\n" + "\n".join(
            f"- {item['path']}: {item['error']}" for item in failures
        ))

    changed = [item for item in plans if item["status"] == "migrate"]
    if args.apply:
        collisions = [
            Path(item["absolute_path"]).with_name("tools.legacy.json")
            for item in changed
            if Path(item["absolute_path"]).with_name("tools.legacy.json").exists()
        ]
        if collisions:
            raise SystemExit("Migration preflight found existing provenance files; no files were changed:\n" + "\n".join(
                f"- {path}" for path in collisions
            ))
        for item in changed:
            source = Path(item["absolute_path"])
            legacy = source.with_name("tools.legacy.json")
            atomic_write(legacy, item["original"])
            atomic_write(source, item["canonical"])

    report = {
        "migration": CURRENT_SCHEMA,
        "apply": args.apply,
        "profiles_root": str(profiles_root),
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "files": len(plans),
        "already_current": sum(item["status"] == "current" for item in plans),
        "migrated": len(changed),
        "migrated_legacy_events": sum(item.get("source_schema") == "events" for item in changed),
        "migrated_unversioned_tools": sum(item.get("source_schema") == "tools" for item in changed),
        "changed": [{key: item[key] for key in ("path", "source_schema", "tool_count")} for item in changed],
    }
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-runtime-tools-v1.json")
    atomic_write(report_path, json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({
        "ok": True,
        "apply": args.apply,
        "report_path": str(report_path),
        "files": report["files"],
        "already_current": report["already_current"],
        "migrated": report["migrated"],
        "migrated_legacy_events": report["migrated_legacy_events"],
        "migrated_unversioned_tools": report["migrated_unversioned_tools"],
    }, indent=2, ensure_ascii=False))
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles-root", type=Path, required=True)
    parser.add_argument("--report-dir", type=Path, default=DEFAULT_REPORT_DIR)
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args()


def plan(path: Path, profiles_root: Path) -> dict[str, Any]:
    original = path.read_text(encoding="utf-8")
    relative_path = path.relative_to(profiles_root).as_posix()
    try:
        payload = json.loads(original)
        require_object(payload, "tools sidecar")
        if payload.get("schema") == CURRENT_SCHEMA:
            validate_current(payload)
            return {"status": "current", "path": relative_path, "absolute_path": str(path), "tool_count": len(payload["tools"])}
        if isinstance(payload.get("tools"), list):
            tools = [normalize_unversioned_tool(item, relative_path, index) for index, item in enumerate(payload["tools"])]
            source_schema = "tools"
        elif isinstance(payload.get("events"), list):
            tools = [normalize_legacy_event(item, relative_path, index) for index, item in enumerate(payload["events"])]
            source_schema = "events"
        else:
            raise ValueError("expected a tools or events array")
        canonical = {"schema": CURRENT_SCHEMA, "tools": tools}
        validate_current(canonical)
        return {
            "status": "migrate",
            "path": relative_path,
            "absolute_path": str(path),
            "source_schema": source_schema,
            "tool_count": len(tools),
            "original": original,
            "canonical": json.dumps(canonical, indent=2, ensure_ascii=False) + "\n",
        }
    except (AttributeError, TypeError, ValueError, json.JSONDecodeError) as error:
        return {"status": "invalid", "path": relative_path, "absolute_path": str(path), "error": str(error)}


def normalize_unversioned_tool(item: Any, path: str, index: int) -> dict[str, Any]:
    require_object(item, "tool")
    return canonical_tool(
        item,
        path,
        index,
        item.get("name"),
        item.get("started_at"),
        item.get("args", {}),
        item.get("result", {}),
        item.get("duration_ms", 0),
        item.get("ok"),
        item.get("id"),
        item.get("source"),
    )


def normalize_legacy_event(item: Any, path: str, index: int) -> dict[str, Any]:
    require_object(item, "legacy tool event")
    result = item.get("result", {})
    require_object(result, "legacy tool result")
    return canonical_tool(
        item,
        path,
        index,
        first_string(item.get("tool"), result.get("name")),
        item.get("timestamp"),
        item.get("arguments", {}),
        legacy_result(result),
        milliseconds(item.get("duration_seconds", 0)),
        item.get("ok", result.get("ok")),
        None,
        "legacy_runtime",
    )


def canonical_tool(
    item: dict[str, Any],
    path: str,
    index: int,
    name: Any,
    started_at: Any,
    args: Any,
    result: Any,
    duration_ms: Any,
    ok: Any,
    identifier: Any,
    source: Any,
) -> dict[str, Any]:
    if not isinstance(name, str) or not name:
        raise ValueError("tool name is missing")
    if not isinstance(started_at, str) or not started_at:
        raise ValueError("tool started_at is missing")
    if not isinstance(args, dict):
        args = {"value": args}
    if not isinstance(result, dict):
        result = {"text": json.dumps(result, ensure_ascii=False)}
    if not isinstance(duration_ms, (int, float)) or isinstance(duration_ms, bool):
        raise ValueError("tool duration must be numeric")
    if not isinstance(ok, bool):
        raise ValueError("tool ok is missing")
    return {
        "id": identifier if isinstance(identifier, str) and identifier else f"migration:{path}:{index}",
        "index": item.get("index", item.get("call_index", index)),
        "name": name,
        "source": source if isinstance(source, str) and source else "legacy_runtime",
        "started_at": started_at,
        "duration_ms": round(duration_ms),
        "ok": ok,
        "args": args,
        "result": result,
    }


def legacy_result(result: dict[str, Any]) -> dict[str, Any]:
    content = result.get("content", {})
    if not isinstance(content, dict):
        return {"text": json.dumps(content, ensure_ascii=False)}
    normalized: dict[str, Any] = {}
    text = first_string(content.get("text"), content.get("result_text"), content.get("summary"))
    if text:
        normalized["text"] = text
    for name in ("stdout", "stderr"):
        if isinstance(content.get(name), str) and content[name]:
            normalized[name] = content[name]
    if isinstance(content.get("exit_status"), int) and not isinstance(content["exit_status"], bool):
        normalized["exit_status"] = content["exit_status"]
    if isinstance(content.get("artifacts"), list):
        normalized["artifacts"] = content["artifacts"]
    if content.get("truncated") is True or content.get("result_truncated") is True:
        normalized["truncated"] = True
    if not normalized and content:
        normalized["text"] = json.dumps(content, ensure_ascii=False, sort_keys=True)
    return normalized


def validate_current(payload: Any) -> None:
    require_object(payload, "tools sidecar")
    if payload.get("schema") != CURRENT_SCHEMA:
        raise ValueError(f"expected schema {CURRENT_SCHEMA}")
    tools = payload.get("tools")
    if not isinstance(tools, list):
        raise ValueError("tools must be an array")
    for tool in tools:
        require_object(tool, "tool")
        for name in ("id", "name", "source", "started_at"):
            if not isinstance(tool.get(name), str) or not tool[name]:
                raise ValueError(f"tool {name} must be a non-empty string")
        for name in ("index", "duration_ms"):
            if not isinstance(tool.get(name), int) or isinstance(tool[name], bool):
                raise ValueError(f"tool {name} must be an integer")
        if not isinstance(tool.get("ok"), bool):
            raise ValueError("tool ok must be a bool")
        require_object(tool.get("args"), "tool args")
        require_object(tool.get("result"), "tool result")


def require_object(value: Any, name: str) -> None:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")


def first_string(*values: Any) -> str | None:
    return next((value for value in values if isinstance(value, str) and value), None)


def milliseconds(seconds: Any) -> int:
    if seconds is None:
        return 0
    if not isinstance(seconds, (int, float)) or isinstance(seconds, bool):
        raise ValueError("legacy tool duration_seconds must be numeric")
    return round(seconds * 1_000)


def atomic_write(path: Path, text: str) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


if __name__ == "__main__":
    raise SystemExit(main())
