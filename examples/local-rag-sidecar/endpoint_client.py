#!/usr/bin/env python3
"""Isolated, bounded HTTP transport for local_rag_sidecar.py.

The parent sends one JSON request on stdin and enforces the total deadline by
terminating this process. Diagnostics never include headers, bodies, URLs, or
server-controlled reason text.

This file inherits the repository's MIT license. See ../../LICENSE.
"""

from __future__ import annotations

import base64
import http.client
import json
import sys
import urllib.parse


MAX_INPUT_BYTES = 48 * 1024 * 1024


def reply(document: dict[str, object], status: int) -> int:
    sys.stdout.write(json.dumps(document, separators=(",", ":")))
    return status


def main() -> int:
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        return reply({"ok": False, "error": "invalid-config"}, 2)
    try:
        request = json.loads(raw.decode("utf-8"))
        endpoint = request["endpoint"]
        headers = request["headers"]
        request_body = base64.b64decode(request["body"], validate=True)
        timeout = float(request["timeout"])
        max_response_bytes = int(request["max_response_bytes"])
        parsed = urllib.parse.urlsplit(endpoint)
        _ = parsed.port
        if (
            not isinstance(endpoint, str)
            or not isinstance(headers, dict)
            or parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.fragment
            or not 0 < timeout <= 600
            or not 1 <= max_response_bytes <= 16 * 1024 * 1024
        ):
            raise ValueError
    except (KeyError, TypeError, ValueError, UnicodeError, json.JSONDecodeError):
        return reply({"ok": False, "error": "invalid-config"}, 2)

    path = parsed.path or "/"
    if parsed.query:
        path += f"?{parsed.query}"
    connection: http.client.HTTPConnection | None = None
    try:
        connection_class = (
            http.client.HTTPSConnection
            if parsed.scheme == "https"
            else http.client.HTTPConnection
        )
        connection = connection_class(parsed.hostname, parsed.port, timeout=timeout)
        connection.request("POST", path, body=request_body, headers=headers)
        response = connection.getresponse()
        if not 200 <= response.status < 300:
            return reply(
                {"ok": False, "error": "http-status", "status": int(response.status)},
                1,
            )
        declared = response.getheader("Content-Length")
        if declared:
            try:
                if int(declared) > max_response_bytes:
                    return reply({"ok": False, "error": "response-limit"}, 1)
            except ValueError:
                pass
        response_body = response.read(max_response_bytes + 1)
        if len(response_body) > max_response_bytes:
            return reply({"ok": False, "error": "response-limit"}, 1)
        return reply(
            {
                "ok": True,
                "body": base64.b64encode(response_body).decode("ascii"),
            },
            0,
        )
    except Exception as exc:
        return reply(
            {"ok": False, "error": "transport", "type": type(exc).__name__},
            1,
        )
    finally:
        if connection is not None:
            connection.close()


if __name__ == "__main__":
    raise SystemExit(main())
