#!/usr/bin/env python3
"""Current Pi RPC double for isolated Wheatley integration probes."""

from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4


def main() -> int:
    if "--version" in sys.argv:
        print("wheatley-probe-pi-rpc 1.0")
        return 0

    for line in sys.stdin:
        request = json.loads(line)
        request_id = request.get("id", "")
        kind = request.get("type", "")
        if kind == "get_available_models":
            emit({
                "id": request_id,
                "type": "response",
                "success": True,
                "data": {"models": [
                    model("ornith-1.5-35b-a3b", "Synthetic Ornith 35B"),
                    model("unsloth/qwen3.8-27b", "Synthetic Qwen3.8 27B"),
                    model("gemma-4-31b-it", "Synthetic Gemma 31B"),
                ]},
            })
            continue
        emit({"id": request_id, "type": "response", "success": True})
        if kind != "prompt":
            continue
        prompt = request.get("message", "")
        trace_prompt(prompt)
        emit({
            "type": "message_start",
            "message": {"role": "user", "content": [{"type": "text", "text": prompt}]},
        })
        emit({
            "type": "message_start",
            "message": {"role": "assistant", "content": []},
        })
        time.sleep(float(os.environ.get("WHEATLEY_FAKE_PI_DELAY_SECONDS", "0.5")))
        thinking_parts = int(os.environ.get("WHEATLEY_FAKE_PI_THINKING_PARTS", "0"))
        thinking_interval = float(
            os.environ.get("WHEATLEY_FAKE_PI_THINKING_INTERVAL_SECONDS", "0.1")
        )
        if thinking_parts > 0:
            emit({
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_start",
                    "contentIndex": 0,
                },
            })
            for index in range(1, thinking_parts + 1):
                emit({
                    "type": "message_update",
                    "assistantMessageEvent": {
                        "type": "thinking_delta",
                        "contentIndex": 0,
                        "delta": f"durable thought {index}. ",
                    },
                })
                time.sleep(thinking_interval)
            emit({
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_end",
                    "contentIndex": 0,
                },
            })
        tool_enabled = os.environ.get("WHEATLEY_FAKE_PI_TOOL", "0") == "1"
        if tool_enabled:
            emit({
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "toolcall_end",
                    "contentIndex": 1 if thinking_parts > 0 else 0,
                    "toolCall": {"id": "fake-call-1"},
                },
            })
            emit(message_end(input_tokens=32768, output_tokens=64))
            emit({
                "type": "tool_execution_start",
                "toolCallId": "fake-call-1",
                "toolName": "web_search",
                "args": {"query": "abc"},
            })
            time.sleep(float(os.environ.get("WHEATLEY_FAKE_PI_TOOL_DELAY_SECONDS", "0.34")))
            emit({
                "type": "tool_execution_end",
                "toolCallId": "fake-call-1",
                "toolName": "web_search",
                "isError": False,
                "result": {"content": [{"type": "text", "text": "Synthetic result."}]},
            })
            emit({
                "type": "message_start",
                "message": {"role": "assistant", "content": []},
            })
        response = "Synthetic multi-turn response completed."
        emit({
            "type": "message_update",
            "assistantMessageEvent": {
                "type": "text_delta",
                "contentIndex": 1 if thinking_parts > 0 else 0,
                "delta": response,
            },
        })
        time.sleep(float(os.environ.get("WHEATLEY_FAKE_PI_GENERATION_INTERVAL_SECONDS", "0.02")))
        emit(message_end(
            input_tokens=43008 if tool_enabled else 32768,
            output_tokens=783 if tool_enabled else 847,
        ))
        emit({
            "type": "agent_end",
            "messages": [{"role": "assistant", "content": response}],
        })
        persist_session_messages(prompt, response)
        emit({"type": "agent_settled"})
    return 0


def trace_prompt(prompt: str) -> None:
    path = os.environ.get("WHEATLEY_FAKE_PI_TRACE", "")
    if not path:
        return
    with Path(path).open("a", encoding="utf-8") as trace:
        trace.write(json.dumps({
            "received_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "pid": os.getpid(),
            "prompt": prompt,
        }, separators=(",", ":")) + "\n")


def model(model_id: str, name: str) -> dict:
    return {
        "provider": "lmstudio",
        "id": model_id,
        "name": name,
        "api": "openai-completions",
        "reasoning": True,
        "thinkingLevelMap": {
            "off": "none",
            "minimal": None,
            "low": "low",
            "medium": "medium",
            "high": None,
            "xhigh": "xhigh",
            "max": None,
        },
        "input": ["text", "image"],
        "contextWindow": 131072,
        "compat": {"maxTokensField": "max_tokens"},
    }


def emit(value: dict) -> None:
    print(json.dumps(value, separators=(",", ":")), flush=True)


def message_end(*, input_tokens: int, output_tokens: int) -> dict:
    return {
        "type": "message_end",
        "message": {
            "role": "assistant",
            "usage": {
                "input": input_tokens,
                "output": output_tokens,
                "cacheRead": 0,
                "cacheWrite": 0,
                "reasoning": 0,
                "totalTokens": input_tokens + output_tokens,
            },
        },
    }


def persist_session_messages(prompt: str, response: str) -> None:
    if "--session" not in sys.argv:
        return
    path = Path(sys.argv[sys.argv.index("--session") + 1])
    timestamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    with path.open("a", encoding="utf-8") as session:
        for role, text in (("user", prompt), ("assistant", response)):
            session.write(json.dumps({
                "type": "message",
                "id": str(uuid4()),
                "parentId": None,
                "timestamp": timestamp,
                "message": {
                    "role": role,
                    "content": [{"type": "text", "text": text}],
                },
            }, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
