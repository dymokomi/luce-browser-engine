# Phase-1 seams: JS stand-ins, heap test pages and documents, Document::create — what other regions need to know

Two seams kept phase-1 paths from running: FontFaceSet's constructor (and every `@font-face` rule) makes a
`JS::Set` and WebIDL promises, which were phase-3 traps, so `Document::create` stopped there; and the test
documents and Pages lived outside the heap, so tests deferred or faked collections. This branch fills both
(DESIGN.md §3.6, "P1 stand-ins").

## Fragments

| Fragment | Donor |
| --- | --- |
| `external/lib_js/promise` | `LibJS/Runtime/Promise.cpp/.h`, `PromiseResolvingFunction.cpp/.h`; `PromisePrototype::then` and `PromiseConstructor::construct` for `%Promise%` |
| `external/lib_js/promise_jobs` | `PromiseCapability.cpp/.h` (+ `new_promise_capability`), `PromiseReaction.cpp/.h`, `PromiseJobs.cpp/.h`, `JobCallback.cpp/.h`, `GetFunctionRealm` of native functions |
| `external/lib_js/set` | `Map.cpp/.h`, `Set.cpp/.h`, `ValueTraits.h`, `same_value` / `same_value_non_number` |
| `external/lib_js/vm` (added to) | `VM`'s promise job queue, `run_queued_promise_jobs`, `promise_rejection_tracker` and the default host hooks |
| `web_idl/promise` | `WebIDL/Promise.cpp` in full (was all P3 traps) |
| `bindings/main_thread_vm_host_hooks` | the promise host hooks of `MainThreadVM.cpp` (133-360) |
| `html/universal_global_scope` | `UniversalGlobalScope.cpp` 157-243: the rejected-promise lists and `notify_about_rejected_promises` (moved out of `stub_closure`) |
| `page/page` | `Page.cpp` 37-68: `Page::create`, `Page::Page`, `Page::visit_edges` (taken ahead of **r28**) |
| `page/tests_page`, `web_idl/tests_promise` | tests and the shared heap page/document helpers |

Types filled by hand: `types_promise` (`JsPromise`, `JsPromiseState`, `JsPromiseRejectionOperation`,
`JsPromiseResolvingFunctions`), `types_promise_capability` (`JsPromiseCapability`, and the new `JsPromiseReaction`,
`JsPromiseReactionType`, `JsJobCallback`, `JsPromiseJob`, `JsPromiseJobFunction`), `types_set` (`JsSet`),
`types_map` (`JsMap`, `JsValueTraits`), `types_vm` (`m_promise_jobs`, the five `host_*` hooks,
`on_promise_unhandled_rejection` / `on_promise_rejection_handled`). The new classes share JS::Cell's class id
(as `JsNativeFunction`) and are recognized by their `ClassInfo` (`is_js_promise`, `is_js_set`, `is_js_map`).

## What other regions must know

### Promises, sets and maps (any region)

- Use the WebIDL operations as the donor does: `idl_create_promise`, `idl_create_resolved_promise`,
  `idl_create_rejected_promise`, `idl_resolve_promise`, `idl_reject_promise`, `idl_react_to_promise`,
  `idl_upon_fulfillment`, `idl_upon_rejection`, `idl_mark_promise_as_handled`, `idl_is_promise_fulfilled`,
  `idl_wait_for_all`, `idl_get_promise_for_wait_for_all`, `idl_create_rejected_promise_from_exception`,
  `idl_reject_promise_with_exception` (signatures unchanged). Reactions run as microtasks through
  `html_queue_a_microtask` in the spec's order.
- **A current realm is needed** where LibJS needs one: `NewPromiseCapability` (every `create_*promise`,
  `react_to_promise`) reads `vm.current_realm()`, and reacting (`perform_then` → `HostMakeJobCallback`) needs
  the incumbent settings object, i.e. a `TemporaryExecutionContext` with `CallbacksEnabled::Yes`, as the donor's
  callers have.
- `JS::Set`: `js_set_create`, `js_set_set_add/_has/_remove/_size/_clear`, `js_set_values` (its keys in
  insertion order). `JS::Map`: `js_map_create`, `js_map_map_set/_get/_has/_remove/_size/_clear`,
  `js_map_entries`. Keys compare with SameValue (`js_same_value`, ported; it was a closure stub).
- `bind_platform_object_wrapper(object)` (r14) now answers `js_value_from_object(object)`, r19's phase-1 form
  of `JS::Value(Object*)` (it trapped): promises are resolved with, and sets hold, platform objects.
- `js_object_shape_realm` answers for promises, sets and maps (their shape's realm).
- Still P3 (trap): `Get(x, "then")` of anything but these promises is undefined; self-resolution's TypeError;
  `JS::Array::create_from` (so `FontFaceSet::load` and `get_promise_for_wait_for_all` stop when they succeed);
  `PromiseRejectionEvent` (the `unhandledrejection` task of a checkpoint that found an unhandled rejection, and
  `rejectionhandled`); WebIDL ReactionSteps cannot throw.

### Test helpers (every region's tests)

- `web_test_create_page(vm)` (`page/tests_page`): a Page in the heap (`page_create`) with a heap test
  PageClient (id, page, zoom/DPR 1, preferences `auto`, headless; `request_frame` / `page_did_change_title`
  counted in `test_document_client_log`).
- `web_test_create_document(realm, type_ = xml)`: a Document as `Document::create` makes it, in a realm of
  `web_test_create_settings_realm` — the real constructor (style and font computers, FontFaceSet, style scope,
  the realm's page, event loop registration) and `initialize` minus ListOfAvailableImages (r26); it installs
  the test fonts first. `web_test_create_vm_realm_and_document()` makes all three.
- `test_html_heap_document(realm)` (r29) and `test_fonts_document(realm)` (r41) are now this heap document, so
  tests that use them can collect. `test_document_page()` (r17) is a heap page the VM keeps alive (the
  documents made outside the heap still use it).
- `web_test_install_agent(vm)` also installs the promise host hooks (as `bind_initialize_main_thread_vm`).
  The test global of `web_test_create_settings_realm` is an EventTarget whose UniversalGlobalScopeMixin
  `this_impl` answers it.
- `web_test_install_event_loop_plugin()` / `web_test_remove_event_loop_plugin()`: an EventLoopPlugin over
  `install_test_event_loop()` (FontFace::load defers through it).
- `test_page_still_unported(stub_file, cpp_name)`: the way to assert a stop (traps cannot be caught): the test
  fails once the owning region ports the function.
- Allocate with the VM's heap as the current allocator (`let allocator: memory.Allocator = vm_heap(vm);
  with allocator:`) when a test collects: a test's own allocator is a fixed buffer the collector does not scan.

### Removed workarounds

- r23's forms GC test and r29's event-loop document test no longer swap Document's and Page's vtables
  (`test_html_forms_collectable_pages`, the test page/document vtables are gone); `test_html_forms_collect(vm)`
  is a plain full collection.
- r42's oracle and scenario tests no longer run under DeferGC (`test_media_invalidation_end_defer_gc` is gone).
- r41's font tests keep DeferGC for a different reason, now documented: fonts the font database makes during a
  test (Typeface::font's cache) are managed memory referred to only from the database in the C heap.
  `test_fonts_setup` now loads the font files with the C heap as ak's atomic allocator (they outlived only the
  first test VM before).

### For region r28 (Page, Navigables, Window)

- `page/page.lucb` holds `Page::create`, `Page::Page` (with the default member initializers, including
  `m_current_cursor`) and `Page::visit_edges`; their stubs are gone from `stub_r28_html_browsing`. Port the rest
  of `Page.cpp` around them (merge into your Page fragments as you like).
- `Window::visit_edges` should call the UniversalGlobalScopeMixin's visit (not ported here: the lists are
  managed memory the global's bytes keep), and `Window::this_impl` answers the window.

## Where Document::create stops now

`Document::create(realm, url)` runs the whole constructor and `initialize` up to:

1. `realm.create<HTML::ListOfAvailableImages>()` in `Document::initialize` — **r26**
   (`html_list_of_available_images_construct`). After it, `initialize` completes (`page_did_create_new_document`,
   `ensure_cookie_version_index`, whose `HTTP::Cookie::canonicalize_domain` is ported here).

For an HTML document the caller is `HTMLDocument::create` — **r27** (ported).

`Document::create_and_initialize(type, content_type, navigation_params)` needs, in order:

1. NavigationParams with a navigable: `TraversableNavigable::create_a_new_top_level_traversable` — **r28**.
2. Step 1, obtain a browsing context: `Navigable::active_browsing_context`, `BrowsingContext::is_top_level`,
   `page()` — **r28**.
3. The response's URL and headers: `fetch_response_url`, `fetch_request_current_url`,
   `fetch_response_header_list`, `http_header_list_get`, `fetch_response_monotonic_response_time` — **P2**
   closure stubs (Fetch).
4. The realm's global: `Window::create`, `BrowsingContext::window_proxy` — **r28**;
   `WindowEnvironmentSettingsObject::setup` (r29, ported) then reaches r28's Window accessors.
5. `HTMLDocument::create` — **r27** (ported).
6. `realm.create<CustomElementRegistry>` — **P3** closure stub; CSP initialization — **P2**.

`page/tests_page` asserts stops 1 of Document::create and 1, 2, 4, 6 of create_and_initialize with
`test_page_still_unported`.

## Tests

- `web_idl/tests_promise` (10): reactions as microtasks in order, once, with the value; derived promises a tick
  later and interleaved chains; resolving with a promise takes two more ticks; rejection and derived rejection;
  HostPromiseRejectionTracker's lists and the checkpoint's notification; LibJS's default job queue; wait for all
  (order, first rejection once, empty in a microtask); JS::Set (insertion order, add/has/remove/size/clear,
  SameValue, NaN, ±0); JS::Map; a full collection keeping a pending promise's reactions and a set's values and
  freeing them after.
- `page/tests_page` (5): the stops; a Document as Document::create makes it (page, FontFaceSet with its JS::Set,
  ready promise fulfilled when no longer pending on the environment, event loop registration, an element by
  `create_element` appended by `append_child`); a style sheet with `@font-face` rules through StyleSheetList's
  "create a CSS style sheet" loading CSS-connected FontFaces into the FontFaceSet (one loading, one ranged);
  Page::visit_edges through collections; a full collection over a heap page, document, element, text, FontFaceSet,
  its JS::Set and ready promise and a FontFace, and the document freed after.

## Notes

- Blobs are scanned conservatively (DESIGN.md §3.3), so a dequeued `AK::Queue` slot (the microtask queue's) keeps
  what it pointed to until it is overwritten: a test cannot expect a finished reaction's cells to be collected.
- The font database in the C heap with fonts cached from a VM's heap is a hazard beyond tests: whoever makes the
  embedder's font database should make it, and its fonts, managed memory the VM keeps (`vm_keep_alive`).

## Compiler issues

None found.
