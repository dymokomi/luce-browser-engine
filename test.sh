#!/bin/sh
# Type-check every module of luce-browser-engine with warnings as errors, then run the unit tests
# of every module. Stops at the first failing step.
set -e
cd "$(dirname "$0")"

# Every hand-written fragment is laid out as the pinned compiler's formatter lays it out (the
# skeleton generator's types_* and stubs/ fragments are not).
echo "== luce-base fmt --check"
for file in $(git ls-files '*.lucb' | grep -v -e '/types_' -e '/stubs/' -e '/generated'); do
    luce-base fmt "$file" --check > /dev/null || { echo "$file is not formatted (luce-base fmt $file --write)"; exit 1; }
done

for module in web; do
    echo "== luce-base check src/luce_browser_engine/$module -W"
    # -W reports warnings without failing, so any output at all fails the run.
    output=$(luce-base check "src/luce_browser_engine/$module" -W 2>&1) || { echo "$output"; exit 1; }
    if [ -n "$output" ]; then
        echo "$output"
        exit 1
    fi
done

# Unit tests (the regions' `tests_*` fragments), module by module.
for module in web; do
    echo "== luce-base test src/luce_browser_engine/$module"
    luce-base test "src/luce_browser_engine/$module"
done
