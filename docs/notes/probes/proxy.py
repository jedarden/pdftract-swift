#!/usr/bin/env python3
"""Minimal logging forward proxy for pdftract HTTP(S)_PROXY probe tests.

Handles the two shapes an HTTP client uses a proxy for:

  * absolute-form requests   GET http://host:port/path HTTP/1.1  (HTTP_PROXY)
  * CONNECT host:port        tunnel, then TLS inside             (HTTPS_PROXY)

Every request is logged as one JSONL line to LOGFILE before being forwarded,
so probes can assert exactly what reached the proxy (method, target, and for
absolute-form requests the full header set). For CONNECT tunnels the target
is logged; the tunneled bytes themselves are opaque and are relayed blindly.

Usage (single command):
    python3 proxy.py 18888 proxy.jsonl
Then, in another shell:
    curl -x http://127.0.0.1:18888 http://127.0.0.1:18765/ok.pdf
    curl -x http://127.0.0.1:18888 --cacert certs/self-signed.pem https://127.0.0.1:18443/ok.pdf
"""
import json
import select
import socket
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18888
LOG = sys.argv[2] if len(sys.argv) > 2 else "proxy.jsonl"

_log_lock = threading.Lock()


def log(entry):
    entry["t"] = time.time()
    with _log_lock, open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")


def read_request_line_and_headers(sock):
    """Read one CRLF-terminated request head. Returns (line, headers, leftover)."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            return None, {}, b""
        buf += chunk
        if len(buf) > 1048576:
            return None, {}, b""
    head, _, leftover = buf.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    return lines[0].decode("latin-1"), _parse_headers(lines[1:]), leftover


def _parse_headers(lines):
    headers = {}
    for line in lines:
        if b":" in line:
            k, _, v = line.partition(b":")
            headers[k.strip().decode("latin-1")] = v.strip().decode("latin-1")
    return headers


def relay(a, b):
    """Pump bytes a->b and b->a until either side closes."""
    sockets = [a, b]
    try:
        while sockets:
            readable, _, _ = select.select(sockets, [], [], 60)
            if not readable:
                continue
            for s in readable:
                data = s.recv(65536)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except OSError:
        pass


def handle_forward(client, method, target, headers, head_line, leftover):
    """Absolute-form request: re-issue it origin-form at the origin."""
    log({"type": "forward", "request_line": head_line, "target": target,
         "headers": headers})
    rest = target.split("://", 1)[1]
    hostport = rest.split("/", 1)[0]
    host, _, port = hostport.partition(":")
    port = int(port or 80)
    path = "/" + rest.split("/", 1)[1] if "/" in rest else "/"
    try:
        upstream = socket.create_connection((host, port), timeout=10)
    except OSError as exc:
        body = b"proxy upstream connect failed: " + str(exc).encode()
        client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: %d\r\n"
                       b"Connection: close\r\n\r\n%s" % (len(body), body))
        client.close()
        return
    body_len = int(headers.get("Content-Length", "0") or 0)
    payload = leftover
    while len(payload) < body_len:
        chunk = client.recv(65536)
        if not chunk:
            break
        payload += chunk
    req = ("%s %s HTTP/1.1\r\n" % (method, path)).encode("latin-1")
    for k, v in headers.items():
        if k.lower() in ("proxy-connection", "proxy-authorization"):
            continue
        req += ("%s: %s\r\n" % (k, v)).encode("latin-1")
    req += b"Connection: close\r\n\r\n"
    upstream.sendall(req + payload[:body_len])
    # stream the upstream response back verbatim
    try:
        while True:
            data = upstream.recv(65536)
            if not data:
                break
            client.sendall(data)
    except OSError:
        pass
    upstream.close()
    client.close()


def handle_connect(client, hostport, headers, head_line):
    """CONNECT tunnel: log, acknowledge, then blind relay."""
    log({"type": "connect", "request_line": head_line, "target": hostport,
         "headers": headers})
    host, _, port = hostport.partition(":")
    try:
        upstream = socket.create_connection((host, int(port)), timeout=10)
    except OSError as exc:
        client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: %d\r\n"
                       b"Connection: close\r\n\r\n" % len(str(exc).encode())
                       + str(exc).encode())
        client.close()
        return
    client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    relay(client, upstream)
    upstream.close()
    client.close()


def handle(client):
    try:
        head_line, headers, leftover = read_request_line_and_headers(client)
        if not head_line:
            client.close()
            return
        parts = head_line.split()
        method, target = parts[0], parts[1]
        if target.startswith("http://") or target.startswith("https://"):
            handle_forward(client, method, target, headers, head_line, leftover)
        elif method == "CONNECT":
            handle_connect(client, target, headers, head_line)
        else:
            # origin-form request: not a proxy request shape; log and reject
            log({"type": "unexpected", "request_line": head_line,
                 "headers": headers})
            client.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n"
                           b"Connection: close\r\n\r\n")
            client.close()
    except (OSError, ValueError, IndexError):
        try:
            client.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(64)
    print("proxy listening on 127.0.0.1:%d, logging to %s" % (PORT, LOG),
          flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
