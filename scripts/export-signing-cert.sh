#!/usr/bin/env bash
#
# Export the "SpeakClean Dev" code-signing identity from the login
# keychain as a password-protected .p12, base64-encode it, and print
# the two values to paste into GitHub Actions secrets:
#
#   SIGNING_CERT_P12       (the base64 string)
#   SIGNING_CERT_PASSWORD  (the password below)
#
# Run once when setting up CI, or again when rotating the cert
# (see docs/superpowers/plans/2026-04-23-release-workflow.md).
#
set -e

IDENTITY_NAME="${IDENTITY_NAME:-SpeakClean Dev}"
OUT_P12="${OUT_P12:-/tmp/speakclean-signing.p12}"
P12_PASSWORD="${P12_PASSWORD:-}"

if [[ -z "$P12_PASSWORD" ]]; then
    P12_PASSWORD="$(uuidgen)"
fi

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME"; then
    echo "error: no code-signing identity named '$IDENTITY_NAME' in keychain" >&2
    echo "hint: generate one with openssl + keychain import, or set IDENTITY_NAME=..." >&2
    exit 1
fi

rm -f "$OUT_P12"

security export \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -t identities \
    -f pkcs12 \
    -P "$P12_PASSWORD" \
    -o "$OUT_P12"

if [[ ! -s "$OUT_P12" ]]; then
    echo "error: export produced empty file $OUT_P12" >&2
    exit 1
fi

echo ""
echo "==> .p12 written to $OUT_P12"
echo ""
echo "Paste these two values into GitHub Actions secrets"
echo "(Repo → Settings → Secrets and variables → Actions → New repository secret):"
echo ""
echo "  Name:  SIGNING_CERT_P12"
echo "  Value: (the base64 string below, one line, no leading/trailing newline)"
echo ""
base64 -i "$OUT_P12"
echo ""
echo "  Name:  SIGNING_CERT_PASSWORD"
echo "  Value: $P12_PASSWORD"
echo ""
echo "After pasting, delete the local file: rm $OUT_P12"
