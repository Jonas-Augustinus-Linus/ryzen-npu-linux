#!/usr/bin/env python3
"""A small, inspectable local-RAG scoring sidecar for AMD XDNA NPUs.

The CPU reads and hashes text, a persistent NPU matmul scores all document
chunks, and the CPU selects top-k context.  An OpenAI-compatible endpoint is
optional and disabled unless both --endpoint and --model are supplied.

This file inherits the repository's MIT license.  See ../../LICENSE.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import re
import stat
import statistics
import subprocess
import sys
import time
import unicodedata
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import numpy as np


DIM = 256
MAX_CHUNK_TOKENS = 256
MAX_CHUNKS = 256
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_TOTAL_CORPUS_BYTES = 16 * 1024 * 1024
MAX_CORPUS_FILES = 512
MAX_CHUNK_CHARS = 16 * 1024
MAX_QUERY_CHARS = 16 * 1024
MAX_ENDPOINT_CONTEXT_CHARS = 5 * 1024 * 1024
MAX_ENDPOINT_MODEL_CHARS = 4096
MAX_ENDPOINT_HELPER_INPUT_BYTES = 48 * 1024 * 1024
DEFAULT_RESPONSE_LIMIT = 2 * 1024 * 1024
NPU_ERROR_TOLERANCE = 0.05
SUPPORTED_SUFFIXES = {".md", ".markdown", ".txt"}
WORD_RE = re.compile(r"[^\W_]+(?:['\N{RIGHT SINGLE QUOTATION MARK}-][^\W_]+)*", re.UNICODE)
ENV_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
# Literal loopback addresses avoid resolver or /etc/hosts aliases escaping the
# default local-only policy. A hostname always requires --allow-remote.
LOCAL_ENDPOINT_HOSTS = {"127.0.0.1", "::1"}


class SidecarError(RuntimeError):
    """An expected operator-facing failure."""


def terminal_text(value: str) -> str:
    """Escape terminal controls while preserving ordinary Unicode and layout."""
    rendered: list[str] = []
    for character in value:
        if character in {"\n", "\t"}:
            rendered.append(character)
        elif unicodedata.category(character) in {"Cc", "Cf", "Cs"}:
            rendered.append(f"\\u{ord(character):04x}")
        else:
            rendered.append(character)
    return "".join(rendered)


def terminal_single_line(value: str) -> str:
    return terminal_text(value).replace("\n", "\\n").replace("\t", "\\t")


@dataclass(frozen=True)
class Chunk:
    source: str
    text: str
    token_count: int


@dataclass(frozen=True)
class CorpusFile:
    path: Path
    source: str
    device: int
    inode: int
    size: int
    mtime_ns: int


@dataclass(frozen=True)
class SelftestCase:
    query: str
    expected_source: str


SELFTEST_DOCUMENTS = (
    (
        "persistent-runtime.txt",
        "Persistent runtime loads a VMFB once and reuses one NPU context. "
        "It avoids process startup and device-open overhead during repeated "
        "matrix multiplication dispatches.",
    ),
    (
        "retrieval-pipeline.txt",
        "Local RAG converts document chunks and queries into feature vectors. "
        "The NPU matrix multiplication scores every document. The CPU selects "
        "the top matches and assembles retrieved context.",
    ),
    (
        "optional-model.txt",
        "An OpenAI-compatible local language model receives selected context "
        "only after retrieval. The endpoint is optional and disabled by default.",
    ),
    (
        "device-targets.txt",
        "XDNA1 Phoenix and XDNA2 Strix use device-specific compiled modules. "
        "The detector refuses unknown device mappings instead of guessing.",
    ),
    (
        "correctness.txt",
        "Correctness requires comparing every NPU output element with a "
        "bfloat16-rounded CPU oracle, checking finite values and ranking parity.",
    ),
    (
        "privacy.txt",
        "Local inference can keep private notes on the laptop. Remote model "
        "endpoints require explicit authorization and careful data handling.",
    ),
)

SELFTEST_CASES = (
    SelftestCase(
        "How are process startup and device-open overhead avoided during "
        "repeated NPU matrix multiplication?",
        "persistent-runtime.txt#chunk-1",
    ),
    SelftestCase(
        "Who selects the top matches and assembles retrieved context after "
        "NPU document scoring?",
        "retrieval-pipeline.txt#chunk-1",
    ),
    SelftestCase(
        "Why does a remote model endpoint need explicit authorization for "
        "private laptop notes?",
        "privacy.txt#chunk-1",
    ),
)


def lexical_tokens(text: str) -> list[str]:
    """Return stable, Unicode-normalized bag-of-words terms."""
    normalized = unicodedata.normalize("NFKC", text).casefold()
    return [match.group(0) for match in WORD_RE.finditer(normalized)]


def iter_chunks_from_text(source: str, text: str) -> Iterable[Chunk]:
    """Yield bounded chunks without materializing every regex match."""
    normalized = unicodedata.normalize("NFKC", text)
    chunk_number = 0
    chunk_start: int | None = None
    chunk_end = 0
    token_count = 0

    def make_chunk() -> Chunk:
        nonlocal chunk_number
        if chunk_start is None or token_count == 0:
            raise SidecarError("internal chunker state is empty")
        chunk_number += 1
        return Chunk(
            source=f"{source}#chunk-{chunk_number}",
            text=normalized[chunk_start:chunk_end].strip(),
            token_count=token_count,
        )

    for match in WORD_RE.finditer(normalized):
        if match.end() - match.start() > MAX_CHUNK_CHARS:
            raise SidecarError(
                f"corpus token exceeds {MAX_CHUNK_CHARS} characters: {source}"
            )
        would_exceed_chars = (
            chunk_start is not None and match.end() - chunk_start > MAX_CHUNK_CHARS
        )
        if token_count == MAX_CHUNK_TOKENS or would_exceed_chars:
            yield make_chunk()
            chunk_start = None
            token_count = 0
        if chunk_start is None:
            chunk_start = match.start()
        chunk_end = match.end()
        token_count += 1
    if token_count:
        yield make_chunk()


def chunks_from_text(source: str, text: str) -> list[Chunk]:
    """Split text deterministically into resource-bounded lexical chunks."""
    return list(iter_chunks_from_text(source, text))


def _corpus_files(paths: Iterable[Path]) -> list[CorpusFile]:
    files: dict[tuple[int, int], CorpusFile] = {}
    sources: dict[str, Path] = {}
    candidate_count = 0

    def add_file(candidate: Path, source: str) -> None:
        nonlocal candidate_count
        if candidate.suffix.casefold() not in SUPPORTED_SUFFIXES:
            return
        candidate_count += 1
        if candidate_count > MAX_CORPUS_FILES:
            raise SidecarError(
                f"corpus exceeds {MAX_CORPUS_FILES} candidate text-file paths"
            )
        try:
            metadata = candidate.lstat()
        except OSError as exc:
            raise SidecarError(f"could not inspect corpus file {candidate}: {exc}") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise SidecarError(f"corpus symbolic links are not allowed: {candidate}")
        if not stat.S_ISREG(metadata.st_mode):
            return
        resolved = candidate.resolve(strict=True)
        previous = sources.get(source)
        if previous is not None and previous != resolved:
            raise SidecarError(
                f"ambiguous corpus source label '{source}'; use distinct corpus roots"
            )
        sources[source] = resolved
        key = (metadata.st_dev, metadata.st_ino)
        item = CorpusFile(
            path=resolved,
            source=source,
            device=metadata.st_dev,
            inode=metadata.st_ino,
            size=metadata.st_size,
            mtime_ns=metadata.st_mtime_ns,
        )
        previous_item = files.get(key)
        if previous_item is None or (item.source, str(item.path)) < (
            previous_item.source,
            str(previous_item.path),
        ):
            files[key] = item

    for supplied in paths:
        path = supplied.expanduser()
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            raise SidecarError(f"corpus path does not exist: {supplied}")
        except OSError as exc:
            raise SidecarError(f"could not inspect corpus path {supplied}: {exc}") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise SidecarError(f"corpus symbolic links are not allowed: {supplied}")
        if stat.S_ISREG(metadata.st_mode):
            add_file(path, path.name)
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            raise SidecarError(f"corpus path is not a regular file or directory: {supplied}")

        root = path.resolve(strict=True)
        root_label = root.name or "corpus"

        def traversal_error(error: OSError) -> None:
            location = error.filename or str(root)
            raise SidecarError(
                f"could not traverse corpus directory {location}: "
                f"{error.strerror or type(error).__name__}"
            )

        for directory, dirnames, filenames in os.walk(
            root, followlinks=False, onerror=traversal_error
        ):
            dirnames.sort()
            filenames.sort()
            directory_path = Path(directory)
            for dirname in dirnames:
                nested = directory_path / dirname
                if nested.is_symlink():
                    raise SidecarError(
                        f"corpus directory symbolic links are not allowed: {nested}"
                    )
            for filename in filenames:
                candidate = directory_path / filename
                relative = candidate.relative_to(root).as_posix()
                add_file(candidate, f"{root_label}/{relative}")
    if not files:
        allowed = ", ".join(sorted(SUPPORTED_SUFFIXES))
        raise SidecarError(f"corpus contains no supported text files ({allowed})")
    return sorted(files.values(), key=lambda item: item.source)


def _read_corpus_file(item: CorpusFile) -> str:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(item.path, flags)
    except OSError as exc:
        raise SidecarError(f"could not securely open corpus file {item.path}: {exc}") from exc
    try:
        before = os.fstat(descriptor)
        identity = (before.st_dev, before.st_ino)
        if not stat.S_ISREG(before.st_mode) or identity != (item.device, item.inode):
            raise SidecarError(f"corpus file changed during discovery: {item.path}")
        if before.st_size != item.size or before.st_mtime_ns != item.mtime_ns:
            raise SidecarError(f"corpus file changed during discovery: {item.path}")
        if before.st_size > MAX_FILE_BYTES:
            raise SidecarError(
                f"corpus file exceeds {MAX_FILE_BYTES} bytes: "
                f"{item.path} ({before.st_size} bytes)"
            )
        data = bytearray()
        while len(data) <= MAX_FILE_BYTES:
            block = os.read(descriptor, min(64 * 1024, MAX_FILE_BYTES + 1 - len(data)))
            if not block:
                break
            data.extend(block)
        after = os.fstat(descriptor)
        if len(data) > MAX_FILE_BYTES:
            raise SidecarError(f"corpus file grew beyond {MAX_FILE_BYTES} bytes: {item.path}")
        if (
            after.st_dev != before.st_dev
            or after.st_ino != before.st_ino
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
        ):
            raise SidecarError(f"corpus file changed while it was read: {item.path}")
    finally:
        os.close(descriptor)
    try:
        return data.decode("utf-8")
    except UnicodeError as exc:
        raise SidecarError(f"could not decode UTF-8 corpus file {item.path}: {exc}") from exc


def load_corpus(paths: Iterable[Path]) -> list[Chunk]:
    chunks: list[Chunk] = []
    files = _corpus_files(paths)
    total_bytes = sum(item.size for item in files)
    if total_bytes > MAX_TOTAL_CORPUS_BYTES:
        raise SidecarError(
            f"corpus exceeds {MAX_TOTAL_CORPUS_BYTES} total bytes ({total_bytes} bytes)"
        )
    for item in files:
        text = _read_corpus_file(item)
        for chunk in iter_chunks_from_text(item.source, text):
            if len(chunks) == MAX_CHUNKS:
                raise SidecarError(
                    f"corpus produces more than {MAX_CHUNKS} chunks; curate it to "
                    f"at most {MAX_CHUNKS} chunks of {MAX_CHUNK_TOKENS} tokens and "
                    f"{MAX_CHUNK_CHARS} characters"
                )
            chunks.append(chunk)
    if not chunks:
        raise SidecarError("corpus files contain no lexical tokens")
    return chunks


def selftest_corpus() -> list[Chunk]:
    chunks: list[Chunk] = []
    for source, text in SELFTEST_DOCUMENTS:
        chunks.extend(chunks_from_text(source, text))
    return chunks


def round_bf16_f32(values: np.ndarray) -> np.ndarray:
    """Round float32 to bf16 (nearest-even), retaining a float32 container."""
    array = np.ascontiguousarray(values, dtype=np.float32)
    bits = array.view(np.uint32)
    bias = np.uint32(0x7FFF) + ((bits >> np.uint32(16)) & np.uint32(1))
    rounded = ((bits + bias) & np.uint32(0xFFFF0000)).view(np.float32)
    return np.ascontiguousarray(rounded)


def hashed_bow(text: str) -> np.ndarray:
    """Make a stable signed-SHA256, L2-normalized, bf16-rounded BoW vector."""
    vector = np.zeros(DIM, dtype=np.float32)
    terms = lexical_tokens(text)
    for term in terms:
        digest = hashlib.sha256(term.encode("utf-8")).digest()
        bucket = int.from_bytes(digest[:4], "little") % DIM
        sign = -1.0 if digest[4] & 1 else 1.0
        vector[bucket] += sign
    norm = float(np.linalg.norm(vector.astype(np.float64)))
    if norm:
        vector /= norm
    return round_bf16_f32(vector)


def document_matrix(chunks: list[Chunk]) -> np.ndarray:
    if not 1 <= len(chunks) <= MAX_CHUNKS:
        raise SidecarError(f"document count must be in [1, {MAX_CHUNKS}]")
    matrix = np.zeros((DIM, DIM), dtype=np.float32)
    for row, chunk in enumerate(chunks):
        matrix[row, :] = hashed_bow(chunk.text)
    return round_bf16_f32(matrix)


def query_matrix(query: str) -> np.ndarray:
    if len(query) > MAX_QUERY_CHARS:
        raise SidecarError(f"query exceeds {MAX_QUERY_CHARS} characters")
    feature = hashed_bow(query)
    if not np.any(feature):
        raise SidecarError("query contains no lexical tokens")
    matrix = np.zeros((DIM, DIM), dtype=np.float32)
    matrix[:, 0] = feature
    return round_bf16_f32(matrix)


def cpu_oracle(documents: np.ndarray, queries: np.ndarray) -> np.ndarray:
    """Mirror the NPU ABI: bf16-rounded inputs with f32 accumulation."""
    return round_bf16_f32(documents) @ round_bf16_f32(queries)


def ranked_indices(scores: np.ndarray, count: int, top_k: int) -> list[int]:
    if top_k < 1:
        raise SidecarError("--top-k must be positive")
    limit = min(top_k, count)
    # Explicit index tie-break makes output reproducible across NumPy versions.
    return sorted(range(count), key=lambda index: (-float(scores[index]), index))[:limit]


def normalized_max_error(actual: np.ndarray, reference: np.ndarray) -> tuple[float, float]:
    max_abs = float(np.max(np.abs(actual - reference)))
    scale = max(float(np.max(np.abs(reference))), 1e-9)
    return max_abs, max_abs / scale


def percentile_ms(samples: list[float], percentile: float) -> float:
    if not samples:
        raise SidecarError("latency sample list is empty")
    ordered = sorted(samples)
    rank = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[rank]


def open_npu(vmfb: str):
    module = Path(vmfb).expanduser()
    if not module.is_file() or module.stat().st_size == 0:
        raise SidecarError(f"NPU VMFB is missing or empty: {module}")
    repo = Path(__file__).resolve().parents[2]
    runner_dir = repo / "tools" / "npu-runner"
    sys.path.insert(0, str(runner_dir))
    try:
        from npu import NPU  # type: ignore
    except (ImportError, OSError) as exc:
        raise SidecarError(f"could not load the persistent NPU runner: {exc}") from exc
    try:
        return NPU(str(module), fn="module.matmul")
    except (OSError, RuntimeError) as exc:
        raise SidecarError(f"could not open NPU module {module}: {exc}") from exc


def _timed_score(documents: np.ndarray, queries: np.ndarray, npu) -> tuple[np.ndarray, float]:
    started = time.perf_counter_ns()
    if npu is None:
        output = cpu_oracle(documents, queries)
    else:
        try:
            output = npu.matmul_bf16(documents, queries)
        except (OSError, RuntimeError, ValueError) as exc:
            raise SidecarError(f"NPU scoring failed: {exc}") from exc
    elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000.0
    output = np.asarray(output, dtype=np.float32)
    if output.shape != (DIM, DIM):
        raise SidecarError(f"scorer returned {output.shape}; expected {(DIM, DIM)}")
    return output, elapsed_ms


def run_selftest(cpu_only: bool, vmfb: str | None, repeat: int, top_k: int) -> int:
    if repeat < 2:
        raise SidecarError("--repeat must be at least 2 so p50/p95 are meaningful")
    chunks = selftest_corpus()
    documents = document_matrix(chunks)
    if not np.array_equal(documents, document_matrix(chunks)):
        raise SidecarError("document feature generation is not deterministic")
    if any(chunk.token_count > MAX_CHUNK_TOKENS for chunk in chunks):
        raise SidecarError("chunker exceeded its 256-token contract")

    expected_sources = {chunk.source for chunk in chunks}
    for case in SELFTEST_CASES:
        if case.expected_source not in expected_sources:
            raise SidecarError(f"selftest fixture is missing {case.expected_source}")

    mode = "cpu-only" if cpu_only else "npu"
    target = os.environ.get("NPU_TARGET", "not-reported")
    print(
        f"SELFTEST mode={mode} target={terminal_single_line(target)} chunks={len(chunks)} "
        f"matmul={DIM}x{DIM}x{DIM}"
    )
    all_ok = True
    latencies: list[float] = []
    npu = None if cpu_only else open_npu(vmfb or "")
    try:
        for case_number, case in enumerate(SELFTEST_CASES, start=1):
            queries = query_matrix(case.query)
            if not np.array_equal(queries, query_matrix(case.query)):
                raise SidecarError("query feature generation is not deterministic")
            reference = cpu_oracle(documents, queries)
            reference_rank = ranked_indices(reference[:, 0], len(chunks), top_k)
            expected_ok = chunks[reference_rank[0]].source == case.expected_source
            worst_abs = 0.0
            worst_relative = 0.0
            finite_ok = True
            parity_ok = True
            for _ in range(repeat):
                actual, elapsed_ms = _timed_score(documents, queries, npu)
                latencies.append(elapsed_ms)
                finite_ok = finite_ok and bool(np.isfinite(actual).all())
                max_abs, relative = normalized_max_error(actual, reference)
                worst_abs = max(worst_abs, max_abs)
                worst_relative = max(worst_relative, relative)
                actual_rank = ranked_indices(actual[:, 0], len(chunks), top_k)
                parity_ok = parity_ok and actual_rank == reference_rank

            tolerance_ok = cpu_only or worst_relative <= NPU_ERROR_TOLERANCE
            case_ok = expected_ok and finite_ok and parity_ok and tolerance_ok
            all_ok = all_ok and case_ok
            top_sources = ", ".join(chunks[index].source for index in reference_rank)
            print(
                f"  query {case_number}: top-{len(reference_rank)}=[{top_sources}] "
                f"semantic={'PASS' if expected_ok else 'FAIL'}"
            )
            print(
                f"    calls={repeat}; full-output={DIM * DIM:,}/call; "
                f"finite={'PASS' if finite_ok else 'FAIL'}; "
                f"top-k parity={'PASS' if parity_ok else 'FAIL'}; "
                f"worst max-abs={worst_abs:.6g}; normalized-max={worst_relative:.3%}; "
                f"tolerance={'PASS' if tolerance_ok else 'FAIL'}"
            )
    finally:
        if npu is not None:
            npu.close()

    p50 = statistics.median(latencies)
    p95 = percentile_ms(latencies, 0.95)
    print(f"  repeated {mode} calls={len(latencies)}: p50={p50:.3f} ms p95={p95:.3f} ms")
    if cpu_only:
        print("  NOTE: CPU-only checks logic and fixtures; it makes no NPU execution claim.")
    print(f"RESULT: {'PASS' if all_ok else 'FAIL'}")
    return 0 if all_ok else 1


def print_context(chunks: list[Chunk], output: np.ndarray, top_k: int) -> str:
    indices = ranked_indices(output[:, 0], len(chunks), top_k)
    rendered: list[str] = []
    for rank, index in enumerate(indices, start=1):
        chunk = chunks[index]
        score = float(output[index, 0])
        block = f"[{rank}] {chunk.source}  score={score:.6f}\n{chunk.text}"
        rendered.append(block)
        print(
            f"\n[{rank}] {terminal_single_line(chunk.source)}  score={score:.6f}\n"
            f"{terminal_text(chunk.text)}"
        )
    return "\n\n".join(rendered)


def validate_endpoint(endpoint: str, allow_remote: bool) -> urllib.parse.SplitResult:
    try:
        parsed = urllib.parse.urlsplit(endpoint)
        _ = parsed.port
    except ValueError as exc:
        raise SidecarError(f"invalid --endpoint: {exc}") from exc
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise SidecarError("--endpoint must be an absolute http:// or https:// URL")
    if parsed.username or parsed.password:
        raise SidecarError(
            "credentials are not allowed in --endpoint; "
            "use an API-key environment variable"
        )
    if parsed.fragment:
        raise SidecarError("--endpoint must not contain a URL fragment")
    host = parsed.hostname.casefold()
    if host not in LOCAL_ENDPOINT_HOSTS and not allow_remote:
        raise SidecarError(
            f"remote endpoint host '{parsed.hostname}' is blocked; pass --allow-remote explicitly"
        )
    return parsed


def call_endpoint(
    endpoint: str,
    model: str,
    query: str,
    context: str,
    allow_remote: bool,
    timeout: float,
    max_response_bytes: int,
    api_key_env: str | None,
) -> str:
    parsed = validate_endpoint(endpoint, allow_remote)
    if not math.isfinite(timeout) or timeout <= 0 or timeout > 600:
        raise SidecarError("--timeout must be finite and in (0, 600] seconds")
    if not 1 <= max_response_bytes <= 16 * 1024 * 1024:
        raise SidecarError("--max-response-bytes must be in [1, 16777216]")
    if len(query) > MAX_QUERY_CHARS:
        raise SidecarError(f"endpoint query exceeds {MAX_QUERY_CHARS} characters")
    if len(context) > MAX_ENDPOINT_CONTEXT_CHARS:
        raise SidecarError(
            f"endpoint context exceeds {MAX_ENDPOINT_CONTEXT_CHARS} characters"
        )
    if not model or len(model) > MAX_ENDPOINT_MODEL_CHARS:
        raise SidecarError(
            f"endpoint model name must contain 1 to {MAX_ENDPOINT_MODEL_CHARS} characters"
        )
    if api_key_env is not None and not ENV_NAME_RE.fullmatch(api_key_env):
        raise SidecarError("--api-key-env is not a valid environment-variable name")
    is_remote = parsed.hostname and parsed.hostname.casefold() not in LOCAL_ENDPOINT_HOSTS
    if is_remote and parsed.scheme == "http":
        print("WARNING: explicit remote HTTP endpoint is unencrypted.", file=sys.stderr)

    payload = {
        "model": model,
        "stream": False,
        "temperature": 0.2,
        "messages": [
            {
                "role": "system",
                "content": (
                    "Answer from the supplied retrieved context. "
                    "Say when it is insufficient."
                ),
            },
            {
                "role": "user",
                "content": f"Question:\n{query}\n\nRetrieved context:\n{context}",
            },
        ],
    }
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    api_key = os.environ.get(api_key_env) if api_key_env else None
    if api_key_env and not api_key:
        raise SidecarError("the selected API-key environment variable is unset or empty")
    if api_key:
        if len(api_key) > 8192 or any(not 0x21 <= ord(character) <= 0x7E for character in api_key):
            raise SidecarError(
                "the selected API-key environment value is not a bounded printable-ASCII token"
            )
        headers["Authorization"] = f"Bearer {api_key}"
    request_body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    helper = Path(__file__).with_name("endpoint_client.py")
    if not helper.is_file():
        raise SidecarError(f"endpoint helper is missing: {helper}")
    helper_input = json.dumps(
        {
            "endpoint": endpoint,
            "headers": headers,
            "body": base64.b64encode(request_body).decode("ascii"),
            "timeout": timeout,
            "max_response_bytes": max_response_bytes,
        },
        separators=(",", ":"),
    ).encode("utf-8")
    if len(helper_input) > MAX_ENDPOINT_HELPER_INPUT_BYTES:
        raise SidecarError(
            "serialized endpoint request exceeds the isolated transport limit"
        )
    try:
        completed = subprocess.run(
            [sys.executable, str(helper)],
            input=helper_input,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        # subprocess.run kills and waits for the helper, so a slow peer cannot
        # leave a worker thread or socket alive in the NPU process.
        raise SidecarError(
            f"endpoint request exceeded the {timeout:g}-second total deadline"
        ) from exc
    if len(completed.stdout) > (max_response_bytes * 2 + 64 * 1024):
        raise SidecarError("endpoint helper returned an oversized diagnostic")
    try:
        helper_result = json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise SidecarError("endpoint helper returned an invalid diagnostic") from exc
    if completed.returncode != 0 or not helper_result.get("ok"):
        error = helper_result.get("error")
        if error == "http-status" and isinstance(helper_result.get("status"), int):
            raise SidecarError(f"endpoint returned HTTP {helper_result['status']}")
        if error == "response-limit":
            raise SidecarError("endpoint response exceeds --max-response-bytes")
        if error == "transport":
            error_type = helper_result.get("type")
            if not isinstance(error_type, str) or not re.fullmatch(r"[A-Za-z0-9_]{1,64}", error_type):
                error_type = "transport"
            raise SidecarError(f"endpoint request failed: {error_type}")
        raise SidecarError("endpoint helper rejected the request")
    encoded_body = helper_result.get("body")
    if not isinstance(encoded_body, str):
        raise SidecarError("endpoint helper omitted the response body")
    try:
        body = base64.b64decode(encoded_body, validate=True)
    except (ValueError, TypeError) as exc:
        raise SidecarError("endpoint helper returned an invalid response encoding") from exc
    if len(body) > max_response_bytes:
        raise SidecarError("endpoint response exceeds --max-response-bytes")
    try:
        decoded = json.loads(body.decode("utf-8"))
        content = decoded["choices"][0]["message"]["content"]
    except (UnicodeError, json.JSONDecodeError, KeyError, IndexError, TypeError) as exc:
        raise SidecarError("endpoint returned an invalid OpenAI-compatible JSON response") from exc
    if not isinstance(content, str):
        raise SidecarError("endpoint response message content is not text")
    return content


def positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def finite_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a number") from exc
    if not math.isfinite(parsed):
        raise argparse.ArgumentTypeError("must be finite")
    return parsed


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Score local Markdown/text chunks with a persistent 256x256 NPU matmul.",
    )
    parser.add_argument("--corpus", action="append", default=[], type=Path, metavar="PATH")
    parser.add_argument("--query", action="append", default=[], metavar="TEXT")
    parser.add_argument("--top-k", type=positive_int, default=3)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument(
        "--cpu-only", action="store_true", help="exercise logic without loading the NPU"
    )
    parser.add_argument("--vmfb", default=os.environ.get("RAG_VMFB"), help=argparse.SUPPRESS)
    parser.add_argument("--repeat", type=positive_int, default=7, help="self-test calls per query")
    parser.add_argument("--endpoint", help="full OpenAI-compatible chat-completions URL")
    parser.add_argument("--model", help="model name sent to --endpoint")
    parser.add_argument("--allow-remote", action="store_true")
    parser.add_argument("--timeout", type=finite_float, default=60.0)
    parser.add_argument("--max-response-bytes", type=positive_int, default=DEFAULT_RESPONSE_LIMIT)
    parser.add_argument(
        "--api-key-env",
        help="explicit environment-variable name containing a bearer token",
    )
    return parser.parse_args(argv)


def run_queries(args: argparse.Namespace) -> int:
    if not args.corpus:
        raise SidecarError("at least one --corpus PATH is required outside --selftest")
    if not args.query:
        raise SidecarError("at least one --query TEXT is required outside --selftest")
    if bool(args.endpoint) != bool(args.model):
        raise SidecarError("--endpoint and --model must be supplied together")
    if args.allow_remote and not args.endpoint:
        raise SidecarError("--allow-remote has no effect without --endpoint")
    if args.api_key_env and not args.endpoint:
        raise SidecarError("--api-key-env has no effect without --endpoint")

    chunks = load_corpus(args.corpus)
    documents = document_matrix(chunks)
    scorer = None if args.cpu_only else open_npu(args.vmfb or "")
    target = os.environ.get("NPU_TARGET", "target unknown")
    mode = "CPU oracle" if args.cpu_only else f"NPU ({terminal_single_line(target)})"
    print(f"Loaded {len(chunks)} chunk(s); scorer={mode}; matrix={DIM}x{DIM}x{DIM}")
    try:
        for number, query in enumerate(args.query, start=1):
            queries = query_matrix(query)
            output, elapsed_ms = _timed_score(documents, queries, scorer)
            if not np.isfinite(output).all():
                raise SidecarError(f"query {number} produced non-finite scores")
            reference = cpu_oracle(documents, queries)
            max_abs, relative = normalized_max_error(output, reference)
            actual_rank = ranked_indices(output[:, 0], len(chunks), args.top_k)
            reference_rank = ranked_indices(reference[:, 0], len(chunks), args.top_k)
            parity_ok = actual_rank == reference_rank
            tolerance_ok = args.cpu_only or relative <= NPU_ERROR_TOLERANCE
            print(
                f"\nQuery {number}: scoring={elapsed_ms:.3f} ms; "
                f"full-output={DIM * DIM:,}/{DIM * DIM:,}; "
                f"max-abs={max_abs:.6g}; normalized-max={relative:.3%}; "
                f"top-k parity={'PASS' if parity_ok else 'FAIL'}; "
                f"tolerance={'PASS' if tolerance_ok else 'FAIL'}"
            )
            if not parity_ok or not tolerance_ok:
                raise SidecarError(
                    f"query {number} failed the full CPU-reference check; "
                    "retrieved context was not used"
                )
            print("Retrieved context:")
            context = print_context(chunks, output, args.top_k)
            if args.endpoint:
                answer = call_endpoint(
                    args.endpoint,
                    args.model,
                    query,
                    context,
                    args.allow_remote,
                    args.timeout,
                    args.max_response_bytes,
                    args.api_key_env,
                )
                print(f"\nModel answer {number}:\n{terminal_text(answer)}")
    finally:
        if scorer is not None:
            scorer.close()
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.selftest:
        if (
            args.corpus
            or args.query
            or args.endpoint
            or args.model
            or args.allow_remote
            or args.api_key_env
        ):
            raise SidecarError(
                "--selftest uses fixed fixtures and cannot be combined with corpus, "
                "query, or endpoint options"
            )
        return run_selftest(args.cpu_only, args.vmfb, args.repeat, args.top_k)
    return run_queries(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SidecarError, ValueError) as exc:
        print(f"ERROR: {terminal_text(str(exc))}", file=sys.stderr)
        raise SystemExit(1)
