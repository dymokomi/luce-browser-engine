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

for module in src/luce_browser_engine/web tools/gen_css_values; do
    echo "== luce-base check $module -W"
    # -W reports warnings without failing, so any output at all fails the run.
    output=$(luce-base check "$module" -W 2>&1) || { echo "$output"; exit 1; }
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

# The value-dependent generated fragments (web/generated/math_functions.lucb, ...) are written by
# tools/gen_css_values from data/css; regenerate them and compare with the committed ones.
echo "== tools/gen_css_values: regenerate web/generated's CSS fragments and compare"
mkdir -p build
generated=$(mktemp -d)
trap 'rm -rf "$generated"' EXIT
luce-base build tools/gen_css_values -o build/gen_css_values
build/gen_css_values data/css "$generated"
for file in "$generated"/*.lucb; do
    cmp "$file" "src/luce_browser_engine/web/generated/$(basename "$file")"
done
