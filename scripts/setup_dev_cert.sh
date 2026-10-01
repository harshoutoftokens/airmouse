#!/bin/bash
set -e

CERT_NAME="AirTrackpad Development"

# Check if already exists in login keychain
if security find-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    echo "✅ Code signing certificate '$CERT_NAME' is already installed in login keychain."
    exit 0
fi

echo "🔐 Generating self-signed code signing certificate '$CERT_NAME' for persistent local development..."

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat <<EOF > "$TMP_DIR/cert.cnf"
[ req ]
default_bits        = 2048
default_md          = sha256
distinguished_name  = req_distinguished_name
prompt              = no
x509_extensions     = v3_req

[ req_distinguished_name ]
CN                  = $CERT_NAME

[ v3_req ]
keyUsage            = critical, digitalSignature
extendedKeyUsage    = critical, codeSigning
basicConstraints    = critical, CA:FALSE
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP_DIR/dev.key" \
    -out "$TMP_DIR/dev.crt" \
    -config "$TMP_DIR/cert.cnf" 2>/dev/null

openssl pkcs12 -export \
    -in "$TMP_DIR/dev.crt" \
    -inkey "$TMP_DIR/dev.key" \
    -out "$TMP_DIR/dev.p12" \
    -name "$CERT_NAME" \
    -password pass:airtrackpad

security import "$TMP_DIR/dev.p12" -k ~/Library/Keychains/login.keychain-db -P airtrackpad -T /usr/bin/codesign

echo "✅ Certificate '$CERT_NAME' imported into login keychain."
echo "💡 When prompted by macOS for codesign keychain access on first build, choose 'Always Allow'."
