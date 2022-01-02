#!/bin/bash

# The important part of this test: make sure that bun.js successfully loads
# The most likely reason for this test to fail is that something broke in the JavaScriptCore <> bun integration
killall -9 $(basename $BUN_BIN) || echo ""

rm -rf /tmp/next-app
mkdir -p /tmp/next-app
$BUN_BIN create next /tmp/next-app

if (($?)); then
    echo "bun create failed"
    exit 1
fi

cd /tmp/next-app
BUN_CRASH_WITHOUT_JIT=1 $BUN_BIN --port 8087 &
sleep 0.1
curl --fail http://localhost:8087/ && killall -9 $(basename $BUN_BIN) && echo "✅ bun create next passed."
