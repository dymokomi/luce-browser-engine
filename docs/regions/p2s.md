# Region p2s: phase-2 seams — zeroed strings and the ReadableStream stand-in

Two seams kept phase-2 code from running cleanly. Every cell port had to set its AK strings by hand, because a zeroed
`ak.ByteString` was invalid and a zeroed `ak.String` was not `String {}` (missing one crashed, and gave a wrong
`is_network_error`, in p2b). And a fetch body's `Streams::ReadableStream` was opaque, so `Body::fully_read`,
`incrementally_read`, `clone`, `byte_sequence_as_body` (srcdoc documents) and the network's chunks all stopped in
closure stubs. This region fixes the first in luce-browser-foundation and fills the second with a stand-in
(DESIGN.md §3.6, "The ReadableStream stand-in").

## Zeroed strings (luce-browser-foundation 592e10d)

- `StringBase` and `Utf16StringBase` (so `String`, `FlyString`, `Utf16String`, `Utf16FlyString`): eight zero bytes are the
  empty short string. `is_short_string` / `has_short_ascii_storage` answer true for them and `raw` answers the empty
  short string's word (`SHORT_STRING_FLAG`), so a zeroed string equals, hashes and interns as `T {}`. A long string's
  data pointer is never null now (the old `else return …` fallbacks for a null pointer trap as unreachable).
- `ByteString.m_impl` is `const ByteStringImpl*?`: none is the static empty impl; every function reads the impl
  through `byte_string_impl`.
- The C++ null sentinel of `Optional<String/FlyString/Utf16String/Utf16FlyString>` is gone (`string_construct_void`,
  `string_is_invalid`, `fly_string_construct_void`, `fly_string_is_invalid`, `string_base_construct_void`,
  `utf16_string_construct_utf16_string`, `utf16_string_is_invalid`, `utf16_fly_string_construct_utf16_fly_string`,
  `utf16_fly_string_is_invalid`, `utf16_string_base_utf16_string_base`): the port's optionals are Luce optionals, and no
  package used them. The two `optional` tests are ported over `T?` as the C++ tests read.
- Tests: `ak/tests_zeroed_strings` (6): each type zeroed against `T {}` and non-empty strings both ways, through
  every accessor, in a zeroed allocation and as HashMap keys. Foundation `./test.sh` passes (ak: 698 tests).

### What other regions must know

- **Cells need not set empty strings.** A zeroed `String`, `FlyString`, `ByteString`, `Utf16String` or
  `Utf16FlyString` member is the empty string; `ak.String()`, `ak.ByteString()` and the like are `T {}`. Struct
  literals no longer need `m_impl =` for a ByteString field. Memory from `new T[n] ---` (uninitialized) still needs
  its members written.
- The engine's hand initializations that only existed for this are gone: p2b's Request (`m_replaces_client_id`,
  `m_integrity_metadata`, `m_cryptographic_nonce_metadata`), Response (`m_status_message`, `m_method`, `m_body_info`)
  and the opaque/opaque-redirect filtered responses' `m_method`; r13b's `AriaData()` (now writes nothing); CSP's
  Policy and Violation; ImageRequest's current URL; HTMLDialogElement, HTMLInputElement, HTMLTextAreaElement,
  HTMLScriptElement, FormAssociatedElement and LinkProcessingOptions; PreloadEntry; `LoadRequest`, `FileRequest` and
  `RequestCertificateAndKey` literals. `Selector::PseudoElementSelector`'s constructor keeps its `m_name`: its caller
  passes `---` memory. Assignments the C++ makes in algorithms (`m_value = {}` and the like) stay.

## The ReadableStream stand-in

### Fragments

| Fragment | Donor |
| --- | --- |
| `external/lib_js/array_buffer` (+ `types_array_buffer`, filled) | `LibJS/Runtime/ArrayBuffer.cpp` 33-329: create, accessors, `detach_and_take_bytes`, CloneArrayBuffer, CopyDataBlockBytes |
| `external/lib_js/typed_array` (+ `types_typed_array`, filled) | `LibJS/Runtime/TypedArray.cpp` 23-120, 475-760 for Uint8Array: create, `Construct(%Uint8Array%, …)` (InitializeTypedArrayFromArrayBuffer), `typed_array_from`, the witness-record operations, `data()`; `js_value_as_if_uint8_array_data` (p2a's closure stub) |
| `web_idl/buffers` (filled) | `WebIDL/Buffers.cpp`: byte length/offset, element size and viewed buffer of typed arrays; ArrayBufferView creation |
| `streams/types_readable_stream`, `types_readable_stream_default_reader` (filled), `types_readable_byte_stream_controller`, `types_readable_stream_tee`, `types_readable_stream_default_controller`, `types_readable_stream_byob_reader` (new; the last two opaque) | the Streams headers |
| `streams/readable_stream` | `Streams/ReadableStream.cpp` 88-433 with `ReadableStream.h`'s accessors |
| `streams/readable_stream_default_reader` | `ReadableStreamDefaultReader.cpp` 41-248, `ReadableStreamGenericReader.cpp` 17-47 |
| `streams/readable_byte_stream_controller` | `ReadableByteStreamController.cpp` 24-211 |
| `streams/readable_stream_operations_1`, `_2` | `ReadableStreamOperations.cpp` 56-1258 (streams, readers, the byte tee), 1619-2822 (byte controllers) |
| `streams/readable_stream_tee` | `ReadableStreamTee.cpp` 159-320 (ReadableByteStreamTeeParams, ReadableByteStreamTeeDefaultReadRequest) |
| `streams/abstract_operations` | `AbstractOperations.cpp` 420-494 (CanTransferArrayBuffer, TransferArrayBuffer, CloneAsUint8Array), `AbstractOperations.h`'s ResetQueue |
| `fetch/body_init` | `Fetch/BodyInit.cpp` 25-155 for a byte sequence: `safely_extract_body` (p2b's closure stub), `extract_body` |
| `streams/tests_streams_1`, `_2`, `fetch/infrastructure/http/tests_fetch_http_3` | tests (below) |

The closure stubs of `stub_closure`'s "Streams and BodyInit" section and `js_value_as_if_uint8_array_data` are gone.

### What other regions must know (p2c above all)

- **Making a byte stream from the network** (Fetching.cpp:2145): `realm_create_streams_readable_stream(realm, realm)`,
  then `streams_readable_stream_set_up_with_byte_reading_support(stream, pull_algorithm, cancel_algorithm)` (both
  optional `gc.Function0[JsPromiseCapability*]` / `gc.Function1[JsValue, JsPromiseCapability*]`, high water mark 0).
  Body bytes go in as Uint8Arrays: `js_array_buffer_create_byte_buffer(realm, bytes)`, `js_uint8_array_create(realm,
  length, buffer)` and `streams_readable_byte_stream_controller_enqueue_2(streams_readable_stream_byte_controller(stream),
  js_value_from_object((JsObject*)view))` (FetchedDataReceiver), or `streams_readable_stream_pull_from_bytes(stream,
  bytes)`; end with `streams_readable_stream_close(stream)` or `streams_readable_stream_error(stream, e)`;
  `streams_readable_stream_is_readable` guards both. `streams_readable_stream_controller(stream)` is the variant.
- **Execution context.** Setting up a stream and reading it react to promises, so it must happen in an execution
  context of the stream's realm (a `TemporaryExecutionContext` with callbacks enabled), as the donor's callers have;
  the reactions and a tee's chunk forwarding run as microtasks.
- **Names.** Where a member and an abstract operation share a snake name, the member keeps it and the operation takes
  `_2` (as the generator names a later declaration): `streams_readable_stream_close` is `ReadableStream::close`,
  `streams_readable_stream_close_2` is `readable_stream_close`; likewise `error`, `tee`, `cancel`, the reader's `read`
  (`streams_readable_stream_default_reader_read_2`), and the controller's `close`, `error`, `enqueue`
  (`streams_readable_byte_stream_controller_enqueue_2` is ReadableByteStreamControllerEnqueue). The namemap has every
  row.
- **What still traps.** Default controllers (P4: JS underlying sources, ReadableStreamDefaultTee), BYOB readers, BYOB
  requests and pull-into descriptors (P4: never pending here, so ReadableByteStreamControllerRespond and the BYOB
  branches trap), `JS::TypeError::create` (P3: releasing a reader's lock, a chunk that is not a Uint8Array) and
  `JS::Array::create_from` (P3: canceling both branches of a tee). **p2c's network errors** (`stream->error(
  JS::TypeError::create(realm, error))`) stop at `js_type_error_create` until an Error stand-in or phase 3.
- Body::visit_edges and IncrementalReadLoopReadRequest::visit_edges visit their stream and reader as cells; the read
  request's close and error tasks are made in the reader's heap, as in C++ (p2a's note on that is resolved).

## Tests

- `ak/tests_zeroed_strings` (foundation, 6) and the two ported `optional` tests.
- `streams/tests_streams_1` (6): the ArrayBuffer and Uint8Array stand-ins (transfer detaches, views a range,
  CloneAsUint8Array copies it, out-of-bounds views); chunks read in order from the queue and by waiting reads; a close
  requested while chunks are queued; erroring (waiting and later reads, the closed promise, the queue reset); read all
  bytes (before and after the chunks, error, empty); a locked stream refusing a second reader, pull_from_bytes.
- `streams/tests_streams_2` (5): tee (both branches, the second a copy a microtask later, closing), a tee's error
  forwarding and a canceled branch; canceling (waiting reads closed, cancel algorithm once, closed and errored
  streams); the pull algorithm (after start, pullAgain, a rejected pull); a reader keeping its stream, the tee and the
  queued chunks through a collection, all freed after.
- `fetch/infrastructure/http/tests_fetch_http_3` (4): byte_sequence_as_body and safely_extract_body (source, length, a
  stream closed once read, fully_read); Body::fully_read of a streamed body and its error; Body::incrementally_read
  chunk by chunk and its error; Body::clone (tee, copied source, both bodies read).
- `luce-base test src/web`: 638 passed (623 before; 15 new).

## web_test

Unchanged: Layout 864 of 922, Ref 609 of 820, Crash 41 of 52, Screenshot 30 of 67 (1861 tests); the expected-failures
lists need no change. The image and style-sheet tests still stop at `Fetch::Fetching::fetch` (p2c).

## Deviations and notes

- The stand-in ports only the byte-stream half of Streams; the functions it does not port are absent (no stubs), and
  the branches that would call them trap with `unported (P4)` / `(P3)` messages naming them.
- `JS::ArrayBuffer`'s detach key is always undefined and its buffers are never shared or resizable; a Uint8Array's
  [[ArrayLength]] and [[ByteLength]] are never auto, so the witness records keep only their cached byte length.
  `Uint8Array::create` keeps the donor's byte length (the whole buffer's).
- ReadLoopReadRequest::on_chunk appends the chunk's whole viewed buffer, as the donor does (not the view's range).
- `Construct(%Uint8Array%, « buffer »)` in CloneAsUint8Array passes the buffer's length explicitly (the same view).
- `extract_body`'s nested TemporaryExecutionContext (the AD-HOC synchronous action) is kept.
- The streams GC test runs sixteen empty microtasks before its last collection: dequeued microtask slots are still
  found by the conservative scan of the queue's buffer (p1_seams' note), which would keep the controller alive.
- HANDOFF.md §5 item 4's engine follow-ups were done by earlier regions; none concerns this region.

## Compiler issues

None found.
