# Region p2a: fetch_infrastructure — what other regions need to know

Region p2a ports LibWeb's `Fetch/Infrastructure` outside `HTTP/` (FetchAlgorithms, FetchController and
FetchControllerHolder, FetchParams, FetchRecord, FetchTimingInfo and ConnectionTimingInfo, HTTP's default
`User-Agent`, IncrementalReadLoopReadRequest, the MIME type, nosniff and bad-port blocking checks, the network
partition key, queueing fetch tasks, and the data: URL processor of `URL`), `ReferrerPolicy/*` and
`SecureContexts/*`. Every function of `stubs/stub_p2a_fetch_infrastructure` is ported and the stub is gone.

## Fragments

| Fragment | Donor |
| --- | --- |
| `fetch/infrastructure/fetch_algorithms` | `FetchAlgorithms.cpp` 15-57 with `FetchAlgorithms.h` 52-57 |
| `fetch/infrastructure/fetch_controller` | `FetchController.cpp` 19-197 with `FetchController.h` 41-62, 111-112 (FetchControllerHolder too) |
| `fetch/infrastructure/fetch_params` | `FetchParams.cpp` 16-73 with `FetchParams.h` 34-51 |
| `fetch/infrastructure/fetch_record` | `FetchRecord.cpp` 14-46 with `FetchRecord.h` 25-29 |
| `fetch/infrastructure/fetch_timing_info` | `FetchTimingInfo.cpp` 17-73 with `FetchTimingInfo.h` 31-66 |
| `fetch/infrastructure/http` | `HTTP.cpp` (default_user_agent_value) |
| `fetch/infrastructure/incremental_read_loop_read_request` | `IncrementalReadLoopReadRequest.cpp` 15-85 |
| `fetch/infrastructure/mime_type_blocking`, `network_partition_key`, `no_sniff_blocking`, `port_blocking`, `task` | the `.cpp` of the same name |
| `fetch/infrastructure/url` | r28's `URL.cpp` 18-38, extended with `process_data_url` (40-112) |
| `referrer_policy/abstract_operations`, `referrer_policy/referrer_policy` | `ReferrerPolicy/AbstractOperations.cpp`, `ReferrerPolicy.cpp` (`from_string`, which r26 had ported into `stub_closure`, moved here) |
| `secure_contexts/abstract_operations` | `SecureContexts/AbstractOperations.cpp` |
| `external/lib_requests/alpn_http_version` | `LibRequests/ALPNHttpVersion.h` 23-41 (`alpn_http_version_to_fly_string`, which update_final_timings calls) |
| `fetch/infrastructure/tests_fetch_infrastructure_cases`, `_1`, `_2` | tests (below) |

## What other regions must know

### Signatures and types changed

- `fetch_algorithms_create(vm, input: FetchAlgorithmsInput)` is `FetchAlgorithms::create(vm, Input)`; the stub
  took one `process_response_consume_body` function. `FetchAlgorithmsInput` (types_fetch_algorithms, opaque
  before) holds the six `ak.Function`s, empty unless set, so `create(vm, {})` is
  `fetch_algorithms_create(vm, FetchAlgorithmsInput())` and `{ .process_response = f }` is
  `FetchAlgorithmsInput(process_response = f)`. The three callers (`css/fetch`, `svg/svg_script_element`,
  `html/html_track_element`) pass an Input now. `fetch_algorithms_create_with_process_response` and
  `_with_process_response_consume_body` stay as shorthands.
- `FetchController.m_pending_request` is `gc.Weak[gc.Cell]` (generated `gc.Weak[RequestsRequest]`, which cannot be
  made: `Requests::Request` is opaque and not a cell). **p2d:** the controller holds the request weakly, as C++'s
  `WeakPtr<Requests::Request>`, so `fetch_controller_set_pending_request(controller, request)` needs a
  `Requests::Request` that is a cell (as the RequestClient seam's request should be); `stop_request` casts it
  back and calls `requests_request_stop`.
- `RequestsRequestTimingInfo` (types_request_timing_info, opaque before) has its fields now, with the new enum
  `RequestsAlpnHttpVersion` (`Requests::ALPNHttpVersion`); `update_final_timings` reads them. p2d fills one from
  its loads.
- `fetch_controller_set_inner_fetch_controller` traps: FetchController.h declares it, the donor defines it
  nowhere and nothing calls it.

### Closure stubs added (`stub_closure`, section "Region p2a")

- `html_structured_serialize(vm, value) -> ak.Vector[u8]!` (P3): `FetchController::abort` serializes its
  "AbortError" DOMException, so **abort traps until StructuredSerialize is ported** (it trapped as a stub
  before too). `deserialize_a_serialized_abort_reason` calls r28's `html_structured_deserialize` only when a
  reason was serialized.
- `requests_request_stop(request)` (P2, p2d's seam): `Requests::Request::stop`.
- `js_value_as_if_uint8_array_data(chunk) -> (const u8[])?` (P3): `chunk.as_if<JS::Uint8Array>()` and its data,
  for `IncrementalReadLoopReadRequest::on_chunk`.

### Behaviour worth knowing

- A FetchRecord removes itself from its list when finalized, and `IntrusiveListNode::remove` VERIFYs that it is
  in one (as C++): every record must be put in a fetch group (fetching does, Fetching.cpp:322).
- `stop_fetch` removes the controller's queued fetch tasks from the main thread event loop's task queue (the
  tasks queued through `fetch_queue_fetch_task_fetch_controller`), then replaces the fetch params' algorithms by
  empty ones; it does nothing once the controller is aborted or terminated.
- `is_origin_potentially_trustworthy`'s 127.0.0.0/8 check is the donor's `(to_u32() & 0xff000000) != 0`: a
  parsed IPv4 host keeps its first octet in the top byte, so every IPv4 host but `0.x.x.x` is "potentially
  trustworthy" (`http://1.2.3.4` and `http://10.0.0.1` included). Kept as the donor has it, pinned by the oracle.

## Tests

- `tests_fetch_infrastructure_1`: `Tests/LibWeb/TestFetchURL.cpp` (its 8 data: URL tests), and the runner of
  `tests_fetch_infrastructure_cases`: 908 cases pinned to the reference build by p2b's oracle, extended
  (`luce-browser-tools/oracles/luce-browser-engine/fetch_http`: `oracle.cpp`'s `run_p2a`, `cases_p2a.txt`,
  `expected_p2a.txt`, `gen_luce_cases.py p2a`). They cover data: URLs (40, base64 and MIME edge cases), every bad
  port and `block_bad_port`, `determine_nosniff`, MIME type and nosniff blocking for 17 destinations, referrer
  policy strings, the `Referrer-Policy` header and the policy on redirect, stripping URLs, determining the
  referrer for every policy (a URL referrer), origin and URL trustworthiness (45 URLs and both opaque kinds),
  timing infos (opaque timing info, update_final_timings: doubles compared by their bits, exact on every
  platform: add, divide, floor, multiply), and a fetch controller's task ids, ongoing tasks, termination and
  the fetch params' aborted/canceled flags and copy.
- `tests_fetch_infrastructure_2`: what the oracle does not reach: fetch algorithms empty or set, report timing
  steps, the next manual redirect and full timing info, the holder, queueing fetch tasks (parallel queue, global
  object, a controller tracking its tasks), `stop_fetch`, fetch params' defaults/setters/copy, fetch records
  leaving their fetch group when collected, network partition keys, a non-Window client's referrer, the
  incrementally-read loop's close and error steps, and what each cell keeps alive through collections (the
  pending request only weakly).

`luce-base test src/web`: 587 passed (19 new).

## web_test

The pass counts do not change (Layout 855 of 922, Ref 471 of 820, Crash 38 of 52, Screenshot 30 of 67); the
expected-failures lists were rewritten for their notes only: the 45 tests that stopped at
`FetchAlgorithms::create` (CSS `url()` resources) now stop at `Fetch::Fetching::fetch` (p2c).

## Deviations and notes

- `on_close` and `on_error` of IncrementalReadLoopReadRequest create their task's GC::Function in the read
  request's heap; C++ asks the reader for its heap (the same heap; the reader is opaque until phase 4).
- `FetchParams::FetchParams(FetchParams const&)` is `fetch_params_construct_fetch_params` (not in the stub list).
- `queue_fetch_task`'s local `html_task_id` is `task_id` (the name is a function of the module).
