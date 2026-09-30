# URL fetch semantics (pdftract `.url` input)

Supports the `.url`-fetch probe children of umbrella pdfswift-41c4e001: how a
pdftract binary behaves when `extract <INPUT>` is handed an `http://` /
`https://` URL instead of a file path, and what the Swift SDK must mirror.
This file records the controlled-endpoint harness and the probe-target binary
identity; the harness itself lives in `probes/`.

No released pdftract build can perform a remote fetch today (see
[Probe-target binary](#probe-target-binary)); the timeout measurements in
[Timeouts](#timeouts-measured-remote-enabled-build) used a local
`--features remote` build of the same v1.2.0 tag. The harness below is
verified end-to-end with curl, and the `.url` probes against the
remote-enabled build are recorded in the measured sections below
([Timeouts](#timeouts-measured-remote-enabled-build),
[TLS verification](#tls-verification-measured-remote-enabled-build),
[Proxy handling](#proxy-handling-measured-remote-enabled-build),
[Redirects](#redirects-measured-remote-enabled-build)).

## Probe harness

Everything is in `docs/notes/probes/`. One Python process serves every plain
HTTP mode (and the same routes again under TLS when given a cert/key); a
second process is the logging forward proxy; a shell script generates the
three TLS certificates; a fourth script exercises the delay, redirect, TLS,
proxy, size, content-type, status, auth, HEAD-conformance, trickle, and
Range/206 modes end-to-end with curl (44 checks) and exits nonzero on any
failure.

| File | Role |
|---|---|
| `probes/server.py` | all endpoint modes, selected by URL path (JSONL request log) |
| `probes/proxy.py` | minimal forwarding proxy for `HTTP_PROXY`/`HTTPS_PROXY`, logs absolute-form requests and CONNECT targets |
| `probes/make-certs.sh` | openssl-generated self-signed / expired / hostname-mismatch certs |
| `probes/verify-harness.sh` | starts every endpoint, runs 44 curl checks, tears down |
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
| happy path | `/ok.pdf` | 200 — or 206 + `Content-Range` for a ranged GET — fixture body, `Accept-Ranges: bytes` |
| connect-delay | `/slow/connect/<MS>` | TCP accept is instant (kernel backlog); server stays silent `<MS>` ms before the first response byte → time-to-first-byte stall. Ranged GETs are honored (206) after the same stall. A true connect-phase hang (SYN dropped) needs no server: use blackhole address `10.255.255.1` |
| body-delay | `/slow/body/<MS>` | headers + first body byte immediately, then `<MS>` ms silence, then the rest → mid-body stall. Ranged GETs get 206 + the sliced body with the same first-byte-then-stall phase. HEAD gets headers only — a stray body byte on HEAD poisons the keep-alive connection a HEAD-first client reuses |
| range-path body stall | `/slow/rangestall/<MS>` | `/slow/body` on a 206-capable route: headers (incl. `Accept-Ranges`) instant, GET body stalls `<MS>` ms after the first byte — separates the read-phase timeout from the HEAD/TTFB phase |
| trickle | `/trickle/<SECONDS>` (cap 300) | headers + `Content-Length` immediately, then 1 byte per 100 ms for `<SECONDS>` s total → long total, tiny inter-byte gaps: the overall-timeout vs idle-timeout separator |
| range trickle | `/rangetrickle/<SECONDS>` (cap 300) | `/trickle` on a 206-capable route: long total, 1 byte per 100 ms, a Range slice trickles at the same rate — pairs with `/slow/rangestall` to separate overall- from idle-timeout through the Range source |
| redirect chain | `/r/<N>` | `<N>`-hop 302 chain ending at `/ok.pdf` (`/r/1` lands immediately) |
| redirect loop | `/loop` | infinite 302 to itself — client redirect-limit behavior |
| scheme downgrade | `/tlsredir` | 302 to an absolute `http://` URL (meaningful on a TLS port) |
| TLS untrusted root | port 18443 | self-signed `CN=localhost` — name matches, root is untrusted. NOTE: pinning the server cert via `--cacert` makes it its own trust anchor and it verifies; the misbehavior shows against the system trust store |
| TLS expired | port 18444 | validity 2020-01-01..2021-01-01 |
| TLS hostname mismatch | port 18455 | well-formed SAN `DNS:wrong.example.com` only |
| oversized | `/big/<MB>` (cap 64), `/big.pdf` | valid single-page PDF padded to `<MB>` MiB / 5 MiB |
| content type | `/plain.pdf`, `/octet.pdf`, `/notype.pdf`, `/ctype/<TYPE>` | fixture with wrong / octet-stream / missing / arbitrary `Content-Type` |
| ranges | `/noranges.pdf` | no `Accept-Ranges` header; a ranged GET is answered 200 full-body — the negative control. The range-capable routes (`/ok.pdf`, `/slow/*`, `/rangetrickle/*`) answer a satisfiable `Range: bytes=a-b` with 206 + `Content-Range` + the clamped slice (416 + `Content-Range: bytes */<total>` wholly past the end) |
| HEAD-less | `/nohead` | `HEAD` → 405, `GET` → 200 |
| truncated stall | `/stall` | `Content-Length: 100000`, sends 9 bytes, stalls 120 s (HEAD: headers only) |
| silent hang | `/hang` | accepts request, never responds (120 s) |
| empty body | `/zero.pdf` | 200, zero bytes |
| statuses | `/404` `/401` `/403` `/500` `/503` | fixed error statuses (`/401` sends `WWW-Authenticate`) |
| basic auth | `/auth.pdf` | 200 only with `Authorization: Basic` of `user:pass` (build the header at runtime, e.g. `printf 'user:pass' \| base64`) |
| header echo | `/echo` | 200 JSON echo of received headers |

### Per-mode demonstration

One curl per mode against the ports above (server/proxy started as shown,
certs generated once). Each command shows the documented misbehavior; exit
codes quoted are curl's.

```bash
# happy path — 200 fixture, Accept-Ranges: bytes
curl -sD- -o /dev/null http://127.0.0.1:18765/ok.pdf

# connect-delay: connect instant, first response byte after the knob
curl -s -o /dev/null -w 'conn=%{time_connect} ttfb=%{time_starttransfer}\n' \
    http://127.0.0.1:18765/slow/connect/1200        # conn ~0, ttfb ~1.2 s

# body-delay: headers + first byte instant, total carries the knob
curl -s -o /dev/null -w 'ttfb=%{time_starttransfer} total=%{time_total}\n' \
    http://127.0.0.1:18765/slow/body/1200           # ttfb ~0, total ~1.2 s

# true connect-phase hang — no server involved (SYN dropped, exit 28)
curl -s --connect-timeout 4 -o /dev/null http://10.255.255.1/ok.pdf

# redirect chain: exactly N hops down to fixture bytes
curl -sL -o /dev/null -w '%{num_redirects} %{http_code}\n' http://127.0.0.1:18765/r/6   # "6 200"

# redirect loop: aborts at the redirect limit (exit 47)
curl -sL --max-redirs 3 -o /dev/null http://127.0.0.1:18765/loop

# scheme downgrade (on a TLS port): 302 to an absolute http:// URL
curl -sk -o /dev/null -w '%{http_code} %{redirect_url}\n' https://127.0.0.1:18443/tlsredir

# TLS misbehavior — all three reject with curl exit 60
curl -s https://127.0.0.1:18443/ok.pdf                                  # untrusted root (system trust)
curl -s --cacert certs/expired.pem  https://127.0.0.1:18444/ok.pdf      # certificate has expired
curl -s --cacert certs/mismatch.pem https://127.0.0.1:18455/ok.pdf      # no subject name matches

# oversized: valid single-page PDF padded to the knob (cap 64 MiB)
curl -s -o /dev/null -w '%{size_download}\n' http://127.0.0.1:18765/big/3    # ≥ 3 MiB

# content-type variants (fixture bytes in every case)
curl -sI http://127.0.0.1:18765/plain.pdf  | grep -i content-type   # text/plain
curl -sI http://127.0.0.1:18765/octet.pdf  | grep -i content-type   # application/octet-stream
curl -sI http://127.0.0.1:18765/notype.pdf | grep -ci content-type  # 0 (header absent)
curl -s -o /dev/null -w '%{content_type}\n' http://127.0.0.1:18765/ctype/application/x-vnd.pdftract-probe

# Range/206: range-capable routes answer a ranged GET 206 + Content-Range
# (416 when wholly past the end); the TLS listener behaves identically
curl -s  -o /dev/null -D- -H 'Range: bytes=0-99' http://127.0.0.1:18765/ok.pdf
#   -> HTTP/1.1 206 Partial Content / Content-Range: bytes 0-99/1412
curl -sk -o /dev/null -D- -H 'Range: bytes=0-99' https://127.0.0.1:18443/slow/body/200
#   -> 206 with the same first-byte-then-stall phase as the unranged GET
curl -s  -o /dev/null -D- -H 'Range: bytes=0-99' http://127.0.0.1:18765/noranges.pdf
#   -> 200 (negative control: Range ignored, no Accept-Ranges)

# ranges: no Accept-Ranges header
curl -sI http://127.0.0.1:18765/noranges.pdf | grep -ci accept-ranges    # 0

# HEAD-less: HEAD 405, GET 200
curl -s -o /dev/null -w '%{http_code}\n' -I http://127.0.0.1:18765/nohead
curl -s -o /dev/null -w '%{http_code}\n'    http://127.0.0.1:18765/nohead

# truncated stall: promises 100000 bytes, sends 9, stalls — cut it off
curl -s --max-time 3 http://127.0.0.1:18765/stall | wc -c                # 9

# silent hang: request accepted, no response (exit 28 at --max-time)
curl -s --max-time 2 -o /dev/null http://127.0.0.1:18765/hang

# empty body: 200, zero bytes
curl -s -o /dev/null -w '%{http_code} %{size_download}\n' http://127.0.0.1:18765/zero.pdf

# error statuses
for s in 404 401 403 500 503; do
  curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:18765/$s"
done

# basic auth: 200 with the runtime-built header, 401 without
curl -s -H "Authorization: Basic $(printf 'user:pass' | base64)" \
    -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18765/auth.pdf

# header echo: exactly what the server received
curl -s http://127.0.0.1:18765/echo | python3 -m json.tool
```

### Proxy

```bash
python3 proxy.py 18888 /tmp/proxy.jsonl
HTTP_PROXY=http://127.0.0.1:18888 curl -s http://127.0.0.1:18765/ok.pdf     # absolute-form, logged
HTTPS_PROXY=http://127.0.0.1:18888 curl -s --cacert certs/self-signed.pem \
    https://127.0.0.1:18443/ok.pdf                                           # CONNECT, target logged
```

Absolute-form requests are logged with their full header set and re-issued
origin-form at the origin; CONNECT tunnels are logged by target and relayed
blindly (the tunneled TLS bytes are opaque by design). An origin-form request
(i.e. a client *not* configured to use the proxy) is answered 400 and logged
as `"type": "unexpected"`, so a probe can also assert that proxy env vars
actually took effect on the client.

### End-to-end harness check

```bash
bash verify-harness.sh
```

starts the plain server, the three TLS servers, and the proxy in a scratch
dir, runs 44 checks (connect-delay asserts the phase split — connect instant,
ttfb ≥ 1.15 s — while body-delay asserts the inverse — ttfb fast, total
≥ 1.15 s; the two hand-rolled-header routes are additionally asserted
HEAD-conformant by replaying a HEAD-first client: HEAD, then GET on the same
connection, expecting a clean `HTTP/1.1 200 OK` status line and not stray
body bytes; `/trickle/1` serves exactly 10 bytes over ≥ 0.9 s proving the
knob is the total duration at a fixed 1-byte/100ms rate; all five
range-capable routes — `/ok.pdf`, `/slow/connect`, `/slow/body`,
`/slow/rangestall`, `/rangetrickle` — answer `Range: bytes=0-99` with `206`
and a `Content-Range` clamped to the true resource length (the
`/rangetrickle` stream clamps to its 10 bytes) on both the plain and the TLS
listener, `/noranges.pdf` keeps answering a ranged GET `200` with no
`Accept-Ranges`, and the `/ok.pdf` 206 slice delivers exactly its promised
100 bytes; `/r/0` `/r/2` `/r/6` each exactly N redirects down to fixture bytes,
plus `/r/6` → 302 → `/r/5`; loop abort with curl exit 47 under
`--max-redirs 3`; each TLS server serves under `-k` and fails verification the
intended way with exit 60 — the self-signed case against the system trust
store, since `--cacert` pinning would make it its own trust anchor; self-signed
accepted when pinned; proxy forwards and logs both absolute-form and CONNECT
shapes; `/big/2` and `/big/4` each honoring their own MiB floor, strictly
increasing, head and tail PDF-valid; two arbitrary content types including a
slash subtype echoed with fixture bytes via GET; all five error statuses;
basic auth accepted with `user:pass` and rejected with wrong credentials;
JSONL log captures method/path/User-Agent), and prints `ALL CHECKS PASSED`
on success. The modes the script does not automate — `/tlsredir`, `/stall`,
`/hang`, `/zero.pdf`, `/nohead`, `/noranges.pdf`, the fixed content-type
routes, `/echo`, and the blackhole connect hang — are covered by the per-mode
curl one-liners above.

### Harness readiness — timeout-probe foundation (re-verified 2026-09-30)

The five routes the timeout probes depend on were re-exercised fresh on
2026-09-30 and the probe binary re-confirmed, before any further probe work.
No timeout claims are (re)made here — [Timeouts](#timeouts-measured-remote-enabled-build)
remains the measured record. Session raw captures:
`~/scratch/pdfswift-dc382d4c/` (`captures.txt`, `verify-harness.out`,
server JSONL logs, probe-binary outputs).

Server started exactly as documented above (plain listener 18765, TLS
listener 18443, JSONL logs in the session scratch dir; ports pre-cleared of
the previous session's listeners). Each control below is verbatim; `curl`
exit codes quoted are curl's.

| Route | Control command (run from `probes/`) | Observed |
|---|---|---|
| `/ok.pdf` | `curl -sD- -o /dev/null http://127.0.0.1:18765/ok.pdf` | `HTTP/1.1 200 OK`, `Content-Length: 1412`, `Content-Type: application/pdf`, `Accept-Ranges: bytes`, exit 0 |
| `/ok.pdf` ranged | `curl -sD- -o /dev/null -H 'Range: bytes=0-99' http://127.0.0.1:18765/ok.pdf` | `HTTP/1.1 206 Partial Content`, `Content-Range: bytes 0-99/1412`, 100-byte body, exit 0 |
| `/slow/connect/1500` | `curl -s -o /dev/null -w 'conn=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total} code=%{http_code}\n' http://127.0.0.1:18765/slow/connect/1500` | `conn=0.000063 ttfb=1.500585 total=1.500608 code=200`, exit 0 — connect instant, TTFB carries the knob |
| `/slow/body/1500` | `curl -s -o /dev/null -w 'ttfb=%{time_starttransfer} total=%{time_total} code=%{http_code}\n' http://127.0.0.1:18765/slow/body/1500` | `ttfb=0.000478 total=1.500670 code=200`, exit 0 — headers+first byte instant, total carries the knob |
| `/hang` | `curl -s --max-time 2 -o /dev/null -w 'code=%{http_code} size=%{size_download}\n' http://127.0.0.1:18765/hang` | `code=000 size=0`, exit 28 — no response byte ever arrives |
| `/rangetrickle/1` | `curl -s -o /dev/null -D- -w 'size=%{size_download} total=%{time_total} code=%{http_code}\n' http://127.0.0.1:18765/rangetrickle/1` | `200`, `Content-Length: 10`, `Accept-Ranges: bytes`, `size=10 total=0.902197`, exit 0 — the 1 byte/100 ms pacing |
| `/rangetrickle/1` slice | `curl -s -o /dev/null -D- -w 'size=%{size_download} total=%{time_total}\n' -H 'Range: bytes=0-4' http://127.0.0.1:18765/rangetrickle/1` | `206`, `Content-Range: bytes 0-4/10`, `size=5 total=0.401032`, exit 0 — the slice trickles at the same rate |

Full harness check re-run the same session: `bash verify-harness.sh` →
exit 0, 44 `PASS` lines, `== summary: 0 failure(s) ==` / `ALL CHECKS PASSED`,
including all four range-capable timeout routes (`/ok.pdf`, `/slow/connect`,
`/slow/body`, `/rangetrickle`) answering a ranged GET `206` on both the
plain and TLS listeners. (`/hang` is in the script's non-automated set; the
curl control above covers it.)

#### Probe binary re-confirmation (2026-09-30)

| Check | Command | Observed |
|---|---|---|
| sha256 | `sha256sum ~/scratch/pdfswift-1d763709/probe-tmp/bin/pdftract-remote` | `07f95264e59395a30ae622e42c7bd5f882583a20091a89c3ba665c9f16c48e0d` — identical to the 2026-09-29 record, so the binary is reused unchanged |
| Version | `pdftract-remote --version` | `pdftract 0.1.0`, exit 0 |
| Remote-enabled (functional) | `timeout 90 pdftract-remote extract http://127.0.0.1:18765/ok.pdf` | exit 0, 3241-byte JSON extraction, empty stderr |
| Released-binary negative control | `sha256sum` + `timeout 90 …/pdfswift-25c6467c/pdftract-v1.2.0-x86_64-unknown-linux-musl/pdftract extract http://127.0.0.1:18765/ok.pdf` | sha256 `54d47f04185be96481638f7a414c68e8a533e5b795a1f841384df4326aa25481`, exit 2, `Error: Remote sources require the 'remote' feature to be enabled` — confirmed unusable for fetch probes |

Provenance of the probe binary (corroborated 2026-09-30):

- Source tree `~/scratch/pdfswift-1d763709/probe-tmp/pdftract-v120-src` sits
  at commit `f4f6d6a81063492eee2150307efd493e5c4426ea` (`git rev-parse HEAD`;
  `git describe --tags` → `v1.2.0`, clean — on the tag).
- That commit is the *published* tag: `git ls-remote
  https://github.com/jedarden/pdftract refs/tags/v1.2.0^{}` →
  `f4f6d6a81063492eee2150307efd493e5c4426ea` (GitHub mirror of the Forgejo
  source of truth).
- The tag tree carries the feature: `remote = ["dep:ureq",
  "pdftract-core/remote"]` (`crates/pdftract-cli/Cargo.toml:133`).
- The binary is consistent with that tree: `strings` on it shows the crate's
  own paths (`crates/pdftract-cli/src/codegen.rs`,
  `crates/pdftract-cli/src/doctor/checks/network.rs`,
  `crates/pdftract-cli/src/remote_metrics.rs`, …), all present in the tag
  tree, plus the remote-only surface (`--header` "Custom HTTP headers for
  remote sources", `RemoteFetchInterruptedError`), and the functional fetch
  above succeeds — impossible on a remote-disabled build (exit 2, as the
  negative control shows).
- Caveat recorded for honesty: the preserved
  `probe-tmp/build-cli-remote.log` is an earlier *failed* build attempt
  against `~/pdftract` (E0277/E0599, 2026-09-29 12:06), not the log of the
  successful build that produced `bin/pdftract-remote` (12:16); the
  provenance above rests on the tree/tag/binary evidence listed.

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

Re-verified 2026-09-29 against the live Forgejo release: v1.2.0 is still the
only release (published 2026-09-29T07:04:42Z), the `SHA256SUMS` entry and the
downloaded tarball both hash to the value above, the tarball's size matches
the release asset byte count, and a fresh extraction of the tarball reproduces
the binary sha256 exactly. At that re-verification no `--features remote` build
existed, released or local; one was produced later the same day (below).

**Consequence for the probe children, resolved 2026-09-29:** the released
binary still gates at exit 2, but a local v1.2.0 + `--features remote` build
of the same tree was produced and the probes have been run against it —
measured results in [Timeouts](#timeouts-measured-remote-enabled-build).

## Timeouts (measured, remote-enabled build)

Measured 2026-09-29 against a local remote-enabled build of the v1.2.0 tag
(the released binary above still stops at the feature gate): `pdftract-remote`,
`--version` `pdftract 0.1.0`, sha256
`07f95264e59395a30ae622e42c7bd5f882583a20091a89c3ba665c9f16c48e0d`, scratch
provenance `~/scratch/pdfswift-1d763709/probe-tmp/bin/` (raw captures
`connect-probes.attempt1.txt`, `connect-probes.rerun.txt`, `read-probes.txt`,
`connect-stderr/`, `read-stderr/` in the same scratch tree). Method for every probe:
`timeout 90 pdftract-remote extract <url>` — the external cap exists so an
unbounded client hang cannot wedge the probe — wall-clock via `date +%s%3N`,
stderr captured verbatim, harness `probes/server.py` serving 127.0.0.1:18765
(HTTP) and 127.0.0.1:18443 (TLS, self-signed) with a JSONL request log.

**Verdict — plain HTTP:** the TCP connect gets a ~30 s deadline; everything
after connect gets a ~10 s per-request deadline that surfaces cleanly as an
error on the HEAD request; and that deadline does NOT bound the process — a
ranged GET whose body takes ≥ ~10 s is re-issued forever with the error
swallowed, so `extract` hangs with empty stderr until externally killed.
There is no effective read/stall timeout.
**HTTPS:** no timeout is observable — the self-signed-cert rejection ends the
request in ~8–9 ms, before any connect or read phase.

### Connect phase — HTTP

TTFB/response stall above the deadline — `/slow/connect/15000` (TCP accept
instant, server silent 15 s):

```bash
timeout 90 pdftract-remote extract http://127.0.0.1:18765/slow/connect/15000
```

Observed: wall 10328 ms, exit 1 — cut at ~10.3 s by the client, not by the
server (its silence ran 15 s). Server log: `HEAD /slow/connect/15000` at
t=…216.54 with no further request until t=…226.87, a 10.33 s gap matching the
client-side abort. Attempt 1 of the same probe: 10314 ms — within noise.
stderr (verbatim):

```
Error: Failed to open remote PDF source

Caused by:
    HEAD request failed: request timeout
```

Sub-timeout control — `/slow/connect/8000` (8 s stall):

```bash
timeout 90 pdftract-remote extract http://127.0.0.1:18765/slow/connect/8000
```

Observed: wall 16053 ms, exit 0, empty stderr — the client waited out the
full 8 s stall and completed the ranged extract (server log: HEAD at
t=…226.87 followed by its ranged GET at t=…234.87, exactly 8.00 s stall
survived). Baseline `/ok.pdf`: 53 ms, exit 0. So no sub-8 s cutoff exists;
the post-connect deadline sits between 8 s and 10.3 s, consistent with the
~10 s mechanism below.

### Connect phase — blackhole / SYN drop (HTTP)

A true connect-phase hang needs no server; 10.255.255.1 drops SYN:

```bash
timeout 90 pdftract-remote extract http://10.255.255.1/ok.pdf
```

Observed: wall 30035 ms, exit 1 — cut by the client's own deadline, not the
90 s cap (attempt 1: 30020 ms). stderr identical to the TTFB case above
(`HEAD request failed: request timeout`). So the TCP-connect phase has a
~30 s deadline: pdftract sets no connect-phase constant of its own (its
30 s `READ_TIMEOUT_SECS` applies only to the non-range fallback path, see
Mechanism), and the value matches ureq 2.12.1's built-in connect default
(`timeout_connect: Some(Duration::from_secs(30))`, ureq `src/agent.rs:256`),
which pdftract does not override.

### Connect-phase re-verification (2026-09-30)

All three connect-phase probes re-run fresh on 2026-09-30 against the same
binary (sha256 `07f95264…c48e0d` re-confirmed unchanged, so the 2026-09-29
evidence above is in force) and an identically-started harness (`server.py`
18765, JSONL log and per-probe captures in session scratch
`~/scratch/pdfswift-93a1b05e/`, ports pre-cleared, method unchanged). Values
reproduce:

| Probe | Fresh wall | Exit | stderr | Server-log gap |
|---|---|---|---|---|
| `/slow/connect/15000` | 10158 ms | 1 | identical to the verbatim block above | HEAD at t=…734.602, no further request until t=…744.761 — 10.159 s gap, no retry, abort inside the server's 15 s silence |
| `/slow/connect/8000` | 16055 ms | 0 | empty | HEAD at t=…744.761 → ranged GET at t=…752.761, the full 8.001 s stall survived |
| blackhole `10.255.255.1` | 30035 ms | 1 | identical to the verbatim block above | none — no server involved |

Across runs: `/slow/connect/15000` 10158 / 10314 / 10328 ms and blackhole
30020 / 30035 / 30035 ms, all exit 1; `/slow/connect/8000` 16053 / 16055 ms,
exit 0. The ~10 s post-connect deadline and the ~30 s TCP-connect deadline
both stand.

### Read / mid-body stall — HTTP

`/slow/body/<MS>` sends headers + first body byte immediately, then stalls
`<MS>` ms mid-body; HEAD is answered instantly, so the stall lands inside the
ranged-GET body read. Above the deadline — `/slow/body/15000`:

```bash
timeout 90 pdftract-remote extract http://127.0.0.1:18765/slow/body/15000
```

Observed: wall 90004 ms, exit 124 — killed by the EXTERNAL 90 s cap, not by
the client. **stderr: EMPTY — no error was ever surfaced.** Server log: HEAD
answered instantly at t=…076.893, then the identical ranged GET
(`Range: bytes=0-65535`) re-issued 8 times (nine requests logged) at
+10.13/+10.24 s spacing until the kill — a forever retry loop, ~10.2 s per
attempt, no backoff, no escalation.

Sub-deadline control — `/slow/body/5000`:

```bash
timeout 90 pdftract-remote extract http://127.0.0.1:18765/slow/body/5000
```

Observed: wall 5016 ms, exit 0, empty stderr, exactly one ranged GET (server
log). Stalls under ~10 s of total request time succeed cleanly; ~10 s or
above never complete.

No-response variant — `/hang` (accepts the request, never responds; the
server caps it at 120 s):

```bash
timeout 90 pdftract-remote extract http://127.0.0.1:18765/hang
```

Observed: wall 10243 ms, exit 1 — cut by the client's own ~10 s deadline, not
the 90 s cap and not the 120 s server cap. stderr identical to the TTFB case
above. Server log: exactly one HEAD, no retries — the HEAD-phase deadline
surfaces cleanly as an error, unlike the body phase. Observed minimum hang
duration for the no-response case: 10.2 s.

### Idle-gap vs total-time semantics

The post-connect deadline is TOTAL-TIME from request start, not idle-gap.
Separator: a continuously-trickling body whose inter-byte gaps (100 ms) are
far below any plausible idle threshold, but whose 20 s total exceeds the
deadline.

`/trickle/20` as planned is not runnable against this client — it answers
200 without `Accept-Ranges`, and the client refuses instantly (no timeout
measurable on that route):

```bash
timeout 90 pdftract-remote extract http://127.0.0.1:18765/trickle/20
```

Observed: wall 7 ms, exit 1. stderr (verbatim):

```
Error: Failed to download remote PDF

Caused by:
    Server does not support Range requests
```

Its purpose-built 206-capable twin, `/rangetrickle/20` (headers instantly,
then 1 byte per 100 ms for 20 s total):

```bash
timeout 90 pdftract-remote extract http://127.0.0.1:18765/rangetrickle/20
```

Observed: wall 90003 ms, exit 124 (external cap), stderr EMPTY. Server log:
the identical ranged GET re-issued 8 times at +10.00/+10.01 s spacing. A body
trickling continuously at 100 ms/byte was still cut at 10.0 s per attempt; an
idle-gap read timeout would have let the transfer complete at ~20 s. It never
does ⇒ the deadline is total-time, not idle-based.

### Read-phase re-verification (2026-09-30)

All four read-phase probes — `/slow/body/15000`, `/slow/body/5000`, `/hang`,
`/rangetrickle/20` — re-run fresh on 2026-09-30 against the same binary
(sha256 `07f95264…c48e0d` re-confirmed unchanged, so the 2026-09-29 evidence
above is in force) and an identically-started harness (`server.py` 18765,
JSONL log and per-probe captures in session scratch
`~/scratch/pdfswift-b78b894b/`, ports pre-cleared, method unchanged —
`timeout 90` external cap, wall via `date +%s%3N`, stderr verbatim).
Baseline `/ok.pdf` control: 107 ms, exit 0, empty stderr, 3241-byte
extraction. Values reproduce:

| Probe | Fresh wall | Exit | stderr | Server-log request sequence |
|---|---|---|---|---|
| `/slow/body/15000` | 90005 / 90011 ms | 124 (external cap) | **EMPTY (0 bytes)** | HEAD instant, then the identical ranged GET (`Range: bytes=0-65535`) 9× per run (initial + 8 re-issues) at +10.10–10.28 s spacing, no backoff, until the kill |
| `/slow/body/5000` | 5011 / 5012 ms | 0 | empty, 3241-byte extraction | HEAD + exactly one ranged GET; the full 5.02 s stall survived (next request 5.018 s after the HEAD) |
| `/hang` | 10352 / 10438 ms | 1 | identical to the verbatim block above | exactly one HEAD, no retry — the HEAD-phase deadline surfaced cleanly; next request 10.36 / 10.44 s after it |
| `/rangetrickle/20` | 90004 / 90011 ms | 124 (external cap) | **EMPTY (0 bytes)** | HEAD instant, ranged GET 9× per run (initial + 8 re-issues) at +10.00–10.02 s spacing, the continuously-trickling body cut mid-transfer every time |

Across runs: `/slow/body/15000` 90004 / 90005 / 90011 ms and
`/rangetrickle/20` 90003 / 90004 / 90011 ms, all exit 124 with 0-byte stderr;
`/slow/body/5000` 5011 / 5012 (fresh) vs 5016 ms, exit 0; `/hang` 10352 /
10438 (fresh) vs 10243 ms, exit 1. The read-phase findings stand: the ~10 s
agent deadline bounds the HEAD cleanly but never bounds a stalled or slow
ranged-GET body — the request is re-issued forever with the error swallowed
(unbounded `Interrupted`-retry, empty stderr), so the external 90 s cap, not
any client deadline, ends the process; and the continuously-trickling 206
transfer is still cut at ~10 s per attempt, confirming total-time rather than
idle-gap semantics.

### TLS — connect and read phases

TLS unusable with self-signed; timeout not observable. The binary trusts only
its compiled-in webpki-roots (ureq 2.12.1 / rustls 0.23.40; no
rustls-native-certs / native-tls in the lockfile), so `SSL_CERT_FILE` /
`SSL_CERT_DIR` are inert and the handshake fails before any phase whose
timeout could be measured — the read-stall phase over TLS is unreachable, not
merely unmeasured.

Probes run fresh 2026-09-30 against the same binary (sha256
`07f95264…c48e0d`) and an identically-started harness (`server.py` 18443 TLS,
method unchanged — `timeout 90` external cap, wall via `date +%s%3N`, stderr
verbatim); per-probe captures in session scratch
`~/scratch/pdfswift-0bc0fbd6/captures/`. The listener itself is healthy: an
`openssl s_client` handshake against 127.0.0.1:18443 completes (capture
`s_client-18443.txt`), ending `Verify return code: 18 (self-signed
certificate)`, and the served certificate is byte-identical to the committed
harness cert `docs/notes/probes/certs/self-signed.pem` (CN=localhost).

```bash
timeout 90 pdftract-remote extract https://127.0.0.1:18443/slow/connect/15000
timeout 90 pdftract-remote extract https://127.0.0.1:18443/slow/body/15000
timeout 90 pdftract-remote extract https://127.0.0.1:18443/ok.pdf
```

| Probe (2 runs each) | Wall | Exit | stderr |
|---|---|---|---|
| `/slow/connect/15000` | 9 / 8 ms | 1 | identical to the verbatim block below (100 bytes) |
| `/slow/body/15000` | 9 / 9 ms | 1 | identical (100 bytes) |
| `/ok.pdf` (control) | 9 / 8 ms | 1 | identical (100 bytes) |

stderr (verbatim; byte-identical across all six runs — captures
`tls_connect_15000_{a,b}.stderr`, `tls_body_15000_{a,b}.stderr`,
`tls_ok_control_{a,b}.stderr`):

```
Error: Failed to open remote PDF source

Caused by:
    HEAD request failed: connection interrupted
```

First measurement 2026-09-29 agrees: `tls-connect-stall` 7 ms,
`tls-read-stall` 7 ms, `tls-happy` 8 ms, all exit 1 (probe-tmp captures
`connect-probes.rerun.txt`, `read-probes.txt`, `smoke-remote-tls.stderr` —
the same 100-byte stderr).

Trust-knob inertness — pointing the standard OpenSSL env vars at the very
cert in play changes nothing (captures `tls_ok_sslcertfile.*`,
`tls_ok_sslcertdir.*`, `tls_connect_sslcertfile.*`):

```bash
timeout 90 env SSL_CERT_FILE=/home/coding/pdftract-swift/docs/notes/probes/certs/self-signed.pem \
  pdftract-remote extract https://127.0.0.1:18443/ok.pdf
timeout 90 env SSL_CERT_DIR=/home/coding/pdftract-swift/docs/notes/probes/certs \
  pdftract-remote extract https://127.0.0.1:18443/ok.pdf
timeout 90 env SSL_CERT_FILE=/home/coding/pdftract-swift/docs/notes/probes/certs/self-signed.pem \
  pdftract-remote extract https://127.0.0.1:18443/slow/connect/15000
```

Observed: wall 9 / 8 / 9 ms respectively, exit 1 in every case, the same
100-byte stderr. Across all nine TLS probes the server's JSONL request log
gained no pdftract line (its only entry is the harness's own curl smoke GET
`/ok.pdf`): every connection dies at the handshake, before any HTTP request
is issued.

Cert rejection precedes any connect- or read-phase stall. The listener
presents its certificate during the accept itself — `probes/server.py:383-385`
wraps the listening socket server-side, so the TLS handshake completes before
any route logic can stall (`/slow/connect` would otherwise hold 15 s) — and
the client fails in ~8–9 ms against that 15 s stall, happy path included. So
no HTTPS timeout value is derivable on this harness; the HTTP and HTTPS
columns are not comparable here.

### Mechanism (source-corroborated, v1.2.0 tree)

- `crates/pdftract-core/src/source/http_range.rs:26`
  `const CONNECT_TIMEOUT_SECS: u64 = 10` — misnamed: it is the overall
  per-request deadline, applied at `:132` as `ureq::AgentBuilder::timeout`
  on the agent used for BOTH the HEAD and every ranged GET. ureq 2.12.1's
  agent-wide timeout runs from request start through body read ⇒ the measured
  total-time semantics.
- ureq 2.12.1's un-overridden `timeout_connect` default is 30 s
  (`src/agent.rs:256`) — the observed ~30 s blackhole cut.
- `fetch_range` (`http_range.rs:297`) maps a body-read failure to
  `io::ErrorKind::Interrupted`; `read_range`/`read`/`prefetch` contain no
  retry loop, so the endless identical GETs are the std `Interrupted`-retry
  idiom (`Read::read_exact` et al. retry on `ErrorKind::Interrupted`)
  colliding with the per-request deadline: unbounded, no backoff, and the
  error is swallowed entirely (empty stderr at kill).
- `READ_TIMEOUT_SECS = 30` (`http_range.rs:29`) is the NON-range fallback
  full-download path (`download_to_temp_and_mmap_with_hook`, `:722`), not the
  ranged path.

**Defect statement:** any origin whose ranged-GET body takes longer than
~10 s total — a stalled server OR a legitimately slow/large transfer — hangs
`pdftract extract` indefinitely (unbounded retry loop, empty stderr; killed
externally at the 90 s probe cap after eight identical re-issues). The
HEAD/TTFB phase by contrast errors out cleanly at ~10 s (`HEAD request
failed: request timeout`), and the TCP-connect phase at ~30 s. Suggested fix
shape (future work): map body-read timeout to a non-`Interrupted` error kind
or add a bounded retry with escalation, and consider separating a true
idle/read timeout from the overall request deadline.

## Redirects (measured, remote-enabled build)

Measured 2026-09-30, two full runs, against the same remote-enabled build as
[Timeouts](#timeouts-measured-remote-enabled-build) (`pdftract-remote`,
sha256 `07f95264…c48e0d` re-confirmed unchanged immediately before probing).
Harness: the canonical `probes/server.py` on 127.0.0.1:18765 (its
`/r/<N>` exactly-N-redirect 302 chain, `/loop`, `/tlsredir`) plus a
session sidecar on 127.0.0.1:18766 for the redirect status codes and
Location shapes the canonical harness lacks —

```bash
python3 redirect-sidecar.py 18766 sidecar.jsonl \
  <repo>/docs/notes/probes/fixtures/mini.pdf
```

(`~/scratch/pdfswift-e1288f7a/redirect-sidecar.py`; serves the same fixture
bytes at `/fixture.pdf` with canonical `/ok.pdf` semantics — HEAD 200 +
`Accept-Ranges: bytes`, ranged GET 206 + `Content-Range` / 416 — plus the
routes `/s301` `/s302` `/s303` `/s307` `/s308` single redirects with a
relative Location, `/shost` absolute same-host+port, `/xport` absolute
same-host cross-port, `/xhost` absolute cross-host **and** cross-port,
`/noloc` a 302 with no Location header; every request JSONL-logged.)
Harness controls were validated with curl first: `/r/4` under `curl -sL`
reports `redirects=4 code=200`; each `/sNNN` answers its own status
unfollowed and lands 200 (1412 fixture bytes) followed; the sidecar's
`/fixture.pdf` answers `Range: bytes=0-9` with `206 Partial Content`.

Method unchanged: `timeout 90 pdftract-remote extract <url>`, wall via
`date +%s%3N`, stderr verbatim; 20 probes per run (runner
`run-redirect-probes.sh`), run twice back-to-back, then re-verified in a
third full run (`run-redirect-probes-run3.sh`, summary `run3-summary.txt`,
captures `captures-run3/`): identical exit codes and stdout sizes on all 20
probes, byte-identical stderr (md5 match on every `err_*.stderr`, run 2 vs
run 3), and the same server-side walks appended to both JSONL logs
(`/r/6`→`5,4,3,2` and `/r/32`→`32…28` five-request caps, `/noloc` zero
follow-ups, `Range: bytes=0-65535` preserved on followed GETs). Raw captures:
`~/scratch/pdfswift-e1288f7a/` — `captures/out_*.stdout` +
`captures/err_*.stderr` per probe, both servers' JSONL request logs
(`http.jsonl`, `sidecar.jsonl`), second-run summary `run2-summary.txt`.

**Verdict — redirects ARE followed, with a hard limit of 4 hops.** A chain
of 4 redirects extracts fine; the **5th** 3xx response in one request aborts
it with `Too Many Redirects: reached max redirects (5)` (ureq's default
budget is 5 but counts the *response* that trips it, so only 4 are ever
followed — "reached max redirects (5)" after 4 follows). The HEAD request
and the subsequent ranged GET each get a **fresh, independent budget** and
re-follow the chain from the original URL. All of 301/302/303/307/308 are
followed; relative and absolute Locations, cross-port and cross-host alike
(no same-host restriction); a 3xx **without** a Location header is not
followed and surfaces as the HEAD status instead. Exceeding the limit is a
clean exit-1 error in the HEAD phase — no extraction, no retry loop.

### Chain length — bracketing the hop limit

Canonical 302 chain `/r/<N>` = exactly N redirects down to `/ok.pdf`
(2-run walls; identical exit/stdout across runs):

| Probe | Command | Wall (run 1 / run 2) | Exit | stdout |
|---|---|---|---|---|
| no-redirect control | `timeout 90 pdftract-remote extract http://127.0.0.1:18765/ok.pdf` | 54 / 56 ms | 0 | 3241-byte extraction |
| 1 hop | `… extract http://127.0.0.1:18765/r/1` | 53 / 58 ms | 0 | 3241-byte extraction |
| 2 hops | `… extract http://127.0.0.1:18765/r/2` | 52 / 56 ms | 0 | 3241-byte extraction |
| 4 hops | `… extract http://127.0.0.1:18765/r/4` | 53 / 56 ms | 0 | 3241-byte extraction |
| 5 hops | `… extract http://127.0.0.1:18765/r/5` | 7 / 9 ms | **1** | 0 bytes |
| 6 hops | `… extract http://127.0.0.1:18765/r/6` | 7 / 9 ms | **1** | 0 bytes |
| 8 hops | `… extract http://127.0.0.1:18765/r/8` | 7 / 9 ms | **1** | 0 bytes |
| 16 hops | `… extract http://127.0.0.1:18765/r/16` | 7 / 8 ms | **1** | 0 bytes |
| 32 hops | `… extract http://127.0.0.1:18765/r/32` | 8 / 9 ms | **1** | 0 bytes |
| infinite loop | `… extract http://127.0.0.1:18765/loop` | 7 / 9 ms | **1** | 0 bytes |

The bracket is exact: 4 hops succeed (full extraction, ~55 ms), 5 hops fail.
Chain length above the limit changes nothing — `/r/6` `/r/8` `/r/16`
`/r/32` and `/loop` all fail at the same 5th response, so there is no
larger hidden limit and no per-host variation. The 6-hop failure the prior
attempt observed (`probe-tmp/out_D05-dev-6hops.stderr`,
[Prior salvage](#prior-salvage-probe-tmp-2026-09-29)) reproduces as real
behavior here — but for the limit, not the invocation bug that capture
actually shows (it is a clap `unrecognized subcommand` usage error; the
capture above is the true 6-hop failure).

Server-side hop evidence (JSONL request log `http.jsonl`, identical across
both runs) — the client walks the chain on the HEAD and stops after the 5th
redirect *response*, never reaching the fixture:

| Probe | HEAD-phase requests the server saw | Then |
|---|---|---|
| `/r/4` | `HEAD /r/4`, `/r/3`, `/r/2`, `/r/1`, `/ok.pdf` — 4 redirects followed | ranged `GET /r/4` **re-follows all 4 hops** (`GET /r/4 /r/3 /r/2 /r/1 /ok.pdf`) and extracts |
| `/r/5` | `HEAD /r/5`, `/r/4`, `/r/3`, `/r/2`, `/r/1` — 5 requests, 4 redirects followed | abort on the 5th 302 response; **no `/ok.pdf` request, no ranged GET** |
| `/r/6` | `HEAD /r/6` … `/r/2` — same 5-request cap | abort; chain never reached `/r/1` |
| `/r/32` | `HEAD /r/32` … `/r/28` — 5 requests | abort |
| `/loop` | `HEAD /loop` × 5 | abort |

The `/r/4` row also proves the two budgets are independent: the HEAD
consumes its full 4-hop budget, and the ranged GET then spends a *fresh*
budget re-following the same chain from the original URL — a shared budget
would have failed the second phase. (Corroborated on the sidecar: every
successful single-status probe shows `HEAD /sNNN → HEAD /fixture.pdf` then
ranged `GET /sNNN → GET /fixture.pdf` — `sidecar.jsonl` entries 17–40.)

Over-limit stderr, verbatim and byte-identical across all failing probes
and both runs (md5 `bafc7683…` for `/r/5`; capture
`captures/err_r5.stderr`):

```
Error: Failed to open remote PDF source

Caused by:
    HEAD request failed: http://127.0.0.1:18765/r/5: Too Many Redirects: reached max redirects (5)
```

(`/loop` differs only in the URL: `…/loop: Too Many Redirects: reached max
redirects (5)`.) Exit code **1** in every case, ~7–9 ms — the error is
immediate, there is no backoff and no retry of the over-limit chain.

### Redirect status codes — 301/302/303/307/308 all followed

Sidecar single-hop probes, each `<status> → /fixture.pdf`:

| Probe | Command | Wall (run 1 / 2) | Exit | stdout | Server saw |
|---|---|---|---|---|---|
| 301 | `timeout 90 pdftract-remote extract http://127.0.0.1:18766/s301` | 55 / 60 ms | 0 | 3241-byte extraction | `HEAD /s301 → HEAD /fixture.pdf`, ranged `GET /s301 → GET /fixture.pdf` |
| 302 | `… extract http://127.0.0.1:18766/s302` | 53 / 57 ms | 0 | 3241-byte extraction | same shape |
| 303 | `… extract http://127.0.0.1:18766/s303` | 53 / 60 ms | 0 | 3241-byte extraction | same shape |
| 307 | `… extract http://127.0.0.1:18766/s307` | 53 / 61 ms | 0 | 3241-byte extraction | same shape |
| 308 | `… extract http://127.0.0.1:18766/s308` | 52 / 60 ms | 0 | 3241-byte extraction | same shape |

No status is distinguishable from another for this client: HEAD is
preserved through every one of them (the server logs `HEAD`, never a
converted `GET`, at the redirect target), and every status yields the
identical full extraction. The 302-only canonical chain probes agree.

### Location shapes — relative, absolute, cross-port, cross-host: all followed

| Probe | Location emitted | Command | Exit | Server saw |
|---|---|---|---|---|
| relative (control) | `Location: /ok.pdf` (canonical `/r/1`) | `… extract http://127.0.0.1:18765/r/1` | 0 | walk + extraction |
| absolute, same host+port | `Location: http://127.0.0.1:18766/fixture.pdf` (`/shost`) | `… extract http://127.0.0.1:18766/shost` | 0 | `HEAD /shost → HEAD /fixture.pdf`, ranged GET likewise |
| absolute, cross-port | `Location: http://127.0.0.1:18765/ok.pdf` (`/xport`) | `… extract http://127.0.0.1:18766/xport` | 0 | sidecar got only `HEAD /xport` + ranged `GET /xport`; the follow-ups landed as `HEAD /ok.pdf` + ranged `GET /ok.pdf` in `http.jsonl` |
| absolute, cross-host + cross-port | `Location: http://localhost:18765/ok.pdf` (`/xhost`, requested as `127.0.0.1:18766`) | `… extract http://127.0.0.1:18766/xhost` | 0 | same split: follow-ups logged by the canonical server |
| absolute, same host (`/tlsredir` on the plain port) | `Location: http://127.0.0.1:18765/ok.pdf` | `… extract http://127.0.0.1:18765/tlsredir` | 0 | `HEAD /tlsredir → HEAD /ok.pdf`, ranged `GET /tlsredir → GET /ok.pdf` |

**No same-host restriction exists**: a redirect to a different host string
*and* port is followed exactly like a same-host one (both run 1 and run 2,
exit 0, full 3241-byte extraction — 53–58 ms). Header preservation across
the hop is observable in the same logs: the post-redirect ranged GET still
carries `Range: bytes=0-65535` (`sidecar.jsonl` entries 20, 24, 28, 32,
36, 40) — the Range source survives the redirect rather than restarting.

HTTPS variants are not runnable on this harness, not merely unmeasured: by
the [TLS findings](#tls--connect-and-read-phases) the handshake dies before
any HTTP request, so an `https://` redirect source (and the
https→http downgrade `/tlsredir` is built to exercise) cannot be probed
with the self-signed listener.

Negative control — 302 **without** a Location header
(`/noloc`; `… extract http://127.0.0.1:18766/noloc`): wall 6 / 9 ms,
exit **1**, zero requests beyond the initial HEAD in `sidecar.jsonl`
(entry 45 — no follow-up request), stderr verbatim:

```
Error: Failed to open remote PDF source

Caused by:
    HEAD request failed with status 302
```

So the client does not treat 3xx as terminal-success-with-empty-body nor
loop on it: a Location-less 3xx is surfaced as a plain failed-HEAD status
error, same shape as any non-200.

### Mechanism (source-corroborated, ureq 2.12.1 + v1.2.0 tree)

- `crates/pdftract-core/src/source/http_range.rs:131-133` builds the
  ranged-path agent as `AgentBuilder::new().timeout(…).build()` — **no
  `.redirects()` override**, so ureq 2.12.1's default applies.
- ureq 2.12.1 `src/agent.rs:262` — default `redirects: 5`.
- ureq 2.12.1 `src/unit.rs:164-172` (`connect`, the redirect loop): before
  following, `if history.len() + 1 >= redirects { return Err(ErrorKind::TooManyRedirects.msg(format!("reached max redirects ({})", …))) }` —
  with `redirects: 5` the check fires when the **5th** 3xx response arrives
  (`history.len()` is 4), so exactly 4 redirects are ever followed and the
  error text names the raw budget, 5 — precisely the observed bracket
  (`/r/4` exit 0, `/r/5` exit 1) and the observed `reached max redirects
  (5)` wording.
- ureq 2.12.1 `src/error.rs:411` — `ErrorKind::TooManyRedirects` displays
  as `Too Many Redirects`, which is why the surfaced cause reads
  `<url>: Too Many Redirects: reached max redirects (5)` (the URL prefix is
  ureq's `Error` Display, `src/error.rs:229-230`; the
  `HEAD request failed:` wrapper is pdftract's
  `classify_http_error`, as in every other HEAD-phase failure above).
- ureq 2.12.1 `src/unit.rs:189-201` — method choice on redirect:
  301/302/303 keep `GET`/`HEAD` as-is; 307/308 keep the method for the
  GET/HEAD/OPTIONS/TRACE family. The probe client only ever sends
  HEAD/GET, so every followed status re-issues the same method — matching
  the observed identical handling of all five statuses.
- ureq 2.12.1 `src/unit.rs:216-224` — on redirect the previous header vec
  is reused minus `content-length` and `cookie` (and `authorization` per
  the default `RedirectAuthHeaders::Never` policy, `agent.rs:20-23`);
  everything else — `Range` included — is re-sent. Source-derived for
  `authorization` (not probed here); `Range` survival is directly observed
  in `sidecar.jsonl` above.

**SDK-mirroring consequence:** a Swift client claiming pdftract
compatibility must follow redirects — 301/302/303/307/308, relative or
absolute, cross-host allowed — but stop after **4** followed hops per
request with an error equivalent to `Too Many Redirects: reached max
redirects (5)` (exit 1, no partial output), keep HEAD as HEAD on every
followed status, re-follow the chain independently for the ranged GET, keep
the `Range` header across hops, and reject a 3xx lacking `Location` as a
plain `<status>` HEAD failure.

## TLS verification (measured, remote-enabled build)

Measured 2026-09-30 against the same remote-enabled build as
[Timeouts](#timeouts-measured-remote-enabled-build) and
[Redirects](#redirects-measured-remote-enabled-build) (`pdftract-remote`,
sha256 `07f95264…c48e0d` — full hash in `captures/binary-identity.txt` and
`captures-cd7d7321/binary-identity.attempt3.txt`, re-confirmed unchanged
2026-09-30 by `captures-bfafd83c/run-output.txt`; each probe run's console
header re-prints the 16-char prefix `07f95264e59395a3`,
`captures-r3/runA-runB-C-console.txt`).
Harness: the canonical `probes/server.py` listeners on 127.0.0.1:18765
(plain) and 127.0.0.1:18443/18444/18455 (TLS, self-signed / expired /
hostname-mismatch certs from `probes/certs/`), plus `probes/proxy.py` on
127.0.0.1:18888 (used by [Proxy handling](#proxy-handling-measured-remote-enabled-build));
the r3 harness ran the repo's own `docs/notes/probes/server.py` — its
bind-failure traceback for 18455 names that exact path
(`captures-r3/srv-mi.out`).
Method for every probe (`captures-r3/run-probes.sh`): a clean proxy env (all
eight `*_PROXY`/`NO_PROXY` variants unset) + `timeout 90 pdftract-remote
extract <url>`, wall via `date +%s%3N`, stdout/stderr captured per probe, and
the server-side JSONL request logs diffed around each probe.

Two full probe runs (A, B) were executed against a freshly started harness
each, plus a dedicated two-round mismatch re-run (C1, C2, first-party
listener, fresh log) after a harness-hygiene defect was found and fixed:
throughout runs A/B the 18455 listener was an untracked orphan, not the
harness's own — the r3 harness's mismatch listener failed to bind
(`captures-r3/srv-mi.out`, `OSError: [Errno 98] Address already in use`)
because a python3 pid outside every recorded pid set (140287, per the
`ss -ltnp` cross-check in `captures-r3/runA-runB-C-console.txt`; r1 `pid-mi`
45700, r2 `pid-mi2` 95188 — that one already dead on a wrong script path,
`captures-r2/server-mi2.out`) held the port. The pre-r3 cleanup scan had
grepped listeners with `1844[345]` — a pattern that cannot match `18455` —
and reported the port free, which is how the orphan escaped detection. The
port was cleared, a first-party listener started (`pid-mi`, fresh log), and
the mismatch probes re-run; the stderr of all four rounds is byte-identical
(md5 below) and neither server logged any request during its probes (below),
so the A/B mismatch rows stand on their own evidence. Raw captures:
`~/scratch/pdfswift-4c4d046f/captures-r3/` (`{A,B,C1,C2}_<probe>.out/.stderr`,
server logs `origin.jsonl`, `tls-ss.jsonl`, `tls-ex.jsonl`, `tls-mi.jsonl`,
`proxy.jsonl`; run-A copies kept as `*.runA.jsonl`; run B and C1/C2 console
records in `runA-runB-C-console.txt`). An earlier run of the same bead
(`~/scratch/pdfswift-4c4d046f/captures/`) independently matches: same
100-byte stderr on all three conditions, zero non-curl entries in any TLS
server log, zero pdftract entries in the proxy log (verified by reading
`captures/tls-*.jsonl` and `captures/proxy.jsonl`).

**Verdict — verification is strict and immutable: every non-publicly-trusted
chain is rejected at the TLS handshake, before any HTTP request is issued,
and the failure is reported as one undifferentiated error regardless of
cause.** Self-signed (untrusted root), expired, and hostname-mismatch certs
are all rejected; a publicly-trusted certificate is accepted and extracts
normally. There is no knob: the trust store is the compiled-in webpki-roots
(ureq 2.12.1 / rustls 0.23.40; no `rustls-native-certs` / `native-tls` in
the v1.2.0 `Cargo.lock`), and the standard `SSL_CERT_FILE` / `SSL_CERT_DIR` env vars are
inert (measured in [TLS — connect and read phases](#tls--connect-and-read-phases)).

### The three certificates (probes/certs/, characterized fresh 2026-09-30)

`openssl x509` via docker (`docker run --rm -v probes/certs:/certs
swift:5.10-jammy openssl x509 …` — the lab host's openssl CLI is broken):

| Cert | Subject = Issuer | Validity | SANs |
|---|---|---|---|
| `self-signed.pem` | `CN=localhost` | 2026-09-29 → 2026-10-01 (current) | `DNS:localhost, IP Address:127.0.0.1` |
| `expired.pem` | `CN=localhost` | expired 2021-01-01 | `DNS:localhost, IP Address:127.0.0.1` |
| `mismatch.pem` | `CN=wrong.example.com` | 2026-09-29 → 2026-10-01 (current) | `DNS:wrong.example.com` only |

So name matching is exercisable independently of trust/expiry: the self-signed
and expired certs carry SANs matching both target spellings (`127.0.0.1` IP
SAN and `localhost` DNS SAN), while the mismatch cert matches neither —
probed against both `https://127.0.0.1:18455` (IP literal) and
`https://localhost:18455` (DNS name), both of which mismatch.

### Listener health and verification-failure controls (curl)

Each listener serves the fixture when verification is bypassed, and fails it
in exactly its own intended way otherwise (curl 8.14.1, run 2026-09-30;
`P=docs/notes/probes`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://127.0.0.1:18443/ok.pdf                     # exit 60 (untrusted root, system trust)
curl -s --cacert $P/certs/self-signed.pem -o /dev/null -w '%{http_code}\n' https://127.0.0.1:18443/ok.pdf   # 200 — pinning makes it its own anchor
curl -s --cacert $P/certs/expired.pem     -o /dev/null -w '%{http_code}\n' https://127.0.0.1:18444/ok.pdf   # exit 60 (certificate has expired)
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:18444/ok.pdf                                     # 200
curl -s --cacert $P/certs/mismatch.pem    -o /dev/null -w '%{http_code}\n' https://127.0.0.1:18455/ok.pdf    # exit 60 (no SAN matches)
curl -s --cacert $P/certs/mismatch.pem    -o /dev/null -w '%{http_code}\n' https://localhost:18455/ok.pdf    # exit 60
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:18455/ok.pdf                                     # 200
```

Observed: `000/exit=60`, `200/exit=0`, `000/exit=60`, `200/exit=0`,
`000/exit=60`, `000/exit=60`, `200/exit=0`. The listeners are healthy and the
certs fail verification for their own reasons; any pdftract rejection below is
therefore attributable to certificate verification, not a broken endpoint.
Captured evidence: the pinned and `-k` rows verbatim in
`captures/curl-sanity.txt` (the earlier run against the same repo cert trio),
the default-trust row in `captures-cd7d7321/curl-controls.attempt3.txt`
(control 4, `000`/`exit=60`), and all seven rows re-confirmed 2026-09-30 in
`captures-bfafd83c/run-output.txt` + `controls-pass2.txt` — which additionally
pin the *served* certs of the later-regenerated harness, isolating each cause
cleanly (`pin-served-ss` 200/exit=0: pinning removes the untrusted-root
failure; `pin-served-expired` 000/exit=60: expiry alone; `pin-served-mi-ip`
and `pin-served-mi-host` 000/exit=60: name mismatch alone, trust and validity
being correct).

### Probe results — all three conditions rejected, identically

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy \
    -u all_proxy -u NO_PROXY -u no_proxy \
    timeout 90 pdftract-remote extract https://127.0.0.1:18443/ok.pdf   # self-signed
#   … https://localhost:18443/ok.pdf / https://127.0.0.1:18444/ok.pdf   # expired
#   … https://localhost:18444/ok.pdf / https://127.0.0.1:18455/ok.pdf   # mismatch
#   … https://localhost:18455/ok.pdf
```

| Condition | Target | Wall run A / run B (ms) | Exit | stdout | stderr |
|---|---|---|---|---|---|
| self-signed (untrusted root) | `https://127.0.0.1:18443/ok.pdf` | 10 / 9 | **1** | 0 B | 100 B |
| self-signed | `https://localhost:18443/ok.pdf` | 11 / 9 | **1** | 0 B | 100 B |
| expired | `https://127.0.0.1:18444/ok.pdf` | 9 / 8 | **1** | 0 B | 100 B |
| expired | `https://localhost:18444/ok.pdf` | 10 / 9 | **1** | 0 B | 100 B |
| hostname mismatch | `https://127.0.0.1:18455/ok.pdf` | 9 / 8 (A/B) + 9 / 9 (C1/C2) | **1** | 0 B | 100 B |
| hostname mismatch | `https://localhost:18455/ok.pdf` | 9 / 8 (A/B) + 9 / 9 (C1/C2) | **1** | 0 B | 100 B |
| **publicly-trusted control** | `https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf` | 102 / 70 | **0** | 1216 B | 0 B |

Sources for the wall column: verbatim run A / run B / C1 / C2 console records
in `captures-r3/runA-runB-C-console.txt` (the r3 console output was not
originally saved to disk; the file is a labeled verbatim extract of the
parent session transcript, with the per-probe stdout/stderr files having been
on disk all along), cross-checked against the on-disk captures (`{A,B}_*`
sizes and stderr md5 match every row). All probes were independently
re-measured 2026-09-30 against the standing harness in
`captures-bfafd83c/run-output.txt`: same exits, stdout/stderr sizes and md5s,
walls 8–10 ms (rejected), 107 ms (public control), 53–73 ms (proxy rows).

stderr is byte-identical across **all 16 bad-cert runs** (md5
`007483650c299f988786821cf358d211`), verbatim:

```
Error: Failed to open remote PDF source

Caused by:
    HEAD request failed: connection interrupted
```

Server-side evidence that the rejection precedes any HTTP: in run B **no TLS
listener log existed at all** — run B started against a fresh harness whose
JSONL logs are created lazily on first request (`server.py:187` appends per
request; the run-B console shows the log-delta helper erroring `No such file
or directory` on `tls-ss.jsonl`/`origin.jsonl`/`proxy.jsonl` at start, and
its `mv` of `tls-mi.jsonl` failing the same way) and the probes never created
one. The `tls-ss/ex/mi.jsonl` files now in `captures-r3/` were created only
by the post-C2 curl control pass — a single `curl/8.14.1` entry each at
`t=1790737210`, zero ureq entries — and the C-round's own check recorded
verbatim: `tls-mi.jsonl never created — zero HTTP requests reached the
listener` (`captures-r3/runA-runB-C-console.txt`). In run A the TLS logs
exist from the harness's own startup curl controls and contain only
`curl/8.14.1` entries (`tls-ss.runA.jsonl`: 3, `tls-ex.runA.jsonl`: 2) —
zero pdftract/ureq lines — and the orphan's log (`captures-r2/tls-mi2.jsonl`)
has exactly four `curl/8.14.1` entries (22:44:26, 22:53:50 ×2, 22:57:36
local), none inside either probe window (run A from 02:54:36Z, run B from
02:55:24Z). Combined with the ~8–11 ms wall (far below the same harness's
own plain-HTTP round trips, 53–107 ms in these very tables, and far below
every measured pdftract timeout), the client dies inside the TLS
handshake: the server presents its certificate during the accept
(`probes/server.py:383-385` wraps the listening socket), rustls rejects the
chain/name, and ureq surfaces the handshake failure as its generic transport
error `connection interrupted` — the same text already recorded for every
TLS case in [TLS — connect and read phases](#tls--connect-and-read-phases).

The publicly-trusted control proves the rejections are verification working,
not TLS broken: against `www.w3.org`'s publicly-trusted chain the client
handshakes, fetches, and extracts normally (exit 0, 1216-byte extraction,
page text `Dummy PDF file`, 102 / 70 ms — capture `A_tls-public.out`).

**Cause is not distinguishable from the outside.** Untrusted root, expired,
and wrong-name all produce the identical 100-byte stderr and exit 1. A Swift
SDK mirroring pdftract can assert *rejection* and *exit 1* for all three
conditions, but must not promise cause-specific error text: the observable
contract is `Failed to open remote PDF source / HEAD request failed:
connection interrupted`, pre-HTTP, with no request ever reaching the origin.

## Proxy handling (measured, remote-enabled build)

Measured 2026-09-30, same binary (sha256 `07f95264…c48e0d`), same harness
and method as [TLS verification](#tls-verification-measured-remote-enabled-build)
(two full runs A/B; captures in `~/scratch/pdfswift-4c4d046f/captures-r3/`).
The mock proxy is the harness's logging forward proxy `probes/proxy.py` on
127.0.0.1:18888: it logs every absolute-form request and CONNECT it receives
and answers origin-form (non-proxy-shaped) requests with 400. It was proven
working immediately before probing, with curl explicitly configured:

```bash
curl -sx http://127.0.0.1:18888 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18765/ok.pdf   # 200; "forward" entry in proxy.jsonl
curl -sx http://127.0.0.1:18888 --cacert probes/certs/self-signed.pem \
     -o /dev/null -w '%{http_code}\n' https://127.0.0.1:18443/ok.pdf                             # 200; "connect" entry in proxy.jsonl
```

Captured: run A's log copy `captures-r3/proxy.runA.jsonl` holds exactly those
two entries — `"type": "forward"` and `"type": "connect"`, `User-Agent:
curl/8.14.1`, `t=1790736830.92/.93` — and the earlier run's
`captures/proxy.jsonl` the same pair; re-confirmed 2026-09-30 against the
standing harness (`captures-cd7d7321/curl-controls.attempt3.txt` controls
9–10: forward 200, CONNECT 200, fresh entries appended;
`captures-bfafd83c/run-output.txt` c8/c9 and `controls-pass2.txt`).

Probe command shape as above (`env -u …` clean proxy env, `timeout 90`,
`pdftract-remote extract <url>`), with one proxy variable added per probe;
the `DEAD` proxy address `http://127.0.0.1:18999` has no listener.

**Verdict — every proxy environment variable is ignored entirely; the fetch
always connects directly to the origin, and `NO_PROXY` is vacuous.**

| Env added | Target | Exit | Wall A / B (ms) | stdout | Origin log (18765) | Proxy log (18888) |
|---|---|---|---|---|---|---|
| none (baseline) | `http://127.0.0.1:18765/ok.pdf` | 0 | 54 / 54 | 3241 B | +2: direct ureq `HEAD`+`GET` | +0 |
| `HTTP_PROXY=http://127.0.0.1:18888` | same | 0 | 54 / 53 | 3241 B | +2 direct | +0 |
| `http_proxy=…` (lowercase) | same | 0 | 54 / 53 | 3241 B | +2 direct | +0 |
| `HTTPS_PROXY=…` | same (plain-http URL) | 0 | 55 / 53 | 3241 B | +2 direct | +0 |
| `ALL_PROXY=…` | same | 0 | 54 / 54 | 3241 B | +2 direct | +0 |
| `all_proxy=…` (lowercase) | same | 0 | 54 / 54 | 3241 B | +2 direct | +0 |
| `HTTP_PROXY=http://127.0.0.1:18999` (dead) | same | 0 | 54 / 53 | 3241 B | +2 direct | +0 (unreachable anyway) |
| `ALL_PROXY=http://127.0.0.1:18999` (dead) | same | 0 | 54 / 53 | 3241 B | +2 direct | +0 |
| `HTTP_PROXY=…:18888` + `NO_PROXY=127.0.0.1` | same | 0 | 54 / 54 | 3241 B | +2 direct | +0 |
| `HTTPS_PROXY=…:18888` | `https://127.0.0.1:18443/ok.pdf` | 1 | 9 / 9 | 0 B | — | **+0 (no CONNECT)** |
| `HTTP_PROXY=…:18888` | same https URL | 1 | 9 / 9 | 0 B | — | +0 |
| `ALL_PROXY=…:18888` | same https URL | 1 | 9 / 9 | 0 B | — | +0 |
| `HTTP_PROXY=…:18888` + `NO_PROXY=127.0.0.1` | same https URL | 1 | 8 / 9 | 0 B | — | +0 |

Wall column sources as in
[TLS verification](#tls-verification-measured-remote-enabled-build):
`captures-r3/runA-runB-C-console.txt` (runs A/B consoles) plus the
independent 2026-09-30 re-measurement in `captures-bfafd83c/run-output.txt`
(same exits/sizes/md5s; walls 53–73 ms plain rows, 8–9 ms https rows).

Routing evidence, per row: the origin server's JSONL gained exactly one
`User-Agent: ureq/2.12.1` pair (`HEAD /ok.pdf`, then `GET /ok.pdf` with
`Range: bytes=0-65535`) for each successful plain-HTTP probe — run B's
`origin.jsonl` ends with exactly 18 entries, all ureq, 9× HEAD + 9× GET,
matching the nine plain-HTTP probes one-for-one — while the proxy's log
**was never even created** during run B (zero traffic of any kind reached
18888, including the curl sanity entries, which lived only in run A's log).
The `+2 direct` pattern is identical with a live proxy, a dead proxy, and no
proxy at all: a client honoring `HTTP_PROXY` would have logged an
absolute-form request on 18888, and a client honoring the dead-proxy rows
could not have succeeded at all (nothing listens on 18999 — success there is
the strongest single datapoint). For the HTTPS rows the mock proxy log is the
only routing witness (the TLS listener can never log — every handshake dies,
per [TLS verification](#tls-verification-measured-remote-enabled-build)): no
CONNECT was ever logged under any proxy variable, so those requests were not
proxied; they failed as the usual direct self-signed rejection (the same
100-byte `connection interrupted` stderr, md5 `007483650c…`).
`NO_PROXY=127.0.0.1` changes nothing in either direction — there is no
proxying to bypass.

Source corroboration (v1.2.0 tree): the ranged-path agent is built with
`ureq::AgentBuilder::new().timeout(...).build()` and nothing else
(`crates/pdftract-core/src/source/http_range.rs:131-133`); `.proxy(` appears
nowhere in either crate (the only "proxy" hits are log-redaction/hop-by-hop
header lists and `serve` deployment docs), so ureq 2.12.1 — which uses a proxy only when
one is explicitly set on the agent, and never reads the environment on its
own — connects directly. The `socks-proxy` feature flag is enabled on the
cli crate's *dev*-dependency `ureq`
(`crates/pdftract-cli/Cargo.toml:170`) but no `Proxy` is ever constructed, so
it changes nothing observable.

**SDK-mirroring consequence:** a Swift client claiming pdftract compatibility
must NOT honor `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` (either case) for
`.url` sources: pdftract connects directly to the origin whatever the
environment says, ignores `NO_PROXY` (there is nothing to bypass), and offers
no proxy configuration. TLS verification meanwhile is strict, anchored in the
compiled-in webpki-roots, immune to `SSL_CERT_FILE`/`SSL_CERT_DIR`, and
fails pre-HTTP with a single cause-free error for untrusted, expired, and
wrong-name certificates alike.
