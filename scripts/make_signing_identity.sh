#!/bin/bash
# Creates a self-signed code-signing identity called "Sweep Local Signing" in the login keychain.
#
# Why: an ad-hoc signature changes with every build, so macOS treats each rebuild as a new app and
# forgets permissions such as Full Disk Access. Signing with the same certificate every time gives
# the app a stable identity, and the permissions stick.
#
# The identity is only used on this Mac. It is safe to run this script repeatedly.
set -euo pipefail

NAME="Sweep Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists; nothing to do."
  exit 0
fi

# All key material lives in a private temp directory that is removed on exit.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $NAME

[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# A 2048-bit RSA key and a certificate valid for ten years.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The passphrase only protects the bundle for the few seconds it exists on disk.
PASSPHRASE="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$NAME" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASSPHRASE"

# -T lets codesign use the private key without asking each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSPHRASE" -T /usr/bin/codesign

echo "Created identity \"$NAME\" in the login keychain."
