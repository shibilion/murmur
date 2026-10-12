#!/bin/bash
# Verifies the designated requirement is identical across two builds (so permissions survive rebuilds).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! security find-identity -v -p codesigning | grep -q '"Murmur Dev"'; then
    echo "Signing identity 'Murmur Dev' is missing. Run scripts/create-signing-identity.sh first." >&2
    exit 2
fi

scripts/bundle.sh >/dev/null
first="$(codesign -dr - build/Murmur.app 2>&1 | grep '^designated')"
scripts/bundle.sh >/dev/null
second="$(codesign -dr - build/Murmur.app 2>&1 | grep '^designated')"

if [ "$first" = "$second" ]; then
    echo "designated requirement stable"
    echo "$first"
else
    echo "designated requirement CHANGED between builds:" >&2
    echo "$first" >&2
    echo "$second" >&2
    exit 1
fi
