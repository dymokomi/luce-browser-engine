# Regions p2e + p2f: Content Security Policy — what other regions need to know

Regions p2e (`csp_policy`) and p2f (`csp_directives`) port LibWeb's `ContentSecurityPolicy/` whole: policies and CSP
lists (parsing a serialized policy, a response's `Content-Security-Policy` and `-Report-Only` headers and the
`<meta>` pragma's policy; serializing and cloning), the 23 directive classes and their checks, the directive
operations (effective directives, fallback lists, source expressions, matching URLs, requests, responses, nonces,
integrity metadata and elements to source lists, hashes), violations and reporting them
(`securitypolicyviolation`), and the blocking algorithms Fetch, navigation and the inline checks call. Every
function of `stubs/stub_p2e_csp_policy` and `stubs/stub_p2f_csp_directives` is ported and both stubs are gone.
`SRI/SRI.cpp` (not in any region) is ported with them: the CSP checks parse integrity metadata with it, and Fetch
(p2c) matches response bytes with it.

## Fragments

| Fragment | Donor |
| --- | --- |
| `content_security_policy/policy` | `Policy.cpp` 1-228 with `Policy.h` 41-55 (the constructor's member defaults) |
| `content_security_policy/policy_list` | r28's `PolicyList.cpp` (directive names through `Directives::Names` now) |
| `content_security_policy/violation` | `Violation.cpp` 1-476 with `Violation.h` 43-81 |
| `content_security_policy/security_policy_violation_event` | `SecurityPolicyViolationEvent.cpp` 1-50 with its header's accessors |
| `content_security_policy/blocking_algorithms_1` | `BlockingAlgorithms.cpp` 1-396 (requests, responses, integrity policy, navigations) |
| `content_security_policy/blocking_algorithms_2` | `BlockingAlgorithms.cpp` 398-742 (r28's inline and `<base>` checks, string and WebAssembly compilation) |
| `content_security_policy/directives/directive`, `directive_factory` | `Directive.cpp` with `Directive.h` 50-100; `DirectiveFactory.cpp` |
| `content_security_policy/directives/names`, `keyword_sources`, `keyword_trusted_types` | `Names.cpp`, `KeywordSources.cpp`, `KeywordTrustedTypes.cpp` (interned by `web_initialize_strings`) |
| `content_security_policy/directives/directive_operations_1`, `_2` | `DirectiveOperations.cpp` 1-445, 447-1034 |
| `content_security_policy/directives/source_expression` | `SourceExpression.cpp` 1-439 |
| `content_security_policy/directives/<name>_directive` (23) | each `<Name>Directive.cpp` |
| `sri/sri`, `sri/types_sri` | `SRI/SRI.cpp` 1-191, `SRI.h`'s `Metadata` |
| `trusted_types/types_require_trusted_types_for_directive` | `RequireTrustedTypesForDirective.h`'s class (types only; its check is a closure stub) |
| `content_security_policy/tests_csp_cases`, `tests_csp_1`, `tests_csp_2` | tests (below) |

`SerializedPolicy.cpp` and `Directives/SerializedDirective.cpp` hold only IPC encoders and decoders: not ported.

## What other regions must know

### Signatures and types changed

- `content_security_policy_directive_name(directive) -> ak.String` (C++ `String const&`); r28's stub answered a
  FlyString. Compare with `ak.string_eq_fly_string(&name, &content_security_policy_directives_names_<x>)`, as C++
  compares with `Directives::Names::X`. `navigation_params` and `policy_list` are updated.
- `content_security_policy_policy_parse_a_serialized_csp(heap, serialized: ByteStringOrString, source, disposition)`:
  C++'s `Variant<ByteString, String>` (a response header is a ByteString, isomorphic-decoded). `html_meta_element`
  passes `ByteStringOrString.string(input)` and removes `Names::ReportUri`, `FrameAncestors` and `Sandbox`.
- `content_security_policy_policy_create_from_serialized_policy(heap, serialized: const SerializedPolicy*)`.
- Directive classes are made by `heap.allocate<T>` in C++ (GC::Cells without `initialize`): the 24 generated
  `realm_create_content_security_policy_*directive` helpers, which would have run JS::Cell's initialize on a GC::Cell,
  are `heap_allocate_content_security_policy_*directive(heap, name, value)` now; Policy has
  `heap_allocate_content_security_policy_policy(heap)`. The namemap rows say so.
- `StringViewTraits` (generated, trapping) hashes and compares as AK's `Traits<StringView>`.
- Window's `UniversalGlobalScopeMixin` vtable had no `this_impl` (Window::this_impl overrides both mixins'; the
  generator mapped only WindowOrWorkerGlobalScopeMixin's): it is filled now (`Violation::url` reaches it).
- `RequireTrustedTypesForDirective` (TrustedTypes, phase 3) exists as a type so DirectiveFactory can make one for a
  `require-trusted-types-for` directive; it is recognized by `is<Directive>`.

### For Fetch (p2c)

- `content_security_policy_should_request_be_blocked_by_content_security_policy(realm, request)`,
  `report_content_security_policy_violations_for_request(realm, request)`,
  `should_response_to_request_be_blocked_by_content_security_policy(realm, response, request)` and
  `should_request_be_blocked_by_integrity_policy(request)` need the request's policy container to be a
  `PolicyContainer` (Variant::get VERIFYs) and, once a policy is violated, a client (its global object owns the
  violation).
- `sri_do_bytes_match_metadata_list(bytes, metadata)`, `sri_parse_metadata`, `sri_apply_algorithm_to_bytes` are SRI's.
- Reporting a violation queues a task (source "unspecified") that fires `securitypolicyviolation` at the element,
  the document or the global; a `report-uri` directive makes it build the deprecated serialization (Infra JSON
  serialization traps `unported (P3)`, it needs `%JSON.stringify%`) and fetch it (`fetch_fetching_fetch`).

### Closure stubs added (`stub_closure`, section "Region p2e")

- `trusted_types_require_trusted_types_for_directive_pre_navigation_check_impl` (P3): a navigation with a
  `require-trusted-types-for` directive traps there. Its constructor is ported (trivial).
- `js_value_as_if_trusted_types_trusted_script`, `trusted_types_trusted_script_to_string`,
  `realm_create_trusted_types_trusted_script` (P3) for `ensure_csp_does_not_block_string_compilation`, whose
  Trusted Types step already called the closure stub `get_trusted_type_compliant_string`.
- `vm_throw_completion_web_assembly_compile_error` (P4) for `ensure_csp_does_not_block_wasm_byte_compilation`.
- `html_worker_global_scope_url` (P4) for `Violation::url` of a worker.

### luce-crypto

The SHA-256/384/512 hashes (hash-source matching, SRI) are luce-crypto's `native.digest`: luce-crypto is a new engine
dependency (`package.prisma`, `bootstrap/PACKAGES` at 13484cb), imported as `from luce_crypto import native as crypto`
in `module.lucb`.

## Tests

- `tests_csp_cases` + `tests_csp_1`: 3,995 cases pinned to the reference build by a local oracle
  (`luce-browser-tools/oracles/luce-browser-engine/csp`: `oracle.cpp` links the reference build's LibWeb objects and
  runs in a test page's window document; `gen_cases.py` writes `cases.txt`; `expected.txt`; `gen_luce_cases.py`;
  `build.sh`). They cover parsing serialized policies (names, case, duplicates, whitespace, non-ASCII, every
  directive class) and response headers (enforce and report-only, the self-origin of http(s), file: and data:
  URLs), every source-expression production over 70 inputs, URL-to-expression and source-list matching (schemes
  and upgrades, hosts and wildcards, ports and defaults, paths and redirects, `'self'` for tuple and opaque
  origins, `'none'`), effective directives for every destination and initiator, inline effective directives,
  fallback lists, should-directive-execute, the pre- and post-request checks of 29 policies over 31 requests
  (nonces, integrity metadata, `'strict-dynamic'` and parser metadata, redirects, prefetch), does-request-violate,
  should request/response be blocked (enforce and report), the inline checks of 23 policies for every inline type
  and HTML/SVG script, style and other elements (nonces, nonceability, duplicate attributes, `'unsafe-hashes'`,
  SHA-256/384/512 and base64url hashes of UTF-8 sources, `'strict-dynamic'`), does-element-match, navigation
  (form-action, javascript: URLs), `<base>`, the integrity policy, WebRTC, blocked URIs, violations for requests,
  and SRI's metadata parsing, strongest metadata, matching and hashes.
- `tests_csp_2`: what the oracle does not reach: serializing, deserializing and cloning policies and CSP lists;
  directive lookup and removal, the self-origin, the interned names; the CSP-derived sandboxing flags; the `<meta>`
  pragma enforcing a policy and a `<style>` it blocks keeping no sheet; violations (the global's URL, the empty URL
  without one) and reporting them: the `securitypolicyviolation` event at the document, at a connected element
  (bubbling) and at the document for a detached one, with its attributes and the 40-code-point sample;
  SecurityPolicyViolationEvent's construct_impl; the sandbox initialization of a Document, frame-ancestors for a
  top-level target, navigation responses without a request, reporting a request's report-only violations; and a
  collection keeping a CSP list's policies, their directives and a violation's policy and element.

`luce-base test src/web`: 623 passed after merging p2d (7 new). The CSP tests install the test Core::EventLoop
(queueing a violation's task wakes it) before their VM and remove it after it is destroyed.

## web_test

The pass counts do not change, before and after merging p2d (Layout 864 of 922, Ref 609 of 820, Crash 41 of 52, Screenshot 30 of 67): no Layout,
Ref, Crash or Screenshot test has a policy, and the inline and `<base>` checks answered "Allowed" over the empty CSP
lists before as now; `--update-failures` left the lists as they were.

## Deviations and notes

- `Directive::value()` and `Policy::directives()` answer a copy of the Vector struct (its buffer shared) as r28's
  stubs did; callers do not change them.
- `SourceExpressionParser::StateTransaction`'s destructor runs in a `defer`, after the parse function's result is
  computed, as the C++ destructor does.
- `report_a_violation`'s `dbgln` prints for every violation, as in C++ (the CSP tests print many).
- The `find_if` lambdas over directives and source lists are loops (DESIGN.md §2.9).
- HANDOFF.md §5 item 4's engine follow-ups were done by earlier regions; none concerns this region.
