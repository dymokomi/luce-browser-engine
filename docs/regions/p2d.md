# Region p2d: loader_resources — what other regions need to know

Region p2d ports LibWeb's `Loader/` (`ResourceLoader`, `LoadRequest`, `FileRequest`, `ContentFilter` with its
`AsciiStringMatcher`, `ProxyMappings`, `GeneratedPagesLoader`, `UserAgent`, `NavigatorCompatibilityMode`),
`HTML/PotentialCORSRequest`, `PreloadEntry`, `NavigationObserver` and `BitmapDecodedImageData`, and writes the LibCore
seams `Core::Promise` and `Core::Resource` (with `ResourceImplementation`, the bits of `Core::System`, `MappedFile`,
`DirIterator`, `File`, `ProxyData` and `MimeData` they need). Ladybird's RequestServer client (LibRequests) is replaced by
an in-process seam with the engine's own client (file:, data:, http(s): on luce-std `net`, luce-tls and luce-compress),
and images decode through luce-png and luce-jpeg behind `Platform::ImageCodecPlugin`. Every function of
`stubs/stub_p2d_loader_resources` is ported and the stub is gone (its XMLDocumentBuilder part went to p2x).

## Fragments

| Fragment | Donor |
| --- | --- |
| `external/lib_core/promise` (+ `types_promise`, filled) | `LibCore/Promise.h` 27-186: generic `CorePromise[TResult, TTError]` and `core_promise_*` |
| `external/lib_core/system` | the LibCore calls of the loader over luce-std: `System::stat`/`fstat`/`getcwd`/`close`, `MappedFile::map`, `DirIterator`, `File::adopt_fd` + `read_until_eof` |
| `external/lib_core/resource` (+ `types_resource`, new) | `LibCore/Resource.cpp` 13-115 with `Resource.h`, `ResourceImplementation.cpp`, `ResourceImplementationFile.cpp` |
| `external/lib_core/proxy` (+ `types_proxy`, filled) | `LibCore/Proxy.h` 26-45 (`ProxyData::parse_url`) |
| `external/lib_core/mime_data` | `LibCore/MimeData.cpp` 50-161 (`guess_mime_type_based_on_filename` and its table) |
| `external/lib_requests/network_error` | `LibRequests/NetworkError.h` 29-61 |
| `external/lib_requests/request_client` (+ `types_request`, `types_request_client`, filled) | the RequestClient seam, after `Request.cpp` 27-113 and `RequestClient.cpp` 37-62 |
| `html/bitmap_decoded_image_data`, `navigation_observer`, `potential_cors_request`, `preload_entry` | the `.cpp` (and inline `.h` members) of the same name; `preload_entry` has `Traits<PreloadKey>` |
| `loader/content_filter`, `file_request`, `generated_pages_loader`, `load_request`, `proxy_mappings` | the `.cpp`/`.h` of the same name (`generated_pages_loader` carries a private port of AK's `SourceGenerator`) |
| `loader/resource_loader_1`, `_2`, `_3` | `ResourceLoader.cpp` 33-196, 198-352, 354-522 with `ResourceLoader.h` |
| `loader/types_user_agent` (filled) | `UserAgent.h`'s constants for each target |
| `loader/in_process_request_client`, `in_process_http` | new: the engine's RequestClient (not a port) |
| `platform/image_codec_plugin_luce` | new: the engine's ImageCodecPlugin over luce-png and luce-jpeg (not a port) |
| `loader/tests_loader_cases`, `tests_loader_1`, `_2`, `_3`, `html/tests_html_loading` | tests (below) |

## What other regions must know

### The network seam

- `RequestsRequestClient` (C heap, for the process) has a vtable `{ start_request, stop_request, ensure_connection }`
  and the heap its requests are cells of. `requests_request_client_start_request(client, method, url, headers?, body,
  ...)` makes a `RequestsRequest` cell with the next id and asks the implementation to start it; the implementation
  delivers `requests_request_did_receive_headers`, `_did_receive_data` and `_did_finish` on the event loop, never during
  start_request. `requests_request_stop` (p2a's closure stub, now ported) answers `bool` as C++.
- **`InProcessRequestClient`** (`in_process_request_client_create(heap)`) serves file:, data: and http(s):. A request
  runs as a Core deferred invocation; an http(s) request blocks the event loop while it runs (connect, TLS 1.3 with the
  public roots, one HTTP/1.1 exchange with `Connection: close` and `Accept-Encoding: gzip, deflate`, 1xx heads skipped,
  fixed/chunked/until-close bodies, gzip and deflate decoded when the body is complete, redirects delivered for Fetch).
  The event loop seam watches no sockets yet; non-blocking requests, connection reuse, HTTP/2 and a cache are follow-ups.
- `in_process_request_file(file_request)` implements `PageClient::request_file` in process (WebContent asks the UI
  process): an embedder's PageClient forwards to it. web_test's worker does.
- **Embedders** do what WebContent's main does: `core_resource_implementation_install(core_resource_implementation_file_create(dir))`
  (the repository's resources are `data/res`), `luce_image_codec_plugin_install()`, and
  `resource_loader_initialize(heap, &in_process_request_client_create(heap).client)`. web_test's
  `worker_install_loading` does all three.

### ResourceLoader

- The loader (`resource_loader_the()`) and what it keeps live in the C heap (DESIGN §3.3 rule 7): its setters copy their
  strings there, and `m_active_requests` is retyped to `HashMap[u64 id, gc.Root[RequestsRequest]]` (a C++ RefPtr per
  active request).
- `resource_loader_load(loader, request: LoadRequest*, on_headers, on_data, on_complete)` keeps the stub's signature; the
  three `gc.Function`s must not be none (they are `GC::Root`s in C++). Its lambdas' captures are managed memory, so the
  caller runs with its VM's heap current, as the engine does.
- `handle_file_load_request`, `handle_about_load_request` and `handle_resource_load_request` take AK Functions where C++
  takes template handlers (module-private now). `log_failure` takes the error formatted as text.
- `store_response_cookies` calls the closure stub `http_parse_cookie` (P3): an http(s) response with `Set-Cookie` and
  credentials included traps there until cookies are ported.
- about: loads read `resource://ladybird/about-pages`, which the repository does not carry (C++'s MUST traps without it).

### Signatures and types changed

- **Core::Promise is generic**: `core_promise_construct[TResult, TTError]()`, `core_promise_resolve`, `_reject`,
  `_is_resolved`, `_is_rejected`, `_await` (answers `CorePromiseResultOrError[TResult, TTError]`, the C++ ErrorOr),
  `_when_resolved(handler: Function1[TResult*, unit])`, `_when_rejected(handler: Function1[TTError*, unit])`,
  `_add_child`. The per-instantiation stubs (`core_promise_typeface_*`, `_bool_*`, `_empty_*`) are gone and their
  callers updated (`css/font_face_1`, `html/html_link_element_2`, `navigable_5`, `navigable_container`,
  `session_history_traversal_queue`, `traversable_navigable_3/4/5`): handlers take a pointer to the value, as C++'s
  `Result&` (`Typeface**`, `Empty*`, `AkError*`).
- `CoreResource` (stub_closure's opaque struct) is declared in `external/lib_core/types_resource`; `core_resource_clone_data`
  takes `const CoreResource*`.
- `FileRequest.on_file_request_finish` is `ak.Function1[ErrorOrI32, unit]` (C++ `Function<void(ErrorOr<i32>)>`; the new
  enum `ErrorOrI32` is in `types_file_request`).
- `LoadRequest.m_load_timer` is `ak.MonotonicTime?` (Core::ElapsedTimer: when the timer started); `load_request_create(headers)`
  makes one (`LoadRequest load_request { headers }`).
- `html_navigation_observer_set_navigation_complete` takes `ak.Function0[unit]?` like `set_ongoing_navigation_changed`
  (an empty function or none clears the callback, as C++).
- `default_user_agent`, `default_platform`, `default_navigator_compatibility_mode` are `let`s (`str`), per target.
- Filled types: `AsciiStringMatcherTransition`/`Node`, `CoreProxyData` (+ `CoreProxyDataType`), `RequestsRequest` (a
  JS::Cell-classed cell, `requests_request_class`), `RequestsRequestClient` (+ vtable, `RequestsStartRequest`,
  `RequestServerCacheLevel`), `ResourceLoaderFileLoadResult`, `HtmlPreloadKeyTraits` (generated/types_traits).

### Images

`luce_image_codec_plugin_decode(bytes)` decodes still PNG (any color type, palettes, tRNS) and JPEG (baseline and
progressive) to one premultiplied BGRA8888 frame (`raster.premultiply_u8`, Skia's rounding; Ladybird's decoders give
unpremultiplied BGRA8888, which the rasterizer premultiplies the same way), sRGB. `decode_image` settles its promise on
the next turn of the event loop, as the ImageDecoder process replies later. GIF, WebP, APNG and other formats are
follow-ups (new luce packages); ICC profiles and cICP are not read.

### Dependencies

`package.prisma` adds luce-jpeg, luce-compress and luce-tls (luce-png was there); `bootstrap/PACKAGES` pins luce-jpeg
`fca5e66`, luce-crypto `13484cb` and luce-tls `81eb835`, which build with luce-base e7baf89 and luce-std 2347ecb. The
module imports `from luce_std import files as std_files, net`, `from luce_compress import flate`, `from luce_tls import
stream as tls_stream`, `from luce_png import png as png_codec`, `from luce_jpeg import jpeg as jpeg_codec`, `import c as
libc` and render's `raster` (`files`, `jpeg` and `c` are names of locals elsewhere in the module).

## Tests

- `tests_loader_1` runs `tests_loader_cases`: 283 cases pinned to the reference build by a local oracle
  (`luce-browser-tools/oracles/luce-browser-engine/loader_resources`: `oracle.cpp`, `build.sh`, `expected.txt`,
  `gen_luce_cases.py`): AsciiStringMatcher over six pattern sets, ContentFilter on and off, ProxyMappings (its SOCKS5
  URLs never parse as IPv4 hosts, as in C++), every create_potential_CORS_request combination, translate_a_preload_destination,
  Traits<PreloadKey>::hash, 40 file names' MIME types, the network error strings, the user agent and platform (macOS
  arm64 only), the Last-Modified format and three generated error pages.
- `tests_loader_2`: Core::Promise, Core::Resource (file:// and resource://, children, load_from_filesystem, errors), the
  directory page, LoadRequest, ResourceLoader's settings (copies surviving a collection) and loads (blocked port,
  filtered URL, unsupported scheme, file: without a page, resource: files and errors, file: through request_file, a
  directory), the in-process client's data: and file: requests and stop, and request_file's descriptor.
- `tests_loader_3`: http: on a loopback server (its own thread): Content-Length, chunked (with a query), until-close,
  gzip, deflate, 100 Continue, a redirect, a POST echo, a truncated body, a refused connection, the request head sent;
  ResourceLoader's http load (page notifications, the rooted request through a collection, the error text); the image
  plugin (a partial-alpha RGBA PNG's premultiplied pixels, smiley.png, a JPEG within 4 of libjpeg, unsupported and
  broken data, decode_image's promise); BitmapDecodedImageData.
- `html/tests_html_loading`: NavigationObserver (registration, callbacks, unregistered when collected), preload keys,
  entries and consume_a_preloaded_resource, PreloadEntry's visit_edges.
- New test data: `data/res/ladybird/templates/{error,directory}.html` (Ladybird's, BSD-2, `data/res/LICENSE`) and
  `tests/libweb/Text/.../imagebitmap/resources/squares_1.jpg` (the JPEG fixture, from Ladybird's tests).

`luce-base test src/web`: 616 passed (18 new).

## web_test

The pass counts do not change (Layout 864 of 922, Ref 609 of 820, Crash 41 of 52, Screenshot 30 of 67, as on main); the
expected-failures lists were rewritten for their notes: the 140 tests that stopped at `create_potential_CORS_request`
(`<img>`, SVG `<image>`, `feImage`, external `<use>`) now stop at `Fetch::Fetching::fetch` (p2c), and the 5 iframe tests
that stopped at `Core::Promise<Empty>::construct` at `History::create` (P3).

## Deviations and notes

- Fds: luce-std opens and reads by path, so a descriptor from request_file is reached as `/dev/fd/N` (macOS and Linux).
  The file load closes a directory's descriptor, which C++ leaves open.
- `Core::DirIterator` lists through luce-std, sorted by bytes (readdir's order in C++); `Resource::children` is therefore
  sorted. `Resource::stream`, `Promise::after` and `Promise::map` (no instantiation in the engine) and LibRequests'
  buffered mode and certificates are not ported. A Promise handler cannot fail (the ErrorOr-answering when_resolved
  overload's error path has no caller).
- `load_error_page` and `load_file_directory_page` use a private port of AK's `SourceGenerator` (set/get/append), which
  the pinned foundation lacks.
- The proxy mappings' log line prints `[ a, b ]` as AK's Vector formatter does.
- HANDOFF.md §5 item 4's engine follow-ups were done by earlier regions; none concerns this region.
