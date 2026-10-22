#!/bin/zsh
# Creates a self-signed code-signing identity "Feedback Recorder Dev" in the login keychain.
# Ad-hoc signatures change on every build and reset TCC permissions; this identity is stable.
set -euo pipefail
NAME="Feedback Recorder Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# An imported-but-untrusted certificate is still listed here, tagged CSSMERR_TP_NOT_TRUSTED;
# only a line without that tag counts as a usable identity.
IDENTITY_LINE=$(security find-identity -v -p codesigning | grep "$NAME" || true)
if [ -n "$IDENTITY_LINE" ] && ! echo "$IDENTITY_LINE" | grep -q "CSSMERR_TP_NOT_TRUSTED"; then
  echo "identity '$NAME' already exists"; exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  # Certificate was already generated and imported by an earlier run but never
  # trusted for code signing (e.g. the trust dialog was left unanswered).
  # Reuse it instead of importing a second, ambiguous copy.
  echo "certificate '$NAME' already imported but not trusted; retrying trust step only"
  security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/cert.pem"
  # Trust for code signing. This may show a macOS password dialog once.
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
  security find-identity -v -p codesigning | grep "$NAME"
  echo "trusted identity '$NAME'"
  exit 0
fi

cat > "$TMP/cert.cnf" <<EOF
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
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# -legacy: macOS's security tool cannot import OpenSSL 3's default PBES2 PKCS#12.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout pass:temp -name "$NAME"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign -T /usr/bin/security
# Trust for code signing. This may show a macOS password dialog once.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
security find-identity -v -p codesigning | grep "$NAME"
echo "created identity '$NAME'"
