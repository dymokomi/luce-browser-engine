# Region p2r: the rest of phase 2 without rendering — what other regions need to know

Region p2r takes the stops left after p2c that are not painting: web_test no longer reaches the network, SVG
documents used as images load and render through `SVGDecodedImageData`'s page (Ladybird's own engine, not
luce-svg, DESIGN §7.0), iframes load their documents with scripting off, and a font promise's rejection fires
`unhandledrejection`. It is new work over existing types (no stub fragment): each piece ports what the path needs of
a class that was opaque or stubbed, and keeps the rest (JS-facing APIs, messaging) trapping in its phase.

Plus three follow-ups: foundation's `gc.WeakHashSetValues` iterator is public (foundation `e0d0c05`, branch
`port/p2r`), luce-std is pinned at 0.5.1 (`647af31`), and the stream test helpers compare lengths.

## Fragments

| Fragment | Donor |
| --- | --- |
| `html/message_port` (+ `types_message_port`, new) | `MessagePort.cpp` 33-89, 172-188 with `MessagePort.h` 41 |
| `file_api/blob_url_store` (+ `types_blob_url_store`, new) | `BlobURLStore.cpp` 21-25, 130-143 with `BlobURLStore.h` 18-27 |
| `html/window_or_worker_global_scope` (extended) | `WindowOrWorkerGlobalScope.cpp` 1064-1102 |
| `html/history` (+ `types_history`, filled) | `History.cpp` 22-46, 82-85, 130-170 with `History.h` 37-41 |
| `html/navigation` (+ `types_navigation`, filled) | `Navigation.cpp` 68-96, 113-126, 451-499, 1428-1458 with `Navigation.h` 132-137 |
| `html/navigation_history_entry` (+ `types_navigation_history_entry`, new) | `NavigationHistoryEntry.cpp` 24-40 with `.h` 32 |
| `html/structured_serialize` (new) | `StructuredSerialize.cpp` 1248-1280 (serialize for storage, deserialize) for undefined and null |
| `html/before_unload_event` (+ `types_before_unload_event`, new) | `BeforeUnloadEvent.cpp` 1-35 with `.h` |
| `html/promise_rejection_event` (+ `types_promise_rejection_event`, new) | `PromiseRejectionEvent.cpp` 1-48 with `.h` |
| `html/universal_global_scope`, `bindings/main_thread_vm_host_hooks` (completed) | `UniversalGlobalScope.cpp` notify_about_rejected_promises' task, `MainThreadVM.cpp` 186-199 |
| `html/scripting/exception_reporter` (completed) | `ExceptionReporter.cpp` 38-50: a DOMException's error data |
| `dom/event_target_2` (completed) | `EventTarget.cpp` 698-709: a BeforeUnloadEvent's return value |
| `tests/web_test/worker_network` (new, not a port) | the hermetic RequestClient |
| `html/tests_message_port`, `tests_history`, `tests_promise_rejection_event` | tests (below) |

## What other regions must know

### web_test is hermetic

`worker_install_loading` installs `HermeticRequestClient` over the in-process client: file:, data:, about:,
resource:, blob: and every non-HTTP scheme, and http(s) on a loopback host (`localhost` and names under it,
127.0.0.0/8, `::1`) go to `InProcessRequestClient`; any other request finishes on the next turn of the event loop
with `UnableToResolveHost` and no headers, as an offline RequestServer's does (a refused request can still be
stopped). `Layout/input/object-fallback.html` (it names https://ladybird.org) thus gets a network error, whose
fallback Ladybird renders offline; ours stops, as before with the network, in fetch response handover's report
timing steps: `ResourceTiming::PerformanceResourceTiming::mark_resource_timing` (P4), now deterministically.

`Core::EventLoop` has `core_event_loop_uninstall()` so that tests can install one loop each.

### Destroying a document

`Document::destroy` (SVGDecodedImageData's page replaces its initial about:blank; navigations replace documents)
walks:

- **MessagePort's registry.** `HtmlMessagePort` is declared (EventTarget's class id, its ClassInfo). Every port
  joins `all_message_ports` (a module-global `gc.WeakHashSet`, its table in the C heap, DESIGN §3.3 rule 7) in its
  constructor and leaves it in `finalize`; `for_each_message_port` visits the live ports from a copy, and
  `disentangle` unpairs a port and its remote port. The transport (`IPC::Transport`) and the message queues are
  phase 4: `m_transport` is always none (disentangling a port that has one traps), and nothing makes a port before
  MessageChannel/BroadcastChannel/workers.
- **FileAPI's blob URL store** (`file_api_blob_url_store()`, a module global in the C heap, entries holding
  `gc.Root`s as C++'s `GC::Root`s) and `run_unloading_cleanup_steps`, which takes the entries of the document's
  environment out and releases their roots. Adding, resolving and revoking blob URLs stay phase 3.
- **The window's registries**: `forcibly_close_all_event_sources`, `close_all_idb_connections` (no database exists
  before IndexedDB) and `make_disappear_all_web_sockets` are ported; `EventSource::forcibly_close` and
  `WebSocket::make_disappear` are new P4 closure stubs (the registries are empty before phase 4).

### Session history with scripting off

- **History** (`HtmlHistory`, PlatformObject's class id): create, state (`unsafe_state`, `set_state`), index and length
  (`html_history_index`/`_set_index`/`_length`/`_set_length`, `usize` as the stubs had; the fields are C++'s `u64`),
  `can_have_its_url_rewritten`. pushState/replaceState/go/back/forward/length/state/scrollRestoration are P3.
- **Navigation** (`HtmlNavigation`, EventTarget's class id) keeps its entry list: `has_entries_and_events_disabled`,
  `get_the_navigation_api_entry_index`, `current_entry`, `initialize_the_navigation_api_entries_for_a_new_document`
  and the inline accessors. Its transition and API method trackers are phase-3 classes held as `gc.Cell*?` (always
  none). The navigate event, `abort_the_ongoing_navigation`, `fire_a_traverse_navigate_event`,
  `fire_a_push_replace_reload_navigate_event` and the same-document update stay P3 stubs.
- **NavigationHistoryEntry** (create, session_history_entry); its JS getters are P3.
- **StructuredSerialize**: `html_structured_serialize_for_storage` moved here from the closure stubs;
  `html_structured_deserialize` reads the one-byte records of undefined and null (in a TemporaryExecutionContext of
  the target realm, as C++); any other record traps (P3).
- **BeforeUnloadEvent** (Event's class id): `html_before_unload_event_create(realm, name, init = {})` answers the
  `HtmlBeforeUnloadEvent*` as C++ (the stub answered the `DomEvent*`; its two callers take `.dom_event()`). The
  event-handler processing algorithm sets its return value (through `js_value_to_string`, P3).

### Promise rejections

`HtmlPromiseRejectionEvent` (Event's class id) with `HtmlPromiseRejectionEventInit` (`html_promise_rejection_event_init_default()`
is C++'s `{}`: undefined reason). notify_about_rejected_promises' task fires a cancelable `unhandledrejection` at the
global, adds a still-unhandled promise to the outstanding rejected promises weak set and reports a rejection nobody
canceled to the console; HostPromiseRejectionTracker's task fires `rejectionhandled` at the window.
`report_exception_to_console` follows a DOMException's error data (it is its own ErrorData): an empty stack line
(no script frames before phase 3), and no console client to report to; a JS object other than a DOMException or a
primitive still traps (P3).

### Signatures and types changed

- `html_before_unload_event_create` answers `HtmlBeforeUnloadEvent*` and takes an optional `DomEventInit`.
- Filled or new types: `HtmlMessagePort`, `FileApiBlobUrlEntry` (+ `FileApiBlobUrlEntryObject`, `FileApiBlobUrlStore`),
  `HtmlHistory`, `HtmlNavigation`, `HtmlNavigationHistoryEntry`, `HtmlBeforeUnloadEvent`, `HtmlPromiseRejectionEvent`
  (+ init).
- Closure stubs removed (ported): MessagePort's two, `file_api_run_unloading_cleanup_steps`, the three
  WindowOrWorkerGlobalScope functions, `html_history_create` and its six accessors, `realm_create_html_navigation`,
  the Navigation accessors and `initialize_the_navigation_api_entries_for_a_new_document`, `html_structured_deserialize`,
  `html_structured_serialize_for_storage` (moved), `html_before_unload_event_create`; the private
  `dom_event_target_is_before_unload_event` is `is_html_before_unload_event`.
- Closure stubs added (section "Region p2r"): `html_event_source_forcibly_close`, `web_sockets_web_socket_make_disappear` (P4).
- `core_event_loop_uninstall` (new, external/lib_core/event_loop).
- foundation: `gc.WeakHashSetValues.iterator` and `WeakHashSetIterator.next` are `pub` (foundation `e0d0c05` on its
  `port/p2r`; the engine's `bootstrap/PACKAGES` pins it, so foundation's branch lands first).
  `AnimationTimeline::associated_animations` loops with `gc.weak_hash_set_begin`.
- luce-std `^0.5.1` (`647af31`): a 204 with `Content-Length: 0` is bodiless; p2c's CORS-preflight test server sends it again.

## Tests

- `html/tests_message_port`: the registry (a port joins, for_each visits it, an unreferenced port is collected and
  leaves), disentangle, the blob URL store's cleanup (entries of the document's environment removed, others kept,
  roots released), and `Document::destroy` on a browsing context's document (its window's entangled ports are
  disentangled, those of a realm whose global is not a window are not; the window's registries are empty).
- `html/tests_history`: History's defaults and setters and `Document::history`; `can_have_its_url_rewritten` for
  http(s), credentials, ports, file: paths and other schemes (C++'s conditions); Navigation on the initial
  about:blank (disabled, the AD-HOC flag reset), an opaque origin, then a tuple origin (one NavigationHistoryEntry
  per SHE, the current entry the initial SHE's, kept through a collection); BeforeUnloadEvent; serializing and
  deserializing undefined and null.
- `html/tests_promise_rejection_event`: create; notify about rejected promises at a window: a canceled
  unhandledrejection (the promise stays outstanding), a promise handled before the task (skipped), a DOMException
  rejection nobody cancels (reported).
- `tests/web_test`: the hermetic client (which URLs are local; a refused request fails on the event loop with
  UnableToResolveHost; a local one is served; a refused one can be stopped).
- The p2s stream helpers (`test_streams_log_is`, `test_streams_bytes_are`, `fetch_test_body_log_is` and two asserts)
  compare lengths too (`test_streams_span_is`).

`luce-base test src/web`: 670 passed (659 before; 11 new). `luce-base test tests/web_test`: 12 passed (1 new).

## web_test

| Suite | Before | After |
| --- | --- | --- |
| Layout | 909 / 922 | 917 / 922 |
| Ref | 694 / 820 | 717 / 820 |
| Crash | 44 / 52 | 46 / 52 |
| Screenshot | 32 / 67 | 34 / 67 |

The 29 SVG-as-image tests and the 6 iframe Ref tests pass; the expected-failures lists are rewritten. Now running to
the end and differing (painting, not chased here): `Screenshot/input/can-load-images-in-sandboxed-iframe-with-no-scripting.html`
and `css-background-repeat.html` (the page overflows the viewport and we paint the top-level scrollbar, Ladybird's
screenshots have none; css-background-repeat also differs in its tiles' pixels), and `Ref/input/css/font-weight-range.html`:
it loads `../../../../../Base/res/fonts/SerenitySans-Regular.ttf`, which in Ladybird's tree is the repository's
`Base/res/fonts` and is missing from our copy, so two of its three faces fail and Ahem is matched for every
weight; with the file copied there (from the pinned donor) the test passes locally. That is for the test-data copy
(the lead's).

Still stopping: `JS::Array::create_from` (P3, 17 font-variant-alternates tests), `CSS::EasingFunction::from_style_value`
(P4, 8), `AudioTrackList` (P4, 5), `mark_resource_timing` (P4, object-fallback), PDF documents, WOFF2 (Brotli),
WebP (`abspos-box-with-replaced-element`).

## Deviations and notes

- `html_history_index`/`_length` and their setters keep the stubs' `usize` over C++'s `u64` fields (the callers'
  type; a cast at the boundary).
- `can_have_its_url_rewritten`'s single condition of step 2 is checked in three `if`s (the formatter would put it on
  one 300-column line); same result.
- MessagePort's pending message vectors are left out of the struct (their element type, SerializedTransferRecord, is
  phase 4); `disentangle` notes their clearing.
- A refused request of the hermetic client is told from the in-process client's own by its state's first field (the
  hermetic client), since both keep their state in `RequestsRequest.m_client_data`.
- HANDOFF.md §5 item 4's engine follow-ups were done by earlier regions (checked: the CSS invalid-rule reporter, the
  tokenizer's parser hook); none concerns this region.

## Compiler issues

None found.
