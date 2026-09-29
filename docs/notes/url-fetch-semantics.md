# URL fetch semantics (pdftract `.url` input)

Supports the `.url`-fetch probe children of umbrella pdfswift-41c4e001: how a
pdftract binary behaves when `extract <INPUT>` is handed an `http://` /
`https://` URL instead of a file path, and what the Swift SDK must mirror.
This file records the controlled-endpoint harness and the probe-target binary
identity; the harness itself lives in `probes/`.

No released pdftract build can perform a remote fetch today (see
[Probe-target binary](#probe-target-binary)), so current probes stop at the
feature gate. The harness below is verified end-to-end with curl and is ready
for the moment a remote-enabled build exists.

## Probe harness

Everything is in `docs/notes/probes/`. One Python process serves every plain
HTTP mode (and the same routes again under TLS when given a cert/key); a
second process is the logging forward proxy; a shell script generates the
three TLS certificates; a fourth script demonstrates every mode with curl and
exits nonzero on any failure.

| File | Role |
|---|---|
| `probes/server.py` | all endpoint modes, selected by URL path (JSONL request log) |
| `probes/proxy.py` | minimal forwarding proxy for `HTTP_PROXY`/`HTTPS_PROXY`, logs absolute-form requests and CONNECT targets |
| `probes/make-certs.sh` | openssl-generated self-signed / expired / hostname-mismatch certs |
| `probes/verify-harness.sh` | starts every endpoint, runs 27 curl checks, tears down |
| `probes/fixtures/mini.pdf` | 1.4 KiB single-page fixture served by the PDF routes |

Each mode starts with a single command (run from `docs/notes/probes/`):

```bash
# plain HTTP, every route (port 18765)
python3 server.py 18765 /tmp/http.jsonl fixtures/mini.pdf

# TLS variants — same routes, wrapped with the named cert
python3 server.py 18443 /tmp/tls_ss.jsonl fixtures/mini.pdf certs/self-signed.pem certs/self-signed.key
python3 server.py 18444 /tmp/tls_ex.jsonl fixtures/mini.pdf certs/expired.pem     certs/expired.key
python3 server.py 18455 /tmp/tls_mi.jsonl fixtures/mini.pdf certs/mismatch.pem    certs/mismatch.key

# logging forward proxy (port 18888)
python3 proxy.py 18888 /tmp/proxy.jsonl
```

Certificates are generated once with `bash make-certs.sh` (default output
`certs/`; the script probes for a working openssl binary and handles this
box's shim/nix-store quirks itself).

### Modes and expected misbehavior

Every request (method, path, headers) is appended as one JSONL line to the
log file, so a probe can assert exactly what the client sent.

| Mode | Route | Observable behavior |
|---|---|---|
| happy path | `/ok.pdf` | 200, fixture, `Accept-Ranges: bytes` |
| connect-delay | `/slow/connect/<MS>` | TCP accept is instant (kernel backlog); server stays silent `<MS>` ms before the first response byte → time-to-first-byte stall. A true connect-phase hang (SYN dropped) needs no server: use blackhole address `10.255.255.1` |
| body-delay | `/slow/body/<MS>` | headers + first body byte immediately, then `<MS>` ms silence, then the rest → mid-body stall |
| redirect chain | `/r/<N>` | `<N>`-hop 302 chain ending at `/ok.pdf` (`/r/1` lands immediately) |
| redirect loop | `/loop` | infinite 302 to itself — client redirect-limit behavior |
| scheme downgrade | `/tlsredir` | 302 to an absolute `http://` URL (meaningful on a TLS port) |
| TLS untrusted root | port 18443 | self-signed `CN=localhost` — name matches, root is untrusted. NOTE: pinning the server cert via `--cacert` makes it its own trust anchor and it verifies; the misbehavior shows against the system trust store |
| TLS expired | port 18444 | validity 2020-01-01..2021-01-01 |
| TLS hostname mismatch | port 18455 | well-formed SAN `DNS:wrong.example.com` only |
| oversized | `/big/<MB>` (cap 64), `/big.pdf` | valid single-page PDF padded to `<MB>` MiB / 5 MiB |
| content type | `/plain.pdf`, `/octet.pdf`, `/notype.pdf`, `/ctype/<TYPE>` | fixture with wrong / octet-stream / missing / arbitrary `Content-Type` |
| ranges | `/noranges.pdf` | no `Accept-Ranges` header |
| HEAD-less | `/nohead` | `HEAD` → 405, `GET` → 200 |
| truncated stall | `/stall` | `Content-Length: 100000`, sends 9 bytes, stalls 120 s |
| silent hang | `/hang` | accepts request, never responds (120 s) |
| empty body | `/zero.pdf` | 200, zero bytes |
| statuses | `/404` `/401` `/403` `/500` `/503` | fixed error statuses (`/401` sends `WWW-Authenticate`) |
| basic auth | `/auth.pdf` | 200 only with `Authorization: Basic` of `user:pass` (build the header at runtime, e.g. `printf 'user:pass' \| base64`) |
| header echo | `/echo` | 200 JSON echo of received headers |

### Proxy

```bash
python3 proxy.py 18888 /tmp/proxy.jsonl
HTTP_PROXY=http://127.0.0.1:18888 curl -s http://127.0.0.1:18765/ok.pdf     # absolute-form, logged
HTTPS_PROXY=http://127.0.0.1:18888 curl -s --cacert certs/self-signed.pem \
    https://127.0.0.1:18443/ok.pdf                                           # CONNECT, target logged
```

Absolute-form requests are logged with their full header set and re-issued
origin-form at the origin; CONNECT tunnels are logged by target and relayed
blindly (the tunneled TLS bytes are opaque by design).

### Demonstrating every mode

```bash
bash verify-harness.sh
```

starts the plain server, the three TLS servers, and the proxy in a scratch
dir, runs 27 checks (delay knobs ≥ 1.15 s wall time, `/r/6` → 302 → `/r/5`
and follows to fixture, loop abort with curl exit 47, each TLS server serves
under `-k` and fails verification the intended way with exit 60, self-signed
accepted when pinned, proxy forwards + logs both shapes, `/big/2` ≥ 2 MiB,
arbitrary content type echoed, all five error statuses, basic auth accepted
with `user:pass` and rejected with wrong credentials, JSONL log captures
method/path/User-Agent), and prints `ALL CHECKS PASSED` on success.

### Prior salvage (probe-tmp, 2026-09-29)

The earlier capture sets preserved in
`~/scratch/pdfswift-51d6bc44/probe-salvage-from-workspace-20260929/probe-tmp/`
did not exercise fetch semantics:

- the P/E-series runs (released v1.2.0) all exited 2 at the `remote` feature
  gate before any I/O;
- the D-series runs (`~/.cargo/bin/pdftract`, incl. the 6-hop
  `out_D05-dev-6hops.stderr`) were invoked **without the `extract`
  subcommand** — every capture is a clap "unrecognized subcommand" usage
  error, not network behavior.

Treat those files as evidence that earlier attempts were invocations-errors;
the harness above supersedes them.

## Probe-target binary

**Released build (preferred), confirmed — but it cannot fetch.**

| Property | Value |
|---|---|
| Release | Forgejo `jedarden/pdftract` tag `v1.2.0` (published 2026-09-29, the only release; the release line the Swift SDK 1.2.0 generation targets) |
| Artifact | `pdftract-v1.2.0-x86_64-unknown-linux-musl.tar.gz`, sha256 `f86d7274e89aa22d1faa13db8ab900344c4cd6fedc52e444094512f7d33152fa` (matches the release's `SHA256SUMS`) |
| Binary | `pdftract` (extracted), sha256 `54d47f04185be96481638f7a414c68e8a533e5b795a1f841384df4326aa25481` |
| Local copy | `/home/coding/scratch/pdfswift-25c6467c/pdftract-v1.2.0-x86_64-unknown-linux-musl/pdftract` — byte-identical to the release (same sha256) |
| Version string | `pdftract 0.1.0` (`--version` and `doctor` both report `0.1.0`; the v1.2.0 tag carries a 0.1.0 crate version — record both when matching SDK compat) |
| Remote fetch | **not supported**: `extract http://127.0.0.1:18765/ok.pdf` → exit 2, `Remote sources require the 'remote' feature to be enabled — Build pdftract with: --features remote` |

Fallback candidate `~/.cargo/bin/pdftract` (local build 2026-08-25, sha256
`ac1a3d951b44bc7a70616d1597bf8fe7db30d908cb238ceaaef3943ed7dd3432`) has the
identical limitation, so per the bead's condition ("acceptable only if it
supports the `.url` input source") it does not qualify either.

**Consequence for the probe children:** every `.url` probe currently
deterministically exits 2 at the feature gate — no network I/O happens, so
the harness's network misbehaviors cannot be observed through pdftract yet.
The blocking prerequisite is a pdftract build with `--features remote`
(either a new release or a local build). The harness above is the verified
endpoint side of those probes; re-run
`<binary> extract http://127.0.0.1:18765/<mode> --ndjson` against it once a
remote-enabled binary exists, with the JSONL request logs as the
client-behavior evidence.
