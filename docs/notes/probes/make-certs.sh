#!/usr/bin/env bash
# Generate the three probe TLS server certificates.
#
#   self-signed.pem   CN=localhost, SAN DNS:localhost + IP:127.0.0.1, 2 days
#                     -> isolates "untrusted root" (name would match)
#   expired.pem       same names, validity 2020-01-01..2021-01-01
#                     -> isolates certificate expiry
#   mismatch.pem      CN/SAN DNS:wrong.example.com, 2 days
#                     -> isolates hostname verification (well-formed SAN,
#                        just not one matching localhost/127.0.0.1)
#
# Usage: make-certs.sh [OUTDIR]   (default: certs/ next to this script)
#
# openssl resolution on this box: the shim on PATH can be broken (dynamically
# linked against libssl.so.1.1, which is absent) and openssl 3.0-3.3 rejects
# `-days 0` while lacking req's -not_before/-not_after (added in 3.4). So the
# candidates are probed for runnability, nix-store ones are tried newest
# first, and the expired cert uses explicit validity dates when the binary
# supports them (-days 0 as the legacy fallback). Override with OPENSSL_BIN.
set -eu -o pipefail
cd "$(dirname "$0")"
OUT="${1:-certs}"
mkdir -p "$OUT"

OPENSSL_BIN="${OPENSSL_BIN:-}"
if [ -z "$OPENSSL_BIN" ]; then
  for cand in openssl /usr/bin/openssl \
      $(ls -d /nix/store/*-openssl-*-bin/bin/openssl 2>/dev/null \
          | sed 's|.*/openssl-\([0-9.]*\)-bin/.*|\1 &|' | sort -ru | cut -d' ' -f2); do
    if "$cand" version >/dev/null 2>&1; then OPENSSL_BIN="$cand"; break; fi
  done
fi
if [ -z "$OPENSSL_BIN" ] || ! "$OPENSSL_BIN" version >/dev/null 2>&1; then
  echo "error: no working openssl found (set OPENSSL_BIN)" >&2
  exit 1
fi
echo "using openssl: $OPENSSL_BIN ($("$OPENSSL_BIN" version 2>&1 | head -1))"

gen() { # name subject extra-req-args...
  local name="$1" subj="$2"; shift 2
  "$OPENSSL_BIN" req -x509 -newkey rsa:2048 -keyout "$OUT/$name.key" \
    -out "$OUT/$name.pem" -nodes -subj "$subj" "$@" \
    2>&1 | sed -E '/^[.+*-]+$/d' >&2
}

if "$OPENSSL_BIN" req -x509 -help 2>&1 | grep -q -- -not_after; then
  EXPIRED_ARGS=(-not_before 20200101000000Z -not_after 20210101000000Z)
else
  # legacy openssl: -days 0 makes notAfter == notBefore == now
  EXPIRED_ARGS=(-days 0)
fi

gen self-signed "/CN=localhost" -days 2 -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
gen expired     "/CN=localhost" "${EXPIRED_ARGS[@]}" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
gen mismatch    "/CN=wrong.example.com" -days 2 -addext "subjectAltName=DNS:wrong.example.com"

echo "certificates in $OUT/:"
ls -1 "$OUT" | sed "s|^|  $OUT/|"
