# Region p2x: XML documents — what other regions need to know

Region p2x ports LibWeb's `XML/XMLDocumentBuilder` and `XML/XMLFragmentParser`, and LibXML's `Parser`
(`Parser.cpp`, `Parser.h`) with **luce-xml** (github.com/dymokomi/luce-xml, our conforming XML 1.0 +
Namespaces parser) in libxml2's place. XHTML, SVG and XML documents now load: web_test loads `.xht`,
`.xhtml`, `.svg` and `.xml` tests and references through `load_document`'s steps. XMLDocumentBuilder's
types and stubs came from the p2d (loader_resources) skeleton and `stub_closure`; `docs/regions.tsv` has
a p2x row now and p2d's row no longer lists `XML/XMLDocumentBuilder`.

## Fragments

| Fragment | Donor |
| --- | --- |
| `external/lib_xml/parser` | `LibXML/Parser/Parser.cpp` 1-543 and `Parser.h` 1-92: the parser and its SAX handlers over luce-xml (below), and the `xml_parse_with_document_builder` seam |
| `external/lib_xml/types_document` | `XML::Doctype`, `ExternalID`, `PublicID`, `SystemID`, filled by hand (the generated `XmlDoctype` was opaque) |
| `xml/types_xml_document_builder` | `NamespaceStackEntry` and `NamespaceAndPrefix` filled by hand; `m_text_builder`'s UTF-16 mode in `init_fields` |
| `xml/xml_document_builder` | `XMLDocumentBuilder.cpp` 1-434 with `XMLDocumentBuilder.h` |
| `xml/xml_fragment_parser` | `XMLFragmentParser.cpp` 1-98 (its closure stub in `stub_closure` is gone) |
| `xml/tests_xml_document_builder_cases`, `tests_xml_document_builder`, `tests_xml_document_builder_2` | tests (below) |

## luce-xml in libxml2's place

luce-xml is a new engine dependency (`package.prisma`, `bootstrap/PACKAGES` at b20338f), imported as
`from luce_xml import xml` in `module.lucb`. Ladybird's `XML::Parser` drives libxml2's SAX2 push parser
and turns its callbacks into `XML::Listener` calls; here `XmlParserContext` (C++ `ParserContext`) is the
luce-xml `Listener` and calls the same handlers for the events libxml2 would have called them for:

- the source is decoded UTF-8 already (`xmlSwitchEncoding`): `xml.Options.assume_utf8`;
- XML_PARSE_NONET: external entities and the external DTD subset are never read (`resolve` answers none);
- the namespace declarations come first in an element's attributes (libxml2 lists them apart), the
  binding of `xml`, which libxml2 never reports, left out;
- `preserve_cdata` off (XML_PARSE_NOCDATA) makes a CDATA section text; `preserve_comments` off drops comments;
- `named` requests (luce-xml's undeclared entity where XML allows one) are libxml2's `getEntity`: HTML named
  characters for documents whose DOCTYPE names a known XHTML public identifier, nothing otherwise (libxml2's
  suppressed warning drops the reference too);
- MAX_XML_TREE_DEPTH (5000) is the start handler's own check, as in C++.

The reference build's DOM trees are reproduced for every oracle case (below) except where luce-xml is right
and libxml2 is not, on purpose:

- attribute values are as XML specifies (references replaced): libxml2's SAX2 without XML_PARSE_NOENT leaves a
  declared entity's reference unexpanded and writes `&amp;` and `&#38;` as `&#38;`;
- an entity declared through a parameter entity reference in the internal subset is read (libxml2 drops it);
- a namespace error stops the parse before the builder sees the element (libxml2 goes on, so the builder's
  `has_error` is also set there); the document becomes the error document either way;
- parse error messages are luce-xml's, positions from luce-xml (the error document says
  `Failed to parse XML document: <luce-xml message> at line: L, col: C (offset O)`).

## What other regions must know

### Signatures and types

- `XmlParserOptions` moved from `stub_closure` to `external/lib_xml/parser`, with C++'s defaults
  (`preserve_cdata = true`, `treat_errors_as_fatal = true`) and the `resolve_named_html_entity` function
  pointer. A zeroed `XmlParserOptions()` used to mean `preserve_cdata = false`. Callers pass
  `resolve_named_html_entity = resolve_named_html_entity` as C++ does (`document_loading_1`,
  `svg_decoded_image_data` updated).
- `xml_parse_with_document_builder(document, source, options, scripting_support = .enabled)`: the scripting
  support is a new parameter; SVGDecodedImageData passes `XmlScriptingSupport.disabled`, as C++.
- `XmlParser`, `xml_parser_create`, `xml_parser_parse_with_listener(parser, builder) -> XmlParseError?` (the
  C++ `ErrorOr<void, ParseError>`), `xml_parse_error_to_string` (AK's formatter) for callers that need the
  parser itself (XMLFragmentParser does).
- `ByteStringTraits` (generated, trapped) hashes and compares as AK's `Traits<ByteString>`.
- `DocumentLoadingProcessXmlBody` (load_xml_document's `process_body`) is `pub` for web_test's worker.
- Two locals named `xml` (`tests_namespace`, `node_5`'s serializer) were renamed: the module now imports `xml`.

### Fixes in other regions' code

- `load_xml_document`'s two error paths built the error document's Utf16String from a UTF-8 StringBuilder
  (`utf16_string_from_string_builder` asserts a UTF-16 builder): they convert the UTF-8 text now
  (`Utf16String::formatted` in C++).

### Where XML documents stop

- An HTML `<script>` in an XML document with XML scripting support (every document load_xml_document makes):
  the end tag prepares the script, whose `prepare_script_text` stops in
  `TrustedTypes::get_trusted_type_compliant_string` (a closure stub, phase 3). No web_test test reaches it.
- Style sheets and images of XHTML tests stop in the fetch regions (`create_potential_CORS_request`,
  `FetchAlgorithms::create`), as HTML tests do.
- A `<style>` inline check needs the global object's CSP list, and an SVG `<title>` the page's top-level
  traversable: the unit tests' settings realm has neither, so their cases avoid both (web_test's pages have them).

## web_test

The worker (`tests/web_test/worker_load`) does what `load_document` does: the file: response's Content-Type is
the type LibCore guesses from the file name (`Core::guess_mime_type_based_on_filename`, the rows test files
can match), the computed type is sniffed in a browsing context, and an HTML type is loaded as before while an
XML type gets `Document::create_and_initialize("xml", essence)`, the activation, "ready to run scripts" (as
the activation of a history entry sets it) and load_xml_document's `process_body` steps over the file's bytes
(Body::fully_read reads them from a stream, phase 4). Another type (the PDF test) traps
`unported: loading a document of type application/pdf`.

| Suite | Before | After |
| --- | --- | --- |
| Layout | 855 / 922 | 864 / 922 |
| Ref | 471 / 820 | 609 / 820 |
| Crash | 38 / 52 | 41 / 52 |
| Screenshot | 30 / 67 | 30 / 67 |

None of the 189 tests stops at "not HTML" any more: 150 pass; 11 Ref tests now fail on pixels (five `.xht`
tests whose text is antialiased differently, as `float-nowrap-*.html` are, and six `perspective-origin-*.html`
whose reference is XHTML and fail as `perspective-zero.html` does: 3D transforms); the rest stop in fetching.
The expected-failures lists were rewritten. The layout trees of the 188 XML test documents that load were
compared with the reference build's (`Ladybird --headless=layout-tree`, `compare_layout.py` below): 182 are
identical (the baselines masked, since the headless run's fonts differ from test-web's), and the 6 others
differ only in line heights of the headless run's fonts (table tests in monospace).

## Tests

- `tests_xml_document_builder_cases` + `tests_xml_document_builder`: 77 cases pinned to the reference build by a
  local oracle (`luce-browser-tools/oracles/luce-browser-engine/xml_documents`: `oracle.cpp` links the reference
  build's LibWeb objects, `cases.txt`, `expected.txt`, `gen_luce_cases.py`, `build.sh`; `compare_layout.py`
  compares web_test's layout trees with headless Ladybird's): `resolve_named_html_entity`; documents as
  load_xml_document parses them (XHTML with and without XHTML public identifiers and named characters,
  internal entities, attribute defaults and normalization, whitespace, prolog comments and PIs, the DOCTYPE
  inserted first, CDATA and the text joined into it, nested templates, SVG with xlink and xml attributes and a
  foreignObject, MathML, prefixed and default namespaces, line ends, encodings, a BOM, and 15 error documents);
  build_xml_document's result and tree; SVGDecodedImageData's parse (scripting disabled); the XML fragment
  parsing algorithm (namespaces in scope, exceptions, comments dropped). Each DOM dump shows namespaces,
  qualified names, element classes (the element factory's) and attributes in order. Parse error messages are
  written `*` on both sides.
- `tests_xml_document_builder_2`: the five deviating cases pinned to the port's results, luce-xml's messages
  in the ParseError format and the parse error causes, the tree kept up to an error, `preserve_cdata` off, and
  `set_source`. MAX_XML_TREE_DEPTH is not tested: a tree 5000 elements deep takes minutes to build here as in
  the reference build (every insertion walks its ancestors).

`luce-base test src/web`: 579 passed (11 new).

## Deviations and notes

- `Parser::parse` (LibXML's own tree) is not ported: LibWeb never calls it.
- The ParseError of MAX_XML_TREE_DEPTH has offset 0 (libxml2's input offset is not known to the listener).
- `get_entity_handler`'s static 32-byte buffer becomes the context's list of answers, kept alive until the parse
  returns, as luce-xml needs.
- The template node stack is a plain Vector (C++ `GC::RootVector`): the builder lives on its caller's stack.
- `document_end`'s load task keeps the donor bug that sets `dom_content_loaded_event_end_time` for the load
  event's end time (`# donor bug`).
- HANDOFF.md §5 item 4's engine follow-ups were done by earlier regions (CSS/Serialize, the invalid-rule
  reporter, the tokenizer hook, the TokenStreamToken constraints); none concerns this region.
