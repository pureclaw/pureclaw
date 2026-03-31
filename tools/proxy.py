#!/usr/bin/env python3
"""Transparent logging proxy for the Anthropic Messages API.

Sits between a client (OpenClaw or PureClaw) and the real Anthropic API.
Logs the full request body as JSONL, then forwards to the upstream and
streams the response back unmodified.

Usage:
    python3 tools/proxy.py                          # defaults
    python3 tools/proxy.py --port 9999 --log captures.jsonl
    ANTHROPIC_API_KEY=sk-... python3 tools/proxy.py  # if client doesn't send auth

Environment:
    ANTHROPIC_UPSTREAM  — upstream base URL (default: https://api.anthropic.com)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

DEFAULT_PORT = 9999
DEFAULT_LOG = "captures.jsonl"
DEFAULT_UPSTREAM = "https://api.anthropic.com"

_log_lock = threading.Lock()
_verbose = False


def _dbg(*args: object) -> None:
    if _verbose:
        ts = time.strftime("%H:%M:%S", time.localtime())
        sys.stderr.write(f"[proxy {ts}] {' '.join(str(a) for a in args)}\n")


def _log_request(log_path: str, body: dict) -> None:
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **body,
    }
    line = json.dumps(record, separators=(",", ":")) + "\n"
    with _log_lock:
        with open(log_path, "a") as f:
            f.write(line)


class ProxyHandler(BaseHTTPRequestHandler):
    upstream: str
    log_path: str

    def do_POST(self) -> None:  # noqa: N802
        t0 = time.monotonic()
        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length)

        _dbg(f">>> {self.command} {self.path} ({content_length} bytes)")
        if _verbose:
            for k, v in self.headers.items():
                if k.lower() in ("x-api-key", "authorization"):
                    _dbg(f"    {k}: {v[:12]}...{v[-4:]}")
                else:
                    _dbg(f"    {k}: {v}")

        # Log the request body
        try:
            body = json.loads(raw_body)
            _log_request(self.log_path, body)
            _dbg(f"    model={body.get('model', '?')} stream={body.get('stream', False)} "
                 f"messages={len(body.get('messages', []))} tools={len(body.get('tools', []))}")
        except json.JSONDecodeError:
            _dbg("    ERROR: invalid JSON body")
            self._send_error(400, "Invalid JSON in request body")
            return

        # Forward to upstream
        upstream_url = self.upstream.rstrip("/") + self.path
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in ("host", "content-length")
        }
        headers["Content-Length"] = str(len(raw_body))

        req = Request(upstream_url, data=raw_body, headers=headers, method="POST")

        try:
            resp = urlopen(req)
            elapsed = time.monotonic() - t0
            _dbg(f"<<< {resp.status} ({elapsed:.1f}s)")
            if _verbose:
                for key, val in resp.getheaders():
                    _dbg(f"    {key}: {val}")
            self.send_response(resp.status)
            for key, val in resp.getheaders():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.end_headers()
            # Stream the response back in chunks
            total_bytes = 0
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                total_bytes += len(chunk)
                self.wfile.write(chunk)
            _dbg(f"    streamed {total_bytes} bytes to client")
        except HTTPError as e:
            elapsed = time.monotonic() - t0
            err_body = e.read()
            _dbg(f"<<< {e.code} ({elapsed:.1f}s)")
            if _verbose:
                for key, val in e.headers.items():
                    _dbg(f"    {key}: {val}")
                try:
                    _dbg(f"    body: {err_body.decode()[:500]}")
                except Exception:
                    _dbg(f"    body: ({len(err_body)} bytes, not decodable)")
            self.send_response(e.code)
            for key, val in e.headers.items():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.end_headers()
            self.wfile.write(err_body)
        except URLError as e:
            elapsed = time.monotonic() - t0
            _dbg(f"<<< UNREACHABLE ({elapsed:.1f}s): {e.reason}")
            self._send_error(502, f"Upstream unreachable: {e.reason}")

    def _send_error(self, code: int, message: str) -> None:
        body = json.dumps({"error": message}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        # Quieter logging — just method + path + status
        sys.stderr.write(f"[proxy] {args[0] if args else ''}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Anthropic API logging proxy")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Listen port (default: {DEFAULT_PORT})")
    parser.add_argument("--log", default=DEFAULT_LOG, help=f"JSONL output file (default: {DEFAULT_LOG})")
    parser.add_argument("--upstream", default=os.environ.get("ANTHROPIC_UPSTREAM", DEFAULT_UPSTREAM),
                        help=f"Upstream API URL (default: {DEFAULT_UPSTREAM})")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose debug logging to stderr")
    args = parser.parse_args()

    global _verbose
    _verbose = args.verbose

    ProxyHandler.upstream = args.upstream
    ProxyHandler.log_path = args.log

    server = HTTPServer(("127.0.0.1", args.port), ProxyHandler)
    print(f"Proxy listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    print(f"  Upstream: {args.upstream}", file=sys.stderr)
    print(f"  Logging to: {args.log}", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.", file=sys.stderr)
        server.server_close()


if __name__ == "__main__":
    main()
