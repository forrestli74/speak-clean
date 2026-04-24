#!/usr/bin/env bash
#
# Export all code-signing identities from the login keychain as a
# password-protected .p12, base64-encode it, and print the two values
# to paste into GitHub Actions secrets:
#
#   SIGNING_CERT_P12       (the base64 string)
#   SIGNING_CERT_PASSWORD  (the password below)
#
# WARNING: macOS `security export -t identities` does NOT filter by
# name — it exports every code-signing identity in the login keychain.
# If you have other identities (e.g. "Apple Development: ..."), they
# will be bundled into the same .p12. The script prints the full list
# before exporting so you can spot-check. If the list includes more
# than just "SpeakClean Dev", remove the extras from your login
# keychain first (Keychain Access → login → My Certificates) or run
# this script from a secondary keychain that contains only the
# SpeakClean Dev identity.
#
# Run once when setting up CI, or again when rotating the cert
# (see docs/superpowers/plans/2026-04-23-release-workflow.md).
#
set -euo pipefail

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

echo ""
echo "==> Code-signing identities in login keychain (ALL will be exported):"
security find-identity -v -p codesigning
echo ""
echo "Double-check the list above. Ctrl-C now if it includes anything other than \"$IDENTITY_NAME\"."
echo ""

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
