#!/usr/bin/env python3
"""Transparent logging proxy for the Anthropic Messages API.

Sits between a client (OpenClaw or PureClaw) and the real Anthropic API.
Logs the full request body as JSONL, then forwards to the upstream and
streams the response back unmodified.

Supports two modes:

  1. Direct mode (default): client sends plain HTTP POST requests.
     Point ANTHROPIC_BASE_URL=http://localhost:9999 at the proxy.

  2. CONNECT mode: client uses the proxy as an HTTPS proxy.
     Set HTTPS_PROXY=http://localhost:9999 and
     NODE_TLS_REJECT_UNAUTHORIZED=0 (self-signed MITM cert).
     The proxy terminates TLS, logs the plaintext request, then
     forwards to the real upstream over HTTPS.

Usage:
    python3 tools/proxy.py                          # defaults
    python3 tools/proxy.py -v --log captures.jsonl  # verbose
    python3 tools/proxy.py --port 9999 --log captures.jsonl
    ANTHROPIC_API_KEY=sk-... python3 tools/proxy.py  # if client doesn't send auth

Environment:
    ANTHROPIC_UPSTREAM  — upstream base URL (default: https://api.anthropic.com)
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import select
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

MITM_HOSTS = {"api.anthropic.com"}

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


def _generate_mitm_cert() -> tuple[str, str, str]:
    """Generate a self-signed cert for MITM. Returns (tmpdir, certfile, keyfile)."""
    tmpdir = tempfile.mkdtemp(prefix="proxy-mitm-")
    certfile = os.path.join(tmpdir, "cert.pem")
    keyfile = os.path.join(tmpdir, "key.pem")
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyfile, "-out", certfile,
            "-days", "1", "-nodes",
            "-subj", "/CN=api.anthropic.com",
        ],
        check=True,
        capture_output=True,
    )
    return tmpdir, certfile, keyfile


class ProxyHandler(BaseHTTPRequestHandler):
    upstream: str
    log_path: str
    mitm_certfile: str | None = None
    mitm_keyfile: str | None = None

    # Set by do_CONNECT so do_POST knows the tunnel target
    _connect_host: str | None = None

    def do_CONNECT(self) -> None:  # noqa: N802
        """Handle HTTPS CONNECT tunneling.

        For Anthropic hosts: MITM with TLS termination to log requests.
        For all other hosts: blind TCP passthrough (no interception).
        """
        host, _, port = self.path.partition(":")
        port_num = int(port) if port else 443

        if host not in MITM_HOSTS:
            _dbg(f">>> CONNECT {host}:{port_num} (passthrough)")
            self._tunnel_passthrough(host, port_num)
            return

        _dbg(f">>> CONNECT {host}:{port_num} (MITM)")

        if not self.mitm_certfile:
            _dbg("    ERROR: no MITM cert available")
            self._send_error(501, "CONNECT not supported without MITM cert")
            return

        # Tell the client the tunnel is established
        self.send_response(200, "Connection Established")
        self.end_headers()

        # Wrap the client socket in TLS (we present our self-signed cert)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.mitm_certfile, self.mitm_keyfile)
        try:
            self.connection = context.wrap_socket(
                self.connection, server_side=True,
            )
        except ssl.SSLError as e:
            _dbg(f"    TLS handshake failed: {e}")
            return

        self.rfile = self.connection.makefile("rb", self.rbufsize)
        self.wfile = self.connection.makefile("wb", self.wbufsize)

        # Remember the tunnel target for URL construction in do_POST
        self._connect_host = host

        _dbg(f"    TLS established, handling tunneled requests to {host}")

        # Handle requests through the tunnel until the client disconnects
        self.close_connection = False
        while not self.close_connection:
            try:
                self.handle_one_request()
            except (ConnectionError, OSError):
                break

    def _tunnel_passthrough(self, host: str, port: int) -> None:
        """Blind TCP tunnel — no TLS termination, no logging."""
        try:
            upstream = socket.create_connection((host, port), timeout=10)
        except OSError as e:
            _dbg(f"    passthrough connect failed: {e}")
            self._send_error(502, f"Cannot connect to {host}:{port}")
            return

        self.send_response(200, "Connection Established")
        self.end_headers()

        client = self.connection
        sockets = [client, upstream]
        try:
            while True:
                readable, _, errored = select.select(sockets, [], sockets, 30)
                if errored:
                    break
                for sock in readable:
                    data = sock.recv(65536)
                    if not data:
                        return
                    if sock is client:
                        upstream.sendall(data)
                    else:
                        client.sendall(data)
        except (ConnectionError, OSError):
            pass
        finally:
            upstream.close()

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

        # Build upstream URL:
        # - CONNECT tunnel: forward to https://<connect_host><path>
        # - Direct mode: forward to <upstream><path>
        if self._connect_host:
            upstream_url = f"https://{self._connect_host}{self.path}"
        else:
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

    # Generate MITM cert for CONNECT support
    print("Generating MITM certificate...", file=sys.stderr)
    tmpdir, certfile, keyfile = _generate_mitm_cert()
    atexit.register(shutil.rmtree, tmpdir, True)
    ProxyHandler.mitm_certfile = certfile
    ProxyHandler.mitm_keyfile = keyfile
    print(f"  MITM cert: {certfile}", file=sys.stderr)

    server = HTTPServer(("127.0.0.1", args.port), ProxyHandler)
    print(f"Proxy listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    print(f"  Upstream: {args.upstream}", file=sys.stderr)
    print(f"  Logging to: {args.log}", file=sys.stderr)
    print(f"  CONNECT/MITM: enabled (set HTTPS_PROXY=http://localhost:{args.port})", file=sys.stderr)
    print(f"  Note: client needs NODE_TLS_REJECT_UNAUTHORIZED=0 for self-signed cert", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.", file=sys.stderr)
        server.server_close()


if __name__ == "__main__":
    main()
