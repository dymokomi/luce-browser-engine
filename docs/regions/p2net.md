# Region p2/net: non-blocking network loading

p2d's in-process RequestClient loaded http(s) in one deferred invocation that blocked the event loop from connect to
last byte, because the Core event-loop seam could not watch sockets. This region ports Core::Notifier onto the seam,
waits for timers and notifiers in one wait (EventLoopImplementationUnix's `wait_for_events`), and drives every
http(s) request as a state machine on the loop: resolution on a thread of its own, a non-blocking connect, the TLS 1.3
handshake step by step, the request written as the socket takes it, the response parsed and decoded as it arrives,
connections kept alive and reused per origin. What arrives is delivered as LibRequests delivers RequestServer's IPC
replies to WebContent: the headers, the body chunks as they come, then the end, each on a later turn of the loop.

## Fragments

| Fragment | Donor |
| --- | --- |
| `external/lib_core/types_notifier` (new) | `LibCore/Notifier.h` 17-63: `NotificationType`, `Notifier` |
| `external/lib_core/notifier` | `LibCore/Notifier.cpp` 1-67 with `Notifier.h`'s inline members |
| `external/lib_core/event_loop` (+ `register_notifier`, `unregister_notifier`) | `EventLoop.cpp` 134-142, `EventLoopImplementation.h` 30-31 |
| `external/lib_core/event_loop_notifiers` | `EventLoopImplementationUnix.cpp`: ThreadData's notifiers (276-282), `register_notifier`/`unregister_notifier` (657-690), `wait_for_events`' poll and notifier activation (334-433) |
| `loader/in_process_request_client` | p2d's client, with the http(s) settings (curl's options as RequestServer sets them) and the pool |
| `loader/in_process_http_connection` | new: resolving, connecting, TLS, timeouts, closing (curl's connection setup) |
| `loader/in_process_http` | new: one HTTP/1.1 exchange (request, head, body, retry, end) |
| `loader/in_process_http_delivery` | new: deliveries on the loop; the timing info after `Request::acquire_timing_info` |
| `loader/in_process_http_pool` | new: curl's connection pool as RequestServer uses it |
| `loader/in_process_http_encoding` | the Content-Encoding writer stack, now streaming |
| `loader/in_process_http_support` | new: C-heap byte buffers and lists |
| `loader/tests_loader_5`, `_6` | tests (below) |

## What other regions must know

### The event loop seam

- `CoreEventLoopImplementation` has two more methods, `register_notifier(notifier)` and `unregister_notifier(notifier)`
  (EventLoopManager's). Every embedder's loop implements them; `CoreEventLoopNotifiers` (`event_loop_notifiers`) is the
  registry and the poll for them: forward the two calls to `core_event_loop_notifiers_register`/`_unregister`, wait
  through `core_event_loop_notifiers_wait(notifiers, deadline)` (until the next timer, `net.Deadline()` for none, an
  expired one only looks) instead of sleeping, and run `core_event_loop_notifiers_dispatch` after the deferred
  invocations queued before the wait and before the due timers (the order ThreadEventQueue processes what
  `wait_for_events` posted). With nothing registered the wait answers at once.
- The wait is luce-std `net.Poller` (poll on macOS and Linux, WSAPoll on Windows; Ladybird polls too), made per wait
  in the C heap with one slot per descriptor: a socket's read and write notifiers share a slot. A notifier unregistered
  by an earlier activation of the same dispatch is skipped (registrations carry a serial number, so a freed notifier
  whose address is reused is not confused with it).
- `core_notifier_create(fd, kind)` / `core_notifier_construct(storage, fd, kind)` make an enabled notifier (C++
  constructs enabled); `set_enabled`, `set_type`, `close`, `fd`, `type`, `is_enabled` are the C++ members;
  `core_notifier_event` is the NotifierActivation the loop delivers. `CoreNotificationType` is a flag enum
  (`core_notification_type_has`, `_union`, `_intersection`). The owner thread is not kept (one loop per process).
- web_test's `WorkerEventLoop` waits for its notifiers and timers together; a loop with no deferred invocation, no
  timer and no notifier is still a stalled test. The engine's test loops: `LoaderTestEventLoop` fires timers (single
  and repeating) and waits for notifiers in `loader_test_drain`; `FetchingTestEventLoop` waits for notifiers in
  `fetching_test_run`; `tests_platform`'s `TestEventLoop` counts registrations.

### The in-process client's http(s) requests

- A request runs from `in_process_http_run`: the pool (`in_process_http_pool_acquire`) hands it an idle connection to
  its origin that still looks alive (nothing readable on it, curl's `Curl_conn_seems_dead`), or opens a new one, or
  queues it when the per-host limit is reached. A connection (`InProcessHttpConnection`, the C heap) resolves the host
  with luce-std `net.Lookup` (a thread per name; numeric addresses need none), connects to each address in turn
  (`net.Connection.start_connect` / `finish_connect`), runs the TLS handshake with luce-tls's non-blocking Stream
  (`begin_tls` / `continue_tls`), then carries one exchange at a time. Its Core::Notifier watches the lookup's signal,
  then the socket, for what the current step waits for; a Core::Timer bounds the setup and the request.
- The exchange writes the request (no `Connection: close` any more: HTTP/1.1 keeps the connection, curl sends no
  Connection field), skips 1xx heads, parses the head with `net.http_parse_response`, frames the body with
  `net.HttpBodyDecoder` and decodes its Content-Encoding as it arrives through the writer stack (a gzip coding holds its
  first two bytes until it knows the framing; deflate keeps its input until the zlib stream gives output, for the raw
  retry). After a complete response that does not close the connection (no `Connection: close`, framed, nothing
  extra after it) the connection returns to the pool and goes to the first request waiting for its origin.
- Deliveries (`InProcessHttpDelivery`, managed) are deferred invocations, so a request's callbacks never run inside a
  connection's step: they may start and stop requests freely. A stopped request is delivered nothing more.
- `stop_request`: a queued request leaves the queue; a request with a connection closes it (curl closes a connection
  whose transfer is abandoned part way). A finished request (its end posted) answers false.
- A failure on a reused connection before any byte of the response came is retried once on a new connection (curl's
  "Connection died, retrying a fresh connect").
- Errors follow RequestServer's `curl_code_to_network_error`: resolution UnableToResolveHost, connect UnableToConnect,
  deadlines TimeoutReached, TLS SSLHandshakeFailed (luce-tls does not tell a failed verification from another failed
  handshake), a body cut short IncompleteContent (CURLE_PARTIAL_FILE), damaged codings InvalidContentEncoding; an
  empty reply, a malformed head or broken chunk framing, and send/receive errors are Unknown (curl's
  GOT_NOTHING/WEIRD_SERVER_REPLY/RECV_ERROR/SEND_ERROR). p2d answered IncompleteContent for an empty reply.
- `did_finish`'s total size is the decoded body delivered (RequestServer's `m_bytes_transferred_to_client`); p2d gave
  the encoded size. The timing info is `Request::acquire_timing_info`'s formula over curl's cumulative times measured
  from the request's start (p2d gave absolute monotonic microseconds); `encoded_body_size` is the body as sent, the
  ALPN identifier HTTP/1.1 (HTTP/1.0 for a 1.0 response).
- Settings (`InProcessRequestClient`): `m_timeout_nanoseconds` (whole request, 0 = none: RequestServer sets no
  CURLOPT_TIMEOUT; p2d's default was 30 s), `m_connect_timeout_nanoseconds` (90 s, CURLOPT_CONNECTTIMEOUT),
  `m_max_host_connections` (0 = none: RequestServer leaves CURLMOPT_MAX_HOST_CONNECTIONS at curl's default),
  `m_max_idle_nanoseconds` (118 s, curl's CURLOPT_MAXAGE_CONN), `m_trust` (the public roots; a pinned issuer for test
  servers). Idle connections beyond curl's default pool size (four per transfer in progress, at least four) close,
  oldest first.
- `ensure_connection` with CreateConnection opens a connection to the origin unless one exists (ResolveOnly does
  nothing: no resolution is cached). `in_process_request_client_close_idle_connections(client)` closes idle
  connections (embedders shutting down, tests); `in_process_request_client_connection_counts(client)` answers (all,
  idle).
- Memory: connections, the pool, buffers and decoders live in the C heap (DESIGN.md §3.3 rule 7) and allocate from
  `memory.heap` whatever is current; a connection refers to its request only through a `gc.Root` of the request cell,
  a queued request likewise. Request states and deliveries are managed. Tests that move more than a few kilobytes run
  with the VM's heap current (as the engine does), so the deliveries' buffers, which ak allocates in the newest heap,
  are reachable from the loop's queue.

### Packages

- luce-std 0.6.0: `net.Connection.start_connect(address)` and `connection.finish_connect()` (a connect without waiting),
  `net.Lookup` (`start(host, port, version)`, `descriptor()`, `finished()`, `take()`, `destroy()`: resolution on a thread
  of its own, signalled on a socketpair descriptor; numeric addresses at once). `Connection.connect` is written over
  the same steps.
- luce-tls 0.5.0: the client handshake is a resumable state machine (`client.Handshake`: `start`, `step`, `complete`,
  `close`; `client.connect` runs it to its end, so the blocking path and its tests are the same code); `Stream` has a
  non-blocking mode (`set_nonblocking`, `is_nonblocking`, `queued`, `flush`, `begin_tls`, `continue_tls`; reads and
  writes answer `io.would_block` instead of waiting, records wait in an outgoing queue) and `accept_tls(der, d)`, the
  package's small server on a Stream. New test `nonblocking_tests` (a dripped handshake, a HelloRetryRequest, a queued
  200 kB upload, accept_tls); every existing test and the BearSSL/OpenSSL-derived suites pass unchanged.
- luce-http-client is not used: the engine frames HTTP with luce-std's codec, which is already incremental.

## What still blocks

- Nothing blocks the event loop on the network path. The OS resolver runs on a thread per lookup (getaddrinfo cannot
  be interrupted: an abandoned lookup's thread finishes on its own). RequestServer uses its own asynchronous DNS
  client (LibDNS) and caches answers; a resolver cache and `ensure_connection`'s ResolveOnly are follow-ups.
- The TLS handshake's cryptography (key agreement, certificate chain verification) runs on the loop between reads, as
  curl's does in RequestServer's process: one handshake step can take a few milliseconds.
- HTTP/2, proxies, a cache, cookies (P3), client certificates and certificate-verification error details are not
  done.

## Tests

- `tests_loader_6` (7, on `tests_loader_5`'s server: a thread per keep-alive connection, optionally TLS with a minted
  certificate): Core::Notifier and the loop's wait (shared slots, disable, set_type, close, skipped activations); a
  body dripped 10 bytes every 30 ms arrives in chunks while a 5 ms timer keeps firing (the loop is not blocked);
  keep-alive reuse (five requests, one connection), a response that closes the connection; twenty concurrent
  requests, a per-host limit of two serving ten requests on two connections; a gzip body sent chunked in growing
  pieces, decoded as it arrives; stopping a request in flight (the server sees the connection close) and one in the
  queue, stop after finish; a request timeout; `localhost` resolved off the loop, an unknown host, a refused port;
  preconnect; https on a pinned issuer with keep-alive and a 1 MiB body, an untrusted certificate; a load of 4 × 150
  concurrent mixed requests (small, dripped, streamed gzip, 1 MiB) with and without a limit of six.
- `tests_loader_3`/`_4` (p2d's) pass over the new client (the request head no longer carries `Connection: close`;
  total sizes are decoded sizes); `tests_fetching_3` runs Fetch's HTTP scenarios (CORS, preflight, redirects
  followed, refused and to another scheme) over it.
- web_test: the worker's loop test of one wait for a timer and a notifier.
