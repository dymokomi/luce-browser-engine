# fix/real-sites: what real websites reached — what other regions need to know

The branch makes the engine survive popular sites with scripting disabled. `tools/site_sweep` loads
each site of `tools/site_sweep/sites.txt` (62 pages) in a process of its own the way luced-browser
does (`--watch` runs the loop as its window loop does, `--png` writes the frame it judged) and
groups the traps by message. Everything it found that is not animations (branch `p4/animations`)
is ported here, faithfully to the donor.

## Fragments

| Fragment | Donor |
| --- | --- |
| `html/audio_track_list`, `video_track_list`, `text_track_list` (+ types, filled) | `AudioTrackList.cpp`, `VideoTrackList.cpp`, `TextTrackList.cpp` whole |
| `html/media_track_base`, `audio_track`, `video_track` (+ types) | `MediaTrackBase.cpp`, `AudioTrack.cpp`, `VideoTrack.cpp` whole |
| `html/text_track` (+ types, filled) | `TextTrack.cpp` and `TextTrackObserver.cpp` whole |
| `html/track_event`, `time_ranges`, `media_error` (+ types) | `TrackEvent.cpp`, `TimeRanges.cpp`, `MediaError.cpp` whole |
| `external/lib_media/track`, `time_ranges`, `incrementally_populated_stream`, `playback_manager` (+ types, filled) | LibMedia's `Track.h`, `DecoderError.h`, `TimeRanges.cpp`, `IncrementallyPopulatedStream.cpp` (writing side), `PlaybackManager.cpp` as a seam (below) |
| `html/navigation` (extended), `html/navigation_current_entry_change_event`, `pop_state_event`, `hash_change_event` (+ types) | `Navigation.cpp` 1461-1558, the three events' `.cpp` whole |
| `web_idl/abstract_operations` (extended) | `AbstractOperations.cpp` 258-364 (invoke_callback_impl, invoke_callback) |
| `trusted_types/require_trusted_types_for_directive` | `RequireTrustedTypesForDirective.cpp` 26-83 |
| `external/lib_js/primitive_string`, `array`, `ordinary_object`, `json_object`, `value_conversions` (+ types) | LibJS stand-ins, DESIGN.md §3.6 |
| `layout/node_2` (extended) | `~NodeWithStyle`'s effect as the cell's finalize |

## What other regions must know

- **LibMedia is a seam without demuxers** (DESIGN.md §7.1). `PlaybackManager::create_demuxer_for_stream`
  answers a NotImplemented DecoderError, reported through `on_unsupported_format_error` on the event loop
  as `handle_media_init_error` does, so every `<video>`/`<audio>` takes the element's "unsupported format"
  steps: the fetch is cancelled, the next `<source>` tried, the poster shown, the load event released. The
  manager stays in the Starting state; Playing, Paused and Seeking, the data providers and the sinks trap
  (only a demuxer's tracks reach them). The media element destroys a manager it replaces
  (`media_playback_manager_destruct`, the OwnPtr's destructor revoking the weak link).
- **Native callbacks run.** `WebIDL::invoke_callback` calls a callback's function (the media controls'
  requestAnimationFrame callback is a native function); a JS function is still P3.
- **Fragment navigation works**: Navigation's same-document update fires `currententrychange` and
  `dispose`; `popstate` and `hashchange` are real events.
- **JS values before P3**: strings, arrays, ordinary objects and JSON.stringify (DESIGN.md §3.6).
- **web_test unloads the replaced document** when a reftest loads its reference, as test-web's navigation
  does: Document::unload destroys it and its queued tasks.

## Known, not fixed

- **Nested spin_until deadlock (donor).** Main fetch's "wait until the preloaded response candidate is not
  pending" spins the event loop inside a deferred invocation. A second `<link rel=preload>` of the same URL
  consumes the first one's entry and spins; a consumer of the second (an `<img>`) spins inside it, waiting for
  a body the outer spin holds back. Ladybird's code has the same shape (it would hang the tab); the
  webview traps "the event loop waits for an event that can never come" (react.dev, nodejs.org,
  bestbuy.com, developer.mozilla.org at times).
- **TLS 1.2-only servers** (arstechnica.com, craigslist.org, html.spec.whatwg.org) fail the handshake:
  luce-tls speaks TLS 1.3.

## Tests

`html/tests_html_media_2` (factory-made media elements, TextTrack and its observer, TimeRanges, MediaError,
the stream, the playback manager seam), `external/lib_media/tests_time_ranges` (Ladybird's
`Tests/LibMedia/TestTimeRanges.cpp`, all 37 cases), `external/lib_js/tests_stand_ins`, and the webview's
`tests_webview_pages` (a page with video and audio; a fragment link). web_test: Layout 921/922, Ref 776/820,
Crash 47/52, Screenshot 65/67.
