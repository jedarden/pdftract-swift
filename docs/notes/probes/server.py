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

Routes (mode selected by URL path). The range-capable routes (/ok.pdf,
/slow/connect, /slow/body, /slow/rangestall, /rangetrickle) answer a GET
carrying a satisfiable "Range: bytes=a-b" with 206 + Content-Range + the
matching slice (416 + "Content-Range: bytes */<total>" when wholly past
the end), preserving each route's stall phase; the pdftract HttpRangeSource
refuses any origin that answers a ranged GET 200. /noranges.pdf is the
negative control that keeps answering 200 full-body with no Accept-Ranges:
    /ok.pdf              200/206 fixture, Accept-Ranges: bytes   (happy path)
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
                         HEAD gets headers only — HEAD must never carry a
                         body, and a stray body byte poisons the keep-alive
                         connection a HEAD-first client reuses.
    /slow/rangestall/<MS> range-era twin of /slow/body: headers (incl.
                         Accept-Ranges) return instantly so a Range client
                         keeps its source, then the GET body stalls <MS> ms
                         after the first byte — measures the read-phase
                         timeout separately from the HEAD/TTFB phase
    /rangetrickle/<SECONDS>  /trickle on a 206-capable route (cap 300):
                         long total, 1 byte per 100 ms; a Range slice
                         trickles at the same rate — pairs with
                         /slow/rangestall to separate overall-timeout from
                         idle/read-timeout through the Range source
    /hang                accept request, never respond (120 s)
    /stall               headers promising 100000 bytes, send 9, stall (120 s);
                         HEAD gets headers only (same keep-alive rule)
    /trickle/<SECONDS>   headers + Content-Length immediately, then one byte
                         every 100 ms for SECONDS seconds total (cap 300).
                         Inter-byte gaps stay far below any read timeout
                         while the total duration carries the knob — this is
                         the overall-timeout vs idle-timeout separator: an
                         overall cap fires at the deadline, an idle/read cap
                         never fires and the transfer completes.
    /big/<MB>            valid single-page PDF padded to MB MiB (cap 64)
    /big.pdf             5 MiB variant of the above
    /zero.pdf            200 with empty body
    /404 /401 /403 /500 /503   fixed HTTP error statuses
    /auth.pdf            200 only with Authorization: Basic <base64 of user:pass>
    /echo                200 JSON echo of received request headers
"""
import base64
import json
import re
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


def parse_byte_range(header, total):
    """Parse a Range header against a `total`-byte representation.

    Returns an inclusive (start, end) tuple clamped to the resource for a
    satisfiable bytes= range, the string "unsatisfiable" for a valid bytes=
    range lying wholly past the end, and None when the header is absent or
    not a valid bytes= spec — an ignorable Range header must be answered
    200 with the full body (RFC 9110 §14.1.1, §14.2).
    """
    if not header:
        return None
    m = re.fullmatch(r"\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*", header.strip())
    if not m:
        return None
    first, last = m.group(1), m.group(2)
    if first == "" and last == "":
        return None  # "bytes=-" names no range: ignore the header
    if total <= 0:
        return "unsatisfiable"
    if first == "":
        # suffix form "bytes=-N": the final N bytes
        if int(last) == 0:
            return "unsatisfiable"
        return (max(0, total - int(last)), total - 1)
    start = int(first)
    if start >= total:
        return "unsatisfiable"
    end = min(int(last), total - 1) if last else total - 1
    return (start, end)


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

    def _select_range(self, body):
        """Compute (code, payload, extra_headers) serving `body` under this
        request's Range header: 206 + Content-Range + the clamped slice,
        416 for a range wholly past the end, 200 + full body otherwise.
        Always advertises Accept-Ranges: bytes. Routes that interleave
        their send (slow/body, slow/rangestall, rangetrickle) use the
        payload; the rest go through _send_ranged."""
        extra = {"Accept-Ranges": "bytes"}
        rng = parse_byte_range(self.headers.get("Range", ""), len(body))
        if rng is None:
            return 200, body, extra
        if rng == "unsatisfiable":
            extra["Content-Range"] = "bytes */%d" % len(body)
            return 416, b"", extra
        start, end = rng
        extra["Content-Range"] = "bytes %d-%d/%d" % (start, end, len(body))
        return 206, body[start:end + 1], extra

    def _send_ranged(self, body, ctype="application/pdf"):
        code, payload, extra = self._select_range(body)
        self._send(code, payload, ctype=ctype if code != 416 else None,
                   extra=extra)

    def _send_stalled_body(self, ms):
        """Headers (200, or 206 per Range) + first body byte immediately,
        then <ms> silence, then the rest of the selected slice — the
        body-delay phase split layered on top of Range handling. HEAD gets
        headers only (a stray body byte poisons the keep-alive connection
        a HEAD-first client reuses)."""
        code, payload, extra = self._select_range(fixture_bytes())
        self.send_response(code)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Type", "application/pdf")
        for k, v in extra.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command == "HEAD" or not payload:
            return
        self.wfile.write(payload[:1])
        self.wfile.flush()
        time.sleep(ms / 1000.0)
        self.wfile.write(payload[1:])

    def _route(self):
        self._log()
        p = self.path.split("?")[0]

        if p == "/ok.pdf":
            self._send_ranged(fixture_bytes())
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
            time.sleep(ms / 1000.0)  # stall BEFORE any response header
            self._send_ranged(fixture_bytes())
        elif p.startswith("/slow/body/"):
            self._send_stalled_body(int(p.rsplit("/", 1)[1]))
        elif p.startswith("/slow/rangestall/"):
            # range-era twin of /slow/body (it predates /slow/body being
            # 206-capable); kept because the timeout probes pair it with
            # /rangetrickle — see ../url-fetch-semantics.md
            self._send_stalled_body(int(p.rsplit("/", 1)[1]))
        elif p.startswith("/rangetrickle/"):
            # /trickle on a 206-capable route: long total, 100 ms inter-byte
            # gaps — the pacing is the preserved stall phase, so a Range
            # slice trickles at the same 1-byte/100ms rate and a per-request
            # overall timeout aborts while an idle/read timeout sails
            # through. Pairs with /slow/rangestall to separate the two.
            secs = min(int(p.rsplit("/", 1)[1]), 300)
            code, payload, extra = self._select_range(b"A" * (secs * 10))
            self.send_response(code)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Content-Type", "application/pdf")
            for k, v in extra.items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                for i in range(len(payload)):
                    self.wfile.write(payload[i:i + 1])
                    self.wfile.flush()
                    time.sleep(0.1)
        elif p == "/hang":
            time.sleep(120)  # accept request, never respond
        elif p == "/stall":
            # send headers, then stall mid-body
            self.send_response(200)
            self.send_header("Content-Length", "100000")
            self.send_header("Content-Type", "application/pdf")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(b"%PDF-1.4\n")
                self.wfile.flush()
                time.sleep(120)
        elif p.startswith("/trickle/"):
            secs = min(int(p.rsplit("/", 1)[1]), 300)
            n = secs * 10
            self.send_response(200)
            self.send_header("Content-Length", str(n))
            self.send_header("Content-Type", "application/pdf")
            self.end_headers()
            if self.command != "HEAD":
                for _ in range(n):
                    self.wfile.write(b"A")
                    self.wfile.flush()
                    time.sleep(0.1)
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
