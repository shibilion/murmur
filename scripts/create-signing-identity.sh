#!/bin/bash
# Creates a self-signed code-signing certificate "Murmur Dev" in your login keychain.
# A stable identity keeps macOS privacy permissions (Accessibility, Input Monitoring, Microphone)
# across rebuilds. This changes keychain trust settings, so run it yourself, once.
set -euo pipefail
NAME="Murmur Dev"
# Use the system LibreSSL explicitly: Homebrew OpenSSL 3+ writes PKCS#12 files that
# `security import` rejects ("MAC verification failed").
OPENSSL=/usr/bin/openssl

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Signing identity '$NAME' already exists."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
$OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
PASS="murmur-$$"
$OPENSSL pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$PASS" -name "$NAME" 2>/dev/null

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
# Trust the certificate for code signing (macOS asks for your password).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Created signing identity '$NAME'."
security find-identity -v -p codesigning | grep "$NAME" || true
