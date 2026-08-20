#!/bin/bash
# Usage: ./setup_utils/get_server_signature.sh 192.168.1.101
# Displays SHA256 fingerprint SSH-host (ESXi) with correct formating, required by plink -hostkey

set -e

if [ $# -ne 1 ]; then
  echo "Usage: $0 <esxi-ip-or-hostname>"
  exit 1
fi

HOST="$1"

if ! command -v ssh-keyscan >/dev/null 2>&1; then
  echo "Error: ssh-keyscan not found. Install 'openssh-client'."
  exit 1
fi

if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "Error: ssh-keygen not found. Install 'openssh-client'."
  exit 1
fi

echo "Fetching host key from $HOST ..."

KEY_OUTPUT="$(ssh-keyscan -T 5 -t ed25519,ecdsa,rsa "$HOST" 2>/dev/null || true)"
KEY_LINE="$(printf '%s\n' "$KEY_OUTPUT" | awk '
  $2 == "ssh-ed25519" && ed25519 == "" { ed25519 = $0 }
  $2 ~ /^ecdsa-sha2-/ && ecdsa == "" { ecdsa = $0 }
  $2 == "ssh-rsa" && rsa == "" { rsa = $0 }
  END {
    if (ed25519 != "") print ed25519
    else if (ecdsa != "") print ecdsa
    else if (rsa != "") print rsa
  }
')"

if [ -z "$KEY_LINE" ]; then
  echo "Error: could not fetch SSH host key from $HOST"
  exit 1
fi

# Calculating fingerprint
FINGERPRINT_LINE="$(echo "$KEY_LINE" | ssh-keygen -lf -)"
# Ex: "256 SHA256:wOAjuVvd7F... hostname (ED25519)"

echo
echo "Raw ssh-keygen output:"
echo "  $FINGERPRINT_LINE"

# Picking SHA256:...
SHA_PART="$(echo "$FINGERPRINT_LINE" | awk '{print $2}')"

echo
echo "Extracted SHA256 fingerprint:"
echo "  $SHA_PART"

echo
echo "For plink -hostkey you can use:"
echo "  -hostkey \"$SHA_PART\""

echo
echo "For JSON config (example):"
echo "  \"esxiHostKey\": \"$SHA_PART\""
