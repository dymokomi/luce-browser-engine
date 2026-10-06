# luce-browser: design of the LibWeb port

The `luce-browser-*` packages are a **faithful port of Ladybird's LibWeb** to luce-base, with the parts of AK, LibGC,
LibGfx, LibUnicode, LibURL and LibTextCodec that LibWeb needs, and with **luce-js** (our QuickJS
port) in place of LibJS. It is meant to become the web engine of the Luce browser. This document
is the contract every porting agent follows. It says what is ported, in what order, how each C++
construct is spelled in luce-base, how memory works, how names map, how the work is split into
regions, how the result is tested against Ladybird's own tests, and what is not ported but
replaced.

Everything below was checked against the donor source unless marked *(unverified)*. Numbers are
`wc -l` of `.cpp` + `.h` unless stated otherwise.

- Donor: Ladybird at commit `47c82b38d0` (2026-05-03, "LibJS: Range-check enum-typed bytecode
  fields in the validator"), the last commit before Rust entered LibWeb. Checkout:
  `../.donors/ladybird-pin` (read-only).
- Language: `../luce-base/docs/language/base.md`. Precedent: `../luce-js/docs/PORTING.md`, whose
  integer, float, `goto`, `switch` and fragment rules apply here unchanged unless this document
  says otherwise.

## Contents

0. [Decisions at a glance](#0-decisions-at-a-glance)
1. [Scope and phases](#1-scope-and-phases)
2. [C++ to luce-base](#2-c-to-luce-base)
3. [Memory](#3-memory)
4. [Packages, names and the region workflow](#4-packages-names-and-the-region-workflow)
5. [Code generators](#5-code-generators)
6. [The test oracle](#6-the-test-oracle)
7. [Dependencies and what is replaced](#7-dependencies-and-what-is-replaced)
8. [Risks, order of work, estimate](#8-risks-order-of-work-estimate)
9. [Questions for the owner](#9-questions-for-the-owner)
10. [Appendix: facts checked against the donor](#10-appendix-facts-checked-against-the-donor)

---

## 0. Decisions at a glance

| Question | Decision | Section |
| --- | --- | --- |
| What is phase 1? | Static rendering of local documents with **scripting disabled** and **no fetching**: HTML parser → DOM → CSS parse/cascade/compute → layout → paintables → display list → CPU raster. Exit: Ladybird's own Layout, Ref and Crash tests that need neither script nor external resources (854 of 961 Layout inputs). | §1 |
| Class hierarchies | Embedded base struct as the first field, a `class_id` range tag for `is<T>`, one static vtable per class reached from the cell header, dispatcher functions with the C++ name, overrides named `…_impl`. | §2.3 |
| Mixins | Stateless pure-virtual mixins become luce-base **interfaces** (views); stateful mixins become **embedded structs** found by per-class offsets in `ClassInfo`; CRTP helper mixins (`ChildNode<T>`, `TreeNode<T>`) become functions on the base / a generic embedded `TreeNode[T]`. | §2.5 |
| Cells (GC objects) | **Port LibGC faithfully**: precise `visit_edges`, the same heap blocks, allocators, marking, finalization and weak cells, and conservative scanning of the stack and registers (done in luce-base with `asm`, verified). | §3.2–3.4 |
| AK owning types (String, Vector, HashMap, RefPtr, OwnPtr, Function captures) | *Decided.* **Managed memory**: they live in the same heap as *conservatively scanned blobs*; the heap is made the current allocator, so ported code writes plain `new`/`alloc` and never writes a destructor, `unref` or `free`. C++ *copies* of mutable containers become explicit `clone()`. | §3.3 |
| JS | luce-js stays reference counted. DOM objects are cells, not JS objects; each platform object may own one **wrapper** (a QuickJS object whose opaque is the cell). A joint collection (QuickJS's trial-deletion + LibGC marking in one pass) handles cross-heap cycles. Phase 1 reserves the wrapper slot and the JS-value visitor entry. | §3.6 |
| Errors | `ErrorOr<T>`, `WebIDL::ExceptionOr<T>`, `JS::ThrowCompletionOr<T>` → `T!`. The WebIDL exception or JS completion is stored in a per-VM slot before failing, as luce-js stores the pending JS exception. `MUST(x)` → `x else trap(...)`. | §2.10 |
| Operator overloading | Named methods (`add`, `sub`, `mul`, `lt`, …) on value types; geometry templates (`Rect<T>` …) are instantiated by a generator into concrete structs (`CssPixelRect`, `IntRect`, `FloatRect`, …). | §2.8 |
| Lambdas | No closures: a capture struct + a function pointer. Escaping callbacks (`Function<>`, `GC::Function<>`) put the capture struct in managed memory. Non-escaping `for_each_*` visitors become iterator loops where the traversal is plain. | §2.7, §2.9 |
| Packages | An acyclic family (§4.1): **luce-browser-foundation** (`ak`, `gc`, `web_unicode`, `text_codec`, `web_url`, `web_infra`) → **luce-browser-css** (`css_syntax`, `css_data`) and **luce-browser-html** (`html_syntax`) → **luce-browser-render** (`gfx`, `web_fonts`, `raster`, `display_list`) → **luce-browser-engine** (`web`) → the `luce-browser` application. The DOM/HTML/CSS-cascade/SVG/Layout/Painting core is one strongly connected component in the donor (e.g. 146 core files reference Layout/Painting, 550 qualified references, 31 layout-node factories) and stays one module; the tokenizers, CSS data and the display list split off with a handful of declaration moves and one hook. |
| Names | *Decided.* Lower packages: no prefix, the module qualifies (`gfx.FloatRect`, `css_syntax.Tokenizer`). Engine: short namespace prefixes `Dom`, `Html`, `Css`, `Layout`, `Paint`, `Svg`, `Fetch`, `Bind`, `Idl`, `Mime` (`DomNode`, `dom_node_append_child(this, …)`, `PaintStackingContext`); fields keep C++ names. A generated `docs/namemap.tsv` is authoritative. |
| Repositories | *Owner rule:* repositories hold only Luce code, the data their generators read, and the tests CI runs (Ladybird's test HTML and expectations are copied in); all C/C++ donor code, the reference build and comparison drivers stay in `/Users/sedov/Dev/luce_dev/.donors/`. |
| Parallel work | A **skeleton generator** (a local tool in `.donors/`: Python + libclang over the reference build's `compile_commands.json`) emits every struct, enum, vtable, `ClassInfo`, upcast/downcast helper and a typed `trap("unported: …")` stub per function, grouped by region and placed in the owning package; agents replace stubs region by region while every package keeps type-checking (luce-js's workflow, scaled up). | §4.4–4.5 |
| Generators | Ported to **Luce programs** in the package that owns their output, with Ladybird's JSON/CSS/IDL inputs copied as data; CI regenerates and diffs. IDL-derived enums/dictionaries come from the skeleton in P1 and from the Luce bindings generator in P3. |
| Test oracle | A headless Luce runner (`web_test`) in the engine runs the **copied** `Tests/LibWeb/{Layout,Ref,Crash}` (later Screenshot, Text), one process per test (traps are not catchable), with Ladybird's test-mode fonts (SerenitySans) and 800×600 viewport, comparing exactly (Layout) or with Ladybird's fuzzy rules (Ref); an expected-failures file ratchets. Comparisons with the reference build are local tools in `.donors/`, run before committing (§6.8). |
| Reference Ladybird | *Decided:* built locally under `.donors/` (by the coordinator); never in a repository. Used by the local skeleton extraction and comparison drivers. |
| Fonts | Replace Skia+HarfBuzz with a pure-Luce OpenType reader and a basic shaper. **Verified**: HarfBuzz's advances for SerenitySans are reproduced exactly by summing `round(advance_units × pixel_size × 64 / units_per_em)` per glyph and dividing by 64 (the test font has no GSUB/GPOS/kern). | §6.7, §7 |
| Painting backend | *Decided:* `DisplayListPlayerSkia` is replaced by a CPU player over a faithful Luce port of **tiny-skia**'s algorithms (to match Skia's anti-aliasing), plus glyphs, blur and filters, all inside **luce-browser-render**; a luce-gpu player later. |

---

## 1. Scope and phases

### 1.1 What is ported, adapted or replaced

| Ladybird | Size (cpp+h) | Package: module (§4.1) | How |
| --- | ---: | --- | --- |
| `Libraries/LibWeb` | 427,057 lines (333,814 cpp + 93,243 h) | engine: `web`; syntax layers in css: `css_syntax`, `css_data` and html: `html_syntax`; display list in render: `display_list` | ported, faithfully, in phases |
| `AK` | 43,167 | foundation: `ak` | the subset LibWeb uses (≈15k lines), adapted to managed memory (§3.3) |
| `Libraries/LibGC` | 3,722 | foundation: `gc` | ported faithfully + managed blobs + large-object space (§3.2–3.3) |
| `Libraries/LibURL` | 7,285 | foundation: `web_url` | ported (URL parser, Origin, Host, Site, public suffix) |
| `Libraries/LibTextCodec` | 2,624 (+ generated tables) | foundation: `text_codec` | ported |
| `Libraries/LibUnicode` | 8,482, **a wrapper over ICU** | foundation: `web_unicode` | replaced: the pieces LibWeb uses (segmenter: grapheme/word/line; bidi and line-break classes; IDNA later) written against UCD tables; normalization and casing from luce-std `unicode` |
| `Libraries/LibGfx` | 23,051, built on **Skia, HarfBuzz, libpng, libjpeg-turbo, …** | render: `gfx`, `web_fonts`, `raster` | geometry, Color, AffineTransform, Font/Typeface/FontDatabase/FontCascadeList/TextLayout *interfaces* ported; Skia typeface, HarfBuzz shaping, Skia paths and the Skia painter replaced (§7) |
| `Libraries/LibJS` | — | **luce-js** | not ported; LibJS types that LibWeb names (`JS::Realm`, `JS::VM`, `JS::Value`, `JS::Cell`) become small engine types (§3.6) |
| `Libraries/LibXML` | 968, **a wrapper over libxml2** | engine, later | XHTML/SVG documents need an XML parser (phase 2) |
| `Libraries/LibRegex` | Rust-backed | luce-regex | `pattern` attribute, URLPattern (phase 3+) |
| `LibCore`, `LibIPC`, `LibWebView`, `Services/*` | — | not ported | the browser shell and process model are Luce's own; LibWeb's `Platform/*Plugin` seams are implemented directly |

### 1.2 Phases

| Phase | Content | Exit criterion |
| --- | --- | --- |
| **P0 foundations** | skeleton generator, `ak`, `gc`, `web_url`, `text_codec`, `web_unicode`, `gfx` (geometry, color, fonts, path/paint model), the rasterizer, all phase-1 generators, test runner scaffold | each module's unit tests (ported from `Tests/AK`, `Tests/LibURL`, `Tests/LibTextCodec`, `Tests/LibUnicode/TestSegmenter.cpp`, `Tests/LibWeb/TestCSSPixels.cpp`) pass; the `web` skeleton type-checks with every function stubbed |
| **P1 static slice** | HTML parser → DOM → CSS → layout → painting → CPU raster, scripting disabled, `file:` documents given as bytes, no subresource fetching | Layout: all 854 runnable tests pass except a reviewed expected-failures list (target ≥ 95%); Ref: the 627 runnable reftests at the same bar; Crash: the 47 runnable crash tests do not trap |
| **P2 loading** | Fetch (`Fetch/`, `Loader/`), real navigation and session history, `file:`/`data:`/`http(s):` via a `RequestClient` seam, images (`<img>`, CSS `url()`), external style sheets and `@import`, `@font-face` (+ WOFF), iframes, SVG-as-image, XHTML/XML documents, CSP and MIME sniffing | the remaining Layout/Ref/Crash/Screenshot tests that need resources but not script |
| **P3 scripting** | bindings generator (IDL → luce-js classes), WebIDL conversions, realms and intrinsics on luce-js contexts, wrappers and the joint GC, microtasks, HTML scripting (classic + module), the JS-facing DOM/CSSOM APIs, events from JS, `Tests/LibWeb/Text` | Text tests (4,785 inputs) at a ratcheting pass rate; all scripted Layout/Ref/Crash tests |
| **P4 the rest** | input and editing (`Page/EventHandler`, `Editing/`, `UIEvents/`), animations and transitions, Canvas 2D, media, workers, storage, `Streams`, `XHR`, `WebSockets`, IndexedDB, … | driven by the browser's needs |

P0 and P1 are the subject of the region list in §8.2. P2–P4 are planned at directory granularity.

### 1.3 Why this phase 1: what the tests need

Counts over `Tests/LibWeb` (an input "needs script" if it contains `<script`; it "needs resources"
if it contains `<img`, a stylesheet `<link>`, a non-fragment `url(`, `@import`, `<iframe`,
`<object`, `<embed`, `<video`, `<audio`, `<picture` or `<source`):

| Suite | Inputs | Need script | Need resources | Need neither (**P1**) |
| --- | ---: | ---: | ---: | ---: |
| Layout | 961 (952 `.html`, 9 `.svg`/other) | 40 | 69 | **854** |
| Ref | 948 | 211 | 128 | **627** |
| Crash | 192 | 140 | 37 | **47** |
| Screenshot | 97 | 30 | 21 | 51 (P2: needs Skia-like pixels, §6.4) |
| Text | 4,785 | all (JS harness) | — | P3 |

Ladybird's runner itself drives tests with injected JavaScript (`afterFontsAndPaint`,
`internals.signalTestIsDone`, reading `<link rel=match>` through JS). The Luce runner does these
steps natively (§6.1), so no JS is needed for the P1 set.

Elements that P1 layout tests use, by number of test files containing them: `div`, `span`, `p`,
`table` (85 files), `svg` (68), `img` (57, P2 when it loads), `input` (29), `button` (19),
`fieldset`/`legend`, `textarea` (6), `ol`/`ul`/`li`, `details`/`summary` (4), `select` (3),
`dialog`, `template`/`slot` (declarative shadow DOM), `progress`, `math` (2), `video`/`audio` (2
each). Form controls matter in P1 because their user-agent shadow trees appear in the layout dumps
and are built in C++, not JS.

P1 runs pages with **scripting disabled** (`Page::set_is_scripting_enabled(false)`, the mode
upstream already uses for SVG-as-image in `SVG/SVGDecodedImageData.cpp`). Only 2 Layout/Ref inputs
contain `<noscript>`, whose parsing depends on the flag; they go on the expected-failures list
until P3.

### 1.4 Phase-1 file list

Legend: **port** = port every function; **types** = port the struct (and constructor) because
phase-1 types reference it or `ElementFactory` must be able to create it, stub the behavior;
**later** = not in P1 (not even types unless the skeleton's closure pulls them in, §4.4).

#### Top level and small directories

| Path | P1 | Notes |
| --- | --- | --- |
| `Dump.cpp/.h` | port | the layout/paint/stacking-context dump is the Layout oracle |
| `PixelUnits.cpp/.h` | port | `CSSPixels`, `CSSPixelFraction`, `DevicePixels` |
| `Namespace.cpp/.h`, `Forward.h`, `InvalidateDisplayList.h`, `GraphemeEdgeTracker.*` | port | |
| `Platform/` (607) | port | `FontPlugin` (test mode: SerenitySans everywhere), `ImageCodecPlugin` (seam), `EventLoopPlugin`, `Timer` — implemented directly, no LibCore |
| `Page/Page.*` (1,615) | port (creation, viewport, rendering entry points) | `EventHandler`, `DragAndDropEventHandler`, `InputEvent`, scroll handlers: later |
| `Infra/` (556), `MimeSniff/` (1,530) | port | |
| `Bindings/` (2,331) | types | `PlatformObject`, `HostDefined`, `Intrinsics` as data; the generated bindings are P3 |
| `WebIDL/` (3,116) | types + `ExceptionOr`, `DOMException`, `SimpleException` | |
| `Loader/`, `Fetch/` | types where referenced | P2 |
| `Animations/`, `ARIA/`, `Editing/`, `Selection/`, `UIEvents/`, `ResizeObserver/`, `IntersectionObserver/` | types where referenced | P3/P4; `ARIAMixin` and `Animatable` are embedded in `Element` (types only) |
| everything else (`Crypto`, `WebGL`, `WebAudio`, `IndexedDB`, `Streams`, `WebDriver`, `ContentSecurityPolicy`, …) | later | |

#### DOM (33,345)

| Files | P1 |
| --- | --- |
| `Node`, `ParentNode`, `ChildNode`, `NonElementParentNode`, `NonDocumentTypeChildNode`, `TreeNode` (top-level `TreeNode.h`), `NodeOperations`, `Element`, `Document` (the rendering, style and structure parts), `DocumentLoading` (the HTML path), `DocumentFragment`, `DocumentType`, `CharacterData`, `Text`, `Comment`, `CDATASection`, `ProcessingInstruction`, `Attr`, `NamedNodeMap`, `QualifiedName`, `ElementFactory`, `ElementByIdMap`, `ShadowRoot`, `Slot`, `Slottable`, `SlotRegistry`, `StyleElementBase`, `PseudoElement`, `AbstractElement`, `AnchorNameMap`, `AdoptedStyleSheets`, `DocumentLoadEventDelayer`, `DocumentObserver`, `DOMImplementation`, `DOMTokenList`, `HTMLCollection`, `LiveNodeList`, `NodeList`, `StaticNodeList`, `Position`, `Utils`, `XMLDocument` | port |
| `Event`, `EventTarget`, `EventDispatcher`, `CustomEvent`, `DOMEventListener`, `IDLEventListener`, `AbortController`, `AbortSignal` | port (load/DOMContentLoaded are dispatched; with no listeners dispatch is cheap) |
| `Range`, `StaticRange`, `AbstractRange`, `MutationObserver`, `MutationRecord`, `MutationType`, `NodeIterator`, `TreeWalker`, `NodeFilter`, `EditingHostManager`, `AccessibilityTreeNode` | types (P3) |

#### CSS (91,710)

| Group | Files | Lines | P1 |
| --- | --- | ---: | --- |
| parser | `CSS/Parser/*` (Tokenizer, Token, ComponentValue, Parser, RuleParsing, SelectorParsing, MediaParsing, DescriptorParsing, SyntaxParsing, ValueParsing, PropertyParsing, GradientParsing, ArbitrarySubstitutionFunctions, Helpers, Types, ErrorReporter, RuleContext, Syntax) | 24,095 | port |
| style values | `CSS/StyleValues/*` (77 classes, e.g. `CalculatedStyleValue` 4,590) | 17,115 | port |
| cascade and computed style | `StyleComputer`, `CascadedProperties`, `ComputedProperties`, `ComputedValues.h`, `StyleProperty`, `CustomPropertyData`, `StyleScope`, `CountersSet`, `CSSStyleProperties`, `CSSStyleDeclaration`, `CSSDescriptors`, `Descriptor` | 11,301 | port |
| selectors | `Selector`, `SelectorEngine`, `PageSelector` | 3,247 | port |
| sheets and rules | `CSSStyleSheet`, `CSSRule`, `CSSRuleList`, `CSS*Rule`, `StyleSheet`, `StyleSheetList`, `StyleSheetIdentifier`, `MediaList`, `CSSNestedDeclarations`, … | 5,786 | port (`CSSImportRule` loading is P2) |
| media, supports, containers | `MediaQuery`, `MediaQueryList`, `BooleanExpression`, `Supports`, `ContainerQuery`, `Preferred*`, `Resolution`, `Ratio`, `Screen`, `VisualViewport` | 2,480 | port (the JS-facing parts types only) |
| values and units | `Length`, `Angle`, `Time`, `Frequency`, `Flex`, `Percentage`, `Number`, `Size`, `Display`, `GridTrackSize`, `GridTrackPlacement`, `LengthBox`, `EdgeRect`, `Clip`, `Filter`, `Sizing`, `Serialize`, `URL`, `Fetch` (CSS fetch helpers, types), `SystemColor`, `CounterStyle*`, `ValueType`, `ColorFunctionDescriptor`, … | 6,861 | port |
| fonts | `FontComputer`, `FontFace`, `FontFaceSet`, `FontFeatureData`, `FontLoading`, `ParsedFontFace`, `CSSFontFace*` | 4,639 | port the computation; web-font loading P2 |
| invalidation | `CSS/Invalidation/*`, `StyleInvalidation*`, `InvalidationSet`, `StyleSheetInvalidation` | 3,986 | port (needed by the "layout-tree-update" tests and by correct restyles) |
| typed OM | `CSSNumericValue`, `CSSUnitValue`, `CSSMath*`, `CSSRotate`, `CSSScale`, `CSSSkew*`, `CSSTranslate`, `CSSPerspective`, `CSSTransformValue`, `CSSTransformComponent`, `CSSMatrixComponent`, `StylePropertyMap*`, `CSSKeywordValue`, `CSSUnparsedValue`, `CSSVariableReferenceValue`, `CSSImageValue`, `CSSStyleValue`, `CSSNumericArray`, `NumericType` | 7,047 | later (P3); `NumericType` is ported if `CalculatedStyleValue` needs it (it does: calc type checking) |
| animations | `Interpolation`, `CSSAnimation`, `CSSTransition`, `CSSKeyframe(s)Rule`, `EasingFunction`, `ColorInterpolation`, `AnimationEvent`, `TransitionEvent` | 5,153 | later (P4); `ColorInterpolation` is needed by `color-mix()` and gradients: port it |

#### Layout (24,610), Painting (14,238), SVG (13,754)

| Directory | P1 |
| --- | --- |
| `Layout/` all 51 classes (`GridFormattingContext` 3,251, `FormattingContext` 2,862, `FlexFormattingContext` 2,704, `TableFormattingContext` 2,190, `Node` 2,034, `BlockFormattingContext` 1,957, `TreeBuilder` 1,448, `LayoutState` 1,308, `TextNode`, `SVGFormattingContext`, `InlineFormattingContext`, `InlineLevelIterator`, `LineBuilder`, …) | port (`VideoBox`, `AudioBox`, `CanvasBox` types + trivial layout) |
| `Painting/` all except `DisplayListPlayerSkia` (870) and `BackingStoreManager` | port |
| `Painting/DisplayListPlayerSkia` | **replaced** by `DisplayListPlayerCpu` over the Luce rasterizer (§7.3) |
| `SVG/` elements, `AttributeParser`, `Path`, `SVGLength`, `SVGTransform`, animated-value classes, `SVGDecodedImageData` | port; filter primitive elements (`SVGFE*`) types + attribute parsing, filter rendering later |

#### HTML (96,956)

| Group | P1 |
| --- | --- |
| `HTML/Parser/*` (11,789: `HTMLTokenizer` 3,076, `HTMLParser` 5,892, `HTMLEncodingDetection`, stack/formatting lists, `HTMLToken`, entities) | port (`SpeculativeHTMLParser`, `IncrementalDocumentParser`: types) |
| `HTMLElement` (2,799), `HTMLOrSVGElement`, `FormAssociatedElement` (1,670), `FormControlInfrastructure`, `AutocompleteElement`, `GlobalEventHandlers`, `WindowEventHandlers`, `LazyLoadingElement`, `HTMLHyperlinkElementUtils`, `AttributeNames`, `TagNames`, `EventNames`, `Numbers`, `Dates`, `SourceSet`, `DOMStringMap`, `ValidityState`, `ElementInternals`, `Focus` | port |
| the 74 `HTML*Element` classes | port those that affect style or layout (presentational hints, UA shadow trees, replaced sizing): `Body`, `Html`, `Head`, `Div`, `Span`, `Paragraph`, `Heading`, `Pre`, `BR`, `HR`, `Font`, `Table*` (7), `LI`, `OList`, `UList`, `DList`, `Menu`, `Directory`, `Details`, `Summary`, `Dialog`, `FieldSet`, `Legend`, `Input` (4,355), `TextArea`, `Select`, `Option`, `OptGroup`, `SelectedContent`, `Button`, `Label`, `Meter`, `Progress`, `Output`, `Image`, `Picture`, `Source`, `Slot`, `Template`, `Style`, `Link` (sheet parts), `Meta`, `Base`, `Title`, `Marquee`, `Frame`, `FrameSet`, `IFrame`, `Object`, `Embed`, `Canvas`, `Video`, `Audio`, `Media` (the last seven: types + intrinsic sizing only), `Script` (types; scripting is disabled), all trivial ones (`Data`, `Time`, `Quote`, `Mod`, `Param`, `Map`, `Area`, `Anchor`, `Unknown`, …) |
| `ImageRequest`, `SharedResourceRequest`, `DecodedImageData`, `AnimatedDecodedImageData`, `ListOfAvailableImages` | types (P2) |
| `Window`, `WindowProxy`, `Navigable` (3,619), `TraversableNavigable` (2,053), `NavigableContainer*`, `BrowsingContext*`, `DocumentState`, `SessionHistoryEntry`, `NavigationParams`, `PolicyContainers`, `SandboxingFlagSet`, `CrossOrigin/*` | port creation, viewport and rendering paths (`create_a_new_top_level_traversable`, `Document::create_and_initialize`, `viewport_rect`, `record_display_list_and_scroll_state`, `render_screenshot`); navigation algorithms are P2 stubs |
| `EventLoop/*` (1,380), `Scripting/Environments`, `WindowEnvironmentSettingsObject` | port the task queues, `update_the_rendering` and the environment data; script execution is P3 |
| `MediaControls*` (generated DOM) | types + generated DOM (P1 for the two video/audio tests) |
| `Canvas/*`, `CanvasRenderingContext2D`, `OffscreenCanvas*`, `ImageData`, `ImageBitmap`, text tracks, workers, storage, messaging, history, navigation API, `StructuredSerialize`, `XMLSerializer`, … | later |

Phase-1 LibWeb total, by the groups above: ≈245k lines (cpp+h), of which roughly 10–15%
(navigation, scripting, JS-facing API bodies) stays stubbed at the end of P1.

### 1.5 Generated sources phase 1 needs

| Output (Ladybird path) | From | Generator | P1 |
| --- | --- | --- | --- |
| `CSS/PropertyID.*` | `CSS/Properties.json` (4,703 lines) + `Enums.json` + `LogicalPropertyGroups.json` | `generate_libweb_css_property_id.py` (1,612) | yes |
| `CSS/Enums.*`, `CSS/Keyword.*`, `CSS/Units.*`, `CSS/PseudoClass.*`, `CSS/PseudoElement.*`, `CSS/MediaFeatureID.*`, `CSS/TransformFunctions.*`, `CSS/MathFunctions.*`, `CSS/DescriptorID.*`, `CSS/EnvironmentVariable.*`, `CSS/Parser/GeneratedValueTypesParsing.*` | the matching `CSS/*.json` | the matching `generate_libweb_css_*.py` | yes |
| `CSS/GeneratedCSSStyleProperties.*` | `Properties.json` | `generate_libweb_css_style_properties.py` | yes (the declaration model uses it; the JS accessors are P3) |
| `CSS/GeneratedCSSNumericFactoryMethods.*` | `Units.json` | `…numeric_factory_methods.py` | P3 (typed OM) |
| `CSS/DefaultStyleSheetSource.cpp`, `QuirksModeStyleSheetSource.cpp`, `SVG/SVGStyleSheetSource.cpp`, `MathML/MathMLStyleSheetSource.cpp` | the `.css` files | `embed_as_string.py` | yes |
| `HTML/Parser/NamedCharacterReferences.*` | `HTML/Parser/Entities.json` | `generate_libweb_html_named_character_references.py` (538) | yes |
| `HTML/MediaControlsDOM.*` | `HTML/MediaControls.html` | `generate_dom_tree.py` | yes |
| `ARIA/AriaRoles.*` | `ARIA/AriaRoles.json` | `generate_libweb_aria_roles.py` | yes (small; `ARIAMixin` is in `Element`) |
| `LibTextCodec/LookupTables.*` | `indexes.json` | `generate_encoding_indexes.py` | yes |
| `LibURL/PublicSuffixData.*` | public suffix list | `generate_public_suffix_data.py` | yes |
| IDL enums, dictionaries, `Bindings::InterfaceName` (phase-1 code names 352 distinct `LibWeb/Bindings/*.h` headers, e.g. `Bindings::ShadowRootMode`, `NavigationType`, `ScrollLogicalPosition`) | `*.idl` via the C++ `BindingsGenerator` | **P1: extracted by the skeleton generator from the reference build's generated headers**; P3: our Python bindings generator | types only |
| `AK/Debug.h` (CMake-generated debug switches) | `AK/Debug.h.in` | none: one constant file | yes |

The generator column names Ladybird's generators; each is ported as a Luce program in the
package that owns its output (§5).

---

## 2. C++ to luce-base

### 2.1 Principles

- **Same algorithms, same order, same comments.** Every spec-step comment (`// 3. Let parent be
  this's parent.`) is kept as a `#` comment above the same code. Where the C++ says `FIXME`, the
  port says `FIXME`. Behavior is never "improved" during the port.
- **One C++ function, one Luce function**, in the C++ file's order, in the fragment that mirrors
  that file (§4.3). Inline header functions go to the fragment of the matching `.cpp`.
- **Mechanical before clever.** When two spellings are possible, choose the one a reviewer can
  check line by line against the C++.
- The luce-js rules on integer overflow (`+%` for wrapping), promotion, conversions (`(T)x` vs
  `T(x)`), `goto`, `switch`→`match` and fallthrough apply unchanged
  (`../luce-js/docs/PORTING.md`, "Integer semantics", "Errors and control flow").
- **Floats keep their width.** C++ `float` stays `f32`, `double` stays `f64`; mixed expressions
  are widened where C++ widens. Layout results depend on it.
- **Order-sensitive helpers are ported, never substituted**: `AK::quick_sort` (not a stable sort),
  AK's hash functions (`int_hash`, `string_hash`, `pair_int_hash`), AK's float formatting
  (`FormatBuilder::put_f64`), because the dumps and iteration orders depend on them.

### 2.2 The receiver and methods

C++ member functions become **free functions** whose first parameter is `this` (luce-base
reserves `self` for methods declared inside a struct body, and struct bodies cannot span
fragments). Fields keep their C++ names. `const` on GC objects is dropped (Ladybird's `const` on
cells is shallow and routinely `const_cast`); `const` stays on value types passed by pointer.

```c++
// DOM/Node.cpp
void Node::set_needs_style_update(bool value) { ... m_needs_style_update = value; ... }
```

```luce
## Ported from DOM/Node.cpp Node::set_needs_style_update.
func dom_node_set_needs_style_update(this: DomNode*, value: bool):
    ...
    this.m_needs_style_update = value
```

Struct bodies hold only fields and **generated** one-line methods (upcasts and interface
requirements); every ported function is free.

### 2.3 Class hierarchies with virtual methods

Ladybird has ≈473 cell classes in DOM/CSS/Layout/Painting/SVG/HTML/Page (221 `GC_CELL`, 565
`WEB_PLATFORM_OBJECT`, 27 `WEB_NON_IDL_PLATFORM_OBJECT`, 20 `JS_OBJECT` across LibWeb) and ≈455
introduced (non-`override`) virtual declarations in those directories, plus the ref-counted
`CSS::StyleValue` family (72 kinds). All use the same scheme:

1. **Embedded base first.** A derived struct's first field is its base struct, so a pointer to
   the derived struct is a pointer to every base (C layout is guaranteed, §5.11 of the language).
2. **A class id** in the cell header, numbered in pre-order over the whole hierarchy, so "is an X
   or a subclass of X" is `first(X) <= id <= last(X)`.
3. **A vtable per class**, a `let` struct of function pointers. A class that introduces virtuals
   has a vtable struct whose first field is its base's vtable struct. The cell header points at
   the most-derived class's table.
4. **A `ClassInfo` per class**: name, id range, size, vtable, allocator, mixin offsets (§2.5).
5. **Dispatchers keep the C++ name**: `dom_node_node_name(node)` makes the virtual call. Each
   class's body for a virtual is `<class>_<method>_impl`, taking the *introducing* class's pointer
   (`base`) and casting on entry. `Base::method(...)` upcalls call the base's `_impl` directly.

All of the following is generated by the skeleton (§4.4) except the `_impl` bodies:

```luce
# ---- gc (the cell header, ported from LibGC/Cell.h) -------------------------------------
pub struct CellVTable:
    pub let class_name: str                                 # GC_CELL's class_name()
    pub let visit_edges: func(Cell*, Visitor*) -> unit
    pub let finalize: func(Cell*) -> unit
    pub let must_survive_garbage_collection: func(Cell*) -> bool

pub struct Cell:
    pub var vtable: const CellVTable*
    pub var class_id: u16          # web.ClassId as u16; gc does not know the enum
    pub var m_mark: bool
    pub var m_state: CellState

# ---- web (JS::Cell, LibJS/Heap/Cell.h: the base of every LibWeb cell) ------------------------
pub struct JsCellVTable:
    pub let cell: CellVTable
    pub let class_info: const ClassInfo*
    pub let initialize: func(Cell*, Realm*) -> unit        # virtual void initialize(Realm&)

pub struct ClassInfo:
    pub let name: str
    pub let first_id: u16
    pub let last_id: u16           # pre-order range of this class and its subclasses
    pub let size: usize
    pub let vtable: const JsCellVTable*
    pub let mixins: const MixinOffsets*   # §2.5
```

```luce
# ---- web: generated for DOM::Node (web/dom/types_node.lucb) ---------------------------------
pub struct DomNodeVTable:
    pub let event_target: DomEventTargetVTable     # base table first
    pub let node_name: func(DomNode*) -> FlyString  # virtual FlyString node_name() const = 0
    pub let is_html_element: func(DomNode*) -> bool
    ...

pub struct DomNode: IsCell, IsDomEventTarget, IsDomNode:
    pub var event_target: DomEventTarget   # base first (DOM::EventTarget → PlatformObject → JS::Cell → GC::Cell)
    pub var tree: TreeNode[DomNode]     # the TreeNode<Node> mixin, §2.5
    pub var m_document: DomDocument*?
    pub var m_layout_node: LayoutNode*?
    pub var m_needs_style_update: bool
    ...
    func cell() -> Cell*: return (Cell*)&self
    func dom_event_target() -> DomEventTarget*: return (DomEventTarget*)&self
    func dom_node() -> DomNode*: return (DomNode*)&self

func dom_node_vt(this: DomNode*) -> const DomNodeVTable*:
    return (const DomNodeVTable*)this.cell().vtable      # DomNodeVTable begins with JsCellVTable

## Virtual: DOM::Node::node_name().
pub func dom_node_node_name(this: DomNode*) -> FlyString:
    return dom_node_vt(this).node_name(this)
```

A full class, `HTML/HTMLDivElement.cpp` (61 lines of C++), ported:

```luce
#==============================================================================================
#
#   html_div_element - HTMLDivElement: presentational hints for <div align>
#
#   DESCRIPTION:
#       Port of LibWeb/HTML/HTMLDivElement.cpp (lines 1-61).
#
#==============================================================================================

## Ported from HTMLDivElement.cpp:17 HTMLDivElement::HTMLDivElement.
func html_div_element_construct(this: HtmlDivElement*, document: DomDocument*,
        qualified_name: DomQualifiedName):
    html_element_construct(this.html_element(), document, qualified_name)
    cell_set_class(this.cell(), &html_div_element_class)    # the C++ vptr moves after the base ctor

## Ported from HTMLDivElement.cpp:24 HTMLDivElement::is_presentational_hint (override).
func html_div_element_is_presentational_hint_impl(base: DomElement*, name: FlyString) -> bool:
    if html_element_is_presentational_hint_impl(base, name):
        return true
    return name == html_attribute_names_align

## Ported from HTMLDivElement.cpp:33 HTMLDivElement::apply_presentational_hints (override).
# https://html.spec.whatwg.org/multipage/rendering.html#flow-content-3
func html_div_element_apply_presentational_hints_impl(base: DomElement*,
        properties: Vector[CssStyleProperty]*):
    html_element_apply_presentational_hints_impl(base, properties)
    for attribute in dom_element_attributes(base):           # for_each_attribute([&](name, value) {...})
        if attribute.name == html_attribute_names_align:
            let value = attribute.value
            if value.equals_ignoring_ascii_case("left"):
                properties.append(CssStyleProperty(property_id = .text_align,
                    value = css_keyword_style_value_create(.libweb_left)))
            elif value.equals_ignoring_ascii_case("right"):
                properties.append(CssStyleProperty(property_id = .text_align,
                    value = css_keyword_style_value_create(.libweb_right)))
            elif value.equals_ignoring_ascii_case("center"):
                properties.append(CssStyleProperty(property_id = .text_align,
                    value = css_keyword_style_value_create(.libweb_center)))
            elif value.equals_ignoring_ascii_case("justify"):
                properties.append(CssStyleProperty(property_id = .text_align,
                    value = css_keyword_style_value_create(.justify)))

## Ported from HTMLDivElement.cpp:51 HTMLDivElement::initialize (override).
func html_div_element_initialize_impl(base: Cell*, realm: Realm*):
    web_set_prototype_for_interface(base, realm, .html_div_element)   # WEB_SET_PROTOTYPE_FOR_INTERFACE: no-op until P3
    html_element_initialize_impl(base, realm)
```

and the generated parts it relies on:

```luce
let html_div_element_vtable = HtmlElementVTable(
    element = DomElementVTable(
        node = DomNodeVTable(... inherited slots copied from html_element_vtable's initializer ...),
        is_presentational_hint = html_div_element_is_presentational_hint_impl,
        apply_presentational_hints = html_div_element_apply_presentational_hints_impl,
        ...),
    ...)

pub let html_div_element_class = ClassInfo(name = "HTMLDivElement",
    first_id = (u16)ClassId.html_div_element, last_id = (u16)ClassId.html_div_element,
    size = memory.size_of(HtmlDivElement), vtable = (const JsCellVTable*)&html_div_element_vtable,
    mixins = &html_div_element_mixins)
```

**Creation.** `realm.create<T>(args…)` = allocate (under `DeferGC`), construct, then the virtual
`initialize(realm)`; `heap.allocate<T>(args…)` = allocate and construct. The generator emits one
typed helper per C++ constructor:

```luce
## realm.create<HTML::HTMLDivElement>(document, qualified_name)
pub func realm_create_html_div_element(realm: Realm*, document: DomDocument*,
        qualified_name: DomQualifiedName) -> HtmlDivElement*:
    let heap = realm_heap(realm)
    heap_defer_gc(heap)
    let this = (HtmlDivElement*)web_allocate_cell(heap, &html_div_element_class)   # zeroed; the class's allocator
    html_div_element_construct(this, document, qualified_name)
    heap_undefer_gc(heap)
    cell_initialize(this.cell(), realm)
    return this
```

C++ default member initializers (`bool m_x { true };`) run at the start of the constructor, before
the body: the skeleton emits `<class>_init_fields(this)` for non-zero defaults it can translate
(literals, enum values, `{}`); the porter writes the rest. Memory is zeroed, so zero defaults need
nothing.

**Destructors** do not exist in the port (managed memory, §3.3). A C++ destructor with an
observable side effect other than freeing (rare: unregistering from a registry, closing an OS
handle) becomes the cell's `finalize` (LibGC runs finalizers before sweeping) or a blob finalizer.

**Ref-counted hierarchies** (`CSS::StyleValue` and its 72 kinds, `CSS::Selector`,
`CSS::CalculationNode`, `Painting::DisplayList`, `Gfx::Font`, …) use the same embedded-base +
kind + vtable scheme without the GC header; `StyleValue` already has a `Type` enum
(`ENUMERATE_CSS_STYLE_VALUE_TYPES`), which becomes the kind. `NonnullRefPtr<StyleValue const>`
is `CssStyleValue*` (§2.6).

### 2.4 `is<T>`, `as<T>`, `as_if<T>`, `verify_cast`

Generated per class, from the class-id ranges (C++ `fast_is<T>` specializations and `is_foo()`
virtuals are subsumed; the `is_foo()` virtuals are still ported because other code calls them):

```luce
pub func is_html_element(node: DomNode*) -> bool:
    let id = node.cell().class_id
    return id >= (u16)ClassId.html_element and id <= (u16)ClassId.html_element_last

pub func as_if_html_element(node: DomNode*) -> HtmlElement*?:
    if is_html_element(node): return (HtmlElement*)node
    return none

pub func as_html_element(node: DomNode*) -> HtmlElement*:        # as<T>, verify_cast<T>
    return as_if_html_element(node) else trap("as<HTML::HTMLElement> failed")
```

Each helper takes the root class of its hierarchy (`DomNode*` for DOM nodes, `LayoutNode*`,
`PaintPaintable*`, `Cell*` for anything). C++ templates parameterized by a class
(`first_child_of_type<T>()`, `for_each_in_subtree_of_type<T>`, `first_ancestor_of_type<T>`)
cannot be luce-base generics, because a generic body cannot ask a type parameter for its class id
(no static interface requirements; checked). They take a `ClassInfo` value instead, and the call
site downcasts:

```luce
# document.first_child_of_type<HTML::HTMLHtmlElement>()
let html = as_if_html_html_element(dom_node_first_child_of_type(doc.dom_node(), &html_html_element_class) else ...)
```

### 2.5 Multiple inheritance and mixins

| C++ pattern | Examples | Luce |
| --- | --- | --- |
| Single primary base | everything | embedded base first (§2.3) |
| CRTP tree mixin with state | `TreeNode<Node>` (DOM), `TreeNode<Layout::Node>`, `TreeNode<Painting::Paintable>`, `TreeNode<PseudoElementTreeNode>` | generic embedded struct `TreeNode[T]` + generic functions constrained by an interface giving access to it |
| CRTP helper mixins, no state | `ChildNode<Element>`, `NonDocumentTypeChildNode<Element>`, `HTMLOrSVGElement<HTMLElement>` (its state is two fields) | functions on the concrete base (`dom_element_before`, …); the two `HTMLOrSVGElement` fields are embedded |
| Stateful mixin with virtuals | `FormAssociatedElement`, `SlottableMixin`, `ARIA::ARIAMixin`, `Animations::Animatable`, `FormAssociatedTextControlElement`, `PopoverTargetAttributes`, `AutocompleteElement`, `SVGURIReferenceMixin`, `SVGFilterPrimitiveStandardAttributes` | embedded struct at a class-specific offset + its own vtable pointer + a back pointer to the owning cell; cross-casts through `ClassInfo.mixins` |
| Pure-virtual interface, no state | `Layout::ImageProvider`, `HTML::GlobalEventHandlers`, `WindowEventHandlers`, `Bindings::Serializable`, `Transferable` | a luce-base **interface**; the owning class declares conformance and the generator emits the requirement methods as one-line forwards |
| `Weakable`, `RefCounted`, `AtomicRefCounted` | `Selector`, `StyleValue`, `Font`, `Typeface`, … | dropped (§3.3); `WeakPtr` becomes a GC weak |

`TreeNode<T>` (top-level `TreeNode.h`):

```luce
pub struct TreeNode[T]:
    pub var m_parent: T*?
    pub var m_first_child: T*?
    pub var m_last_child: T*?
    pub var m_next_sibling: T*?
    pub var m_previous_sibling: T*?

pub interface HasTreeNode[T]:
    func tree() -> TreeNode[T]*

## TreeNode<T>::append_child
pub func tree_append_child[T: HasTreeNode[T]](this: T*, node: T*):
    assert(node.tree().m_parent == none)
    if let last = this.tree().m_last_child:
        last.tree().m_next_sibling = node
    node.tree().m_previous_sibling = this.tree().m_last_child
    node.tree().m_parent = this
    this.tree().m_last_child = node
    if this.tree().m_first_child == none:
        this.tree().m_first_child = this.tree().m_last_child
```

(The generic-with-interface pattern, generic structs conforming to generic interfaces, and a
`let` vtable of nested structs of function pointers were each compiled and run with the current
compiler while writing this document.)

Stateful mixins: C++ reaches a mixin subobject by a pointer adjustment. Luce does it explicitly:

```luce
pub struct FormAssociatedElement:        # HTML/FormAssociatedElement.h
    pub var vtable: const FormAssociatedElementVTable*
    pub var m_owner: HtmlElement*         # the cell this mixin lives in (C++ `this` adjustment)
    pub var m_form: HtmlFormElement*?
    pub var m_parser_inserted: bool
    ...

pub struct MixinOffsets:
    pub let form_associated_element: usize?    # offsetof(ConcreteClass, m_form_associated)
    pub let slottable: usize?
    pub let aria_mixin: usize?
    ...

pub func as_if_form_associated_element(node: DomNode*) -> FormAssociatedElement*?:
    let info = cell_class_info(node.cell())
    let offset = info.mixins.form_associated_element else return none
    return (FormAssociatedElement*)((u8*)node + offset)
```

`FormAssociatedElement`'s virtuals (`is_listed`, `is_submittable`, `suffering_from_*`, …) are
slots in `FormAssociatedElementVTable`; each class that mixes it in has one such table.

Stateless interfaces are a natural fit for luce-base interface views (two words, no allocation,
checked):

```luce
pub interface ImageProvider:                     # Layout/ImageProvider.h
    func is_image_available() -> bool
    func intrinsic_width() -> CssPixels?
    ...

pub struct HtmlImageElement: IsCell, IsDomNode, ..., ImageProvider:
    ...
    func is_image_available() -> bool: return html_image_element_is_image_available(&self)

pub struct LayoutImageBox:
    pub var replaced_box: LayoutReplacedBox
    pub var m_image_provider: ImageProvider      # ImageProvider const&: a view
```

### 2.6 AK templates and value types

| AK / C++ | luce-base | Notes |
| --- | --- | --- |
| `GC::Ref<T>`, `T&` to a cell | `T*` | never null by type |
| `GC::Ptr<T>`, `T*` to a cell | `T*?` | |
| `GC::Root<T>`, `GC::RootVector<T>` | `T*` / `Vector[T*]` in managed memory; `gc.Root` only outside managed memory | §3.4 |
| `GC::Weak<T>` | `gc.Weak[T]` | ported (`WeakBlock`, `WeakImpl`) |
| `RefPtr<T>`, `NonnullRefPtr<T>` | `T*?`, `T*` | managed; no ref counting |
| `OwnPtr<T>`, `NonnullOwnPtr<T>` | `T*?`, `T*` | managed; `move()` is a plain copy |
| `WeakPtr<T>` (2 uses) | `gc.Weak[T]` over a blob | |
| `Optional<T>` | `T?` | one layer; `Optional<T*>` → `T*?`; `Optional<Optional<T>>` → a named enum |
| `Variant<A, B, …>` | a named payload enum, generated per distinct instantiation (565 uses) | name from the members, e.g. `NodeOrUtf16String`; recorded in the namemap |
| `ErrorOr<T>`, `WebIDL::ExceptionOr<T>`, `JS::ThrowCompletionOr<T>` | `T!` | §2.10 |
| `Vector<T, N>` | `ak.Vector[T]` | inline capacity dropped at first (performance only) |
| `HashTable<T>`, `HashMap<K, V>`, `OrderedHashMap<K, V>` | `ak.HashTable[T, TT]`, `ak.HashMap[K, V, KT]`, `ak.OrderedHashMap[K, V, KT]` | ported from AK with AK's traits and hash functions, `KT: Traits[K]` a one-byte traits struct (e.g. `FlyStringTraits`) |
| `Span<T>`, `ReadonlySpan<T>`, `Bytes`, `ReadonlyBytes` | `T[]`, `const T[]`, `u8[]`, `const u8[]` | |
| `Array<T, N>` | `T[N]` | |
| `String` | `ak.String` (8-byte value: short-string inline or a pointer to immutable UTF-8 data) | equality blocked by a union member so `==` is a compile error (checked); use `.equals()`. Eight zero bytes are the empty string (p2s), so a zeroed cell's Strings, FlyStrings, Utf16Strings and Utf16FlyStrings are `T {}` with no constructor setting them; C++'s null sentinel of `Optional<String>` does not exist (`String?` is a Luce optional) |
| `FlyString` | `ak.FlyString` (8 bytes: inline short string or interned pointer) | compared with `fly_string_eq_fly_string` (pointer or inline identity): it holds a union, and Luce gives `==` only to structs whose every component has equality (base.md §6) |
| `StringView` | `ak.StringView` (a `const u8[]` in a struct) | not `str`: a StringView may hold non-UTF-8 bytes (ByteString), and `(str)` on non-UTF-8 is undefined |
| `Utf16String`, `Utf16View`, `Utf16FlyString` | `ak.Utf16String` (ASCII storage or UTF-16), … | DOM text and layout offsets are UTF-16 code units (the dumps print them) |
| `ByteString` | `ak.ByteString` | a zeroed ByteString (no impl) is the empty string (p2s) |
| `StringBuilder` | `ak.StringBuilder` (implements `io.Writer`) | `appendff` → `builder.append(f"...")` only when the format is plain `{}`; AK format specs (`{:.2}`, `{:x}`) go through `ak.format` |
| `"foo"sv`, `"foo"_string`, `"foo"_fly_string` | `sv("foo")`, `ak.string("foo")`, generated FlyString constants | short FlyStrings (≤ 7 bytes) are constant `let`s built by the generator; longer ones are `var`s interned by `web_initialize_strings()` at startup (as older Ladybird did) |
| `Function<R(A…)>` | one generic struct per arity (luce-base has no variadic generics): `ak.Function0[R]`, `ak.Function1[A, R]`, `ak.Function2[A, B, R]`, … each `{ call: func(void*, A, …) -> R, context: void* }` | §2.7 |
| `GC::Function<T>` | a cell holding the same pair; its `visit_edges` scans the capture struct conservatively (as LibGC's does: `visit_possible_values`) | |
| `CircularBuffer`, `CircularQueue`, `Queue`, `Stack`, `IntrusiveList`, `RedBlackTree`, `BinaryHeap`, `Trie` | ported on demand as generic structs | `IntrusiveList` → luce-js-style `ListHead` + `container_of` |
| `Badge<T>` (315) | dropped | a parameter that only restricts callers |
| `NonnullRawPtr<T>`, `Ref`, `RawPtr` | `T*` | |
| `TemporaryChange`, `ScopeGuard`, `ArmedScopeGuard` (75 uses) | `let saved = x; x = v; defer ak.restore(&x, saved)` (`defer` takes a call) / `defer f()` / a flag + `defer` | |
| `DeferGC` | `heap_defer_gc(heap); defer heap_undefer_gc(heap)` | |
| `enum class E : u8 { … }` | `enum E as u8:` with lower-snake cases | `none` → `none_`, reserved words get `_` |
| `AK_ENUM_BITWISE_OPERATORS` flag enums | integer-backed enums (`|`, `&` are defined) | `match` needs `_` |
| `constexpr` values | `let` | |
| `static` locals | module `var` (with a `_initialized` flag when the C++ initializer is not constant) | |
| default arguments | default parameter values (constant expressions) | non-constant defaults become an overload-free wrapper |
| overloaded functions | distinct names with a type suffix, chosen by the generator (`dump_tree_dom_node`, `dump_tree_layout_node`) | recorded in the namemap |
| bit-fields | separate `bool`/`u8` fields | as luce-js |

The generic containers take a traits type because luce-base scalars cannot conform to user
interfaces and the builtin `hash` is process-seeded (AK's iteration order must be reproduced):

```luce
pub interface Traits[K]:
    func hash_of(key: const K*) -> u32
    func equals(a: const K*, b: const K*) -> bool

pub struct FlyStringTraits: Traits[FlyString]:
    var unused: u8
    func hash_of(key: const FlyString*) -> u32: return key.hash()        # AK's FlyString hash
    func equals(a: const FlyString*, b: const FlyString*) -> bool: return fly_string_eq_fly_string(*a, *b)

pub struct HashMap[K, V, KT: Traits[K]]:
    var m_table: HashTable[HashMapEntry[K, V], HashMapEntryTraits[K, V, KT]]
```

### 2.7 Lambdas and captures

3,596 lambdas in LibWeb (1,884 capture by reference), 531 `Function<>` types, 631
`GC::create_function` calls. Three cases:

1. **Non-escaping visitor** passed to a traversal (`for_each_child`, `for_each_attribute`,
   `for_each_in_subtree_of_type`): rewrite as a loop over a generated iterator (§2.9). This is
   the common case and removes the capture entirely.
2. **Non-escaping callback that is not a plain traversal** (a sort comparator, a
   `first_matching` predicate, a helper that calls back several times): a capture struct on the
   stack and a function taking `context: void*`.
3. **Escaping** (`Function<>` stored in a field, `GC::Function<>`, tasks queued on the event
   loop, promise reactions): the capture struct is allocated in managed memory (`new`) and kept
   in an `ak.Function`; captured cells stay alive because managed blobs are scanned (§3.3) and
   `GC::Function` scans its captures, exactly as LibGC does.

```c++
// HTML/HTMLImageElement.cpp (shape of a queued task)
queue_an_element_task(Task::Source::DOMManipulation, [this, url = move(url)] { ... use url ... });
```

```luce
struct HtmlImageElementLoadTask:          # the lambda's captures, named <function>_<purpose>
    var this: HtmlImageElement*
    var url: web_url.URL

func html_image_element_load_task_run(context: void*):
    let captures = (HtmlImageElementLoadTask*)context
    let this = captures.this
    ... use captures.url ...

let captures = new HtmlImageElementLoadTask(this = this, url = url) else trap("out of memory")
html_element_queue_an_element_task(this.html_element(), .dom_manipulation,
    gc_create_function(heap, html_image_element_load_task_run, captures))
```

The capture struct is named after the enclosing function plus a word for its purpose, and lives
immediately above the function that creates it.

### 2.8 Operator overloading

C++ operators on value types become named methods; one reads `a + b * c` as `a.add(b.mul(c))`.
The names are fixed: `add`, `sub`, `mul`, `div`, `rem`, `neg`, `lt`, `le`, `gt`, `ge`, `cmp`
(`<=>`), `eq` where structural `==` would be wrong or does not exist (a struct holding a union has no `==`). Mixed-type C++ operators (`CSSPixels *
int`, `CSSPixels < float`) are spelled with an explicit conversion of the other operand
(`a.mul(CssPixels.from_int(2))`, `a.to_float() < f`), which is what the C++ templates do.

```luce
pub struct CssPixels:                                  # PixelUnits.h
    pub var m_value: i32                               # fixed point, 6 fractional bits

    static func from_raw(value: i32) -> CssPixels: return CssPixels(m_value = value)
    static func from_int(value: i64) -> CssPixels:    # template<Signed I> CSSPixels(I)
        if value > (i64)css_pixels_max_integer_value: return CssPixels(m_value = i32_max)
        if value < (i64)css_pixels_min_integer_value: return CssPixels(m_value = i32_min)
        return CssPixels(m_value = (i32)value << css_pixels_fractional_bits)
    static func nearest_value_for(value: f64) -> CssPixels: ...

    func add(other: CssPixels) -> CssPixels:
        return CssPixels.from_raw(ak.saturating_add(self.m_value, other.m_value))

    func mul(other: CssPixels) -> CssPixels:           # rounds half to even, as the C++
        var value = (i64)self.m_value * (i64)other.m_value
        var int_value = ak.clamp_to_i32(value >> css_pixels_fractional_bits)
        if (value & (1 << (css_pixels_fractional_bits - 1))) != 0:
            if (value & (css_pixels_radix_mask >> 1)) != 0:
                int_value = ak.saturating_add(int_value, 1)
            else:
                int_value = ak.saturating_add(int_value, int_value & 1)
        return CssPixels.from_raw(int_value)

    func lt(other: CssPixels) -> bool: return self.m_value < other.m_value
    func to_double() -> f64: return f64(self.m_value) / 64.0
```

Bug-compatibility: `CSSPixels::operator/=` multiplies in the donor. The port keeps it
(`div_assign` calls `mul`) with a `# donor bug:` comment. Such cases are listed in
`docs/donor-quirks.md` as they are found.

**Geometry templates** (`Gfx::Point<T>`, `Size<T>`, `Rect<T>`, `Line<T>`, `Quad<T>`,
`AffineTransform`, `Matrix4x4<T>`, `VectorN`) are instantiated by `tools/gen_geometry/` (a Luce program in luce-browser-render) from
one template file into the concrete types LibWeb uses: `CssPixelPoint` (407 uses),
`CssPixelRect` (263), `FloatPoint` (238), `IntRect` (165), `CssPixelSize` (120), `IntSize`
(99), `DevicePixelRect` (82), `DevicePixelPoint` (59), `FloatRect`, `IntPoint`, `FloatSize`,
`DevicePixelSize`, `DoubleRect`. A generic `Rect[T]` is not possible because `i32`/`f32` cannot
implement an arithmetic interface.

### 2.9 `IterationDecision`, `TraversalDecision`, `for_each_*`

For traversals (654 `for_each_*` uses), the skeleton emits iterator structs implementing
luce-base's `Iterable`/`Iterator` protocol, so the C++ callback body becomes a loop body:

| C++ | Luce |
| --- | --- |
| `node.for_each_child([&](Node& child) { …; return IterationDecision::Continue; })` | `for child in dom_node_children(node): …` (`continue`) |
| `… return IterationDecision::Break;` | `break` |
| `for_each_in_inclusive_subtree(…)` with `TraversalDecision::SkipChildrenAndContinue` | `var it = dom_node_subtree(node)` / `while let n = it.next(): … it.skip_children()` |
| `for_each_in_subtree_of_type<T>` | `for n in dom_node_subtree_of_class(node, &html_element_class): let e = (HtmlElement*)n` |
| `element.for_each_attribute([&](auto& name, auto& value) {...})` | `for attribute in dom_element_attributes(element): …` |

Where the callback form must stay (the callback escapes, or the traversal is recursive with
state), use §2.7 case 2. A traversal's C++ return value (`IterationDecision` of the whole walk) is
kept as a Luce enum when callers test it.

### 2.10 Errors, exceptions and assertions

| C++ | Luce |
| --- | --- |
| `ErrorOr<T>`, `TRY(x)`, `return Error::from_string_literal("…")` | `T!`, `try x`, `error(ak_error, "…")` |
| `ErrorOr<T>` from errno | `error(ak_errno_error, message)` with the errno in a per-thread slot |
| `WebIDL::ExceptionOr<T>` | `T!`; `throw_dom_exception(realm, .hierarchy_request_error, "…") -> never!` stores the `WebIDL::Exception` in `vm.m_pending_exception` and fails with `error(webidl_exception, "")` |
| `JS::ThrowCompletionOr<T>` | `T!` with the completion value in the same slot (`error(js_exception, "")`), P3 bridges it to luce-js's pending exception |
| `if (result.is_exception()) …` / `result.release_error()` | `catch failure:`; read the stored exception with `webidl_take_pending_exception(vm)` |
| `MUST(x)` | `x else trap("MUST: <what>")` |
| `release_value_but_fixme_should_propagate_errors()` | `x else trap("FIXME: should propagate errors")` |
| `VERIFY(c)`, `VERIFY_NOT_REACHED()`, `TODO()` | `assert(c)`, `trap("VERIFY_NOT_REACHED")`, `trap("TODO")` |
| `dbgln(…)`, `dbgln_if(FLAG, …)` | `ak.dbgln(f"…")`; `if ak_debug.flag: ak.dbgln(…)` (constants from `AK/Debug.h`) |
| allocation failure (C++ crashes) | `new …` / `alloc …` are fallible in luce-base; ported code writes `else trap("out of memory")`, or uses `ak.make[T](value)` / `ak.make_span[T](n)` which trap |

The error codes are declared once in `ak` and `web` (`pub let webidl_exception: ErrorCode =
ErrorCode.package(…)`).

`else` binds looser than comparisons and associates to the right (`else_expr =
conditional_expr ["else" else_expr]`): `x else trap("…") == y` is `x else (trap("…") == y)`, so
a fallback that is compared is parenthesized, `(x else trap("…")) == y`.

### 2.11 Text formatting in dumps

Layout dumps print floats (`rect: [8,8 27.15625x18] baseline: 13.796875`) through AK's
`Formatter<float>`/`Formatter<double>`, not luce-base's `Display` (which prints `18.0` where AK
prints `18`). `Dump.cpp` and everything it calls use a port of `AK/Format.cpp`'s number
formatting (`ak.format_f64`, `ak.format_i64`), never `f"{x}"` on a float.

---

## 3. Memory

### 3.1 Summary

One heap per thread, ported from LibGC, holding two kinds of allocation:

| Kind | What | Marking | Freed |
| --- | --- | --- | --- |
| **Cells** | everything that is a `GC::Cell` in the donor (DOM, Layout, Painting, CSS rules and sheets, HTML, realms, …) | **precise**: the ported `visit_edges`; plus a conservative scan of the cell's bytes for *blob* pointers only (so owned Strings/Vectors survive) | swept by LibGC after `finalize` |
| **Blobs** | every other allocation LibWeb makes: String/ByteString/Utf16String data, Vector/HashMap storage, ref-counted objects (`StyleValue`, `Selector`, `DisplayList`, `Font`, …), `OwnPtr` objects, lambda captures | **conservative**: scanned word by word for pointers to cells or blobs (interior pointers included); *atomic* blobs (string bytes, pixel and byte buffers) are not scanned | swept when unmarked; optional finalizer for the rare external resource |

Roots: the stack and registers (conservative, as LibGC), `gc.Root` handles, the embedder's
roots (P3: live JS wrappers), and cells that `must_survive_garbage_collection`.

### 3.2 LibGC, ported faithfully

`Heap` (842 lines), `HeapBlock` (16 KiB blocks), `BlockAllocator`, `CellAllocator` (size classes
64, 96, 128, 256, 512, 1024, 3072 and per-type allocators from `GC_DECLARE_ALLOCATOR`), `Cell`,
`Root`/`RootVector`/`RootHashMap`, `ConservativeVector`, `Weak`/`WeakBlock`/`WeakContainer`,
`DeferGC`, `Function`, the marking visitor, `finalize_unmarked_cells`, `sweep_dead_cells`,
`sweep_weak_blocks`, post-GC tasks and the collection threshold (`GC_MIN_BYTES_THRESHOLD` 4 MiB,
then adaptive) are ported with their algorithms, except for the WeakImpl's reference count
(§3.7). `Cell::Visitor` becomes a struct with a vtable
(`MarkingVisitor`, `GraphConstructorVisitor`), and the overload set of `visit(...)` becomes named
helpers:

```luce
# LibWeb/DOM/Node.cpp Node::visit_edges
func dom_node_visit_edges_impl(base: Cell*, visitor: Visitor*):
    let this = (DomNode*)base
    dom_event_target_visit_edges_impl(base, visitor)   # Base::visit_edges(visitor)
    tree_node_visit_edges(&this.tree, visitor)          # TreeNode<Node>::visit_edges
    visit(visitor, this.m_document)                     # visitor.visit(m_document)
    visit(visitor, this.m_layout_node)
    visit(visitor, this.m_paintable)
    visit_vector(visitor, &this.m_registered_observer_list)   # visitor.visit(Vector<GC::Ref<…>>)
    ...
```

`visit[T: IsCell](visitor, p: T*?)` is generic over the upcast interface; `visit_js_value(visitor,
v: js.Value)` exists from P1 and is a no-op until P3 (§3.6).

Additions to LibGC (clearly marked as such in their fragments):

- **Blob allocation** in the same size classes (a blob is a cell whose header says "blob" and
  whose `visit_edges` is a conservative scan), plus **atomic blobs** (not scanned).
- A **large-object space** for blobs above 3 KiB (Vector buffers, big strings, bitmaps) and for
  any cell too large for a 16 KiB block: individually mapped, kept in an address-sorted array for
  pointer lookup.
- The heap implements luce-base's `Allocator` interface, and LibWeb's thread makes it the
  **current allocator** (`with heap:` around the event loop). So the ported code allocates with
  plain `new` and `alloc`, and `free` is never needed (it is allowed as an optimization).

### 3.3 Why AK storage is managed, and the rules that follow

The alternative, explicit ownership, was rejected. The donor's AK types release memory in C++
destructors that run implicitly at every scope exit, temporary, reassignment and container
removal; in LibWeb `String ` matches 5,968 times, `Vector<` 3,042 and `RefPtr<` (with
`NonnullRefPtr<`) 2,524. luce-js could port QuickJS's reference counting because QuickJS's C
already wrote every `JS_FreeValue`; in LibWeb those calls do not exist in the source and would
have to be invented thousands of times, with a use-after-free (undefined in luce-base) for every
mistake. Ladybird's code does not depend
on reference-count values (one `ref_count()` use in all of LibWeb), only on lifetime. Making AK
storage collectable preserves behavior, turns every missed release into nothing at all, and makes
the translation mechanical.

The rules agents follow:

1. **Moves are copies.** `move(x)` is `x`.
2. **Copies of mutable containers are explicit.** C++ copies a `Vector`, `HashMap`,
   `HashTable`, `StringBuilder` or a struct containing one *by value*; luce-base copies the
   struct and shares the buffer. Where the C++ copies (by-value parameter that the callee
   mutates, `auto x = member;` then mutation, copy-assignment), write `x.clone()`. Immutable
   types (`String`, `FlyString`, `StringView`, `ByteString`, `Utf16String`, `RefPtr` targets
   that are `const`) never need it. The skeleton marks by-value container parameters in stubs
   with `# by-value copy in C++` so the porter sees them.
3. **No destructors, no `unref`, no `free`.** A destructor with an external effect goes to
   `finalize` (cells) or a registered blob finalizer (blobs).
4. **Managed pointers may not live only outside the managed heap.** Memory from the C allocator,
   other threads, luce-js's heap, luce-std structures created under another allocator, or OS
   callbacks is not scanned. A managed pointer stored there is kept alive with a `gc.Root`
   (released explicitly), exactly the donor's rule for `GC::Root`. A `gc.Weak` is not a managed
   pointer in this sense: it may live anywhere, managed or not (§3.7).
5. **Atomic data** (string bytes, `ByteBuffer`, bitmap pixels, glyph masks, `Vector` of scalars
   when hot) is allocated with `ak.alloc_atomic`/`Vector[T].create_atomic()`, so the collector
   neither scans it nor mistakes pixels for pointers.
6. **Threads** (`HTML/RenderingThread`, `CSS/FontLoading`, decoders) run on the main thread in
   P1. Later, a worker thread allocates from the C heap (its current allocator is `memory.heap`)
   and hands results to the main thread by copying.
7. **What outlives every VM lives in the C heap, and refers only to the C heap.** A module
   global (a C++ static or singleton) and everything it keeps outlive any VM: the VM that was
   current when an entry was cached is collected and destroyed while the cache lives on, so a
   cache entry in a VM's heap dangles (and a collection can free it at any time, since module
   globals are not scanned). Such a structure allocates what it keeps from `memory.heap`
   explicitly, whatever allocator is current, with ak's atomic allocator unset (atomic storage
   goes through `ak.atomic_allocator`, which the gc module points at the newest heap), and
   never stores a managed pointer. Managed memory may point at it: it is never freed, like
   the donor's process-wide objects. Allocate only what is kept in such a scope: temporaries
   made there are never freed. A single static object is made `with memory.heap:` (as
   `KeywordStyleValue`'s static instances are); a cache filled later does the same around each
   insertion.

   Fonts follow this rule with one refinement (luce-browser-render
   `web_fonts/font_allocators.lucb`). In Ladybird fonts are reference counted and the font
   database, its system font provider, their typefaces and the fonts those cache live for the
   process. Here `FontDatabase::the()`, `PathFontProvider` (with every font file it loads),
   `Platform::FontPlugin` (its generic-family tables and fallback lists) and gfx's color-space
   singletons live in the C heap whatever is current. A `Typeface` records the allocators that
   were current when it was made (`m_allocators`), and everything it and its fonts keep later
   (`Typeface::font`'s fonts and keys, the HarfBuzz face and fonts, the glyph pages, the
   shaping cache) comes from those: a system typeface keeps its caches in the C heap, while a
   web font's typeface, made by `FontLoader` under the VM's heap, keeps them in that heap and
   is collected with its document. HarfBuzz shapes in the current allocator and the shaping
   cache keeps a copy; an `SfntFace` is complete when it is made (its CFF INDEXes are parsed
   then). Per-document font structures are managed and rightly so: `FontComputer`'s computed
   font cache, `FontCascadeList`s and `FontLoader`s hold system fonts (C heap, never freed) and
   their own web fonts (managed, kept by the conservative scan of their blobs). Fonts dropped
   from a typeface's full cache are not freed (managed memory may still refer to them).
   Tests compute fonts with their VM's heap current (`let allocator: memory.Allocator =
   vm_heap(vm); with allocator:`), collect, and destroy VMs freely; `css/tests_fonts_2`'s
   lifetime test and render's `web_fonts/tests_lifetimes` check this.

Equality is protected by construction: `ak.String` contains a union, so `a == b` does not compile
(verified) and the porter writes `a.equals(b)`; `ak.Vector` likewise.

### 3.4 Conservative roots in luce-base

LibGC scans the registers (via `setjmp`) and the stack from the current frame to the stack top
(`AK::StackInfo`). luce-base does both directly (compiled and run on this Mac):

```luce
extern func pthread_self() -> void*
extern func pthread_get_stackaddr_np(thread: void*) -> void*   # macOS; Linux: pthread_getattr_np

func stack_pointer() -> usize:
    var sp: usize
    asm arm64 (out("x0") sp):
        mov x0, sp
    asm x86_64 (out("rax") sp):
        mov %rsp, %rax
    return sp

func spill_callee_saved(buffer: usize[]):          # replaces setjmp(buf) in gather_conservative_roots
    asm arm64 (in("x0") buffer.data, options(nostack)):
        stp x19, x20, [x0, #0]
        stp x21, x22, [x0, #16]
        stp x23, x24, [x0, #32]
        stp x25, x26, [x0, #48]
        stp x27, x28, [x0, #64]
        stp x29, x30, [x0, #80]
    asm x86_64 (in("rdi") buffer.data, options(nostack)):
        movq %rbx, 0(%rdi)
        movq %rbp, 8(%rdi)
        movq %r12, 16(%rdi)
        movq %r13, 24(%rdi)
        movq %r14, 32(%rdi)
        movq %r15, 40(%rdi)
```

On Windows x64, `rdi` and `rsi` are callee-saved too and are spilled as well; the stack bounds
come from the TEB. The native backend must not hide pointers (no pointer compression, no tagged pointers to
managed memory other than `ak.String`'s short-string bit, which never tags a real pointer); the C
backend is only used for comparison runs. A diagnostic mode collects on every allocation
(`set_should_collect_on_every_allocation`, already in LibGC) to flush out missing roots.

### 3.5 External resources

Almost nothing in the port owns memory outside the heap: web fonts are parsed from managed
bytes (system fonts live in the C heap for the process, §3.3 rule 7), bitmaps are atomic blobs,
the rasterizer draws into managed buffers. What remains (open files
during loading, GPU textures from P4, luce-js values held by cells, native font handles if a
platform shaper is used) is released by `finalize` or a blob finalizer. Finalizers run before the
sweep and must not allocate.

### 3.6 luce-js, wrappers and the joint collection (P3, reserved now)

In Ladybird a platform object *is* a LibJS object (`PlatformObject : JS::Object`). With QuickJS
the DOM object and its JavaScript object are two objects in two heaps:

- **Cells stay the primary objects.** `Bindings::PlatformObject` derives from `Cell`, not from a
  JS object. `JS::Realm` becomes `web.Realm` (a cell: heap, intrinsics table of QuickJS class ids
  and prototypes, host-defined environment, global object, and in P3 a `js.Context*`); `JS::VM`
  becomes `web.Vm` (heap, pending exception, in P3 a `js.Runtime*`); `JS::Value` is luce-js's
  `js.Value` from P1 on (only `undefined` exists before P3).
- **Wrapper identity.** `PlatformObject.m_wrapper: js.Value` holds at most one wrapper, created
  lazily by `bindings_wrap(realm, object)`: a QuickJS object of the interface's class, prototype
  from the realm's intrinsics, opaque = the cell. The cell keeps one reference to the wrapper
  (expandos and `===` identity survive as long as the node does), the wrapper refers to the cell
  through its opaque.
- **Values held by cells** (`JS::Value` fields, event-listener callbacks, promise capabilities)
  hold one QuickJS reference each and release it in `finalize`; the field setters release the old
  value. This explicit discipline is confined to `js.Value` fields (a few hundred sites, all in P3
  code).
- **Cross-heap cycles** (a node whose listener closure refers to the node's own wrapper) are
  collected by one **joint collection**, run by LibGC's `collect_garbage`:
  1. QuickJS trial deletion (`gc_decref`, luce-js `gc.lucb`) over QuickJS objects, extended so
     that the references held by cells (each wrapper's one reference and every `js.Value` a cell
     reports through `visit_js_value` during a *decref visit* of all cells) are discounted too.
     QuickJS objects left with a positive count are referenced from outside both heaps (C stacks
     of the interpreter, native handles): they are roots.
  2. One marking pass over both heaps from LibGC's roots and those QuickJS roots: marking a cell
     runs `visit_edges` (cells, blobs, and via `visit_js_value` QuickJS objects); marking a
     QuickJS object runs its class `gc_mark` and, for a wrapper, marks its cell.
  3. Sweep: cells unmarked are finalized (their QuickJS references released while QuickJS is in
     its remove-cycles phase, so frees are deferred, not doubled); QuickJS frees its unmarked
     objects (`gc_free_cycles`).
  luce-js is ours: the three hooks (discount, external mark, deferred-free window) are added
  there in P3.
- **Rooting from JS**: a QuickJS object that refers to a wrapper keeps the cell alive through step
  2; nothing else is needed.

What P1 must already have so P3 is not a redesign: `PlatformObject` with `m_realm` and `m_wrapper`;
`Visitor` with `visit_js_value`; `js.Value` as the type of every `JS::Value` field; the collection
split into gather-roots / mark / finalize / sweep functions with embedder hooks; `Realm` and `Vm`
as cells reachable from `Window` and the main thread.

**P1 stand-ins for the JS objects LibWeb makes natively.** Some phase-1 paths make JS objects
themselves, faithfully to the donor: `FontFaceSet`'s set entries are a `JS::Set` and its ready
promise a WebIDL promise, every `FontFace` holds a status promise, `CSSFontFeatureValuesMap` keeps
a `JS::Map`. Before luce-js these are **cells of the engine** (`external/lib_js/promise`,
`promise_jobs`, `set`), ported from LibJS with LibJS's steps and order:

- `JS::Promise` (the 27.2.6 slots; `fulfill`, `reject`, `perform_then`, the resolve/reject
  function steps), `JS::PromiseCapability`, `JS::PromiseReaction`, `JS::JobCallback`, the
  reaction and resolve-thenable jobs, `NewPromiseCapability` and `Promise.prototype.then`;
  `JS::Map` (insertion ids in a red-black tree, entries hashed by `ValueTraits`/SameValue) and
  `JS::Set` over it. They are JS objects in the donor, so before P3 a `js.Value` of one holds the
  cell (r19's `js_value_from_object`), as for platform objects and native functions; their
  classes share JS::Cell's class id and are recognized by their `ClassInfo`; each visits its
  values in `visit_edges` and keeps its shape's realm (`js_object_shape_realm`).
- Resolve/reject functions, executors and WebIDL's reaction steps are `JsNativeFunction`s whose
  captures hold their slots. `%Promise%` is named by its realm (`js_new_promise_capability(vm,
  realm)`): `Construct(%Promise%, « executor »)` runs `PromiseConstructor::construct`'s steps.
- Jobs go through the VM's host hooks (`Vm.host_enqueue_promise_job`, `host_make_job_callback`,
  `host_call_job_callback`, `host_promise_rejection_tracker`, `host_promise_job_queue_is_empty`;
  LibJS's defaults set by `vm_create`). `bind_initialize_main_thread_vm` installs LibWeb's
  (`bind_install_main_thread_vm_host_hooks`): a promise job is a microtask on the main thread
  event loop, run prepared to run script and a callback in its realm, and rejections are tracked
  on the global's about-to-be-notified list, which every microtask checkpoint notifies about.
- The WebIDL operations (`web_idl/promise`) are ported in full over them; their signatures are
  the ones the port already calls, so **P3 swaps the implementation for luce-js objects without
  touching callers**: `JsPromiseCapability*`, `JsSet*`, `JsMap*` become wrappers of QuickJS
  objects (or cells holding them) and the `js_*` functions their operations.
- Anything that needs JS keeps trapping `unported (P3)`: `Get(x, "then")` of an object that is not
  one of these promises answers undefined (no JS properties exist), the self-resolution TypeError,
  `JS::Array` (`get_promise_for_wait_for_all`'s results), GetFunctionRealm of bound functions and
  proxies. (PromiseRejectionEvent is a plain event since region p2r: `unhandledrejection` and
  `rejectionhandled` are fired, and an unhandled DOMException rejection is logged.)
  WebIDL `ReactionSteps` cannot throw before P3 (a GC::Function's result cannot be fallible).

**Strings, arrays, objects and JSON (fix/real-sites).** Real pages reach JS values with
scripting disabled: CSSFontFeatureValuesMap keys its `JS::Map` by strings and keeps each value
list as a `JS::Array`, Infra serializes a Content-Security-Policy report to JSON through
`%JSON.stringify%`, MediaList, DOMTokenList and attribute callbacks make strings. So
`external/lib_js` also has `JS::PrimitiveString` (a cell under LibJS's STRING_TAG; SameValue and
ValueTraits compare strings by content), `JS::Array` (dense indexed storage: ArrayCreate,
create_from, its length), ordinary objects (OrdinaryObjectCreate with a null prototype,
CreateDataPropertyOrThrow, EnumerableOwnPropertyNames' key order), `JSON.stringify` without a
replacer or space, and Value's ToString, ToInt32, ToUint32 and ToLength for the values that
exist before P3. Number::toString of a number that is not an integer, ToPrimitive of an object
and every other property access still trap `unported (P3)`.

**The ReadableStream stand-in (phase 2, region p2s).** Streams are P4, but every fetch body is a
`Streams::ReadableStream`: `Body::fully_read`, `incrementally_read`, `clone` (a tee),
`byte_sequence_as_body` and the network's chunks all go through one. So the engine ports the part
of LibWeb's Streams that byte streams read by default readers need, with Ladybird's steps and
order (`streams/`), over two more JS stand-ins in `external/lib_js`:

- `JS::ArrayBuffer` (a cell owning its data block, fixed-length, unshared, detachable: create,
  `detach_and_take_bytes`, CloneArrayBuffer) and `JS::Uint8Array` (a cell viewing a buffer:
  create, `Construct(%Uint8Array%, « buffer, offset, length »)`, `typed_array_from`, the
  witness-record operations, `data()`). WebIDL's `BufferableObjectBase` reads them.
- `ReadableStream` (its slots; tee, close, error, enqueue, `pull_from_bytes`, get a reader,
  `set_up_with_byte_reading_support`), `ReadableByteStreamController` (the queue of transferred
  buffers, cancel/pull/release steps), `ReadableStreamDefaultReader` with its generic reader mixin
  and `ReadLoopReadRequest` (read a chunk, read all bytes, release), ReadableByteStreamTee with its
  default read request, the abstract operations those call (`ReadableStreamOperations.cpp`'s
  acquire/create/initialize/cancel/close/error/fulfill/reader operations and the byte controller's
  call-pull/close/enqueue/error/fill/drain/should-call-pull/set-up), `TransferArrayBuffer`,
  `CloneAsUint8Array`, `ResetQueue`; and `Fetch::extract_body` of a byte sequence.
- They are cells as in the donor; reactions go through the P1 promise stand-ins and the microtask
  queue, so a stream must be made and read in an execution context (a TemporaryExecutionContext),
  as Fetch does. Names follow the generator: where a ReadableStream member has an abstract
  operation's snake name (close, error, tee, cancel, the reader's read, the controller's close,
  error and enqueue) the member keeps it and the operation takes `_2`.
- The signatures are the C++ ones, so P4's full Streams replaces the bodies without touching
  callers. Still P4 (trap): default controllers (JS underlying sources, ReadableStreamDefaultTee),
  BYOB readers and requests and pull-into descriptors (autoAllocateChunkSize), piping, streams
  from iterables, transferring; the JS-facing IDL members (the constructor, `getReader`,
  `read()`'s iterator results); and still P3: `JS::Array` (canceling both branches of a tee).

**The Error and TransformStream stand-ins (phase 2, region p2c).** Fetch errors a body's stream
with `JS::TypeError::create(realm, message)` when a load fails, and pipes every response body
through an identity `TransformStream` (fetch response handover). So:

- `JS::Error` is a cell of the engine (`external/lib_js/error`): its realm, its class (Error or
  TypeError, recognized by ClassInfo) and the `message` that `Error::set_message` sets.
  `js_type_error_create` keeps the signature LibWeb's callers use (it answers the `js.Value`), so
  phase 3 swaps in luce-js's errors. Stack traces, `cause` and the other native errors stay P3.
- `TransformStream` keeps `set_up`'s shape (the algorithms on a `TransformStreamDefaultController`)
  with a readable byte stream as its readable side; `ReadableStream::piped_through` reads the source
  chunk by chunk into the transform algorithm and, at its end, runs the flush algorithm and closes
  the readable side (an error errors it). The WritableStream side, ReadableStreamPipeTo,
  backpressure, aborting and canceling through the pipe and its AbortSignal stay P4.

### 3.7 Weak references

In LibGC a `Weak<T>` holds a reference-counted `WeakImpl` from a weak block. The impl points to
the cell until the cell dies, then to null. Every copy of a Weak refs the impl and every
destructor unrefs it, and `sweep_weak_blocks` frees the impls whose count is 0. luce-base has no
destructors. A Weak is copied as plain bytes wherever C++ copies it: into a `Vector`'s buffer, a
struct, a return value. Nobody can count those copies.

**Decision: an impl lives exactly as long as its cell, and a Weak remembers the impl's
generation.**

- A cell has at most one `WeakImpl`, shared by all its Weaks. The heap maps each cell to its
  impl (`Heap.m_weak_impls`), and `create_weak_impl` answers the existing impl while the cell
  lives.
- `WeakBlock::sweep` frees the impl of every dead cell and drops it from the map.
  `WeakBlock::deallocate` increments the impl's generation (it replaces `m_ref_count`).
- `gc.Weak[T]` is `{ m_impl, m_generation }`. `weak_ptr` and `weak_impl` answer none when the
  impl's generation is no longer the Weak's, because the impl went back with its dead cell.
  This is exactly when the C++ Weak would read null.

A Weak therefore stays valid for as long as anything holds it, wherever that is: a cell, a blob
(atomic too), the stack, the C heap, a module global, another allocator's memory. Ported code
copies and stores Weaks as C++ does, with no calls to add and no rule to follow. Impl memory is
bounded by the number of live cells that something has made a Weak to (C++ is bounded by the
live Weaks). Nothing is traced, so no scan of the collector looks for weak references.
`gc/tests_weak_holders` enforces this: it holds Weaks on the stack, in the C heap, in a module
global and in an atomic blob, through collections that hand the freed impls to other cells.
The engine's `tests_event_loop` does the same for the event loop's document list.

Options rejected:

| Option | Why not |
| --- | --- |
| Recompute the counts during marking (the first port): every scanned word that points into a weak block counts as a reference | Memory the collector does not scan (the C heap, module globals, atomic blobs, frames above a test heap's stack top) loses its impls at the next collection. Its Weaks then read *another* cell. This hit the event loop's document list and r23's tests, which had to run under `with heap`. |
| Same, plus an explicit external-roots area that C-heap holders register (like `gc.Root`) | A rule every porter must remember for every Weak stored outside a cell. Forgetting it is a silent use-after-recycle that tests rarely catch. |
| Real reference counting: `weak_copy` / `weak_release` wherever C++ copies or destroys a Weak | Invented calls at every copy, container operation and scope exit: §3.3's reason for managed AK storage, on a smaller scale. A missed release leaks; a missed copy is a use-after-recycle. |
| A rule that Weaks live only in managed memory or on the stack, with the C-heap holders moved | Cannot be enforced (a Weak is copied as bytes, so no call site sees where it lands). C-heap objects that hold Weaks, such as the agent's custom element reactions stack, would have to move into the heap. |

### 3.8 Alternatives considered

| Alternative | Why not |
| --- | --- |
| Explicit ownership everywhere (C++ RAII spelled out) | thousands of invented `release` calls, UAF on every mistake (§3.3) |
| Conservative marking of cells too (no `visit_edges`) | would make every intentionally unvisited pointer strong and break `GC::Weak`-like caches; the donor's `visit_edges` are precise and cheap to port |
| Put DOM objects in QuickJS's heap (one heap, reference counting) | QuickJS objects are reference counted with cycle collection of JS objects only; LibWeb's object graph is cyclic everywhere (parent/child, layout ↔ DOM) and written for tracing |
| Boehm-style conservative collector for everything, no LibGC | loses LibGC's precise edges, weak cells, finalization order and the donor's rooting discipline |

---

## 4. Packages, names and the region workflow

### 4.1 Packages: the luce-browser family

The port is a family of packages, `luce-browser-*`, one repository each. luce-base rejects cyclic
module imports and packages see only their direct dependencies, so the family must be an
**acyclic layering**. The layering below was derived from LibWeb's actual include graph and
symbol references (method and numbers in §4.1.2); the design goal was to split off every piece
that can stand alone *without changing the behavior or the shape of any ported function*, and to
keep the rest together.

#### 4.1.1 The packages

```text
luce-std
   │
   ▼
luce-browser-foundation ─────────────── ak, gc, web_unicode, text_codec, web_url, web_infra
   │                    │
   ▼                    ▼
luce-browser-css      luce-browser-html
css_syntax, css_data  html_syntax
   │                    │
   ▼                    │
luce-browser-render     │               gfx, web_fonts, raster, display_list
   │                    │               (also depends on foundation)
   ▼                    ▼
luce-browser-engine ──────────────────── web  (depends on all four; + luce-js in P3;
   │                                     luce-png, luce-jpeg, luce-tiff, luce-compress,
   ▼                                     luce-http-client in P2)
luce-browser ─────────────────────────── the application (later)
```

| Package | Exports (modules) | Contents (Ladybird source) | Depends on | Size (donor lines) |
| --- | --- | --- | --- | ---: |
| `luce-browser-foundation` | `ak`, `gc`, `web_unicode`, `text_codec`, `web_url`, `web_infra` | the AK subset; LibGC + managed blobs; the LibUnicode replacement (segmentation, character types, UCD tables); LibTextCodec; LibURL; `LibWeb/Infra` string and code-point helpers (`Infra/Strings`, `CharacterTypes`, `ByteSequences`, `Types`) | luce-std | ≈15k + 3.7k + 3k new + 2.6k + 5k + 0.3k |
| `luce-browser-css` | `css_syntax`, `css_data` | CSS Syntax Level 3 below the object model: `CSS/Parser/Tokenizer`, `Token`, `ComponentValue`, `TokenStream`, `Types` (the syntax-level `Rule`/`Declaration`/`SimpleBlock`/`Function` structures), `CSS/Number`, `CSS/CharacterTypes`, `CSS/SerializationMode`, the string/identifier/number half of `CSS/Serialize`; **generated data**: the enums and name tables of `Properties.json`, `Keywords.json`, `Enums.json`, `Units.json`, `PseudoClasses.json`, `PseudoElements.json`, `MediaFeatures.json`, `Descriptors.json`, `EnvironmentVariables.json`, `MathFunctions.json`, `TransformFunctions.json`, with their generators (Luce programs) and JSON inputs | foundation | ≈3.4k + generated |
| `luce-browser-html` | `html_syntax` | the HTML tokenizer: `HTML/Parser/HTMLTokenizer` (3,076), `HTMLToken`, `Entities`, the generated `NamedCharacterReferences` (from `Entities.json`, 2,233 lines of JSON) | foundation | ≈3.7k + generated |
| `luce-browser-render` | `gfx`, `web_fonts`, `raster`, `display_list` | `gfx`: the LibGfx subset (geometry instantiations, Color, ColorConversion, AffineTransform, Matrix4x4, Path, Bitmap, PaintingSurface) and `LibWeb/PixelUnits` (`CSSPixels`, `DevicePixels`); `web_fonts`: OpenType reader, Typeface/Font/FontDatabase/FontCascadeList, the shaper, `TextLayout`/`GlyphRun`; `raster`: the tiny-skia port (§7.3); `display_list`: `Painting/DisplayList`, `DisplayListCommand`, `DisplayListRecorder`, `DisplayListPlayer` + the CPU player, `AccumulatedVisualContext`, `ScrollFrame`, `ScrollState`, `PaintStyle` (SVG paint servers), `GradientData`, `BorderRadiiData`, `BordersData`, `ExternalContentSource` | foundation, css (`css_data` enums) | ≈9k + 3k new + 15–20k (tiny-skia) + 3k |
| `luce-browser-engine` | `web` | everything else of LibWeb: DOM, HTML (tree construction, encoding detection, elements, browsing contexts, event loop, scripting environments), CSS (parser proper, object model, style values, cascade, invalidation, fonts), SVG, Layout, Painting (paintables, stacking contexts, recording context, border/background/shadow painters), Page, Platform, MimeSniff, Bindings, WebIDL, Dump; later Fetch, Loader and the rest; the `web_test` runner and the copied Ladybird tests | all of the above | ≈235k (P1 scope) |
| `luce-browser` | (application) | the browser shell over luce-window, luce-gpu, luce-ui; the GPU display-list player | engine, render | later |

Inside one package, modules are acyclic too: `ak` ← `gc` ← the rest in foundation (one hook:
AK's atomic allocation goes through a thread-local allocator view that `gc` installs, because
LibGC itself uses AK's containers); in render, `gfx` ← `web_fonts`, `gfx` ← `raster`, and `display_list` over all three (the CPU
player fills glyph outlines from `web_fonts` with `raster`).

#### 4.1.2 Why the core stays one package: the cycle analysis

Method: every `#include <LibWeb/…>` in LibWeb's 2,510 `.cpp`/`.h` files was mapped to a component
(the grouping of §1.4, with the display list, the two tokenizers and the CSS value layer as
separate candidates), giving a component graph with an edge count per direction; then qualified
references (`Layout::X`, `Painting::X`, `DOM::X`, …) and accessor calls were counted for the edges
that would have to be cut. With every file included, the whole of LibWeb is **one strongly
connected component**. The candidate cuts:

| Candidate split | Edges it must cut (include edges, files) | What those edges are | Verdict |
| --- | --- | --- | --- |
| HTML tokenizer out of the engine | 1 (`HTMLTokenizer.cpp` → `HTMLParser.h`) | one read of the parser: `m_parser->adjusted_current_node()->namespace_uri() != Namespace::HTML` (the CDATA-section check, `HTMLTokenizer.cpp:491–493`), the `m_parser` field and its `visit` | **split** (§4.1.3) |
| CSS tokenizer/tokens/component values out | 16 (`Parser/Helpers.cpp` 8: entry helpers using `Window`, `MainThreadVM`, `CSSStyleSheet`, `Parser`; `RuleContext.*` 3: CSSOM rule types; `Types.h` → `StyleProperty.h` for the `Important` enum; `Token.cpp`, `Types.cpp`, `Number.cpp` → `Serialize.h`) | whole files that belong to the engine anyway, one enum, and a header split | **split** |
| Display list + players out (render) | 9 (`BorderRadiiData.h`, `BordersData.h`, `DisplayListCommand.h` → `CSS/ComputedValues.h` for `CSS::BorderData`/`LineStyle`; `GradientData.h` → `ColorInterpolationMethodStyleValue.h` for the interpolation-method struct; `ScrollFrame.cpp` → `PaintableBox.h`; `DisplayListRecordingContext.h` → `ChromeMetrics`, `DevicePixelConverter`; `BorderRadiusCornerClipper.h` → `BorderPainting.h`) + the Skia player's 24 lines referring to CSS color-space/interpolation enums and one `CSS::InitialValues::scrollbar_color()` | type declarations and generated enums, one weak pointer field | **split** |
| CSS parser + values + CSSOM as a `css` package under the DOM | CSS parser → CSSOM 44, → DOM 5, → HTML 1, → StyleComputer 2; style values → CSSOM 37, → cascade 23, → DOM 15 (DOM refs 23 in 15 files), → Layout 13 (39 refs in 20 files: values resolve against `Layout::NodeWithStyle`), → HTML 12, → Painting 6 (13 refs: gradient resolution); CSSOM → Bindings 231, → DOM 46, → HTML 30, → cascade 26 | the parser builds CSSOM rule *cells* bound to documents and realms; values are resolved against layout nodes and the document | **keep in the engine** |
| DOM/HTML/SVG/CSS below, Layout + Painting above | engine → Layout/Painting: 146 files; `Layout::` qualified 332 times (≈55 distinct names), `Painting::` 218 times; 108 member calls through `layout_node()`/`paintable_box()`/`paintable()` (38 distinct methods, e.g. `absolute_rect`, `scroll_offset`, `is_box`); 31 `create_layout_node` factories in HTML/SVG/MathML elements; fields `Node::m_layout_node`, `m_paintable`. Reverse (natural) direction: Layout → DOM 40, → HTML 29, → SVG 31; Painting ↔ Layout 46/39 | a hook table would need well over 100 entries and ≈500 rewritten call sites, turning direct calls into indirect ones throughout DOM and HTML | **keep in one package** |
| SVG out | SVG → Layout 34, Layout → SVG 31, SVG → DOM 42, SVG → Bindings 148 | SVG elements create SVG layout boxes and vice versa | **keep** |

So the engine is one package with one module, `web` (≈235k donor lines in P1). What luce-base's
rules force is only that the *mutually dependent core* is one module; everything that is not in a
cycle with it has been moved out.

#### 4.1.3 The exact cuts (no ported function changes behavior)

| Cut | Change | Sites |
| --- | --- | ---: |
| HTML tokenizer → parser | the field `HtmlTokenizer.m_parser: HtmlParser*?` becomes `m_adjusted_current_node_is_foreign: (func(void*) -> bool)?` plus `m_parser_context: void*?`, both set by `HTMLParser` where C++ calls `set_parser`; the check at `HTMLTokenizer.cpp:491` calls it; the `visit(m_parser)` is dropped (the parser owns the tokenizer and the context is scanned) | 1 field, 1 call, 1 setter, 1 visit |
| CSS `Important` | the enum moves from `CSS/StyleProperty.h` to `css_syntax` | 1 declaration |
| `CSS/Serialize` | identifier/string/URL/number serialization (used by tokens) in `css_syntax`; `serialize_a_srgb_value(Color)` and the StyleValue/StyleProperty-dependent functions stay in the engine | file split by function |
| `Parser/Helpers.cpp`, `RuleContext.*` | stay in the engine (they are entry points into the CSSOM) | whole files |
| generated CSS code | the Luce generators emit two outputs: data (enums, names, per-property flags that mention no StyleValue) → `css_data`; value-dependent functions (`property_initial_value`, `property_accepts_*`, …) → `web/generated/` | generator split |
| `CSS::BorderData`, `ColorInterpolationMethod` (+ `PolarColorInterpolationMethod`), `CornerClip` | the plain structs/enums move to `display_list`; the engine's `ComputedValues` and `ColorInterpolationMethodStyleValue` use them from there | 3 declarations |
| CSS color-space, hue-interpolation, `LineStyle` enums | taken from `css_data` by `display_list` | 0 (generated) |
| `CSS::InitialValues::scrollbar_color()` | the constant moves to `display_list` (engine's `InitialValues` forwards to it) | 1 |
| `ScrollFrame.m_paintable_box: GC::Weak<PaintableBox>` | `gc.Weak[Cell]`; the engine's `paint_scroll_frame_paintable_box(frame)` casts (callers keep the C++ name) | 1 field, 1 accessor |
| `DisplayListRecordingContext`, `BorderRadiusCornerClipper`, `BorderRadiiData::as_corners(context)` | stay in the engine (they read chrome metrics and device-pixel conversion); `display_list` holds only data | functions stay where their dependencies are |

Every cut is a declaration move, a field retyping or a file placement, except the one tokenizer
hook, which evaluates the same condition through a function pointer the parser installs. The
engine still calls the same functions with the same arguments; the dumps and pixels cannot change.

#### 4.1.4 Repository layout

Each repository holds only Luce code, the data its generators read, and the tests CI runs
(§6.8). The layout, shown for the engine (the others are the same minus the web tree):

```text
luce-browser-engine/
  package.prisma            # export "web" = luce_browser_engine.web; dependencies on the four packages
  README.md, LICENSE, NOTICE          # BSD-2 notice for the Ladybird-derived code and test data
  docs/DESIGN.md                      # this document (lives here once the repositories exist)
  docs/PORTING.md                     # the day-to-day rules (a digest of §2–§4)
  docs/namemap.tsv                    # C++ name → package, module, Luce name (generated locally, committed)
  docs/regions.tsv, docs/donor-quirks.md, docs/compiler-issues/
  src/web/        ORDER + subdirectories mirroring LibWeb:
      module.lucb  dom/ css/ css/parser/ css/style_values/ css/invalidation/ html/ html/parser/
      html/event_loop/ html/scripting/ layout/ painting/ svg/ page/ platform/ bindings/
      webidl/ mime_sniff/ fetch/ … generated/
  tools/gen_*/                        # generators as Luce programs (+ their JSON inputs as data)
  tests/web_test/                     # the headless runner (Luce)
  tests/libweb/                       # copied Ladybird test data (§6.8)
  tests/expected_failures/
  test.sh                             # what CI runs
```

A directory module's `ORDER` may list fragments in subdirectories (`dom/node_1.lucb`); this was
checked with the current compiler. Compile cost: luce-js (≈70k lines) builds in ≈9 s cold on this
Mac, so the ≈235k-line `web` module is expected around 30–60 s *(extrapolated)*; the skeleton is
the early test of the compiler at that size.

Which package each region of §8.2 lands in is listed there.

### 4.2 Name mapping

Decided (short, unambiguous per package):

**Lower packages** (`ak`, `gc`, `web_unicode`, `text_codec`, `web_url`, `web_infra`, `css_syntax`,
`css_data`, `html_syntax`, `gfx`, `web_fonts`, `raster`, `display_list`): the module name is the
namespace, so types carry **no prefix**: the C++ class name with acronyms as words
(`Gfx::FloatRect` → `gfx.FloatRect`, `CSS::Parser::Tokenizer` → `css_syntax.Tokenizer`,
`HTML::HTMLTokenizer` → `html_syntax.HtmlTokenizer`, `Painting::DisplayListRecorder` →
`display_list.DisplayListRecorder`, `Web::CSSPixels` → `gfx.CssPixels`), and functions are
`<snake(type)>_<method>` (`css_syntax.tokenizer_tokenize(…)`, `gfx.float_rect_intersected(…)`).
The export names avoid the ecosystem's existing ones (luce-std's `unicode`, luce-fonts' `fonts`,
luce-raster's module): hence `web_unicode`, `web_fonts`, `web_url`, `web_infra`.

**The engine's `web` module** holds all of LibWeb's core namespaces in one scope, so names carry a
short namespace prefix:

| C++ namespace | Type prefix | Function prefix | Example |
| --- | --- | --- | --- |
| `Web` | — | — | `Web::Page` → `Page`, `page_…` |
| `Web::DOM` | `Dom` | `dom_` | `DOM::Node` → `DomNode`, `Node::append_child` → `dom_node_append_child` |
| `Web::HTML` | `Html` | `html_` | `HTML::HTMLDivElement` → `HtmlDivElement`, `html_div_element_…` |
| `Web::CSS`, `Web::CSS::Parser` | `Css` | `css_` | `CSS::StyleComputer` → `CssStyleComputer`; `CSS::Parser::Parser` → `CssParser` |
| `Web::Layout` | `Layout` | `layout_` | `Layout::Box` → `LayoutBox` |
| `Web::Painting` | `Paint` | `paint_` | `Painting::PaintableBox` → `PaintPaintableBox`, `Painting::StackingContext` → `PaintStackingContext` |
| `Web::SVG` | `Svg` | `svg_` | `SVG::SVGRectElement` → `SvgRectElement` |
| `Web::Fetch`, `Web::Fetch::Infrastructure` | `Fetch` | `fetch_` | `Fetch::Infrastructure::Request` → `FetchRequest` |
| `Web::Bindings` | `Bind` | `bind_` | `Bindings::PlatformObject` → `BindPlatformObject` |
| `Web::WebIDL` | `Idl` | `idl_` | `WebIDL::ExceptionOr` → `T!`; `WebIDL::DOMException` → `IdlDomException` |
| `Web::MimeSniff` | `Mime` | `mime_` | `MimeSniff::MimeType` → `MimeMimeType` |
| `Web::Platform` | `Platform` | `platform_` | |
| `JS` (the LibJS names LibWeb keeps) | `Js` | `js_` | `JS::Realm` → `Realm` and `JS::VM` → `Vm` (the two used everywhere take no prefix); `JS::Cell` → `JsCell` |
| later namespaces (`Streams`, `XHR`, `UIEvents`, …) | the namespace in PascalCase | snake case | chosen by the generator, recorded in the namemap |

Rules that apply everywhere:

| C++ | Luce |
| --- | --- |
| class in a prefixed namespace | prefix + class name in PascalCase (acronyms as words), **dropping the class name's first word when it equals the prefix word** (`HTMLElement` in `Html` → `HtmlElement`, `CSSStyleSheet` → `CssStyleSheet`, `SVGElement` → `SvgElement`); a whole word only (`Paintable` is not `Paint`) |
| a nested namespace sharing the prefix (`CSS::Parser`, `Fetch::Infrastructure`) | the parent's prefix; on a clash the generator appends the nested namespace (`CssParserRule`) and records it |
| member function | `<snake(type)>_<method>` with `this` first |
| virtual function | dispatcher `<snake(introducing type)>_<method>`; bodies `<snake(defining type)>_<method>_impl` |
| static member function | `<snake(type)>_<method>` without `this` |
| constructor | `<snake(type)>_construct(this, …)`; creation helpers `realm_create_<snake(type)>`, `heap_allocate_<snake(type)>` |
| free function or variable in a namespace | `<function prefix><name>` (`CSS::serialize_a_string` → `css_serialize_a_string`, `HTML::TagNames::div` → `html_tag_names_div`) |
| overloads | suffix from the distinguishing parameter type (`dump_tree_dom_node`, `dump_tree_layout_node`) |
| field | unchanged (`m_first_child`) |
| enum | type rule; cases lower snake case (`CSS::PropertyID::BackgroundColor` → `css_data.PropertyId.background_color`; `CSS::Keyword::None` → `css_data.Keyword.none_`) |
| lambda capture struct | `<PascalCase(enclosing function)><Purpose>` (`HtmlImageElementLoadTask`) |

luce-base's naming lint wants acronyms as words and reserves `self`, the core names (`hash`,
`format`, `str`, `error`, …) and the keywords; clashes get a trailing underscore (luce-js rule).
The skeleton generator applies all of this and writes `docs/namemap.tsv` (`C++ name<TAB>package
<TAB>module<TAB>Luce name<TAB>file:line`); agents never invent a name that is in the table.
`grep -w 'Web::DOM::Node::append_child' docs/namemap.tsv` finds the Luce name, and the reverse
works the same way.

### 4.3 Fragments

- One C++ `.cpp` (with its header's inline functions) → one fragment in the mirroring
  subdirectory, `snake(file).lucb`; a file above ≈600 Luce lines is split in its own order at its
  own section boundaries into `…_1.lucb`, `…_2.lucb` (e.g. `DOM/Document.cpp`, 8,270 lines, into
  about 16). Generated tables and test vectors are exempt.
- Types live apart from functions: `types_<file>.lucb` (generated structs, vtable structs,
  `ClassInfo`, helpers) next to the function fragments, so regions never edit a shared type file
  except to fill a field the generator could not map.
- Header box as in luce-js, naming the C++ file and line range; `# mark:` sections in fragments
  over 150 lines; `##` doc line on every `pub` declaration and `## Ported from <file>:<line>
  <C++ name>.` on every ported function; spec comments kept verbatim.
- `luce-base check src/web -W` (and the same for every module of the lower
  packages) is clean before any merge.

### 4.4 The skeleton generator

The luce-js skeleton was one C file and a list of functions. LibWeb is C++ with templates,
macros (`GC_CELL`, `WEB_PLATFORM_OBJECT`, `ENUMERATE_*` X-macros), inherited layouts and
generated headers, so the declarations are extracted by clang itself.

**Where it lives.** The generator reads C++ and drives clang, so under the owner's rule it is a
local tool, never committed to a repository: `/Users/sedov/Dev/luce_dev/.donors/luce-browser-tools/
skeleton/`. What it *produces* is Luce (types, stubs) and documentation (`namemap.tsv`,
`regions.tsv`), and that is committed to the package it belongs to. It is package-aware: each
emitted declaration goes to the package of §4.1 that owns its C++ file, lower-package
declarations are `pub`, and the engine's fragments import them.

**Input.** The reference Ladybird build's `compile_commands.json` (§6.6), so every TU is parsed
with the exact flags and all generated headers (`CSS/PropertyID.h`, `Bindings/*.h`,
`AK/Debug.h`) exist.

**Extraction** (`skeleton/extract.py`): Python with **libclang** (Homebrew LLVM 21 ships
`libclang.dylib`; `pip install libclang` or LLVM's bindings), walking cursors and keeping only
declarations located in `AK/`, `Libraries/Lib{GC,Gfx,URL,TextCodec,Unicode,Web}/` and the
build's generated LibWeb directories. Raw `-Xclang -ast-dump=json` works too but a LibWeb TU's
JSON dump includes every header and runs to hundreds of MB; the cursor walk with a location
filter and USR de-duplication across TUs is the practical form. It records into `model.json`:

- classes: qualified name, bases (access, order), fields (name, canonical type, default
  initializer text), methods (virtual/pure/override/static/const, params with default-argument
  text, return type, definition file:line), friend and nested types, the macro that declared
  them (to recognize `GC_CELL` etc.);
- enums (underlying type, enumerators and values, including X-macro generated ones), typedefs
  and `using` aliases;
- free functions and namespace variables;
- template instantiations actually used (`Gfx::Rect<CSSPixels>`, `Variant<…>`, `Vector<…>`).

**Naming** (`names.py`): §4.2, with overload disambiguation; writes `docs/namemap.tsv`.

**Type mapping** (`types.py`): recursive over clang's canonical types with the table of §2.6;
unknown or out-of-scope types become an opaque `void*?` field with a `# unmapped: <C++ type>`
comment for a human to resolve.

**Scope closure.** Start from the phase's files (§1.4); include every class a field, base or
signature of an included class names; out-of-phase classes pulled in this way get types and
stubs only. The closure is recomputed per phase.

**Emission** (`emit.py`):

- per LibWeb file, `types_<file>.lucb`: structs, vtable structs, vtable instances, `ClassInfo`,
  mixin offsets, `is_/as_/as_if_` helpers, upcast methods, dispatchers, creation helpers,
  iterators (§2.9);
- `web/module.lucb`: the `ClassId` enum in hierarchy pre-order, error codes, imports;
- per region, `stub_rNN_<name>.lucb`: every function of the region with its full signature and a
  `trap("unported: Web::DOM::Node::append_child")` body, in C++ order, each with its
  `## Ported from` line, like luce-js's stubs;
- **trivial bodies are translated directly**: `return m_x;`, `m_x = x;`, `return true;`, `{}`,
  `Base::f(args)` forwards, and the hundreds of `virtual bool is_html_foo() const { return
  false; }`;
- `docs/regions.tsv`.

The skeleton must type-check (`luce-base check`) before any region starts; the generator is
re-run only by the lead, never by region agents, and only onto files no region has touched
(types files and untouched stubs).

**Later phases.** The generator never writes into a ported repository. For a new phase (P2 was
the first) it plans twice against the ported engine (`--baseline`): the previous phase's scope and
the new one, into scratch trees. From the baseline it takes the namemap's names (a declaration or
function the namemap or a `## Ported from` line names keeps that name; a new one never takes a name
the port gives to something else) and the class ids (a new class shares its nearest numbered
ancestor's id and is recognized by its ClassInfo, since renumbering would rewrite every ported
types fragment). Declarations new in the phase that would land in a lower package go to `web`
instead, the lower packages being pinned. A merge step then brings over only what the new plan
adds: new declarations into the types fragments (after their generated neighbour) or new ones, a
struct still declared opaque (or that a region filled in part) replaced by its full declaration,
the region stub fragments, the closure stubs of the new regions' files moved out of
`stubs/stub_closure.lucb` with their hand-written signatures, and the new namemap, regions and
`gc_fields` rows. Since the regions settled them, stubs follow these conventions: a C++ `T const&`
parameter or result is `const T*` unless `T` is a small immutable value (strings, URLs, origins,
qualified names, pixel units, colors, geometry, enums, variants, optionals); C++ default arguments
become default parameter values where a constant expresses them (`Optional<T> {}` is `none`, a
`Variant<Empty, …> {}` is `.empty`); a private member or internal-linkage function is marked to
become module-private when ported (an unused private function is a warning, so the stub stays
`pub`).

**Visit-edges lint.** From the model the generator also writes, per cell class, the list of
fields whose type is a GC pointer or contains one, committed as `docs/gc_fields.tsv`; a Luce test in
each package (`tests/visit_edges`) reads it and checks that each field name appears in the ported
`visit_edges` body. This mirrors Ladybird's own clang plugin
(`Meta/Lagom/ClangPlugins/LibJSGCPluginAction.cpp`).

**Without a reference build** the fallback is a header scanner over Ladybird's very regular
declaration style plus a hand-written list for macros; it is weaker (no inherited layout, no
canonical types) and should be avoided.

### 4.5 The region workflow

As luce-js (`git log`: "Port skeleton: … typed stubs", then "Port region rNN: …"):

1. The lead lands the skeleton and the foundations (P0) on `main` of each package repository,
   bottom-up (foundation, css, html, render, engine).
2. Each region is a list of C++ files (`docs/regions.tsv`), sized ≈2–6k C++ lines, with declared
   dependencies (§8.2). An agent takes one region on a branch `port/rNN`, replaces the region's
   stub fragment with real fragments in C++ order, deletes the stub file, adds unit tests where
   the donor has them, keeps `luce-base check -W` clean, and runs the test runner. Before
   committing it runs the local comparison against the reference build for the tests the region
   affects (§6.8); only Luce code and CI tests are committed.
3. **Reachability-driven order inside P1.** Because every function exists (as a stub), the test
   runner runs from the first day: a `trap("unported: X")` names the next function a test needs.
   The runner's summary counts traps by function, which prioritizes work across regions.
4. Merge when the module checks, the unit tests pass, and the Layout/Ref pass count does not go
   down (expected-failures ratchet, §6.2). Never commit on a pipeline whose status is not the
   test's own (house rule).
5. Cross-region edits: a region may fill an unmapped field or fix a generated signature in a
   types file with a note in the merge message; it never ports another region's functions.
6. Compiler bugs: write the most intuitive code; when the compiler rejects or miscompiles it,
   reduce it to a repro and fix the compiler (the luce-base session owns it) rather than
   working around the bug in the port (owner's rule, luce-js PORTING.md).

---

## 5. Code generators

Under the owner's rule the generators that belong to a package are **Luce programs** committed
with their **data inputs** (Ladybird's JSON and CSS files, BSD-2, with the notice), so CI can
regenerate and compare with the committed output. Ladybird's Python generators are the
specification of what to emit: each Luce generator is a port of one Python generator's logic,
reading JSON with luce-json. Tools that read C++ stay local (§6.8).

| Generator (Ladybird) | Phase | Luce program and package | Output |
| --- | --- | --- | --- |
| `generate_libweb_css_property_id.py` (1,612 lines) and the thirteen other `generate_libweb_css_*.py` (135–545 lines each), inputs `CSS/*.json` | P0 | `tools/gen_css/` in **luce-browser-css** | two outputs (§4.1.3): data (enums, names, flags) → `css_data` in luce-browser-css; value-dependent functions → `web/generated/` in the engine (the program writes into a path given on the command line; the engine's CI runs the css package's generator from its dependency checkout) |
| `embed_as_string.py` (`Default.css`, `QuirksMode.css`, `SVG/Default.css`, `MathML/Default.css`) | P0 | `tools/embed_css/` in the engine | a `let` per style sheet |
| `generate_libweb_html_named_character_references.py` (538), input `Entities.json` | P0 | `tools/gen_entities/` in **luce-browser-html** | the matching trie as Luce arrays |
| `generate_dom_tree.py` (428), input `HTML/MediaControls.html` | P0 | `tools/gen_dom_tree/` in the engine (it reads HTML with `html_syntax`) | Luce that builds the media-controls DOM |
| `generate_libweb_aria_roles.py` (289) | P0 | engine | ARIA role tables |
| `generate_encoding_indexes.py` (308), `generate_public_suffix_data.py` (153) | P0 | foundation | encoding tables (`text_codec`), public suffix data (`web_url`) |
| geometry instantiation (new) | P0 | `tools/gen_geometry/` in **luce-browser-render** | the concrete geometry types (§2.8) |
| UCD tables (new) | P0 | `tools/gen_ucd/` in foundation | tables from the Unicode 17 data files ICU 78.2 uses (`vcpkg.json` overrides: ICU 78.2, HarfBuzz 10.2.0, Skia 144): `LineBreak.txt`, `EastAsianWidth.txt`, `emoji-data.txt`, `DerivedBidiClass.txt`, `WordBreakProperty.txt`, `GraphemeBreakProperty.txt`; tested with `LineBreakTest.txt`, `WordBreakTest.txt`, `GraphemeBreakTest.txt` (copied) and the ported `Tests/LibUnicode/TestSegmenter.cpp` |
| skeleton (new) | P0 | **local** (`.donors/luce-browser-tools/skeleton/`, Python + libclang) | committed types, stubs, `namemap.tsv`, `regions.tsv`, `gc_fields.tsv` |
| IDL → Luce bindings (replaces `BindingsGenerator/IDLGenerators.cpp`, 6,301 lines of C++) | P3 | `tools/gen_bindings/` in the engine, a Luce port of the C++ generator's logic with a WebIDL parser modeled on Ladybird's `Meta/Utils/webidl_parser.py` (562 lines); inputs: the 644 `.idl` files, copied as data | luce-js class definitions, prototype tables, WebIDL conversions, and the enums/dictionaries that P1 took from the skeleton |
| `generate_window_or_worker_interfaces.py` (609) | P3 | part of `gen_bindings` | |
| `generate_ipc_definitions.py`, LibJS generators | never | | |

Each package's `test.sh` regenerates every generated file into a temporary directory and fails
on any difference with the committed output.

---

## 6. The test oracle

### 6.1 The runner

`tests/web_test/` in luce-browser-engine builds one Luce program with two modes:

- **Driver** (`web_test [suites] [-f glob] [-j N] [--update-failures]`): walks the engine
  repository's copy of Ladybird's tests, `tests/libweb/` (§6.8), honors `TestConfig.ini`'s skip lists, runs each test in a child process
  (`process` module) with a timeout, because a luce-base trap cannot be caught and must not end
  the run (the luce-js test262 runner splits for the same reason), collects results, writes
  `results/` (actual text, diffs, PNGs of failing reftests via luce-png) and prints a summary
  including the top `unported:` traps.
- **Worker** (`web_test --one PATH --mode layout|ref|crash|screenshot`): one page, one test.

The worker does natively what Ladybird's `test-web` does through JavaScript and IPC
(`Tests/LibWeb/test-web/main.cpp`):

1. Install the platform plugins in **test mode**: `FontPlugin(is_layout_test_mode = true)`, which
   maps every generic family to `SerenitySans` and uses `Noto Emoji` for symbols (both copied from
   the donor's `Base/res/fonts/` into `tests/libweb/fonts/`); load only those fonts plus fonts the test itself provides (Ladybird
   also loads system fonts, but tests that rely on them are not portable). As test-web runs WebContent with
   `--disable-scrollbar-painting` (PaintViewportScrollbars::No), the worker calls
   `Painting::set_paint_viewport_scrollbars(false)`: no viewport, the top-level one or an iframe's, paints its
   scrollbars, in every suite.
2. Create a `Page` (viewport 800×600, device pixel ratio 1, scripting disabled in P1) and a
   top-level traversable.
3. P1: read the file, create the `Document` for the bytes (`Document::create_and_initialize` with
   `NavigationParams` for a `file:` response, then `HTMLParser::create_with_uncertain_encoding`
   and `run`, then the "completely finish loading" steps), the path
   `SVG/SVGDecodedImageData.cpp` already takes upstream. P2 replaces this with real navigation.
4. Run the event loop until the load event has fired and the document's fonts are ready, then run
   "update the rendering" twice (what `afterFontsAndPaint`'s two `requestAnimationFrame`s
   observe), honoring the `test-wait`/`reftest-wait` class only once scripting exists.
5. Produce the result (§6.2–6.4).

### 6.2 Layout tests

Ladybird's expected text is the concatenation of three dumps, separated by blank lines
(`Services/WebContent/ConnectionFromClient.cpp` `request_internal_page_info` with `LayoutTree |
PaintTree | StackingContextTree`): `dump_tree(layout)` and `dump_tree(paintable)` from
`Dump.cpp`, and `StackingContext::dump`. The worker calls the ported functions with the same
arguments and the harness compares byte for byte with `Layout/expected/<path>.txt`. Before
dumping it renders once (Ladybird takes a screenshot first "to force the lazy layout of
SVG-as-image documents").

A Layout test that traps or crashes is run a second time with `--no-rendering` (r57): the page
stays hidden, so "update the rendering" never paints it, and the dumps are taken right after the
load. The driver reports how many of those match (all three dumps, and the layout tree alone) and
where they stop: a measure of layout while painting is not ported, never a pass.

Expected failures live in `tests/expected_failures/layout.txt`, one path per line with a reason
code (`script`, `resource`, `noscript`, `font`, `unported`, `bug`). The runner fails on any
unexpected failure *and* on any unexpected pass (so the list only shrinks);
`--update-failures` rewrites it after review.

### 6.3 Ref tests

A reftest names its reference with `<link rel="match" href="…">` or `rel="mismatch"`, and may
carry `<meta name="fuzzy" content="maxDifference=0-2;totalPixels=0-12000">` (30 Ref inputs do).
The worker reads both from the parsed DOM, renders the test and the reference in the same page
size, and applies Ladybird's rule (`test-web/Fuzzy.cpp`): identical bitmaps pass; otherwise the
first fuzzy entry whose `reference` matches (or has none) must contain both the maximum channel
difference and the number of differing pixels; without a fuzzy entry a difference fails. Both
sides go through our rasterizer, so reftests test layout and painting logic independently of
Skia. A reference that is an image would be decoded with luce-png and compared as it is (no Ref
test at the pin has one: the `.png` files in `Ref/expected` are images the references load).

### 6.4 Crash, Screenshot and Text tests

- **Crash**: pass if the worker finishes (no trap, no timeout).
- **Screenshot** (97 inputs, 100 expected PNGs rendered by Skia; the 67 that need no script are
  copied with P2): the worker renders the page, decodes the expected PNG with luce-png and
  applies Ladybird's fuzzy rule (the test's `<meta name=fuzzy>`, its references ignored, as
  test-web does); a failed comparison writes the actual, expected and diff PNGs and its
  statistics into the results. Our rasterizer does not match Skia's anti-aliasing everywhere:
  the tests whose picture is right but whose pixels are not Skia's are listed with the reason
  `raster` (r57's notes). After human review, a Luce-rendered baseline set may be kept beside
  (not instead of) the Ladybird PNGs. *(Open, §9.)*
- **Text** (4,785 inputs): P3, through luce-js; the runner then implements `internals` and the
  JS-driven waits like `test-web`.

### 6.5 Unit tests

Ported as `test` blocks in the module they test, in the package that owns it: `Tests/AK/*` (89 files, those for ported types),
`Tests/LibURL/TestURL.cpp` and `TestPublicSuffix.cpp`, `Tests/LibTextCodec/*`,
`Tests/LibUnicode/TestSegmenter.cpp` and `TestUnicodeCharacterTypes.cpp` (the subset),
`Tests/LibWeb/TestCSSPixels.cpp`, `TestCSSTokenStream.cpp`, `TestCSSSyntaxParser.cpp`,
`TestHTMLTokenizer.cpp`, `TestMicrosyntax.cpp`, `TestNumbers.cpp`, `TestStrings.cpp`,
`TestMimeSniff.cpp`, `TestCSSInheritedProperty.cpp`, and the CSS tokenizer corpus
(`Tests/LibWeb/CSSTokenizer`, 33 files copied into luce-browser-css and driven by a Luce test the
way `test-css-tokenizer.py` drives them). Foundation gets the AK, LibURL, LibTextCodec and
segmentation tests; css the CSS tokenizer and syntax tests; html `TestHTMLTokenizer`; render the
geometry, `TestCSSPixels`, font and rasterizer tests (tiny-skia's own reference PNGs, BSD-3,
copied); the engine the rest.

### 6.6 The reference Ladybird

The owner approved building it; the coordinator builds it under
`/Users/sedov/Dev/luce_dev/.donors/`, and it never enters a repository. **Feasible on this Mac** (checked: macOS 15.7.3, 16 cores, 64 GB, 1.3 TB free, Xcode 26.2 with
Apple clang 17, Homebrew LLVM 21 and 23, cmake, ninja, pkg-config, Python 3.14 present).
Missing prerequisites from `Documentation/BuildInstructionsLadybird.md`: `brew install autoconf
autoconf-archive automake libtool nasm` and a Rust toolchain (rustup; the pin already has Rust in
LibJS, LibGfx (YUV), LibUnicode (calendar) and LibRegex). Qt is not needed for `test-web`/headless.
vcpkg builds the dependencies from `vcpkg.json` (Skia, HarfBuzz, ICU, ffmpeg, libjxl, curl, …),
the longest part *(estimated 1–2 hours and tens of GB, unverified)*. Build out of the donor tree
(copy or `git worktree` it; the pin checkout itself stays untouched), with LLVM 21 as CI uses:

```sh
CC=/opt/homebrew/opt/llvm@21/bin/clang CXX=/opt/homebrew/opt/llvm@21/bin/clang++ \
  ./Meta/ladybird.py build test-web        # then: ./Meta/ladybird.py run test-web -f 'Layout/*'
```

What it is for:

1. **The skeleton extraction** (§4.4): `compile_commands.json` and the generated headers. This is
   the one hard dependency, needed in P0.
2. **Debugging divergences**: dumping intermediate state (computed styles via `dump_tree(...,
   show_cascaded_properties)`, selectors, sheets) for a failing test and diffing with ours.
3. Rendering P2 screenshot baselines and checking any test whose expectation looks suspicious.

Layout and Text expectations are part of the copied test data; CI never needs the reference
build. The local comparison drivers that use it are listed in §6.8.

### 6.7 The font-metrics oracle

Layout dumps encode text metrics, so the text stack must reproduce Skia's metrics and HarfBuzz's
advances for the test font. Checked against `Layout/expected/block-and-inline/abspos-block.txt`
(`foo` at 16px has width 27.15625, `bar` 27.640625, baseline 13.796875, line box 18):

- SerenitySans-Regular.ttf (11,904 bytes) has tables `FFTM GDEF OS/2 cmap cvt gasp glyf head hhea
  hmtx loca maxp name post`: **no GSUB, GPOS or kern**, so shaping is cmap + hmtx.
- HarfBuzz is created with scale `pixel_size × 64` (`text_shaping_resolution = 64`); per glyph
  `x_advance = round(advance × 16 × 64 / 1024)`, summed and divided by 64: this reproduces 27.15625
  and 27.640625 **exactly** (computed with a 60-line Python reader while writing this document).
- `units_per_em` 1024; `OS/2.fsSelection` has USE_TYPO_METRICS; typo ascender 819 and descender
  −205 give ascent 12.796875 and descent 3.203125 at 16 px, whose half-leading in an 18 px line
  gives the baseline 13.796875 of the dump. The exact rule Skia's FreeType backend applies
  (hhea vs typo, rounding of the line gap into `normal` line-height) is pinned down by a local
  script (`.donors/luce-browser-tools/font_oracle.py`, which reads the fonts, the expected dumps
  and, where useful, the reference build's metric dumps) before the `web_fonts` region is closed;
  its findings are committed as Luce unit tests in luce-browser-render (font, size → ascent,
  descent, line gap, advances), so CI guards them without the script.

NotoEmoji.ttf does have GSUB (ZWJ sequences) and variation tables; emoji-dependent tests may stay
expected failures until the shaper handles GSUB ligatures.

### 6.8 What is committed where, and what stays local

The owner's rule: repositories hold only Luce code plus the tests CI runs (test data may be
copied in); all C/C++ donor code and all comparison drivers stay in
`/Users/sedov/Dev/luce_dev/.donors/`, and comparisons with the reference are done locally before
committing.

| Repository | Copied test data (with Ladybird's BSD-2 `LICENSE` beside it) | CI (`./test.sh`) |
| --- | --- | --- |
| luce-browser-foundation | UCD test files (`LineBreakTest.txt`, `WordBreakTest.txt`, `GraphemeBreakTest.txt`), the data inputs of its generators (`indexes.json`, public suffix list, UCD files) | `luce-base test` of every module (ported AK, LibURL, LibTextCodec, LibUnicode tests); regenerate and diff generated files; the GC stress mode (collect on every allocation) over the module tests |
| luce-browser-css | `Tests/LibWeb/CSSTokenizer` (33 files, 132 KB); `CSS/*.json` generator inputs | module tests; the tokenizer corpus; regenerate `css_data` and diff |
| luce-browser-html | `Entities.json`; tokenizer test cases from `TestHTMLTokenizer.cpp` (ported as Luce tests) | module tests; regenerate entities and diff |
| luce-browser-render | `SerenitySans-Regular.ttf`, `NotoEmoji.ttf` (+ its OFL), the Lato/HashSans fonts from `Tests/LibWeb/Assets` that font tests use; tiny-skia's test images | module tests (geometry, CSSPixels, fonts incl. the metric tests of §6.7, rasterizer against the tiny-skia images, display-list player) |
| luce-browser-engine | `Tests/LibWeb/{Layout,Ref,Crash}` inputs + expected (8.7 + 7.4 + 0.8 MB) and the `Ref/data`, `Layout/input` assets they reference; `TestConfig.ini`; the two test fonts; `Screenshot/` (8.4 MB) and the needed `Assets/` files in P2; `Text/` (74 MB) in P3; the `.css`, `.json`, `.html` and (P3) `.idl` inputs of its generators | module tests; `web_test layout ref crash` against `tests/expected_failures/`; regenerate and diff |

Test data is copied, never symlinked, keeping Ladybird's directory structure under
`tests/libweb/` because inputs refer to each other by relative paths
(`../expected/…`, `../../Ref/data/…`). The copy is refreshed only from the pinned donor, by the
lead, with the pin recorded in `tests/libweb/PIN`.

Local only (`/Users/sedov/Dev/luce_dev/.donors/`):

| Tool | Purpose |
| --- | --- |
| `ladybird-pin/` and the reference build (built by the coordinator) | the donor source and `test-web`/`headless-browser` at the pin |
| `luce-browser-tools/skeleton/` | the libclang extraction and the skeleton/stub/namemap emitter (§4.4) |
| `luce-browser-tools/compare_layout.py` | runs a test through the reference build with extra dumps (computed styles, cascaded properties, selectors, sheets: `dump_tree(…, show_cascaded_properties)`, `dump_sheet`) and through `web_test --one --dump-all`, and diffs them stage by stage |
| `luce-browser-tools/compare_pixels.py` | renders a test with the reference and with ours, writes the diff image and Ladybird's fuzzy statistics |
| `luce-browser-tools/font_oracle.py` | §6.7 |
| `luce-browser-tools/region_check.sh` | before a region is committed: runs the affected Layout/Ref tests with both engines and refuses when ours diverges on a test the reference passes and the expected-failures list does not name |

So CI proves the committed code against copied expectations, and the reference comparisons,
which need the C++ build, happen on the porter's machine before the commit.

---

## 7. Dependencies and what is replaced

### 7.0 Our own libraries first (owner, 2026-10-03)

Where a Luce library covers a need, the browser uses it and improves it instead of porting
Ladybird's implementation, so the work benefits the whole ecosystem. Decisions:

| Need | Library | Notes |
| --- | --- | --- |
| Fonts and shaping | **luce-fonts** | The browser's `web_fonts` (OpenType reader, CFF, GSUB/GPOS, shaper; render r09) moves into luce-fonts as its portable engine, beside its platform text; the browser depends on luce-fonts. |
| SVG rendering | **luce-svg** | luce-svg is extended until it is fully featured (use/symbol, clip paths, masks, patterns, filters, text, style sheets, every CSS color), measured against resvg's test suite. Inline SVG in HTML stays the engine's DOM port (r55/r56), which is DOM + CSS by nature. |
| Image decoding (P2) | **luce-png**, **luce-jpeg**, new sibling decoders | `ImageCodecPlugin` adapts them; GIF, WebP, BMP, ICO, APNG become luce-base packages over luce-raster. Ladybird's decoders are not ported. |
| Compression | **luce-compress** | gzip framing and Brotli (WOFF2, `Content-Encoding: br`) are added there. |
| Networking (P2) | **luce-std** `net`, **luce-tls** | The `RequestClient` seam sits on them. |
| Files, Unicode tables | **luce-std** | `files`/`paths`, `unicode`. |
| Rasterizer | stays in luce-browser-render | `raster` (tiny-skia made Skia-exact) remains the browser's own (§7.3). |

### 7.1 Seams

| Concern | Donor | Seam | P1 implementation | Later | Luce package |
| --- | --- | --- | --- | --- | --- |
| Font files and faces | `Gfx::Typeface` (abstract) + `TypefaceSkia`; `FontDatabase`, `PathFontProvider` | `web_fonts.Typeface` interface (ported), `TypefaceSfnt` implementation | pure-Luce OpenType reader: cmap, hmtx/vmtx, hhea, OS/2, head, name, glyf/loca, CFF (for OTF), fvar/gvar (variations later) | WOFF (luce-compress), WOFF2 (luce-fonts over luce-compress's Brotli) | new code in `web_fonts` (≈3k lines) |
| Shaping | HarfBuzz in `TextLayout.cpp` (`shape_text`, `measure_text_width`) | `web_fonts.Shaper` | `BasicShaper`: cmap + advances at 1/64 px as HarfBuzz rounds, kern/GPOS pair adjustment, GSUB ligatures | HarfBuzz-grade shaping (complex scripts): a port of a shaper, or platform shaping through luce-fonts for browsing only (not for tests) *(owner decision)* | — |
| Glyph rendering | Skia (`SkTextBlob`) | `raster` path fill of glyph outlines, cached coverage masks | yes | GPU atlas | luce-browser-render |
| Segmentation, bidi, line-break classes | LibUnicode over ICU (`Segmenter` 30 uses in Layout/CSS/DOM, `line_break_class`, `bidirectional_class`) | `web_unicode` | UAX #29 (grapheme via luce-std `unicode`, word), UAX #14 line breaking (ICU's default rules), UCD property lookups | IDNA (UTS #46) for `web_url` hosts in P2 | luce-std `unicode` |
| Normalization, case | ICU | `web_unicode` → luce-std `unicode` (`normalize`, `to_upper`, `case_fold`) | yes | | luce-std |
| Image decoding | `ImageCodecPlugin` → out-of-process decoders over libpng/libjpeg-turbo/libwebp/… | `Platform::ImageCodecPlugin` (ported seam) | none needed (P1 has no images) | luce-png and luce-jpeg (p2d), luce-gif (animated GIFs streamed to `AnimatedDecodedImageData`), luce-bmp and luce-ico (p2img); WebP, AVIF, APNG's animation, TIFF, JXL later, as luce packages | luce-png, luce-jpeg, luce-gif, luce-bmp, luce-ico |
| Networking | `ResourceLoader` → RequestServer (curl) | `RequestsRequestClient` (region p2d: a vtable of start/stop/ensure-connection; the request delivers headers, body chunks and its end on the event loop) | `InProcessRequestClient`: `file:`, `data:` and `http(s):` in process (HTTP/1.1 on luce-std `net`, TLS 1.3 on luce-tls with the public roots, gzip/deflate/Brotli on luce-compress); since p2/net http(s) never blocks the event loop: Core::Notifiers on the sockets, resolution on a thread (`net.Lookup`), non-blocking connect and TLS, streamed decoding, keep-alive pools per origin with curl's limits (docs/regions/p2net.md) | HTTP/2, a resolver cache, a cache, proxies | luce-std, luce-tls, luce-compress |
| Compression | zlib (Content-Encoding, WOFF, PNG) | `web_fonts` (WOFF, WOFF2 through luce-fonts) and the engine (Content-Encoding) call luce-compress | — | gzip/deflate/Brotli: luce-compress; Zstd: missing | luce-compress |
| XML | LibXML over libxml2 | `web.XmlParser` | — | a Luce XML 1.0 parser (P2) | new |
| Regex | LibRegex (Rust) | — | — | luce-regex's ECMAScript dialect | luce-regex |
| JS | LibJS | §3.6 | types only | luce-js | luce-js |
| Media playback | LibMedia (Matroska and FFmpeg demuxers, data providers, sinks, audio output) | `external/lib_media`: Track, DecoderError, TimeRanges, IncrementallyPopulatedStream's writing side, a PlaybackManager whose `create_demuxer_for_stream` answers NotImplemented | every media resource is an unsupported format (the element's failure steps, the poster) | a demuxer and decoders | — |
| Rasterization | Skia (`DisplayListPlayerSkia`, `PainterSkia`, `PathSkia`, `PaintingSurface`) | `display_list.DisplayListPlayer` (ported abstract class, 32 pure virtuals) | CPU player (§7.3) | GPU player on luce-gpu | luce-browser-render |
| Event loop, timers, notifiers | `Platform::EventLoopPlugin`, `Core::Timer`, `Core::Promise`, `Core::Notifier` | ported plugin interfaces; the loop registers notifiers and waits for timers and notifiers in one wait (`event_loop_notifiers`: EventLoopImplementationUnix's poll over luce-std `net.Poller`, p2/net) | the runner's loop | luce-window's loop in the browser | luce-window, luce-std |
| Color management | LibGfx `ColorSpace`, Skia color spaces | `gfx.ColorSpace` | sRGB only (ported `Color`, `ColorConversion` for CSS math) | p2/icc: ICC and CICP via luce-color's `icc` (skcms and SkColorSpace ported); PNG cICP/iCCP (luce-png), JPEG APP2 profiles (luce-jpeg) and a BMP's BITMAPV5HEADER embedded profile give a decoded image its color space as ImageDecoder::color_space does (icons stay sRGB, as ICOImageDecoderPlugin has no icc_data); wherever Skia samples the image (the CPU player, the canvas painter's draw_bitmap and patterns, SkImageFilters::Image) its pixels are converted to sRGB after sampling with Skia's SkColorSpaceXformSteps (raster `color_xform`) | luce-color |

### 7.2 LibGfx: ported, replaced, dropped

| LibGfx | Decision |
| --- | --- |
| `Point`, `Size`, `Rect`, `Line`, `Quad`, `AffineTransform`, `Matrix`, `Matrix4x4`, `VectorN`, `BoundingBox`, `Orientation`, `WindingRule`, `ScalingMode`, `LineStyle`, `CompositingAndBlendingOperator`, `Filter` (the filter *description*), `Gradients` (descriptions), `PaintStyle` (descriptions), `Cursor` enum | port (geometry generated, §2.8) |
| `Color` (1,215), `ColorConversion` (943), `InterpolationColorSpace`, `Palette` (theme colors used by CSS system colors) | port (exact rounding matters) |
| `Font/Font`, `Font/Typeface` (abstract), `FontDatabase`, `FontCascadeList`, `TextLayout` (`GlyphRun`, `shape_text` minus HarfBuzz calls), `UnicodeRange`, `FontVariationSettings`, `FontStyleMapping`, `ShapeFeature` | port, with HarfBuzz/Skia calls replaced by the seams |
| `Font/TypefaceSkia`, `SkiaUtils`, `SkiaBackendContext`, `PainterSkia`, `PathSkia`, `VulkanContext`, `MetalContext` | replaced |
| `Path` (abstract `PathImpl`: move/line/quad/cubic/arc, `bounding_box`, `contains`, `copy_transformed`, `intersect`, `to_svg_string`, text along path) | port the interface; implement on the rasterizer's path type |
| `Bitmap`, `ImmutableBitmap`, `PaintingSurface`, `ShareableBitmap` | port as managed-memory RGBA8 (premultiplied as Skia stores) with a CPU surface |
| `ImageFormats/*` | replaced by Luce codec packages (P2) |
| `SystemTheme`, `SharedImage*`, `YUVData` (Rust), `BitmapSequence`, `VectorGraphic`, `CMYKBitmap` | dropped or later |

### 7.3 The rasterizer

LibWeb records a display list (`Painting/DisplayListCommand.h`: 28 command structs from
`DrawGlyphRun` and `FillRect` to `PaintConicGradient`, `ApplyBackdropFilter`, `SaveLayer`,
`AddRoundedRectClip`, `ApplyEffects`) and hands it to a `DisplayListPlayer`, whose Skia
implementation is 870 lines. luce-browser-render provides `DisplayListPlayerCpu` implementing the same 32
virtuals over a CPU rasterizer that needs: paths (fill nonzero/even-odd, stroke with joins, caps,
dashes), anti-aliasing, linear/radial/conic gradients with color stops and interpolation spaces,
image drawing with nearest/bilinear/bicubic sampling and repeats, clip stacks (rect, rounded rect,
path), layers with opacity and all CSS blend modes, box and text shadows (Gaussian blur),
backdrop and CSS filters, transforms with perspective (an SkM44 per canvas state, paths cut at
w = 0 and projected as SkPath::transform does), and glyph runs.

Decided: the rasterizer is the `raster` module of **luce-browser-render**, a faithful Luce port
of **tiny-skia**'s algorithms (Rust, BSD-3: itself a port of Skia's CPU raster pipeline), so
anti-aliasing, coverage accumulation, stroking, dashing, gradient evaluation and blending match
Skia's. The port follows the same discipline as the LibWeb port (same algorithms, same order,
same constants, comments kept), in regions r11a–d. What tiny-skia lacks and Skia provides to
Ladybird is added in the same module, following Skia's own algorithms: glyph rendering from
`web_fonts` outlines (coverage masks cached per glyph and subpixel offset), Gaussian blur for box
and text shadows (Skia's three-pass box-blur approximation), the CSS filter functions and
backdrop filters, conic gradients (tiny-skia has linear and radial), and the image sampling
filters. `display_list.DisplayListPlayerCpu` executes the commands over it. A GPU player on
luce-gpu comes with the `luce-browser` application in P4; the CPU player stays the reference for
tests.

Alternatives that were considered: extending luce-svg's exact-area coverage rasterizer (its
anti-aliasing differs from Skia's, so Screenshot tests would drift), and a GPU-only player (not
deterministic across drivers, so unusable as the test reference).

---

## 8. Risks, order of work, estimate

### 8.1 Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Hidden C++ semantics: implicit copies of containers, temporaries, evaluation order, `float` promotion | wrong results | managed memory removes lifetime bugs; the by-value copy markers (§3.3 rule 2); float widths kept; luce-js's integer rules |
| Conservative scanning misses a pointer (register not spilled, pointer only in unscanned memory) | premature free, corruption | collect-on-every-allocation diagnostic mode in CI for a subset of tests; `Root` rule for foreign memory; debug heap that poisons swept memory |
| Conservative scanning retains too much / GC pauses | memory, latency | atomic blobs for data; large-object space; later typed scanning for hot containers |
| Text metrics differ from Skia/FreeType by 1/64 px | hundreds of Layout diffs | font oracle before the region closes (§6.7); SerenitySans is simple (verified) |
| Line breaking differs from ICU | Layout diffs in text tests | UAX #14 conformance tests + targeted ICU comparisons; ICU's default rules only |
| libm differences (`sin`, `pow`, `atan2` in transforms/gradients vs the Linux glibc that produced the expectations) | rare 1/64 px diffs | use luce-std math; list residual tests with reason `libm` |
| Compiler scale (one 250k-line module, ~600 fragments, ~50k stubs) | slow builds, compiler bugs | the skeleton exercises it in P0; compiler issues reduced and reported (luce-js rule); split generated tables into their own fragments |
| libclang extraction gaps (macros, templates, X-macros) | manual skeleton fixes | the model records macro origins; unmapped types are explicit comments; a small hand-written overrides file |
| Region coupling (Document, Element, Node each touch everything) | merge conflicts | types generated separately from functions; stubs keep every call site compiling; ordered waves (§8.2) |
| JS integration (P3) invalidating P1 layout | redesign | wrapper slot, `visit_js_value`, `js.Value` fields and the split collection exist in P1 (§3.6) |
| Rasterizer size | P1 Ref tests late | Layout tests do not need it: they gate first; Ref tests follow the rasterizer |
| A lower package later needs an engine type (a cut in §4.1.3 proves incomplete, or P2/P3 code crosses a boundary) | an upward import is impossible | move the declaration down, or add a hook in the §4.1.3 style; never merge packages silently; the skeleton checks each package in isolation, so a violation fails at generation time |
| TLS/HTTP maturity | browsing blocked in P2 | out of the P1/P2 test path (tests are local); a separate track |

### 8.2 Regions

Sizes are donor lines (cpp+h); "deps" are regions whose *types or ported functions* must exist
first (stubs are enough for everything else).

**Wave 0, serial (the lead):**

| Region | Content | Size | Deps |
| --- | --- | ---: | --- |
| r00 | (local) the skeleton tools in `.donors/luce-browser-tools/` over the reference build; the five repositories with their `package.prisma`, `test.sh` and CI; the generated types and stubs in every package checking clean; `namemap.tsv`, `regions.tsv`; the copied test data; `web_test` scaffold | new | — |
| r01 | `ak` core: Types, Assertions, Checked, SaturatingMath, IntegralMath, Math, NumericLimits, Traits, HashFunctions, StringHash, QuickSort, BinarySearch, InsertionSort, Span, Array, Vector, HashTable, HashMap, OrderedHash*, Optional/Variant conventions, Function, Error, IterationDecision, Endian, BitCast, Enumerate | ≈7k | r00 |
| r02 | `ak` text: StringBase, StringData, String, FlyString, StringView, StringBuilder, StringUtils, StringConversions, Utf8View, Utf16View, Utf32View, Utf16String*, Utf16FlyString, ByteString, GenericLexer, CharacterTypes, UnicodeUtils, Base64, Hex | ≈9k | r01 |
| r03 | `ak` format: Format (numbers, floats exactly as AK), NumberFormat, FloatingPoint parsing (reuse luce-js dtoa), JsonValue subset if needed | ≈3k | r02 |
| r03b | `web_infra`: `Infra/Strings`, `CharacterTypes`, `ByteSequences`, `Types` | ≈0.3k | r02 |
| r04 | `gc`: Heap, HeapBlock, BlockAllocator, CellAllocator, Cell, Root*, Weak*, ConservativeVector, DeferGC, Function; blobs, atomic blobs, large-object space, stack scanning, Allocator conformance | ≈4k + 1.5k new | r01 |

**Wave 1, parallel (foundations):**

| Region | Content | Size | Deps |
| --- | --- | ---: | --- |
| r05 | `web_url` (URL, Parser, Origin, Host, Site, PublicSuffix) | ≈5k | r02 |
| r06 | `text_codec` (Decoder, Encoder, lookup tables) | ≈2.6k | r02 |
| r07 | `web_unicode`: UCD tables generator, character types subset, Segmenter (grapheme, word, line) | ≈3k new | r02 |
| r08 | `gfx` geometry + Color + ColorConversion + AffineTransform + Matrix4x4 (generated instantiations) | ≈4.5k | r03 |
| r09 | `web_fonts`: OpenType reader, TypefaceSfnt, Font, FontDatabase, FontCascadeList, TextLayout, BasicShaper, font oracle | ≈2k + 3k new | r08 |
| r10 | `gfx` Path, PaintStyle, Filter, Gradients, Bitmap, ImmutableBitmap, PaintingSurface | ≈3k | r08, r11a |
| r11a–d | `raster` (tiny-skia port): a paths + geometry, b rasterizer + stroker + dash, c pipeline + blend + gradients + patterns, d masks/clips + glyphs + blur + conic gradients + filters | ≈15–20k (Rust) | r01 |
| r12 | all P1 generators as Luce programs (§5), in their packages, committed outputs | ≈5k Python ported | r00 |

**Wave 2, parallel (LibWeb core; start when r01–r04 and r12 are in):**

| Region | Content | Size |
| --- | --- | ---: |
| r13 | top level + MimeSniff + Namespace + Platform plugins + Dump (Infra is in r03b, PixelUnits in r08) | ≈5.5k |
| r14 | Bindings-lite (PlatformObject, HostDefined, Intrinsics data), Realm, Vm, WebIDL (ExceptionOr, DOMException, types) | ≈3k |
| r15a/b | DOM Node (3,960) + TreeNode + ParentNode + ChildNode + NonElementParentNode + NonDocumentTypeChildNode + NodeOperations | ≈5.5k |
| r16a/b | DOM Element (5,654) | ≈5.7k |
| r17a/b/c | DOM Document (9,853) + DocumentLoading (HTML path) | ≈10.5k |
| r18 | DOM leaves: CharacterData, Text, Comment, Attr, NamedNodeMap, DocumentFragment, DocumentType, QualifiedName, ElementFactory (824), ElementByIdMap, ShadowRoot, Slot*, Slottable, StyleElementBase, PseudoElement, AbstractElement, collections, DOMTokenList, DOMImplementation | ≈7k |
| r19 | DOM events: Event, EventTarget (993), EventDispatcher, AbortSignal/Controller, CustomEvent, listeners | ≈2.6k |
| r20 | **html:** HTML tokenizer (3,076) + HTMLToken + entities (the tokenizer→parser hook of §4.1.3) | ≈3.7k |
| r21a/b | HTML tree construction (HTMLParser 5,892) + stack of open elements + active formatting elements + HTMLEncodingDetection | ≈6.8k |
| r22 | HTMLElement (2,799) + HTMLOrSVGElement + GlobalEventHandlers + AttributeNames/TagNames/EventNames + Numbers/Dates/Focus | ≈5k |
| r23 | FormAssociatedElement (1,670) + FormControlInfrastructure + AutocompleteElement + ValidityState + ElementInternals + Form/Label/FieldSet/Legend/Output | ≈5k |
| r24 | HTMLInputElement (4,355) | ≈4.4k |
| r25 | Select/Option/OptGroup/SelectedContent/TextArea/Button/Meter/Progress/DataList | ≈4k |
| r26 | tables (7 elements), lists, Details/Summary/Dialog/Slot/Template, Image/Picture/Source (sizing, SourceSet), Link/Style/Meta/Base/Title | ≈6k |
| r27 | the remaining ~40 elements (trivial + media/canvas/iframe/object/embed types and intrinsic sizing), MediaControls DOM | ≈5k |
| r28 | Window, WindowProxy, Navigable/TraversableNavigable/BrowsingContext creation and rendering paths, DocumentState, NavigationParams, PolicyContainers, SandboxingFlagSet, Page | ≈7k touched |
| r29 | HTML EventLoop, TaskQueue, Task, update-the-rendering, Environments data | ≈3k |
| r30a | **css:** CSS Tokenizer, Token, ComponentValue, TokenStream, syntax Types, Number, CharacterTypes, the syntax half of Serialize | ≈3.4k |
| r30b | CSS Parser core (2,930), Helpers, ErrorReporter, RuleContext, the value half of Serialize | ≈4k |
| r31 | CSS RuleParsing, SelectorParsing, MediaParsing, DescriptorParsing, SyntaxParsing, Syntax | ≈4.9k |
| r32a/b | CSS ValueParsing (5,818) + GradientParsing | ≈6.3k |
| r33a/b | CSS PropertyParsing (5,922) + ArbitrarySubstitutionFunctions | ≈6.6k |
| r34 | StyleValues I: StyleValue, Keyword, numeric/length/percentage values, StyleValueList, Shorthand, Color*, Image*, gradients, Position, Edge, Rect, … | ≈8.5k |
| r35 | StyleValues II: CalculatedStyleValue (4,590) + NumericType + Transformation, BasicShape, Filter, Easing, Counter*, Font*, Grid*, … | ≈8.6k |
| r36 | CSS values and units (Length, Angle, …, Display, GridTrack*, Serialize, SystemColor, CounterStyle*, ColorInterpolation) | ≈8k |
| r37 | CSS sheets and rules, StyleSheetList, MediaList, CSSStyleProperties/Declaration/Descriptors, GeneratedCSSStyleProperties glue | ≈7.4k |
| r38 | Selector + SelectorEngine (1,849) + PseudoClass/Element data | ≈3.2k |
| r39 | StyleComputer (3,320) + CascadedProperties + StyleScope + CustomPropertyData + CountersSet | ≈5k |
| r40 | ComputedProperties (2,674) + ComputedValues + StyleProperty | ≈3.5k |
| r41 | CSS fonts: FontComputer, FontFace/FontFaceSet (data and matching), ParsedFontFace, FontFeatureData | ≈4.6k |
| r42 | media queries, supports, container queries, Screen/VisualViewport data; invalidation (Invalidation/*, InvalidationSet, StyleInvalidation*, StyleSheetInvalidation) | ≈6.5k |
| r43 | Layout tree: Node (2,034), Box, BlockContainer, InlineNode, TextNode, BreakNode, Viewport, ReplacedBox, ImageBox, ListItem*, form-control boxes, TreeBuilder (1,448) | ≈7k |
| r44 | FormattingContext (2,862), BlockFormattingContext (1,957), LayoutState (1,308), AvailableSpace | ≈6.3k |
| r45 | InlineFormattingContext, InlineLevelIterator, LineBuilder, LineBox, LineBoxFragment | ≈2.3k |
| r46 | FlexFormattingContext (2,704) | ≈2.7k |
| r47 | GridFormattingContext (3,251) | ≈3.3k |
| r48 | TableFormattingContext (2,190), TableGrid, TableWrapper | ≈2.5k |
| r49 | SVGFormattingContext + SVG layout boxes | ≈1.5k |
| r50 | Paintable, PaintableBox (1,713), PaintableWithLines, PaintableFragment, TextPaintable, StackingContext, ViewportPaintable | ≈5k |
| r51a | **render:** DisplayList, DisplayListRecorder, commands, AccumulatedVisualContext, ScrollFrame/State, PaintStyle, GradientData, BorderRadiiData/BordersData types (the moves of §4.1.3) | ≈2.4k |
| r51b | DisplayListRecordingContext, BorderRadiusCornerClipper, Scrollbar, ChromeMetrics, DevicePixelConverter | ≈0.8k |
| r52 | Border/Background/Shadow/Gradient/TableBorders painting, BorderRadii*, BoxModelMetrics, ResolvedCSSFilter, Blending | ≈2.8k |
| r53 | SVG paintables, masks, clips, image/marker/form-control paintables | ≈2.2k |
| r54 | **render:** DisplayListPlayerCpu (replaces the Skia player) | ≈1.5k new |
| r55 | SVG I: SVGElement, SVGGraphicsElement, SVGSVGElement, AttributeParser (1,049), Path, geometry elements, lengths, transforms, animated values | ≈6k |
| r56 | SVG II: gradients, patterns, masks, clip paths, use, symbol, text, foreignObject, filter elements (attributes), SVGDecodedImageData | ≈7k |
| r57 | `web_test` complete (layout, ref, crash modes), expected-failures tooling, CI script | ≈2k new |

**Regions by package.**

| Package | Regions |
| --- | --- |
| luce-browser-foundation | r01, r02, r03, r03b, r04, r05, r06, r07, the UCD/encoding/public-suffix parts of r12 |
| luce-browser-css | r30a, the `css_data` part of r12 |
| luce-browser-html | r20, the entities part of r12 |
| luce-browser-render | r08 (with PixelUnits), r09, r10, r11a–d, r51a, r54, the geometry part of r12 |
| luce-browser-engine | r13–r19, r21–r29, r30b, r31–r50, r51b, r52, r53, r55–r57, the style-sheet/media-controls/ARIA parts of r12 |
| local (`.donors/luce-browser-tools`) | r00's extraction and comparison tools |

Waves follow the packages: foundation first, then css, html and render in parallel (render's
display-list region needs only the css data enums), then the engine; the engine's skeleton can be
generated as soon as the lower packages' *types* exist, because stubs in lower packages are enough.

**Wave 3 (convergence):** triage by the runner's failure and trap statistics; fix regions own
their bugs; the expected-failures list shrinks to reviewed reasons.

**Phase 2 (loading).** P1 ported the callers already: navigation and session history
(`Navigable`, `TraversableNavigable`, `NavigableContainer`, r28), `<img>` and its
`SharedResourceRequest`/`ImageRequest` (r26), `<link>` style sheets and `@import` (r26, r37),
`CSS/Fetch` and `url()` (r36), `@font-face`'s `FontLoader` (r41), `<object>`/`<iframe>` (r27, r28),
`SVGDecodedImageData` (r56), XML documents in `DocumentLoading` (r17), MimeSniff and the
`ImageCodecPlugin` seam (r13). Their paths stop in what P2 ports, the regions below. The skeleton
was generated for them against the ported engine (§4.4, "Later phases"): their types are declared
whole (`Fetch::Infrastructure::Request`, `Response` and its filtered responses, `FetchController`,
`FetchParams`, `ResourceLoader`, `Policy`, the 26 directive classes, `XMLDocumentBuilder`, …),
every function has a typed stub in `stubs/stub_p2<x>_<name>[_N].lucb`, and the closure stubs that
P1 regions wrote for these files (with their signatures) moved there from `stubs/stub_closure.lucb`.

| Region | Content | Size | Deps |
| --- | --- | ---: | --- |
| p2b | `fetch_http`: `Fetch/Infrastructure/HTTP/*` (Requests 1.1k, Responses 0.7k, Bodies, CORS, MIME, Statuses) and LibHTTP's `HeaderList`, `Header`, `Method`, `Status`, `HTTP` (r28 ported the header-list parts P1 needed, `external/lib_http`) | ≈3.7k | — |
| p2a | `fetch_infrastructure`: `FetchController`, `FetchParams`, `FetchAlgorithms`, `FetchRecord`, `FetchTimingInfo`, `ConnectionTimingInfo`, `Task`, `URL`, `NetworkPartitionKey`, the port/MIME/nosniff blocking checks, `IncrementalReadLoopReadRequest`; `ReferrerPolicy/*`, `SecureContexts/*` | ≈2.3k | p2b |
| p2e | `csp_policy`: `ContentSecurityPolicy/` `BlockingAlgorithms`, `Policy`, `PolicyList`, `SerializedPolicy`, `Violation`, `SecurityPolicyViolationEvent`; `Directives/` `Directive`, `DirectiveFactory`, `Names`, `KeywordSources`, `KeywordTrustedTypes`, `SerializedDirective` | ≈2.6k | p2b |
| p2f | `csp_directives`: `Directives/DirectiveOperations` (1.1k), `SourceExpression` and the 22 directive classes | ≈3.5k | p2e |
| p2d | `loader_resources`: `Loader/*` (`ResourceLoader`, `FileRequest`, `LoadRequest`, `GeneratedPagesLoader`, `ContentFilter`, `ProxyMappings`), `HTML/PotentialCORSRequest`, `PreloadEntry`, `NavigationObserver`, `BitmapDecodedImageData`, `XML/XMLDocumentBuilder`; the LibCore seams `Core::Resource` and `Core::Promise` (not ported: implemented over luce-std) | ≈2.6k | p2b |
| p2c | `fetch_fetching`: `Fetch/Fetching/*` (`Fetching.cpp` 2.5k: fetch, main fetch, scheme/HTTP/redirect/network fetch, CORS preflight; `FetchedDataReceiver`, `PendingResponse`, `Checks`) | ≈3.1k | p2a, p2b, p2d, p2e |
| p2r | the rest of phase 2 without rendering: a hermetic `web_test` (no network), what `Document::destroy` walks (MessagePort's registry, the blob URL store, the window's event sources, web sockets and IndexedDB connections) so SVG-as-image documents load, History and Navigation's entry list as data, BeforeUnloadEvent and PromiseRejectionEvent, StructuredDeserialize of undefined and null | ≈0.7k | p2c |

In dependency order: p2b, then p2a, p2e and p2d in parallel, then p2f and p2c (≈17.7k donor
lines in all; `docs/regions.tsv` has the files). `stubs/stub_p2_closure.lucb` holds the virtuals
of `Streams::ReadRequest`, whose class the P2 types pull in whole (Streams stay P4; the byte
streams fetch bodies need are the stand-in of §3.6, region p2s).

Decisions of the phase-2 closure:

- The JS-facing Fetch API (`Fetch/Body`, `BodyInit`, `Headers`, `HeadersIterator`, `Request`,
  `Response`, `FetchMethod`, `Enums`) and script fetching (`HTML/Scripting/Fetching`) are P3;
  the Navigation API (`HTML/Navigation`, `History`) stays P3 as before.
- The XML parser is luce-xml's (§7.0): `XMLDocumentBuilder` is the listener it drives. Its
  `XML::Listener` base is LibXML's, outside the port, so the builder's overrides are generated as
  the builder's own vtable (`XmlDocumentBuilderVTable`): the luce-xml adapter calls those slots.
  `xml_parse_with_document_builder` (r17's seam, now in p2d's stubs) is where the adapter goes.
- The image decoders are luce-png, luce-jpeg and the new sibling packages behind the ported
  `Platform::ImageCodecPlugin` (§7.0); no LibGfx decoder is ported. `BitmapDecodedImageData`
  holds what they return.
- `ResourceLoader`'s `Requests::RequestClient` (LibRequests) is the `RequestClient` seam of §7.1,
  written by p2d with an in-process client over `file:`/`data:` and, for `http(s):`, luce-std `net`
  and luce-tls (§7.0; luce-http-client is cleartext IPv4 only).
- Closure stubs that only scripting or user input reaches were relabeled from `unported (P2)` to P3
  or P4: blob URLs and `Blob`/`File` (`FileAPI`), `FileList` (P4), storage, `document.cookie`'s
  `HTTP::Cookie::parse_cookie`, `DOMURL::url_encode` (form encoding), `Core::System`
  (`navigator`), `PerformanceEntryTuple`.
- New classes share the class id of their nearest numbered ancestor (GC::Cell's 0, JS::Cell's 1,
  PlatformObject's 6, DOM::Event's for `SecurityPolicyViolationEvent`) and are recognized by their
  ClassInfo, as r14's `Realm` and r55's `DOMRect`: renumbering would rewrite every ported types
  fragment. r28's hand-filled `Fetch::Infrastructure::Response` (id 0) is now generated whole with
  JS::Cell's id, `is<Response>` covering its five filtered subclasses.

P3 (bindings generator, WebIDL 3k, Bindings 2.3k, the JS-facing halves of DOM/HTML/CSS,
Range/TreeWalker/MutationObserver, UIEvents, Streams, XHR, Encoding, …) and P4 are planned when P2
converges, from the same skeleton tooling with a wider scope.

Phase-4 regions ported ahead of the plan because real sites trap in them: p4a (animations:
`CSS/EasingFunction`, `Animations/*`, `CSSAnimation`, `CSSTransition`, `Interpolation`, the animation and
transition events and Document's animation update; `docs/regions/p4a.md`). Their JS-facing entry points keep their
signatures and trap `unported (P3)`.

### 8.3 Estimate

Calibration: luce-js ported quickjs.c (≈60k lines of C, by its region commits' line ranges) in ≈30 regions (≈2k C lines per region), then
converged to test262 parity. The family's P0+P1 is ≈245k donor lines of LibWeb plus ≈45k of
foundations and a ≈15–20k-line rasterizer port: about **5× luce-js**, in ≈75 regions (several
split a/b/c) of 2–6k lines. With 25–30 agents in parallel: waves 0–2 are roughly 4–5 rounds of
region sessions, the lead's skeleton work (r00) being the critical path at the start. Convergence
is the larger unknown: getting ≥95% of 854 Layout tests exact to 1/64 px is harder than
test262 parity, because a small divergence in fonts, line breaking or a formatting context
fails many tests at once; plan for convergence to take as long as the port itself.
P2 ≈ +25%, P3 ≈ +50% of P1's effort (the bindings generator, the joint GC, and the JS-facing
API bodies across 644 IDL interfaces). These are planning figures, not measurements.

---

## 9. Questions for the owner

Decided:

1. **Managed memory for AK types** (§3.3): *decided by the owner*: accepted as proposed.
2. **Reference Ladybird**: *decided by the owner*: built locally under `.donors/` by the
   coordinator; never in a repository (§6.6, §6.8).
3. **Rasterizer**: *decided by the owner*: part of the browser family, not a separate `luce-2d`;
   a faithful port of tiny-skia's algorithms in `luce-browser-render` (§7.3).
4. **Packages**: *decided by the owner*: the `luce-browser-*` family; the layering is §4.1
   (foundation, css, html, render, engine, application).
5. **Test tree location**: *decided by the owner's repository rule*: Ladybird's test data is
   copied into the repository whose CI runs it; comparison drivers stay local (§6.8).
6. **Naming**: *decided here* (§4.2): no prefixes in the lower packages; short prefixes in the
   engine (`Dom`, `Html`, `Css`, `Layout`, `Paint`, `Svg`, `Fetch`, `Bind`, `Idl`, `Mime`).

Still open:

7. **Shaping beyond the test font**: port a full shaper (HarfBuzz-class, large) later, or use
   platform shaping via luce-fonts for the browser while tests use the Luce shaper?
8. **Screenshot tests**: keep reviewed Luce-rendered baselines beside Ladybird's Skia PNGs, or
   only tolerance-based comparison against the Skia PNGs? (With tiny-skia's pipeline the
   differences should be small; the P2 statistics will show.)
9. **Networking and TLS** for P2 browsing (general TLS, CA store, HTTP/2, Brotli): a separate
   track owned outside the browser family?
10. **Where DESIGN.md lives** once the repositories exist: in luce-browser-engine (proposed), with
    each lower package's README pointing to it.

---

## 10. Appendix: facts checked against the donor

| Claim | How it was checked |
| --- | --- |
| Pin `47c82b38d0`, 2026-05-03 | `git log -1` in the donor |
| Rust at the pin in LibJS, LibGfx (YUV), LibUnicode (ICU4X calendar), LibRegex; none in LibWeb | `Cargo.toml` workspace members; `find -name '*.rs'` |
| LibUnicode wraps ICU; LibGfx uses Skia and HarfBuzz; LibXML wraps libxml2 | includes in `LibUnicode/*.cpp`, `LibGfx/TextLayout.cpp`, `vcpkg.json` |
| Suite sizes and script/resource counts (§1.3) | `find` + `grep` over `Tests/LibWeb` |
| Layout expectations = layout + paint + stacking-context dumps | `test-web/main.cpp` (`request_internal_page_info` with the three flags), `ConnectionFromClient.cpp` |
| Test mode maps generic families to SerenitySans, symbols to Noto Emoji | `Platform/FontPlugin.cpp` |
| Text advances reproduced exactly | Python over `SerenitySans-Regular.ttf` vs `Layout/expected/block-and-inline/abspos-block.txt` |
| Fuzzy reftest rule | `test-web/Fuzzy.cpp` |
| LibGC: conservative stack + registers, 16 KiB blocks, size classes to 3072, interior pointers | `LibGC/Heap.cpp`, `HeapBlock.h` |
| One `ref_count()` use in LibWeb | `grep` |
| C++ pattern counts (§2) | `grep -rF` over LibWeb |
| luce-base: `self` only in methods; generic struct + generic interface traits; vtables of nested function-pointer structs; fallible function pointers; payload enums with pointer payloads; interface views as fields; union blocks `==`; ORDER fragments in subdirectories; no static interface requirements; stack pointer and callee-saved registers readable with `asm` | small programs compiled and run with `~/.local/bin/luce-base` while writing this document |
| luce-js builds in ≈9 s cold | `luce-base build tests/ljs.lucb` timed |
| Package cycle analysis (§4.1.2): whole LibWeb one SCC; edge counts per component pair; 146 core files and 550 qualified references into Layout/Painting; 108 accessor calls (38 methods); 31 `create_layout_node` overrides; tokenizer, CSS syntax and display-list cut sites | a Python script over all 2,510 LibWeb `.cpp`/`.h` includes (component graph + Tarjan SCC) and `grep` counts, scratch only |
