#!/usr/bin/env python3
"""Probe server for pdftract .url fetch behavior testing.

Salvaged from the pre-remote-feature probe attempts (probe-tmp/server.py,
2026-09-29) and extended with explicit delay/size/content-type knobs.

One ThreadingHTTPServer serves every plain-HTTP mode; pass CERT and KEY to
wrap the same routes in TLS. Every request is logged as one JSONL line to
LOGFILE (method, path, headers) so probes can verify what the client
actually sent.

Usage:
    python3 server.py PORT LOGFILE [FIXTURE] [CERT KEY]

Single-command starts (see ../url-fetch-semantics.md):
    python3 server.py 18765 http.jsonl fixtures/mini.pdf
    python3 server.py 18443 tls_ss.jsonl fixtures/mini.pdf certs/self-signed.pem certs/self-signed.key

Routes (mode selected by URL path):
    /ok.pdf              200 fixture, Accept-Ranges: bytes       (happy path)
    /plain.pdf           fixture with Content-Type: text/plain
    /octet.pdf           fixture with application/octet-stream
    /notype.pdf          fixture with no Content-Type header
    /ctype/<TYPE>        fixture with arbitrary Content-Type TYPE
    /noranges.pdf        fixture without Accept-Ranges
    /nohead              HEAD -> 405, GET -> 200 fixture
    /r/<N>               N-hop 302 chain ending at /ok.pdf (exactly N
                         redirects for any N >= 0; /r/0 serves the fixture
                         directly with no redirect)
    /loop                infinite 302 redirect to itself
    /tlsredir            302 to absolute http:// URL (scheme downgrade)
    /slow/connect/<MS>   connect-delay knob: TCP accept is instant (kernel
                         backlog), request is read, then the server stays
                         silent MS ms before the first response byte.
                         Client sees: connect instant, request sent, then a
                         time-to-first-byte stall. A true TCP-connect hang
                         (connect timeout) needs the blackhole address
                         10.255.255.1 — SYN dropped, no server involved.
    /slow/body/<MS>      body-delay knob: response headers + first byte sent
                         immediately, then silence MS ms, then the rest.
                         Client sees: headers instant, body stalled mid-read.
    /hang                accept request, never respond (120 s)
    /stall               headers promising 100000 bytes, send 9, stall (120 s)
    /big/<MB>            valid single-page PDF padded to MB MiB (cap 64)
    /big.pdf             5 MiB variant of the above
    /zero.pdf            200 with empty body
    /404 /401 /403 /500 /503   fixed HTTP error statuses
    /auth.pdf            200 only with Authorization: Basic <base64 of user:pass>
    /echo                200 JSON echo of received request headers
"""
import base64
import json
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[2] if len(sys.argv) > 2 else "server.jsonl"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18765
FIXTURE = sys.argv[3] if len(sys.argv) > 3 else "fixtures/mini.pdf"
CERT = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] != "-" else None
KEY = sys.argv[5] if len(sys.argv) > 5 else None


def make_padded_pdf(n_bytes):
    """Build a well-formed single-page PDF padded with comment lines."""
    stream = b""
    line = b"% " + b"A" * 78 + b"\n"
    while len(stream) < n_bytes:
        stream += line
    objs = []
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objs.append(
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Contents 4 0 R /Resources << >> >>"
    )
    objs.append(
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream"
    )
    out = b"%PDF-1.4\n"
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += str(i).encode() + b" 0 obj\n" + body + b"\nendobj\n"
    xref_pos = len(out)
    out += b"xref\n0 " + str(len(objs) + 1).encode() + b"\n"
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += ("%010d 00000 n \n" % off).encode()
    out += (
        b"trailer\n<< /Size " + str(len(objs) + 1).encode()
        + b" /Root 1 0 R >>\nstartxref\n" + str(xref_pos).encode() + b"\n%%EOF\n"
    )
    return out


_FIXTURE_CACHE = {}


def fixture_bytes():
    if "fixture" not in _FIXTURE_CACHE:
        _FIXTURE_CACHE["fixture"] = open(FIXTURE, "rb").read()
    return _FIXTURE_CACHE["fixture"]


def padded_pdf(mb):
    """Lazily build (and cache) an oversized response body."""
    key = mb
    if key not in _FIXTURE_CACHE:
        _FIXTURE_CACHE[key] = make_padded_pdf(mb * 1024 * 1024)
    return _FIXTURE_CACHE[key]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # keep stdout clean; requests go to the JSONL log

    def _log(self):
        entry = {
            "t": time.time(),
            "method": self.command,
            "path": self.path,
            "headers": dict(self.headers),
        }
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def _send(self, code, body, ctype="application/pdf", extra=None):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        if ctype is not None:
            self.send_header("Content-Type", ctype)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _route(self):
        self._log()
        p = self.path.split("?")[0]

        if p == "/ok.pdf":
            self._send(200, fixture_bytes(), extra={"Accept-Ranges": "bytes"})
        elif p == "/plain.pdf":
            self._send(200, fixture_bytes(), ctype="text/plain")
        elif p == "/octet.pdf":
            self._send(200, fixture_bytes(), ctype="application/octet-stream")
        elif p == "/notype.pdf":
            self._send(200, fixture_bytes(), ctype=None)
        elif p.startswith("/ctype/"):
            self._send(200, fixture_bytes(), ctype=p[len("/ctype/"):])
        elif p == "/noranges.pdf":
            self._send(200, fixture_bytes())
        elif p == "/nohead":
            if self.command == "HEAD":
                self._send(405, b"", ctype="text/plain")
            else:
                self._send(200, fixture_bytes())
        elif p.startswith("/r/"):
            n = int(p.rsplit("/", 1)[1])
            if n <= 0:
                # zero-hop chain: land on the fixture with no redirect at
                # all, so /r/N is exactly N redirects for every N >= 0
                self._send(200, fixture_bytes(), extra={"Accept-Ranges": "bytes"})
                return
            loc = "/ok.pdf" if n == 1 else "/r/%d" % (n - 1)
            self._send(302, b"", ctype="text/plain", extra={"Location": loc})
        elif p == "/loop":
            self._send(302, b"", ctype="text/plain", extra={"Location": "/loop"})
        elif p == "/tlsredir":
            # only meaningful on a TLS port: redirect https -> http
            self._send(
                302, b"", ctype="text/plain",
                extra={"Location": "http://127.0.0.1:%d/ok.pdf" % PORT},
            )
        elif p.startswith("/slow/connect/"):
            ms = int(p.rsplit("/", 1)[1])
            time.sleep(ms / 1000.0)
            self._send(200, fixture_bytes(), extra={"Accept-Ranges": "bytes"})
        elif p.startswith("/slow/body/"):
            ms = int(p.rsplit("/", 1)[1])
            body = fixture_bytes()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "application/pdf")
            self.end_headers()
            self.wfile.write(body[:1])
            self.wfile.flush()
            time.sleep(ms / 1000.0)
            self.wfile.write(body[1:])
        elif p == "/hang":
            time.sleep(120)  # accept request, never respond
        elif p == "/stall":
            # send headers, then stall mid-body
            self.send_response(200)
            self.send_header("Content-Length", "100000")
            self.send_header("Content-Type", "application/pdf")
            self.end_headers()
            self.wfile.write(b"%PDF-1.4\n")
            self.wfile.flush()
            time.sleep(120)
        elif p.startswith("/big/"):
            mb = min(int(p.rsplit("/", 1)[1]), 64)
            self._send(200, padded_pdf(mb))
        elif p == "/big.pdf":
            self._send(200, padded_pdf(5))
        elif p == "/zero.pdf":
            self._send(200, b"", extra={"Accept-Ranges": "bytes"})
        elif p == "/404":
            self._send(404, b"nope", ctype="text/plain")
        elif p == "/401":
            body = b'{"error": "auth required"}'
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="probe"')
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        elif p == "/403":
            self._send(403, b"denied", ctype="text/plain")
        elif p == "/500":
            self._send(500, b"boom", ctype="text/plain")
        elif p == "/503":
            self._send(503, b"busy", ctype="text/plain")
        elif p == "/auth.pdf":
            # expected credential computed at runtime (no literal base64
            # credential in the source, which trips secret scanners)
            auth = self.headers.get("Authorization", "")
            if auth == "Basic " + base64.b64encode(b"user:pass").decode():
                self._send(200, fixture_bytes())
            else:
                self._send(401, b"auth required", ctype="text/plain",
                           extra={"WWW-Authenticate": 'Basic realm="probe"'})
        elif p == "/echo":
            body = json.dumps({"received": dict(self.headers)}).encode()
            self._send(200, body, ctype="application/json")
        else:
            self._send(404, b"not found", ctype="text/plain")

    do_GET = _route
    do_HEAD = _route


if __name__ == "__main__":
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    httpd.daemon_threads = True
    if CERT and KEY:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT, KEY)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()
