#!/bin/sh
# Type-check every module of luce-browser-engine (and run its tests once there are any).
# Stops at the first failing step.
set -e
cd "$(dirname "$0")"

for module in web; do
    echo "== luce-base check src/luce_browser_engine/$module"
    luce-base check "src/luce_browser_engine/$module"
done
