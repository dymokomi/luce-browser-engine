# Region p2b: fetch_http — what other regions need to know

Region p2b ports LibHTTP's `HTTP`, `Header`, `HeaderList`, `Method` and `Status`, and LibWeb's
`Fetch/Infrastructure/HTTP/*` (`Bodies`, `CORS`, `MIME`, `Requests`, `Responses`, `Statuses`): header names and
values, header lists, methods, statuses, the HTTP-level steps of requests and responses (filtered responses
included), CORS-safelisting and MIME type extraction. Every function of the three `stubs/stub_p2b_fetch_http_*`
fragments is ported and the stubs are gone. It is the first phase-2 region; p2a, p2c, p2d and p2e build on it.

## Fragments

| Fragment | Donor |
| --- | --- |
| `external/lib_http/http` | `LibHTTP/HTTP.h` 32-76, `HTTP.cpp` (r13's quoted string, extended) |
| `external/lib_http/types_http` | `HTTP.h` 18-30: the constants, filled by hand (below) |
| `external/lib_http/header` | `Header.cpp` 21-349 with `Header.h` (the IPC encoder/decoder are not ported) |
| `external/lib_http/header_list` | `HeaderList.cpp` 16-354 with `HeaderList.h` (r28's create/contains/get/append, extended) |
| `external/lib_http/method`, `status` | `Method.cpp`, `Status.h` |
| `fetch/infrastructure/http/bodies` | `Bodies.cpp` 20-217 with `Bodies.h` 48-51 |
| `fetch/infrastructure/http/cors`, `mime`, `statuses` | `CORS.cpp`, `MIME.cpp` (with `legacy_extract_an_encoding`, a closure stub until now), `Statuses.cpp` (with `is_ok_status`, likewise) |
| `fetch/infrastructure/http/requests_1` | `Requests.cpp` 21-374 and `Requests.h`'s pending-response members |
| `fetch/infrastructure/http/requests_2` | `Requests.h` 168-287 (the accessors), `Requests.cpp` 377-573 (destination, mode, initiator-type and priority strings) |
| `fetch/infrastructure/http/responses_1` | `Responses.cpp` 22-222 with `Response`'s members in `Responses.h` (r28's `responses`, replaced) |
| `fetch/infrastructure/http/responses_2` | `Responses.cpp` 224-312 with the overrides of `FilteredResponse` and its four kinds |
| `fetch/infrastructure/http/tests_fetch_http_cases`, `tests_fetch_http_1`, `tests_fetch_http_2` | tests (below) |

## What other regions must know

### Signatures changed from the stubs (callers updated)

- `http_header_list_append(list, header: HttpHeader)`, as C++ (`Header`); r28 had `(list, name, value)`. C++'s
  `append({ "Range"sv, value })` is `http_header_list_append(list, http_header_create(ak.sv("Range"), value))`:
  `http_header_create(name, value)` is `HTTP::Header { name, value }` (ByteString's constructor from a view).
  `http_header_list_create(headers = ak.Vector[HttpHeader]())` takes C++'s optional headers.
- `http_header_list_extract_header_list_values` returns `EmptyOrVectorOrHttpHeaderListExtractHeaderParseFailure`,
  `http_header_list_extract_length` `EmptyOrU64OrHttpHeaderListExtractLengthFailure` and
  `http_header_list_extract_content_range_values`
  `HttpHeaderListContentRangeValuesOrHttpHeaderListExtractContentRangeFailure` (the generated variants of the C++
  results); the stubs collapsed "null" and "failure" into an optional, which the CORS preflight (p2c) must tell
  apart. `html_media_element_4` matches on them now.
- `HeaderList.h`'s templates take an `ak.Function1`: `http_header_list_delete_all_matching(list, Function1[const
  HttpHeader*, bool])`, `http_header_list_for_each_header_value(list, name, Function1[StringView,
  IterationDecision])`, `http_header_list_for_each_vary_header(list, Function1[StringView, IterationDecision])`.
- `fetch_body_fully_read` and `fetch_body_incrementally_read` take the C++ `FetchTaskDestination` (r28's stubs took a
  `JsObject*`): callers pass `.js_object(global)`; fetching passes its fetch params' task destination, which may be
  a parallel queue.
- `fetch_request_set_method` takes a `ByteString`, `fetch_request_set_body` a `FetchRequestBodyType`,
  `fetch_request_set_origin` a `FetchRequestOriginType`, `fetch_request_set_policy_container` a
  `FetchRequestPolicyContainerType` (`.byte_buffer(...)`, `.origin(...)`, `.html_policy_container(...)`), as C++.
- `fetch_extract_mime_type` takes `const HttpHeaderList*`; HeaderList's const members take `const HttpHeaderList*`.
- Response's virtual accessors are dispatchers now: r28's non-virtual `fetch_response_url_list`, `status`,
  `header_list`, `body`, `set_body` and `set_url_list` (which a filtered response bypassed) go through
  `FetchResponseVTable`, with the bodies in `fetch_response_*_impl`.
- `fetch_filtered_response_internal_response(response: FetchResponse*)` keeps its stub signature and verifies the
  cast (`as<FilteredResponse>(*response).internal_response()`).
- `tests/web_test/worker_load.lucb` (one line) appends its `Content-Type` header with `http_header_create`.

### Constants

`types_http` declared `HTTP_TAB_OR_SPACE` and `HTTP_WHITESPACE` as uninitialized `ak.StringView` variables. They
are `pub let http_http_tab_or_space: str = "\t "` and `http_http_whitespace: str = "\n\r\t "` now (the namemap's
names), and the two byte arrays are initialized `u32[2]` lets. r13's `http_whitespace` is gone; `mime_type` uses
`http_http_whitespace`.

### Zeroed cells and AK strings

A cell is zeroed when it is allocated, and C++ default-constructs its members. Two AK types differ from their
default when zeroed: a `ByteString` (its impl pointer may not be null) and a `String` (a zeroed String is not
equal to `String {}`: `string_equals` compares the short-string bits). The constructors set them: a response's
status message and method, an opaque filtered response's method, a response's `BodyInfo` (its content type is
compared by `is_network_error`), a request's replaces-client id and integrity and nonce metadata. Ports of other
cells holding these types should do the same.

### Streams and BodyInit (closure stubs)

A body's stream is a `Streams::ReadableStream`, opaque until phase 4. What `Body` asks of it is a closure stub in
`stub_closure` ("Streams and BodyInit"): `streams_readable_stream_tee`, `_get_a_reader`, `_realm`,
`streams_readable_stream_default_reader_read_all_bytes`, `_read_a_chunk`, `_realm` (P4), and
`fetch_safely_extract_body_bytes` (Fetch/BodyInit's `safely_extract_body` of a byte sequence, P3). So
`fetch_body_fully_read`, `incrementally_read`, `clone` and `fetch_byte_sequence_as_body` (srcdoc iframes) still trap
there; reading bodies needs a minimal ReadableStream (or the byte-source path) before images and style sheets load.
`Body::visit_edges` visits the stream and a Blob source through a cell cast, as r28 did for the opaque body.

### Allocation

`Request::create`, `Response::create`, `Body::create` and the filtered responses' `create` allocate as
`vm.heap().allocate<T>(...)` does (no `initialize(realm)`): `web_heap_allocate_cell`, DeferGC around the
constructor.

## Tests

- `tests_fetch_http_1`: `Tests/LibHTTP/TestHTTPUtils.cpp`'s tests of the ported files (collect an HTTP quoted
  string, token validation, extract header values; its Cache-Control tests are of LibHTTP/Cache, not ported), and
  the runner of `tests_fetch_http_cases`: 334 cases pinned to the reference build by a local oracle
  (`luce-browser-tools/oracles/luce-browser-engine/fetch_http`: `oracle.cpp`, `cases.txt`, `build.sh`,
  `gen_luce_cases.py`, which writes the case table from `expected.txt`). They cover header names and values,
  normalizing, forbidden request and response headers, getting/decoding/splitting, extracting header values,
  sorted-lowercase sets, content ranges and range header values, methods and their normalization, every token code
  point, reason phrases, header lists (append, set, combine, delete, get, sort-and-combine, extract values, length,
  content range, unique names, Vary), MIME type extraction (charset carried and released) and the legacy encoding,
  CORS-safelisted and unsafe headers (every byte), safelisted response header names, the statuses, a request's
  redirect-taint, serialized origin and Origin header, the Range header, destinations, modes, initiator types,
  priorities, filtered responses, network errors and the location URL. `Tests/LibWeb/TestFetchURL.cpp` tests
  `Fetch/Infrastructure/URL` (region p2a).
- `tests_fetch_http_2`: what the oracle does not reach: a new request's and response's defaults, URLs and URL lists,
  clone's copies (header list, URL list, members; a filtered response's kind and cloned internal response), filtered
  responses forwarding setters, the HeaderList templates, a body's sniff bytes (byte source, streaming, completion,
  the waiting callback), and a collection keeping a request's body, a response's body and a filtered response's
  internal response.

`luce-base test src/web`: 568 passed (15 new).

## web_test

The pass counts do not change (Layout 855 of 922, Ref 471 of 820, Crash 38 of 52, Screenshot 30 of 67, as on main
before the port); the expected-failures lists were rewritten for their notes only. The 45 tests that stopped at
`Request::create` (CSS `url()` resources) now stop at `FetchAlgorithms::create` (p2a), and the 20 at
`request_priority_from_string` (`<link rel=stylesheet>`) at `create_potential_CORS_request` (p2d).

## Deviations and notes

- `HeaderList::set` removes the later matching headers with a loop rather than `remove_all_matching` and an index
  counter; the result is the same.
- `for_each_vary_header`'s inner `IterationDecision result;` is uninitialized in C++ when a `Vary` value has no
  part; it is `continue_` here.
- `Body::fully_read`'s success and error steps share one capture struct (`FetchBodyFullyReadSteps`).
- `normalize_method`'s static `ByteString` array is a `str[6]`; the normalized method is made from the literal.
- `WEB_FETCH_DEBUG` (AK/Debug.h, off) is `fetch_web_fetch_debug`.
- HANDOFF.md §5 item 4's engine follow-ups were already done by earlier regions (the CSS/Serialize stubs, the
  invalid-rule reporter, the tokenizer hook); none concerns this region.
