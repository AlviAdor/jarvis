#!/bin/sh
# Prints the codesign identity to use: a stable local one, created on first use.
#
# macOS remembers privacy permissions (Microphone, Accessibility, Screen Recording...) and Keychain
# access per code signature. An ad-hoc signature changes on every build, so each rebuild looks like
# a new app and macOS asks again while the old switches in System Settings stay on but no longer apply.
# A self-signed certificate that stays the same across builds fixes that.
#
# The certificate lives in its own keychain, so it never touches your login keychain and never prompts.
# Set JARVIS_SIGN_IDENTITY to use your own identity instead (for example an Apple Development certificate).
set -e

NAME="Jarvis Local Signing"
DIR="$HOME/Library/Application Support/JarvisSigning"
KC="$HOME/Library/Keychains/jarvis-signing.keychain-db"
PW_FILE="$DIR/keychain-password"

if [ -n "$JARVIS_SIGN_IDENTITY" ]; then
    echo "$JARVIS_SIGN_IDENTITY"
    exit 0
fi

# CI machines get a throwaway ad-hoc signature.
if [ -n "$CI" ]; then
    echo "-"
    exit 0
fi

if [ ! -f "$KC" ] || [ ! -f "$PW_FILE" ]; then
    mkdir -p "$DIR"
    chmod 700 "$DIR"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    umask 077
    /usr/bin/openssl rand -hex 24 > "$PW_FILE"
    PW=$(cat "$PW_FILE")
    P12PW=$(/usr/bin/openssl rand -hex 12)
    cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -name "$NAME" -out "$TMP/id.p12" -passout "pass:$P12PW" 2>/dev/null
    rm -f "$KC"
    security create-keychain -p "$PW" "$KC"
    security set-keychain-settings "$KC"
    security unlock-keychain -p "$PW" "$KC"
    security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null 2>&1
    echo "Created the local signing identity \"$NAME\"." >&2
fi

security unlock-keychain -p "$(cat "$PW_FILE")" "$KC" >&2
# codesign only finds identities in keychains on the search list; add ours, keeping the others.
if ! security list-keychains -d user | grep -q "jarvis-signing.keychain-db"; then
    eval "set -- $(security list-keychains -d user | tr '\n' ' ')"
    security list-keychains -d user -s "$@" "$KC" >&2
fi
echo "$NAME"
