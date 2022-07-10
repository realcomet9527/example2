#!/usr/bin/env bash

set -euo pipefail

killall -9 "$(basename "$BUN_BIN")" || echo ""

DIR=$(mktemp -d -t react-app)
$BUN_BIN create react "$DIR"

if (($?)); then
    echo "bun create failed"
    exit 1
fi

cd "$DIR"
BUN_CRASH_WITHOUT_JIT=1 $BUN_BIN dev --port 8087 &
sleep 0.005

curl --fail http://localhost:8087/ && curl --fail http://localhost:8087/src/index.jsx && killall -9 "$(basename "$BUN_BIN")" && echo "✅ bun create react passed."
exit $?
