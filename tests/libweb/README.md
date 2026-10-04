# Ladybird's LibWeb tests (phases 1 and 2)

A copy of part of Ladybird's `Tests/LibWeb`, which `tests/web_test` runs (DESIGN.md §6, §6.8).
Copied from Ladybird at the commit in `PIN` (`47c82b38d0`); Ladybird's tests are under the BSD
2-Clause License in `LICENSE` (Ladybird's own, beside the data; the repository's `LICENSE` is the
same license). `fonts/` has its own `NOTICE`; the fonts in `Assets/` are under `Assets/OFL-1.1.txt`.

| Path | What |
| --- | --- |
| `Layout/input`, `Layout/expected`, `Layout/data` | the Layout tests, their expected dumps (layout tree, paint tree, stacking contexts) and the files they load |
| `Ref/input`, `Ref/expected`, `Ref/data` | the reftests, their references and the files those refer to |
| `Crash` | the crash tests and the files they load |
| `Screenshot/input`, `Screenshot/expected`, `Screenshot/data` | the Screenshot tests, their expected PNGs (rendered by Ladybird with Skia) and the files they load |
| `Assets` | files the copied tests refer to (images, fonts, media, `blank.html`) |
| `TestConfig.ini` | test-web's skip lists, whole |
| `fonts` | the test-mode fonts (SerenitySans, Noto Emoji) and the fonts the CSS font tests use |

A test (`.html`, `.htm`, `.svg`, `.xht`, `.xhtml`, `.pdf`, test-web's `is_valid_test_name`) is
copied when it needs no script (no `<script`), so it belongs to phase 1 or 2, and is not a support
file of an imported WPT test (test-web's `support_file_patterns`):

- **Phase 1**: an HTML document (`.html`, `.htm`) that needs no resources either: no `<img`,
  `<iframe`, `<object`, `<embed`, `<video`, `<audio`, `<picture`, `<source`, no stylesheet
  `<link>`, no `@import`, no `url(` other than a fragment (DESIGN.md §1.3).
- **Phase 2** (loading): the others, which need resources (images, style sheets, fonts, frames,
  SVG-as-image, media) or are XML documents (`.svg`, `.xht`, `.xhtml`) or a PDF.

With a Layout test its expectation is copied (`expected/T/N.txt`), with a Screenshot test its PNG
(`expected/T/N.png`); with every copied document, the files it refers to, recursively through the
style sheets, SVG and XML files it reaches (`href`, `xlink:href`, `src`, `srcset`, `data`, `poster`,
`background`, `url(...)`, `@import`), and their `.headers` files. Directory structure is kept: tests
refer to each other and to `Assets/` by relative paths. Tests that need script are phase 3 (with
`Text/`).

| Suite | Inputs in Ladybird | Phase 1 | Phase 2 | Copied | Need script (phase 3) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Layout | 962 | 845 | 77 | 922 | 40 |
| Ref | 1,032 | 602 | 218 | 820 | 212 |
| Crash | 192 | 43 | 9 | 52 | 140 |
| Screenshot | 97 | 51 | 16 | 67 | 30 |

(Inputs not counting support files. Phase 2 added 771 files, 9.0 MB, of which 2 MB is
`Assets/NotoEmoji.ttf`, which tests load by that path, and 2 MB `Assets/test-webm.webm`.)

The copy is refreshed only from the pinned donor, by the lead, with a local tool
(`luce-browser-tools/web_test/copy_tests.py [--phase N] DONOR ENGINE`, not part of this repository).
