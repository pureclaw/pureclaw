#!/usr/bin/env python3
"""Mock Anthropic Messages API server for deterministic testing.

Returns a canned assistant response for every POST to /v1/messages.
Logs the full request body as JSONL — identical format to proxy.py —
so captures can be compared directly.

No real API calls, no cost, fully deterministic.

Usage:
    python3 tools/mock-provider.py                        # defaults
    python3 tools/mock-provider.py --port 9998 --log mock-captures.jsonl
    python3 tools/mock-provider.py --response "Custom reply"
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler

DEFAULT_PORT = 9998
DEFAULT_LOG = "mock-captures.jsonl"
DEFAULT_RESPONSE_TEXT = "MOCK_RESPONSE"

_log_lock = threading.Lock()


def _log_request(log_path: str, body: dict) -> None:
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **body,
    }
    line = json.dumps(record, separators=(",", ":")) + "\n"
    with _log_lock:
        with open(log_path, "a") as f:
            f.write(line)


def _make_response(model: str, response_text: str, stream: bool) -> tuple[bytes, str]:
    """Build a canned Anthropic Messages API response.

    Returns (body_bytes, content_type).
    If the request asked for streaming, returns a valid SSE stream.
    """
    msg_id = f"msg_{uuid.uuid4().hex[:24]}"

    if stream:
        # Minimal valid SSE stream matching Anthropic's streaming format
        events = [
            {"type": "message_start", "message": {
                "id": msg_id, "type": "message", "role": "assistant",
                "content": [], "model": model, "stop_reason": None,
                "usage": {"input_tokens": 10, "output_tokens": 0},
            }},
            {"type": "content_block_start", "index": 0,
             "content_block": {"type": "text", "text": ""}},
            {"type": "content_block_delta", "index": 0,
             "delta": {"type": "text_delta", "text": response_text}},
            {"type": "content_block_stop", "index": 0},
            {"type": "message_delta",
             "delta": {"stop_reason": "end_turn"},
             "usage": {"output_tokens": 5}},
            {"type": "message_stop"},
        ]
        lines = []
        for event in events:
            lines.append(f"event: {event['type']}")
            lines.append(f"data: {json.dumps(event)}")
            lines.append("")
        body = "\n".join(lines).encode()
        return body, "text/event-stream"

    # Non-streaming response
    response = {
        "id": msg_id,
        "type": "message",
        "role": "assistant",
        "content": [{"type": "text", "text": response_text}],
        "model": model,
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": 10, "output_tokens": 5},
    }
    body = json.dumps(response).encode()
    return body, "application/json"


class MockHandler(BaseHTTPRequestHandler):
    log_path: str
    response_text: str

    def do_POST(self) -> None:  # noqa: N802
        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length)

        try:
            body = json.loads(raw_body)
        except json.JSONDecodeError:
            self._send_error(400, "Invalid JSON in request body")
            return

        # Log the request
        _log_request(self.log_path, body)

        model = body.get("model", "claude-sonnet-4-6")
        stream = body.get("stream", False)

        resp_body, content_type = _make_response(model, self.response_text, stream)

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)

    def _send_error(self, code: int, message: str) -> None:
        body = json.dumps({"error": {"type": "invalid_request_error", "message": message}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        sys.stderr.write(f"[mock] {args[0] if args else ''}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Mock Anthropic Messages API server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Listen port (default: {DEFAULT_PORT})")
    parser.add_argument("--log", default=DEFAULT_LOG, help=f"JSONL output file (default: {DEFAULT_LOG})")
    parser.add_argument("--response", default=DEFAULT_RESPONSE_TEXT, help=f"Canned response text (default: {DEFAULT_RESPONSE_TEXT})")
    args = parser.parse_args()

    MockHandler.log_path = args.log
    MockHandler.response_text = args.response

    server = HTTPServer(("127.0.0.1", args.port), MockHandler)
    print(f"Mock provider listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    print(f"  Logging to: {args.log}", file=sys.stderr)
    print(f"  Response text: {args.response!r}", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.", file=sys.stderr)
        server.server_close()


if __name__ == "__main__":
    main()
