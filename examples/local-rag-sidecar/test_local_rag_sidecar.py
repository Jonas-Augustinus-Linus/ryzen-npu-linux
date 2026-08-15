#!/usr/bin/env python3
"""Hardware-free regression tests for the local RAG sidecar.

This file inherits the repository's MIT license. See ../../LICENSE.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import importlib.util
import os
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

import numpy as np


MODULE_PATH = Path(__file__).with_name("local_rag_sidecar.py")
SPEC = importlib.util.spec_from_file_location("local_rag_sidecar", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {MODULE_PATH}")
sidecar = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = sidecar
SPEC.loader.exec_module(sidecar)


@contextlib.contextmanager
def recording_server(
    *,
    status: int = 200,
    body: bytes | None = None,
    location: str | None = None,
    drip_delay: float = 0.0,
    reason: str | None = None,
):
    records: list[dict[str, object]] = []
    response = body or b'{"choices":[{"message":{"content":"ok"}}]}'

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length", "0"))
            records.append(
                {
                    "path": self.path,
                    "headers": dict(self.headers.items()),
                    "body": self.rfile.read(length),
                }
            )
            self.send_response(status, reason)
            if location is not None:
                self.send_header("Location", location)
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            try:
                if drip_delay:
                    for byte in response:
                        self.wfile.write(bytes([byte]))
                        self.wfile.flush()
                        time.sleep(drip_delay)
                else:
                    self.wfile.write(response)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, _format: str, *_args: object) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}/v1/chat/completions", records
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


class FakeWrongNPU:
    def matmul_bf16(self, _documents: np.ndarray, _queries: np.ndarray) -> np.ndarray:
        return np.zeros((sidecar.DIM, sidecar.DIM), dtype=np.float32)

    def close(self) -> None:
        return


class FakeFailingNPU:
    def matmul_bf16(self, _documents: np.ndarray, _queries: np.ndarray) -> np.ndarray:
        raise RuntimeError("synthetic dispatch failure")


class SidecarTests(unittest.TestCase):
    def test_chunk_boundary_is_256_then_1(self) -> None:
        chunks = sidecar.chunks_from_text("fixture.txt", " ".join(["word"] * 257))
        self.assertEqual([chunk.token_count for chunk in chunks], [256, 1])

    def test_known_hash_layout_and_query_column(self) -> None:
        vector = sidecar.hashed_bow("npu")
        self.assertEqual(np.flatnonzero(vector).tolist(), [186])
        self.assertEqual(float(vector[186]), -1.0)
        matrix = sidecar.query_matrix("npu")
        self.assertEqual(float(matrix[186, 0]), -1.0)
        self.assertEqual(int(np.count_nonzero(matrix[:, 1:])), 0)

    def test_terminal_controls_are_rendered_inert(self) -> None:
        value = "ok\x1b[31m\r\u202esecret"
        self.assertEqual(sidecar.terminal_text(value), "ok\\u001b[31m\\u000d\\u202esecret")

    def test_oversized_token_is_rejected(self) -> None:
        with self.assertRaisesRegex(sidecar.SidecarError, "token exceeds"):
            sidecar.chunks_from_text("huge.txt", "x" * (sidecar.MAX_CHUNK_CHARS + 1))

    def test_corpus_symlink_escape_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "corpus"
            root.mkdir()
            secret = base / "secret.txt"
            secret.write_text("must not be read", encoding="utf-8")
            (root / "leak.txt").symlink_to(secret)
            with self.assertRaisesRegex(sidecar.SidecarError, "symbolic links"):
                sidecar.load_corpus([root])

    def test_hardlink_aliases_cannot_bypass_candidate_file_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "corpus"
            root.mkdir()
            original = root / "00-original.txt"
            original.write_text("bounded corpus", encoding="utf-8")
            for index in range(1, 5):
                os.link(original, root / f"{index:02d}-alias.txt")
            with mock.patch.object(sidecar, "MAX_CORPUS_FILES", 4):
                with self.assertRaisesRegex(sidecar.SidecarError, "candidate text-file"):
                    sidecar.load_corpus([root])

    def test_hardlink_dedup_uses_stable_lexicographic_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "corpus"
            root.mkdir()
            last = root / "z-last.txt"
            last.write_text("stable hardlink", encoding="utf-8")
            os.link(last, root / "a-first.txt")
            chunks = sidecar.load_corpus([root])
        self.assertEqual(chunks[0].source, "corpus/a-first.txt#chunk-1")

    def test_directory_traversal_error_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "corpus"
            root.mkdir()

            def failed_walk(*_args: object, **kwargs: object):
                onerror = kwargs["onerror"]
                onerror(PermissionError(13, "Permission denied", str(root / "blocked")))
                yield  # pragma: no cover - keeps this a generator

            with mock.patch.object(sidecar.os, "walk", side_effect=failed_walk):
                with self.assertRaisesRegex(sidecar.SidecarError, "could not traverse"):
                    sidecar.load_corpus([root])

    def test_normal_query_rejects_wrong_finite_npu_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            corpus = Path(temporary) / "corpus.md"
            corpus.write_text("alpha alpha alpha", encoding="utf-8")
            arguments = argparse.Namespace(
                corpus=[corpus],
                query=["alpha"],
                top_k=1,
                cpu_only=False,
                vmfb="unused.vmfb",
                endpoint=None,
                model=None,
                allow_remote=False,
                timeout=1.0,
                max_response_bytes=1024,
                api_key_env=None,
            )
            with mock.patch.object(sidecar, "open_npu", return_value=FakeWrongNPU()):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(sidecar.SidecarError, "CPU-reference"):
                        sidecar.run_queries(arguments)

    def test_npu_dispatch_error_has_operator_facing_failure(self) -> None:
        matrix = np.zeros((sidecar.DIM, sidecar.DIM), dtype=np.float32)
        with self.assertRaisesRegex(sidecar.SidecarError, "NPU scoring failed"):
            sidecar._timed_score(matrix, matrix, FakeFailingNPU())

    def test_remote_endpoint_is_blocked_without_opt_in(self) -> None:
        with self.assertRaisesRegex(sidecar.SidecarError, "blocked"):
            sidecar.validate_endpoint("https://example.com/v1/chat/completions", False)
        with self.assertRaisesRegex(sidecar.SidecarError, "blocked"):
            sidecar.validate_endpoint("http://localhost/v1/chat/completions", False)

    def test_redirect_is_not_followed(self) -> None:
        with recording_server() as (target_url, target_records):
            with recording_server(status=302, location=target_url) as (source_url, source_records):
                with self.assertRaisesRegex(sidecar.SidecarError, "HTTP 302"):
                    sidecar.call_endpoint(
                        source_url, "model", "query", "context", False, 2.0, 1024, None
                    )
        self.assertEqual(len(source_records), 1)
        self.assertEqual(target_records, [])

    def test_local_endpoint_bypasses_environment_proxy_and_default_key(self) -> None:
        with recording_server() as (endpoint_url, endpoint_records):
            with recording_server() as (proxy_url, proxy_records):
                environment = {
                    "http_proxy": proxy_url,
                    "HTTP_PROXY": proxy_url,
                    "https_proxy": proxy_url,
                    "HTTPS_PROXY": proxy_url,
                    "no_proxy": "",
                    "NO_PROXY": "",
                    "OPENAI_API_KEY": "must-not-leave",
                }
                with mock.patch.dict(os.environ, environment, clear=False):
                    answer = sidecar.call_endpoint(
                        endpoint_url, "model", "query", "context", False, 2.0, 1024, None
                    )
        self.assertEqual(answer, "ok")
        self.assertEqual(len(endpoint_records), 1)
        self.assertEqual(proxy_records, [])
        headers = endpoint_records[0]["headers"]
        self.assertIsInstance(headers, dict)
        self.assertNotIn("Authorization", headers)

    def test_invalid_key_cannot_leak_through_header_error(self) -> None:
        secret = "sentinel-secret\nInjected: yes"
        with recording_server() as (endpoint_url, records):
            with mock.patch.dict(os.environ, {"RAG_BAD_KEY": secret}):
                with self.assertRaises(sidecar.SidecarError) as raised:
                    sidecar.call_endpoint(
                        endpoint_url,
                        "model",
                        "query",
                        "context",
                        False,
                        2.0,
                        1024,
                        "RAG_BAD_KEY",
                    )
        self.assertNotIn("sentinel-secret", str(raised.exception))
        self.assertEqual(records, [])

    def test_explicit_missing_key_fails_before_transport(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(sidecar.SidecarError, "unset or empty"):
                sidecar.call_endpoint(
                    "http://127.0.0.1:1/v1/chat/completions",
                    "model",
                    "query",
                    "context",
                    False,
                    2.0,
                    1024,
                    "RAG_MISSING_KEY",
                )

    def test_server_reason_cannot_reflect_explicit_key(self) -> None:
        secret = "sentinel-valid-secret"
        with recording_server(status=401, reason=f"Bearer {secret}") as (
            endpoint_url,
            records,
        ):
            with mock.patch.dict(os.environ, {"RAG_KEY": secret}):
                with self.assertRaises(sidecar.SidecarError) as raised:
                    sidecar.call_endpoint(
                        endpoint_url,
                        "model",
                        "query",
                        "context",
                        False,
                        2.0,
                        1024,
                        "RAG_KEY",
                    )
        self.assertNotIn(secret, str(raised.exception))
        self.assertEqual(len(records), 1)

    def test_response_limit_is_enforced(self) -> None:
        with recording_server(body=b"x" * 128) as (endpoint_url, _records):
            with self.assertRaisesRegex(sidecar.SidecarError, "exceeds"):
                sidecar.call_endpoint(
                    endpoint_url, "model", "query", "context", False, 2.0, 16, None
                )

    def test_serialized_request_limit_is_explicit(self) -> None:
        with mock.patch.object(sidecar, "MAX_ENDPOINT_HELPER_INPUT_BYTES", 128):
            with self.assertRaisesRegex(sidecar.SidecarError, "serialized endpoint request"):
                sidecar.call_endpoint(
                    "http://127.0.0.1:1/v1/chat/completions",
                    "model",
                    "query",
                    "context" * 32,
                    False,
                    2.0,
                    1024,
                    None,
                )

    def test_timeout_is_a_total_deadline_for_slow_drip(self) -> None:
        with recording_server(drip_delay=0.02) as (endpoint_url, _records):
            started = time.monotonic()
            with self.assertRaisesRegex(sidecar.SidecarError, "total deadline"):
                sidecar.call_endpoint(
                    endpoint_url, "model", "query", "context", False, 0.05, 1024, None
                )
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 0.3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
