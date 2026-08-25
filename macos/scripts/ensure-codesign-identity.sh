#!/usr/bin/env bash
# Ensure a stable local codesigning identity named "Cue Local Codesign".
# Ad-hoc signatures change CDHash every rebuild; macOS then treats Cue as a
# new app for System Audio Recording / Accessibility, so Settings shows the
# old Cue as enabled while the new binary keeps prompting.
set -euo pipefail

IDENTITY="${CUE_CODESIGN_IDENTITY:-Cue Local Codesign}"
KEYCHAIN="${CUE_CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
# Homebrew OpenSSL 3 PKCS#12 exports are rejected by macOS `security import`.
OPENSSL="${CUE_OPENSSL:-/usr/bin/openssl}"

if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$IDENTITY\"" >/dev/null; then
  echo "$IDENTITY"
  exit 0
fi

tmp="$(mktemp -d /tmp/cue-codesign.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

"$OPENSSL" genrsa -out "$tmp/key.pem" 2048 >/dev/null 2>&1
"$OPENSSL" req -new -key "$tmp/key.pem" -out "$tmp/csr.pem" \
  -subj "/CN=$IDENTITY/O=Cue Local/C=US" >/dev/null 2>&1

cat > "$tmp/ext.cnf" <<'EOF'
[v3]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

"$OPENSSL" x509 -req -in "$tmp/csr.pem" -signkey "$tmp/key.pem" -out "$tmp/cert.pem" \
  -days 3650 -extfile "$tmp/ext.cnf" -extensions v3 >/dev/null 2>&1

"$OPENSSL" pkcs12 -export -out "$tmp/cert.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -passout pass:cue-local -name "$IDENTITY" >/dev/null 2>&1

security import "$tmp/cert.p12" -k "$KEYCHAIN" -P cue-local \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Trust for Code Signing so `find-identity -v` marks it valid.
security add-trusted-cert -d -r unspecified -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem" >/dev/null 2>&1 || true

# Allow codesign to use the private key without interactive ACL prompts.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -D "$IDENTITY" -t private "$KEYCHAIN" >/dev/null 2>&1 || true

if ! security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$IDENTITY\"" >/dev/null; then
  echo "error: failed to create codesigning identity '$IDENTITY'" >&2
  echo "Open Keychain Access → My Certificates → '$IDENTITY' → Trust → Code Signing: Always Trust" >&2
  exit 1
fi

echo "$IDENTITY"
