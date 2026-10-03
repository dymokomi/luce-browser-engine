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

for module in src/web tools/gen_css_values tools/embed_css tools/gen_dom_tree tests/web_test; do
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
    echo "== luce-base test src/$module"
    luce-base test "src/$module"
done
echo "== luce-base test tests/web_test"
luce-base test tests/web_test

# The value-dependent generated fragments (web/generated/math_functions.lucb, ...) are written by
# tools/gen_css_values from data/css, the embedded style sheets (web/generated/*_style_sheet_source.lucb)
# by tools/embed_css; regenerate them and compare with the committed ones.
echo "== tools/gen_css_values, tools/embed_css: regenerate web/generated's CSS fragments and compare"
mkdir -p build
generated=$(mktemp -d)
trap 'rm -rf "$generated"' EXIT
luce-base build tools/gen_css_values -o build/gen_css_values
build/gen_css_values data/css "$generated"
luce-base build tools/embed_css -o build/embed_css
build/embed_css data/css "$generated"
for file in "$generated"/*.lucb; do
    cmp "$file" "src/web/generated/$(basename "$file")"
done

# The DOM of the media controls (web/generated/html/media_controls_dom.lucb) is written by
# tools/gen_dom_tree from data/html/MediaControls.html and the engine's tag and attribute names.
echo "== tools/gen_dom_tree: regenerate web/generated/html/media_controls_dom.lucb and compare"
mkdir -p "$generated/html"
luce-base build tools/gen_dom_tree -o build/gen_dom_tree
build/gen_dom_tree data/html src/web "$generated/html"
cmp "$generated/html/media_controls_dom.lucb" src/web/generated/html/media_controls_dom.lucb

# Ladybird's Layout, Ref and Crash tests (the copy in tests/libweb) through the headless runner,
# one worker process per test, against tests/expected_failures: an unexpected failure or an
# unexpected pass fails the run (DESIGN.md §6). After a change that makes tests pass or fail,
# review build/web_test_results and run `build/web_test --update-failures`.
echo "== web_test layout ref crash"
luce-base build tests/web_test -o build/web_test
build/web_test layout ref crash
