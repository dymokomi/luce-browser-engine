# Region p2c: fetch_fetching — what other regions need to know

Region p2c ports LibWeb's `Fetch/Fetching/` whole: `Fetching.cpp` (fetch, populate request from client, main fetch,
determine the environment, fetch response handover, scheme fetch, HTTP fetch, HTTP-redirect fetch,
HTTP-network-or-cache fetch, the network fetch through the ResourceLoader, CORS-preflight fetch, the Fetch metadata
headers, HTTPCache and the memory cache switch), `Checks.cpp` (CORS and TAO checks), `FetchedDataReceiver`,
`PendingResponse` and `RefCountedFlag`. Every function of `stubs/stub_p2c_fetch_fetching` is ported and the stub is
gone. Fetches now run end to end over p2s's ReadableStream stand-in: about:blank, data:, file: and resource:
(through the ResourceLoader), http(s): (the in-process client), with CORS, preflights, redirects, CSP, Mixed Content,
integrity metadata and the blocking checks; blob: stops in FileAPI (phase 3).

To get there the region also ports what Fetching reaches outside every region: `MixedContent/AbstractOperations`,
`Animations/AnimationTimeline` and `DocumentTimeline` (a restyle reads the document timeline), the part of
`LibHTTP/Cache/MemoryCache` that runs with the cache off, and two stand-ins in the spirit of DESIGN §3.6 (JS::Error
and TransformStream).

## Fragments

| Fragment | Donor |
| --- | --- |
| `fetch/fetching/checks` | `Checks.cpp` 1-85 |
| `fetch/fetching/fetched_data_receiver` | `FetchedDataReceiver.cpp` 1-159 with `FetchedDataReceiver.h` |
| `fetch/fetching/fetching_1` | `Fetching.cpp` 75-381: HTTPCache, the cache partition, select/store in the cache, fetch, populate request from client |
| `fetch/fetching/fetching_2` | `Fetching.cpp` 383-725: main fetch |
| `fetch/fetching/fetching_3` | `Fetching.cpp` 727-930: determine the environment, fetch response handover |
| `fetch/fetching/fetching_4` | `Fetching.cpp` 932-1193: scheme fetch |
| `fetch/fetching/fetching_5` | `Fetching.cpp` 1195-1557: HTTP fetch, HTTP-redirect fetch |
| `fetch/fetching/fetching_6` | `Fetching.cpp` 1559-2070: HTTP-network-or-cache fetch |
| `fetch/fetching/fetching_7` | `Fetching.cpp` 2072-2545: the debug log, the network fetch, CORS-preflight fetch, Sec-Fetch-*, the cache switch |
| `fetch/fetching/pending_response` | `PendingResponse.cpp` 1-70 with `PendingResponse.h`, `RefCountedFlag.cpp` with `RefCountedFlag.h` |
| `mixed_content/abstract_operations` (+ `types_abstract_operations`, new) | `MixedContent/AbstractOperations.cpp` 1-121 |
| `external/lib_http/memory_cache` (+ `types_memory_cache`, filled) | `LibHTTP/Cache/MemoryCache.cpp`, partly (below) |
| `external/lib_js/error` (+ `types_error`, new) | the Error stand-in: `LibJS/Runtime/Error.cpp` 16-31, 68-102 |
| `streams/transform_stream` (+ `types_transform_stream`, new) | the TransformStream stand-in (below) |
| `animations/animation_timeline`, `document_timeline` (+ their types, filled) | `AnimationTimeline.cpp` 1-93, `DocumentTimeline.cpp` 1-94 with their headers |
| `fetch/fetching/tests_fetching_cases`, `tests_fetching_1`, `_2`, `_3` | tests (below) |

## What other regions must know

### Signatures and types changed

- `fetch_fetching_fetch(realm, request, algorithms, use_parallel_queue = FetchUseParallelQueue.no)`: C++'s default
  parameter. r28's `fetch_fetching_fetch_use_parallel_queue` stays as the `.yes` shorthand.
- `file_api_obtain_a_blob_object(entry, environment) -> web_url.BlobUrlEntryObject?` as C++ (`Optional<URL::BlobURLEntry::Object>`);
  the r27 stub answered FileAPI's Blob/MediaSource variant. `FileApiEnvironmentOrTopLevelSelfFetch` has C++'s third
  case, `top_level_navigation`. `html_media_element_4` matches the URL variant's cases now.
- `FetchNetworkPartitionKeyTraits` (generated, trapping) hashes and compares as `Traits<NetworkPartitionKey>`.
- `fetch_fetching_document_accept_header_value` and `fetch_fetching_keepalive_maximum_size` (types_fetching's
  uninitialized `var`s) are `let`s with C++'s values.
- Filled types: `HttpMemoryCache` (+ `HttpMemoryCacheEntry`), `AnimationsAnimationTimeline` (+ its vtable with the
  `update_current_time`, `duration`, `is_inactive` and `is_progress_based` dispatchers), `AnimationsDocumentTimeline`.
- Closure stubs removed (ported): `js_type_error_create`, `animations_document_timeline_create`,
  `animations_animation_timeline_current_time`, `_update_current_time` (a dispatcher now), `_associated_animations`.
- Closure stubs added (section "Region p2c"): `resource_timing_performance_resource_timing_mark_resource_timing` (P4:
  fetch response handover's report timing steps for an http(s) fetch with an initiator type),
  `fetch_safely_extract_body_blob` (P3: a redirect or a 401 retry of a request whose body's source is a Blob),
  `file_api_blob_size`, `file_api_blob_slice` (P3: scheme fetch's blob steps).

### The stand-ins (DESIGN §3.6)

- **JS::Error.** `js_type_error_create(realm, message) -> JsValue` (its signature kept, so phase 3's real errors replace
  it) makes a `JsError` cell of the realm whose class is `TypeError`, with its message (`Error::set_message`'s
  property) on the cell; `js_error_create`, `js_error_create_message`, `js_error_name`, `js_error_message`,
  `is_js_error`, `is_js_type_error`. A failed load errors its body's stream with one (`Load failed: ...`), so network
  errors no longer trap. Stack traces, `cause` and the other native errors are phase 3.
- **TransformStream.** Fetch response handover pipes every response body through an identity TransformStream whose
  flush algorithm is processResponseEndOfBody. Ladybird's TransformStream has a WritableStream side and
  `piped_through` runs ReadableStreamPipeTo (phase 4); the stand-in keeps `set_up`'s shape (the transform, flush and
  cancel algorithms on a `TransformStreamDefaultController`) and replaces the writable side and the pipe by a read
  loop over the source (`StreamsPipeThroughReadRequest`): each chunk runs the transform algorithm, the source's end
  runs the flush algorithm and closes the readable side, an error errors it. The readable side is a readable byte
  stream (the stand-in's streams carry Uint8Arrays; C++'s is a default stream, whose controller is phase 4).
  Backpressure, the writable side's queue, aborting and canceling through the pipe and its AbortSignal are not
  modelled. C++ closes the readable side in a promise reaction after flushing; the stand-in closes it right after.

### Memory (DESIGN §3.3 rule 7)

`HTTPCache::the()` is a module global: its map, its keys (a network partition key's origin strings are copied) and the
`HTTP::MemoryCache`s live in the C heap (`fetch_http_cache_get` and `clear_cache` run under `with memory.heap` with
ak's atomic allocator unset). The memory cache is off unless `set_http_memory_cache_enabled(true)` (WebContent's
option): its lookup and storage (`open_entry`, `create_entry`) need `LibHTTP/Cache/Utilities` (cacheability, freshness,
age, SHA-1 cache and vary keys, HTTP dates), which is not ported, and trap; with no entry ever created,
`finalize_entry` (run after every HTTP body when the request has a cache partition) has nothing to finalize. Enabling
the cache and then loading over HTTP traps in `create_entry`.

### Behaviour worth knowing

- Every fetch runs in the event loop as C++ does: main fetch's "in parallel" is a deferred invocation, each
  PendingResponse callback another, and the algorithms run as fetch tasks on the task destination (the networking
  task source of the client's global, or a parallel queue).
- `fetch` VERIFYs (step 10) that an HTTP(S) GET request of a Window client has the client's origin.
- A response of the network fetch keeps C++'s quirks: on_headers_received ignores a second call (trailers); the
  status defaults to 200; a load failure resolves a network error `Load failed: <message>` and errors the stream with
  a TypeError.
- about: URLs other than about:blank go to the ResourceLoader, whose about pages are resources the repository does not
  carry (p2d's note: its MUST traps).
- `MixedContent::does_settings_prohibit_mixed_security_contexts` dereferences the request's client as C++ does: main
  fetch of a request without a client traps there (C++ crashes).
- `Layout/input/object-fallback.html` loads `https://ladybird.org/does-not-exist.html` over the real network (the
  donor's test needs it), and then stops in `mark_resource_timing`.

## Tests

- `tests_fetching_cases` + `tests_fetching_1`: 507 cases pinned to the reference build by p2b's oracle, extended
  (`luce-browser-tools/oracles/luce-browser-engine/fetch_http`: `oracle.cpp`'s `run_p2c`, `cases_p2c.txt`,
  `expected_p2c.txt`, `gen_luce_cases.py p2c`): the CORS check (credentials modes, request origins, every
  Access-Control-Allow-Origin/-Credentials combination), the TAO check (failed flag, modes, origins, taintings,
  Timing-Allow-Origin lists) and the Fetch metadata headers (Sec-Fetch-Dest/-Mode/-Site/-User for URL lists of same
  origin, same site and cross site, untrustworthy URLs, navigations with and without user activation). Then
  PendingResponse (callback before or after the response, a later turn, the request's list), RefCountedFlag, HTTPCache
  (keys' traits, one cache per key, kept keys through a collection, the cache off, clearing), Mixed Content for a
  non-Window settings object and IP hosts, the TypeError stand-in, the TransformStream stand-in (chunks before and
  after the pipe, flush and close, error), and what pending responses, fetched data receivers and transform streams
  keep alive through a collection.
- `tests_fetching_2`: fetches from a test page's about:blank document through the ResourceLoader and the in-process
  client: data: (basic responses, the default `Accept` per destination, `Accept-Language`, a data: URL that does not
  process), about:blank, an unknown scheme, file: subresources (opaque from the opaque-origin page, their bytes, a
  missing file's `Load failed` network error, file: without a destination blocked, same-origin and cors modes refused),
  a terminated fetch, a bad port, local-URLs-only, no-cors with redirect mode manual, integrity metadata matching and
  not, and a request the client's CSP blocks.
- `tests_fetching_3`: HTTP on a loopback server (routes per method and path, every request head recorded): a no-cors
  image (opaque response, the internal response's bytes, the head's Accept, Accept-Language, Sec-Fetch-* and
  User-Agent), a CORS response exposing safelisted and exposed headers only (Origin: null), a failed CORS check, a 404,
  the cache partitions, a refused connection; the CORS-preflight fetch (OPTIONS with Access-Control-Request-Method and
  -Headers, then the PUT) and a preflight that refuses the method; redirects followed (URL list, redirect count), in
  error mode, and to data:.

`luce-base test src/web`: 659 passed (645 before; 14 new).

## web_test

| Suite | Before | After |
| --- | --- | --- |
| Layout | 864 / 922 | 909 / 922 |
| Ref | 609 / 820 | 694 / 820 |
| Crash | 41 / 52 | 44 / 52 |
| Screenshot | 30 / 67 | 32 / 67 |

The expected-failures lists are rewritten (`--update-failures`). Where the tests that stopped at
`Fetch::Fetching::fetch` stop now:

- SVG as an image (`<img src=*.svg>`, CSS backgrounds, `image-set`, 30 tests): `SVGDecodedImageData` makes its page,
  whose window stops in `MessagePort::for_each_message_port` (P4).
- WebP images (`abspos-box-with-replaced-element`): the codec plugin does not decode WebP yet (p2img).
- WOFF2 fonts: a Brotli decoder (`counter-ethiopic-numeric`); a FontFace promise rejection: PromiseRejectionEvent (P3);
  iframes: `History::create` (P3).
- 7 Ref and 8 Screenshot tests now render and differ (image sampling and scaling, backgrounds, filters): to be
  investigated in the painting and raster regions.

Restyles: an image or style sheet that arrives after the first rendering restyles its element, and
`StyleComputer::start_needed_transitions` reads the document timeline (`Document::timeline()`), which trapped in the
P4 DocumentTimeline stub. Whether a test restyled depended on how fast its resources loaded against the frame timer,
so a dozen tests flipped between pass and trap from run to run. Porting AnimationTimeline and DocumentTimeline makes
them pass every time.

## Deviations and notes

- Each lambda is a capture struct with a static function (DESIGN §2.7). fetch response handover's
  `setup_report_timing_steps`, processResponseEndOfBody, its task and processBodyError share one capture struct
  (`FetchFetchingFetchResponseHandover`); the report timing steps keep their own mutable copy of the timing info, as
  the C++ `mutable` lambda.
- Main fetch's step 10 (`... && false`) and HTTP fetch's cross-origin resource policy check (`&& false`) are comments:
  the conditions cannot hold and read nothing with an effect. HTTP fetch's service-worker block is ported though its
  `response` is always null, as in C++.
- HTTP-network-or-cache fetch's ScopeGuard (`aborted` set when step 8's block ends) is the check after the block; the
  block's only early return (the keepalive limit) returns before it, as the guard's effect is then unused.
- HTTPCache::get looks the key up before inserting (`ensure` with a C-heap copy of the key).
- The `TRY_OR_IGNORE(String::formatted(...))` messages of the CORS-preflight fetch are built and validated
  (`fetch_fetching_preflight_message`); a message that is not valid UTF-8 returns without resolving, as C++.
- `AnimationTimeline::associated_animations` answers the live animations of the weak set as a Vector (the closure
  stub's signature), looping over the set with `gc.weak_hash_set_begin` (public since foundation e0d0c05, region p2r).
- luce-std 0.5.0's HTTP parser refused a `204` response with `Content-Length: 0`, which servers do send; luce-std
  0.5.1 (pinned since region p2r) reads such a response as bodiless, and the tests' 204s carry `Content-Length: 0`.
- HANDOFF.md §5 item 4's engine follow-ups were done by earlier regions; none concerns this region.

## Compiler issues

None found.
