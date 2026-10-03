# Ladybird's LibWeb tests (phase 1)

A copy of part of Ladybird's `Tests/LibWeb`, which `tests/web_test` runs (DESIGN.md §6, §6.8).
Copied from Ladybird at the commit in `PIN` (`47c82b38d0`); Ladybird's tests are under the BSD
2-Clause License in `LICENSE` at the repository root. `fonts/` has its own `NOTICE`.

| Path | What |
| --- | --- |
| `Layout/input`, `Layout/expected` | the phase-1 Layout tests and their expected dumps (layout tree, paint tree, stacking contexts) |
| `Ref/input`, `Ref/expected`, `Ref/data` | the phase-1 reftests, their references and the files those refer to |
| `Crash` | the phase-1 crash tests |
| `Assets` | files the copied tests refer to |
| `TestConfig.ini` | test-web's skip lists, whole |
| `fonts` | the test-mode fonts (SerenitySans, Noto Emoji) and the fonts the CSS font tests use |

A test is in phase 1, and copied, when it is an HTML document (`.html`, `.htm`: XML documents need
the XML parser of phase 2) that needs neither script nor resources: no `<script`, no `<img`,
`<iframe`, `<object`, `<embed`, `<video`, `<audio`, `<picture`, `<source`, no stylesheet `<link>`,
no `@import`, no `url(` other than a fragment (DESIGN.md §1.3), and not a support file of an
imported WPT test (test-web's `support_file_patterns`). With a Layout test its expectation is
copied; with every copied document, the files it refers to (`href`, `src`, `url(...)`), such as a
reftest's reference. Directory structure is kept: tests refer to each other by relative paths.

| Suite | Inputs in Ladybird | Copied |
| --- | ---: | ---: |
| Layout | 962 | 845 |
| Ref | 1,037 | 602 |
| Crash | 192 | 43 |

The copy is refreshed only from the pinned donor, by the lead, with a local tool
(`luce-browser-tools/web_test/copy_tests.py DONOR ENGINE`, not part of this repository).
