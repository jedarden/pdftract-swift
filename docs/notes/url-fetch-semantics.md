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
remote-enabled build are recorded in that section.

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
`connect-probes.rerun.txt`, `read-probes.txt`, `connect-stderr/`,
`read-stderr/` in the same scratch tree). Method for every probe:
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
request in ~8 ms, before any connect or read phase.

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

### TLS — connect and read phases

TLS unusable with self-signed; timeout not observable. The binary trusts only
its compiled-in webpki-roots (ureq 2.12.1 / rustls 0.23.40; no
rustls-native-certs / native-tls in the lockfile), so `SSL_CERT_FILE` /
`SSL_CERT_DIR` are inert and the handshake fails before any phase whose
timeout could be measured — the read-stall phase over TLS is unreachable, not
merely unmeasured. The 18443 listener itself is healthy (`s_client` completes
with Verify return code 18).

```bash
timeout 90 pdftract-remote extract https://127.0.0.1:18443/slow/connect/15000
timeout 90 pdftract-remote extract https://127.0.0.1:18443/slow/body/15000
timeout 90 pdftract-remote extract https://127.0.0.1:18443/ok.pdf
```

Observed: wall 7 / 7 / 8–9 ms respectively, exit 1 in every case — including
the happy path. stderr identical in all three (verbatim):

```
Error: Failed to open remote PDF source

Caused by:
    HEAD request failed: connection interrupted
```

Cert rejection precedes any connect-phase stall, so no HTTPS timeout value is
derivable on this harness; the HTTP and HTTPS columns are not comparable
here.

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
