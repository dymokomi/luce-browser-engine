#!/bin/sh
# Lint, not a test (`luc test` runs the tests): every hand-written fragment is laid out as
# luce-base fmt lays it out (the skeleton generator's types_* and stubs/ fragments are not,
# and generated ones are compared with their generators' output by tests/generated), and every
# module checks with -W without a word, except warnings in the code of another package, which
# are shown, and the module must then check without -W.
set -e
cd "$(dirname "$0")/.."
for file in $(git ls-files '*.lucb' | grep -v -e '/types_' -e '/stubs/' -e '/generated'); do
    luce-base fmt "$file" --check > /dev/null || { echo "$file is not formatted (luce-base fmt $file --write)"; exit 1; }
done
for module in src/web src/webview src/webview_api tools/gen_css_values tools/embed_css tools/gen_dom_tree tools/gen_aria_roles tools/site_sweep tests/web_test; do
    status=0
    output=$(luce-base check "$module" -W 2>&1) || status=$?
    pattern='^luce-base: luce_[a-z_]+/src/[^ ]*: warning: '
    dependency_warnings=$(printf '%s\n' "$output" | grep -E "$pattern" || true)
    output=$(printf '%s\n' "$output" | grep -v -E "$pattern" || true)
    if [ -n "$output" ]; then
        echo "$output"
        exit 1
    fi
    if [ "$status" -ne 0 ]; then
        [ -n "$dependency_warnings" ] || exit 1
        printf '%s\n' "$dependency_warnings" | sed 's/^/(another package) /'
        luce-base check "$module"
    fi
done
echo "clean"
