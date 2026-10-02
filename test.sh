#!/bin/sh
# Type-check every module of luce-browser-engine with warnings as errors, then run its unit tests.
# Stops at the first failing step.
set -e
cd "$(dirname "$0")"

for module in web; do
    echo "== luce-base check src/luce_browser_engine/$module -W"
    # -W reports warnings without failing, so any output at all fails the run.
    output=$(luce-base check "src/luce_browser_engine/$module" -W 2>&1) || { echo "$output"; exit 1; }
    if [ -n "$output" ]; then
        echo "$output"
        exit 1
    fi
done

for module in web; do
    echo "== luce-base test src/luce_browser_engine/$module"
    luce-base test "src/luce_browser_engine/$module"
done
