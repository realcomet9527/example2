#!/bin/bash

set -euo pipefail

killall -9 "$(basename "$BUN_BIN")" || echo ""

DIR=$(mktemp -d -t bun-dev-check)

index_content="<html><body>index.html</body></html>"
bacon_content="<html><body>bacon.html</body></html>"
js_content="if(0) { var foo = 'TEST FAILED'; }"
static_content="PASS"
css_not_transpiled_content="@import url(/index.js); @import url(/i-dont-exist.css); @import url('/i-dont-exist.css'); @import url(\"/i-dont-exist.css\");"
css_is_transpiled_import="*{background-color:red;}"
css_is_transpiled="@import url(./css_is_transpiled_import.css);"

echo $index_content >"$DIR/index.html"
echo $js_content >"$DIR/index.js"
echo $bacon_content >"$DIR/bacon.html"
echo $static_content >"$DIR/static.txt"
echo $css_not_transpiled_content >"$DIR/css_not_transpiled_content.css"

cd "$DIR"
$BUN_BIN dev --port 8087 &
sleep 0.005

if [[ "$(curl --fail -sS http://localhost:8087/)" != "$index_content" ]]; then
    echo "ERR: Expected '$index_content', got '$(curl --fail -sS http://localhost:8087/)'"
    exit 1
fi

if [[ "$(curl --fail -sS http://localhost:8087/index)" != "$index_content" ]]; then
    echo "ERR: Expected '$index_content', got '$(curl --fail -sS http://localhost:8087/index)'"
    exit 1
fi

if [[ "$(curl --fail -sS http://localhost:8087/static.txt)" != "PASS" ]]; then
    echo "ERR: Expected static file, got '$(curl --fail -sS http://localhost:8087/static.txt)'"
    exit 1
fi

# Check that the file is actually transpiled
if [[ "$(curl --fail -sS http://localhost:8087/index.js)" == *"TEST FAILED"* ]]; then
    echo "ERR: Expected file to be transpiled, got '$(curl --fail -sS http://localhost:8087/index.js)'"
    exit 1
fi

if [[ "$(curl --fail -sS http://localhost:8087/index.html)" != "$index_content" ]]; then
    echo "ERR: Expected '$index_content', got '$(curl --fail -sS http://localhost:8087/index.html)'"
    exit 1
fi

if [[ "$(curl --fail -sS http://localhost:8087/foo/foo)" != "$index_content" ]]; then
    echo "ERR: Expected '$index_content', got '$(curl --fail -sS http://localhost:8087/index.html)'"
    exit 1
fi

if [[ "$(curl --fail -sS http://localhost:8087/bacon)" != "$bacon_content" ]]; then
    echo "ERR: Expected '$bacon_content', got '$(curl --fail -sS http://localhost:8087/bacon)'"
    exit 1
fi

if [[ "$(curl --fail -sS http://localhost:8087/bacon.html)" != "$bacon_content" ]]; then
    echo "ERR: Expected '$bacon_content', got '$(curl --fail -sS http://localhost:8087/bacon.html)'"
    exit 1
fi

killall -9 "$(basename "$BUN_BIN")" || echo ""
echo "✅ bun dev index html check passed."
