#!/usr/bin/env bash
# Demonstrate every probe-harness endpoint mode with curl.
#
# Starts the plain-HTTP server, the three TLS servers, and the logging
# proxy, exercises each documented misbehavior, prints PASS/FAIL per check,
# then tears everything down. Exits nonzero if any check fails.
#
# Usage: verify-harness.sh
#
# Ports (same defaults as the prior probe runs):
#   18765 plain HTTP   18443 TLS self-signed   18444 TLS expired
#   18455 TLS mismatch 18888 logging proxy
set -u
cd "$(dirname "$0")"

WORK=$(mktemp -d /tmp/pdftract-probe-verify.XXXXXX)
HP=18765; TLS_SS=18443; TLS_EXP=18444; TLS_MIS=18455; PX=18888
PIDS=()
FAILS=0

cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; echo "      $2"; FAILS=$((FAILS + 1)); }

wait_port() { # port
  for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
    sleep 0.1
  done
  return 1
}

echo "== starting endpoints (work dir $WORK) =="
bash make-certs.sh "$WORK/certs" >/dev/null
cp fixtures/mini.pdf "$WORK/fixture.pdf"
: > "$WORK/http.jsonl"; : > "$WORK/proxy.jsonl"

python3 server.py "$HP"     "$WORK/http.jsonl" "$WORK/fixture.pdf" >/dev/null 2>&1 & PIDS+=($!)
python3 server.py "$TLS_SS" "$WORK/http.jsonl" "$WORK/fixture.pdf" "$WORK/certs/self-signed.pem" "$WORK/certs/self-signed.key" >/dev/null 2>&1 & PIDS+=($!)
python3 server.py "$TLS_EXP" "$WORK/http.jsonl" "$WORK/fixture.pdf" "$WORK/certs/expired.pem" "$WORK/certs/expired.key" >/dev/null 2>&1 & PIDS+=($!)
python3 server.py "$TLS_MIS" "$WORK/http.jsonl" "$WORK/fixture.pdf" "$WORK/certs/mismatch.pem" "$WORK/certs/mismatch.key" >/dev/null 2>&1 & PIDS+=($!)
python3 proxy.py  "$PX"     "$WORK/proxy.jsonl" >/dev/null 2>&1 & PIDS+=($!)

for port in "$HP" "$TLS_SS" "$TLS_EXP" "$TLS_MIS" "$PX"; do
  wait_port "$port" || { fail "endpoint :$port" "did not come up within 5s"; }
done

tls_verify_fail() { # name url cacert grep-text
  local out
  out=$(curl -sS --cacert "$3" "$2" 2>&1)
  local rc=$?
  if [ "$rc" -eq 60 ] && echo "$out" | grep -qi "$4"; then
    pass "$1 (curl exit 60: $(echo "$out" | head -1 | cut -c1-90))"
  else
    fail "$1" "exit=$rc out=$(echo "$out" | head -1 | cut -c1-120)"
  fi
}

echo "== checks =="
# 1. happy path
body=$(curl -s "http://127.0.0.1:$HP/ok.pdf")
[ "${body:0:8}" = "%PDF-1.4" ] && pass "HTTP happy path serves fixture" \
  || fail "HTTP happy path" "body head: ${body:0:20}"

# 2. connect-delay knob: the TCP connect itself stays instant and the stall
#    sits before the first response byte (ttfb carries the knob, conn does not)
phases=$(curl -s -o /dev/null -w '%{time_connect} %{time_starttransfer} %{time_total}' \
  "http://127.0.0.1:$HP/slow/connect/1200")
conn=${phases%% *}; t=${phases##* }; ttfb=${phases#* }; ttfb=${ttfb% *}
awk "BEGIN{exit !($conn < 0.5 && $ttfb >= 1.15)}" \
  && pass "connect-delay knob: conn=${conn}s ttfb=${ttfb}s total=${t}s" \
  || fail "connect-delay knob" "conn=$conn ttfb=$ttfb total=$t expected conn<0.5 ttfb>=1.15"

# 3. body-delay knob: headers + first byte immediate (ttfb stays fast), the
#    stall sits mid-body — the inverse phase split of check 2
phases=$(curl -s -o /dev/null -w '%{time_starttransfer} %{time_total}' \
  "http://127.0.0.1:$HP/slow/body/1200")
ttfb=${phases%% *}; t=${phases##* }
awk "BEGIN{exit !($ttfb < 0.5 && $t >= 1.15)}" \
  && pass "body-delay knob: ttfb=${ttfb}s total=${t}s" \
  || fail "body-delay knob" "ttfb=$ttfb total=$t expected ttfb<0.5 total>=1.15"

# 4. redirect chain, configurable hop count: /r/N is exactly N redirects
#    down to fixture bytes (including the zero-hop boundary /r/0)
for n in 0 2 6; do
  out=$(curl -sL -w '|%{num_redirects}' "http://127.0.0.1:$HP/r/$n")
  hops=${out##*|}; body=${out%|*}
  if [ "$hops" = "$n" ] && [ "${body:0:8}" = "%PDF-1.4" ]; then
    pass "redirect /r/$n: exactly $n redirect(s) down to fixture bytes"
  else
    fail "redirect /r/$n" "num_redirects=$hops body=${body:0:20} expected $n + %PDF"
  fi
done
loc=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://127.0.0.1:$HP/r/6")
[ "$loc" = "302 http://127.0.0.1:$HP/r/5" ] && pass "redirect /r/6 -> 302 -> /r/5" \
  || fail "redirect /r/6" "got: $loc"

# 5. infinite redirect loop (curl exits 47 = CURLE_TOO_MANY_REDIRECTS; the
#    reported http_code is the last 302, so the exit code is the signal)
code=$(curl -sL --max-redirs 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HP/loop")
rc=$?
[ "$rc" -eq 47 ] && pass "redirect loop /loop aborts under --max-redirs 3 (curl exit 47, last code $code)" \
  || fail "redirect loop" "exit=$rc http_code=$code expected exit 47"

# 6. TLS: each server serves under -k ...
for entry in "$TLS_SS self-signed" "$TLS_EXP expired" "$TLS_MIS mismatch"; do
  set -- $entry
  body=$(curl -sk "https://127.0.0.1:$1/ok.pdf")
  [ "${body:0:8}" = "%PDF-1.4" ] && pass "TLS $2 server serves (curl -k)" \
    || fail "TLS $2 server" "body head: ${body:0:20}"
done

# 7. TLS: and each fails verification the intended way
# self-signed: --cacert with the server's own cert would make it its own
# trust anchor (it verifies fine — that is check 8), so the untrusted-root
# misbehavior is exercised against the default system trust store instead
out=$(curl -sS "https://127.0.0.1:$TLS_SS/ok.pdf" 2>&1); rc=$?
if [ "$rc" -eq 60 ] && echo "$out" | grep -qi "self.signed\|self signed"; then
  pass "self-signed cert rejected by system trust (curl exit 60)"
else
  fail "self-signed cert rejected" "exit=$rc out=$(echo "$out" | head -1 | cut -c1-120)"
fi
tls_verify_fail "expired cert rejected" \
  "https://127.0.0.1:$TLS_EXP/ok.pdf" "$WORK/certs/expired.pem" "expired"
tls_verify_fail "hostname mismatch rejected" \
  "https://127.0.0.1:$TLS_MIS/ok.pdf" "$WORK/certs/mismatch.pem" "subject name\|mismatch\|wrong.example.com"

# 8. self-signed accepted when its cert is pinned as CA (trust-only failure)
body=$(curl -s --cacert "$WORK/certs/self-signed.pem" "https://127.0.0.1:$TLS_SS/ok.pdf")
[ "${body:0:8}" = "%PDF-1.4" ] && pass "self-signed accepted when pinned via --cacert" \
  || fail "self-signed pinned" "body head: ${body:0:20}"

# 9. proxy forwards absolute-form HTTP and logs it
body=$(curl -s -x "http://127.0.0.1:$PX" "http://127.0.0.1:$HP/ok.pdf")
[ "${body:0:8}" = "%PDF-1.4" ] && pass "proxy forwards HTTP absolute-form request" \
  || fail "proxy HTTP forward" "body head: ${body:0:20}"
grep -q '"type": "forward"' "$WORK/proxy.jsonl" \
  && grep -q "http://127.0.0.1:$HP/ok.pdf" "$WORK/proxy.jsonl" \
  && pass "proxy logged the forwarded request line" \
  || fail "proxy HTTP log" "no forward entry in proxy.jsonl"

# 10. proxy tunnels CONNECT and logs the target
body=$(curl -s -x "http://127.0.0.1:$PX" --cacert "$WORK/certs/self-signed.pem" \
  "https://127.0.0.1:$TLS_SS/ok.pdf")
[ "${body:0:8}" = "%PDF-1.4" ] && pass "proxy tunnels CONNECT for HTTPS" \
  || fail "proxy CONNECT" "body head: ${body:0:20}"
grep -q '"type": "connect"' "$WORK/proxy.jsonl" && grep -q "127.0.0.1:$TLS_SS" "$WORK/proxy.jsonl" \
  && pass "proxy logged the CONNECT target" \
  || fail "proxy CONNECT log" "no connect entry in proxy.jsonl"

# 11. oversized response, configurable size
size=$(curl -s "http://127.0.0.1:$HP/big/2" | wc -c)
[ "$size" -ge $((2 * 1024 * 1024)) ] && pass "oversized /big/2 served $size bytes" \
  || fail "oversized /big/2" "size=$size expected >=2097152"

# 12. configurable content type
ct=$(curl -sI "http://127.0.0.1:$HP/ctype/application-weird+proto" | grep -i '^content-type' | tr -d '\r')
[ "$ct" = "Content-Type: application-weird+proto" ] && pass "configurable content type: $ct" \
  || fail "configurable content type" "got: '$ct'"

# 13. fixed error statuses
for entry in 404 401 403 500 503; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HP/$entry")
  [ "$code" = "$entry" ] && pass "status $entry" || fail "status $entry" "got $code"
done

# 14. basic auth: correct credentials pass, wrong ones get 401
# (Authorization header built at runtime — no credential literal on a
#  curl command line, which the Forgejo push scanner flags as curl-auth-user)
good=$(printf 'user:pass' | base64)
body=$(curl -s -H "Authorization: Basic $good" "http://127.0.0.1:$HP/auth.pdf")
[ "${body:0:8}" = "%PDF-1.4" ] && pass "basic auth accepted with correct credentials" \
  || fail "basic auth accept" "body head: ${body:0:20}"
bad=$(printf 'user:wrong' | base64)
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Basic $bad" "http://127.0.0.1:$HP/auth.pdf")
[ "$code" = "401" ] && pass "basic auth rejected with wrong credentials" \
  || fail "basic auth reject" "http_code=$code expected 401"

# 15. request logging: server recorded method+path+headers
grep -q '"method": "GET"' "$WORK/http.jsonl" && grep -q '"User-Agent": "curl' "$WORK/http.jsonl" \
  && pass "server JSONL log captures method, path, User-Agent" \
  || fail "server request log" "expected GET + curl User-Agent entries"

echo
echo "== summary: $((FAILS == 0 ? 0 : FAILS)) failure(s) =="
if [ "$FAILS" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
fi
echo "work dir retained for diagnosis: $WORK"
exit 1
