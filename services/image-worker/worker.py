#!/usr/bin/env python3
"""Small authenticated, single-lane HTTP worker for Ternary Bonsai MLX."""

from __future__ import annotations

import hmac
import json
import logging
import os
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from typing import Any


MODEL_ID = "prism-ml/bonsai-image-ternary-4B-mlx-2bit"
MODEL_VARIANT = "ternary-mlx"
STEPS = 4
MAX_REQUEST_BYTES = 16 * 1024
MAX_PROMPT_CHARACTERS = 8_000

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("wheatley-image-worker")


class Worker:
    def __init__(self) -> None:
        demo_root = required_directory("BONSAI_DEMO_ROOT")
        model_root = demo_root / "models" / "bonsai-image-4B-ternary-mlx"
        if not model_root.is_dir():
            raise RuntimeError(f"Bonsai model directory is missing: {model_root}")

        from backend.pipeline import FluxPipeline, PipelineConfig

        started = time.perf_counter()
        log.info("loading %s from %s", MODEL_ID, model_root)
        self.pipeline = FluxPipeline(PipelineConfig(
            backend="bonsai-ternary-mlx",
            baked_model_path=str(model_root),
            te_4bit=True,
            evict_text_encoder=True,
        ))
        self.loaded_seconds = time.perf_counter() - started
        self.generation_lane = threading.Lock()
        queue_size = required_integer("WHEATLEY_IMAGE_QUEUE_SIZE", default=2, minimum=0, maximum=16)
        self.capacity = threading.BoundedSemaphore(1 + queue_size)
        self.busy = False
        self.state_lock = threading.Lock()
        log.info("model ready in %.2fs", self.loaded_seconds)

    def health(self) -> dict[str, Any]:
        with self.state_lock:
            busy = self.busy
        return {
            "ok": True,
            "ready": True,
            "busy": busy,
            "model": MODEL_ID,
            "variant": MODEL_VARIANT,
            "steps": STEPS,
            "loaded_seconds": round(self.loaded_seconds, 3),
        }

    def generate(self, request: dict[str, Any]) -> bytes:
        if not self.capacity.acquire(blocking=False):
            raise BusyError("Image worker queue is full")
        try:
            with self.generation_lane:
                with self.state_lock:
                    self.busy = True
                try:
                    started = time.perf_counter()
                    png = self.pipeline.generate_png(
                        prompt=request["prompt"],
                        seed=request["seed"],
                        steps=STEPS,
                        height=request["height"],
                        width=request["width"],
                    )
                    if not isinstance(png, bytes) or not png.startswith(b"\x89PNG\r\n\x1a\n"):
                        raise RuntimeError("Bonsai pipeline returned invalid PNG data")
                    if png_dimensions(png) != (request["width"], request["height"]):
                        raise RuntimeError("Bonsai pipeline returned unexpected PNG dimensions")
                    log.info(
                        "generated request=%s size=%sx%s seed=%s bytes=%s seconds=%.3f",
                        request["request_id"],
                        request["width"],
                        request["height"],
                        request["seed"],
                        len(png),
                        time.perf_counter() - started,
                    )
                    return png
                finally:
                    with self.state_lock:
                        self.busy = False
        finally:
            self.capacity.release()


class BusyError(Exception):
    pass


class Handler(BaseHTTPRequestHandler):
    server: "ImageServer"

    def do_GET(self) -> None:
        if not self._authorized():
            return
        if self.path != "/health":
            self._json_error(HTTPStatus.NOT_FOUND, "Not found")
            return
        self._json(HTTPStatus.OK, self.server.worker.health())

    def do_POST(self) -> None:
        if not self._authorized():
            return
        if self.path != "/v1/generate":
            self._json_error(HTTPStatus.NOT_FOUND, "Not found")
            return
        try:
            request = self._read_generate_request()
            png = self.server.worker.generate(request)
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(png)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(png)
            except (BrokenPipeError, ConnectionResetError):
                log.warning("client disconnected after generation request=%s", request["request_id"])
        except BusyError as error:
            self._json_error(HTTPStatus.TOO_MANY_REQUESTS, str(error))
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            self._json_error(HTTPStatus.BAD_REQUEST, str(error))
        except Exception:
            log.exception("generation failed")
            self._json_error(HTTPStatus.INTERNAL_SERVER_ERROR, "Image generation failed")

    def log_message(self, format: str, *args: object) -> None:
        log.info("%s - %s", self.address_string(), format % args)

    def _authorized(self) -> bool:
        expected = f"Bearer {self.server.token}"
        supplied = self.headers.get("Authorization", "")
        if hmac.compare_digest(supplied, expected):
            return True
        self._json_error(HTTPStatus.UNAUTHORIZED, "Unauthorized")
        return False

    def _read_generate_request(self) -> dict[str, Any]:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ValueError("Content-Length is required")
        length = int(raw_length)
        if length <= 0 or length > MAX_REQUEST_BYTES:
            raise ValueError("Request body size is invalid")
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip()
        if content_type != "application/json":
            raise ValueError("Content-Type must be application/json")
        value = json.loads(self.rfile.read(length))
        if not isinstance(value, dict):
            raise TypeError("Request body must be an object")
        required = {"request_id", "prompt", "width", "height", "seed"}
        if set(value) != required:
            raise ValueError("Request must contain exactly request_id, prompt, width, height, and seed")
        request_id = required_text(value, "request_id", 128)
        prompt = required_text(value, "prompt", MAX_PROMPT_CHARACTERS)
        width = required_dimension(value, "width")
        height = required_dimension(value, "height")
        seed = required_int(value, "seed", 0, 2_147_483_647)
        return {
            "request_id": request_id,
            "prompt": prompt,
            "width": width,
            "height": height,
            "seed": seed,
        }

    def _json(self, status: HTTPStatus, value: dict[str, Any]) -> None:
        body = (json.dumps(value, separators=(",", ":")) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json_error(self, status: HTTPStatus, message: str) -> None:
        self._json(status, {"ok": False, "error": message})


class ImageServer(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self) -> None:
        # HTTPServer performs a reverse-DNS lookup during bind. That can stall a
        # headless Mac even though the service does not use its hostname.
        TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port

    def __init__(self, address: tuple[str, int], worker: Worker, token: str) -> None:
        super().__init__(address, Handler)
        self.worker = worker
        self.token = token


def required_directory(name: str) -> Path:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required")
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise RuntimeError(f"{name} is not a directory: {path}")
    return path


def required_text(value: dict[str, Any], name: str, maximum: int) -> str:
    text = value[name]
    if not isinstance(text, str) or not text.strip():
        raise TypeError(f"{name} must be nonempty text")
    if len(text) > maximum:
        raise ValueError(f"{name} is too long")
    return text.strip()


def required_int(value: dict[str, Any], name: str, minimum: int, maximum: int) -> int:
    number = value[name]
    if isinstance(number, bool) or not isinstance(number, int):
        raise TypeError(f"{name} must be an integer")
    if number < minimum or number > maximum:
        raise ValueError(f"{name} is out of range")
    return number


def required_dimension(value: dict[str, Any], name: str) -> int:
    number = required_int(value, name, 256, 2_048)
    if number % 16:
        raise ValueError(f"{name} must be a multiple of 16")
    return number


def png_dimensions(png: bytes) -> tuple[int, int]:
    if len(png) < 24 or png[12:16] != b"IHDR":
        raise RuntimeError("Bonsai pipeline returned a PNG without IHDR")
    return int.from_bytes(png[16:20], "big"), int.from_bytes(png[20:24], "big")


def required_integer(name: str, *, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as error:
        raise RuntimeError(f"{name} must be an integer") from error
    if value < minimum or value > maximum:
        raise RuntimeError(f"{name} is out of range")
    return value


def main() -> None:
    token = os.environ.get("WHEATLEY_IMAGE_API_TOKEN", "").strip()
    if len(token) < 32:
        raise RuntimeError("WHEATLEY_IMAGE_API_TOKEN must contain at least 32 characters")
    host = os.environ.get("WHEATLEY_IMAGE_LISTEN_HOST", "0.0.0.0")
    port = required_integer("WHEATLEY_IMAGE_PORT", default=8790, minimum=1, maximum=65_535)
    worker = Worker()
    server = ImageServer((host, port), worker, token)
    log.info("listening on http://%s:%s", host, port)
    server.serve_forever()


if __name__ == "__main__":
    main()
