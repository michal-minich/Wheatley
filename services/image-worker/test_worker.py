from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import worker


TOKEN = "test-token-with-at-least-thirty-two-characters"


def png(width: int, height: int) -> bytes:
    return (
        b"\x89PNG\r\n\x1a\n"
        + b"\x00\x00\x00\x0dIHDR"
        + width.to_bytes(4, "big")
        + height.to_bytes(4, "big")
    )


class FakePipeline:
    calls: list[dict[str, object]] = []

    def __init__(self, _config: object) -> None:
        pass

    def generate_png(self, **values: object) -> bytes:
        self.calls.append(values)
        return png(int(values["width"]), int(values["height"]))


class FakeConfig:
    def __init__(self, **_values: object) -> None:
        pass


class WorkerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        demo = Path(self.temp.name)
        (demo / "models" / "bonsai-image-4B-ternary-mlx").mkdir(parents=True)
        os.environ["BONSAI_DEMO_ROOT"] = str(demo)
        os.environ["WHEATLEY_IMAGE_QUEUE_SIZE"] = "0"
        backend = types.ModuleType("backend")
        pipeline = types.ModuleType("backend.pipeline")
        pipeline.FluxPipeline = FakePipeline
        pipeline.PipelineConfig = FakeConfig
        sys.modules["backend"] = backend
        sys.modules["backend.pipeline"] = pipeline
        FakePipeline.calls.clear()
        self.worker = worker.Worker()
        self.server = worker.ImageServer(("127.0.0.1", 0), self.worker, TOKEN)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def test_health_requires_authentication(self) -> None:
        with self.assertRaises(HTTPError) as caught:
            urlopen(f"{self.base}/health", timeout=3)
        self.assertEqual(caught.exception.code, 401)
        response = urlopen(Request(
            f"{self.base}/health",
            headers={"Authorization": f"Bearer {TOKEN}"},
        ), timeout=3)
        self.assertTrue(json.load(response)["ready"])

    def test_generation_uses_fixed_four_steps_and_returns_png(self) -> None:
        response = urlopen(self.request({
            "request_id": "request-1",
            "prompt": "A calm lake",
            "width": 624,
            "height": 416,
            "seed": 42,
        }), timeout=3)
        self.assertEqual(response.headers.get_content_type(), "image/png")
        self.assertEqual(response.read(), png(624, 416))
        self.assertEqual(FakePipeline.calls[0]["steps"], 4)

    def test_full_queue_returns_busy_without_generation(self) -> None:
        self.assertTrue(self.worker.capacity.acquire(blocking=False))
        try:
            with self.assertRaises(HTTPError) as caught:
                urlopen(self.request({
                    "request_id": "request-2",
                    "prompt": "A portrait",
                    "width": 416,
                    "height": 624,
                    "seed": 7,
                }), timeout=3)
            self.assertEqual(caught.exception.code, 429)
            self.assertEqual(FakePipeline.calls, [])
        finally:
            self.worker.capacity.release()

    def request(self, value: dict[str, object]) -> Request:
        return Request(
            f"{self.base}/v1/generate",
            method="POST",
            data=json.dumps(value).encode(),
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Content-Type": "application/json",
            },
        )


if __name__ == "__main__":
    unittest.main()
