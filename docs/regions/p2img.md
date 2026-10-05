# Region p2img: images through luce-gif, luce-bmp and luce-ico — what other regions need to know

Region p2img extends p2d's image decoding seam, `platform/image_codec_plugin_luce` (`Platform::ImageCodecPlugin`), with
our new packages: **luce-gif** (still and animated, composited frames, browser timing, loop count), **luce-bmp** and
**luce-ico** (BMP entries decoded with their masks, PNG entries decoded with luce-png). An animated GIF is streamed
to `AnimatedDecodedImageData` (r26) the way Ladybird's ImageDecoder process streams it. New code behind the ported
seam, not a port: there is no stub fragment and no regions.tsv row.

## Fragments

| Fragment | What |
| --- | --- |
| `platform/image_codec_plugin_luce` (rewritten) | the plugin: install, `decode_image`, and the streaming sessions of animated images (`request_animation_frames`, `stop_animation_decode`), shaped as `Services/ImageDecoder/ConnectionFromClient.cpp` |
| `platform/image_codec_plugin_luce_decode` (new) | choosing the decoder by MimeSniff's image patterns, each format's decode, the conversion to premultiplied BGRA8888 (moved from the plugin fragment) |
| `platform/tests_image_codec_plugin_luce` (new, last in ORDER) | tests (below) |

## What other regions must know

- **Choosing the decoder.** The plugin sees bytes only (as in Ladybird, whose `decode_image` passes no MIME type to the
  ImageDecoder, which sniffs). MimeSniff's ported `match_an_image_type_pattern` names the type and the essence names
  the decoder: image/png → luce-png, image/jpeg → luce-jpeg, image/gif → luce-gif, image/bmp → luce-bmp,
  image/x-icon (icons and cursors; `luce_image_codec_format_for_essence` also maps image/vnd.microsoft.icon) →
  luce-ico. image/webp and AVIF (`ftyp` `avif`/`avis`) fail with `luce_image_codec_unsupported` ("… not supported
  yet"), as does anything else. `html_is_supported_image_type` already listed all of these types.
- **APNG** decodes as its still default image (luce-png reads IDAT); its animation, WebP and AVIF are unsupported
  until their luce packages exist.
- **`luce_image_codec_plugin_decode(bytes)`** (pub, unchanged signature) decodes whole: one frame for a still image;
  for an animated GIF every composited frame, `is_animated`, `frame_count`, `all_durations`, `loop_count`, and
  `session_id` 0 (so a caller that wants every frame, e.g. `BitmapDecodedImageData`, gets them).
- **`decode_image`** (the vtable entry) streams an animated GIF of more than one frame, as `decode_image_to_details`
  does: the promise resolves (next turn of the event loop) with `session_id` (1, 2, … per plugin), `is_animated`,
  `frame_count`, `loop_count`, every duration in `all_durations` and the first `STREAMING_BATCH_SIZE` (4) frames.
  SharedResourceRequest then makes an `AnimatedDecodedImageData`, whose frame requests reach
  `request_animation_frames(session_id, start, count)`: the plugin renders frames `[start, min(frame_count, start +
  count))` on the next turn and calls `on_animation_frames_decoded(session_id, bitmaps)` (or
  `on_animation_decode_failed`); an unknown session or a start past the last frame is ignored, as in C++.
  `stop_animation_decode` (AnimatedDecodedImageData's finalize) frees the session, and a request queued before it
  then does nothing (the job is cancelled).
- **Memory** (DESIGN §3.3 rule 7): the plugin and its sessions live in the C heap: a session holds a C-heap copy of the
  GIF, luce-gif's `Animation` (its frame list and canvases, `in memory.heap`) and one RGBA canvas; the session map is
  filled under `with memory.heap`. Bitmaps are made in the current allocator (the VM's heap) when frames are handed
  over. Frames render fastest in order; a request that goes back (a loop) renders again from the first frame.
- **Timing and loops.** Durations are luce-gif's: the delay in ms, and 100 ms for a delay of 10 ms or less (LibGfx's
  GIFLoader agrees). The loop count is luce-gif's `plays()`, how many times browsers play the animation in all: 0
  forever, 1 without a loop extension, else the written count + 1. HTMLImageElement and ImageStyleValue stop when
  their completed loops reach `loop_count`, so this plays as browsers do; LibGfx answers the written count (one play
  fewer). A still GIF's frame lasts 100 ms with loop count 1, as LibGfx's.
- **Icons** decode the entry `ico.choose` picks: the largest, then the most bits, then the first; unreadable entries
  (damaged, or not the size their directory lists) last, and a chosen unreadable entry fails. LibGfx's
  `find_largest_image` keeps an earlier entry unless a larger one also has more bits (a 3x1 PNG after a 1x1 BMP of 32
  bits each gives the 1x1); we take the largest, as browsers do.
- **BMP** files holding a PNG or JPEG (BI_PNG, BI_JPEG) decode as that image (LibGfx finds no decoder for them).

## Dependencies

`package.prisma` adds luce-gif, luce-bmp and luce-ico (`^0.3.0`); `bootstrap/PACKAGES` pins their current mains,
luce-gif `91ea6e4`, luce-bmp `2272fda`, luce-ico `1ff4cab`, which check with `-W` against the pinned luce-base
c4272ea. The module imports `from luce_gif import gif as gif_codec`, `from luce_bmp import bmp as bmp_codec`,
`from luce_ico import ico as ico_codec` (after `png_codec` and `jpeg_codec`).

## Tests

`platform/tests_image_codec_plugin_luce` (7 tests; `luce-base test src/web`: 630 passed, 623 before):

- LibGfx's `TestImageDecoder.cpp` cases for BMP, CUR, ICO and GIF through the plugin (`test_bmp`, `_1bpp`,
  `_too_many_palette_colors`, `_v4`, `_os2_3bit`, `test_cur`, `test_bmp_embedded_in_ico`,
  `test_24bit_bmp_embedded_in_ico`, `test_malformed_maskless_ico`, `test_ico_malformed_frame`, `test_not_ico`,
  `test_gif`, `test_corrupted_gif`, `test_gif_without_global_color_table`, `test_gif_empty_lzw_data`;
  `test_bmp_top_down` on a small top-down bitmap), on LibGfx's test inputs, copied to `tests/libgfx/test-inputs`
  (124 KB, with Ladybird's LICENSE). Besides the C++ test's pixels, every frame is checked as an FNV-1a hash of its
  premultiplied BGRA8888 pixels against Ladybird's ImageDecoder; all agree.
- Synthetic images: a six-frame GIF on a 2x1 canvas (every disposal, a transparent index, delays 0, 1, 3, 5, 7, 20)
  and its loop variants (count 2, 0, none), two icons (a BMP and a larger PNG entry; three BMP entries of two sizes and
  depths) and a BMP holding a PNG, embedded as byte arrays.
- Sniffing and the declared types; errors: damaged BMP, ICO (no images, a damaged PNG entry; an unreadable PNG
  entry falls back to the BMP one), GIF (no image), WebP, AVIF and unknown data.
- Streaming: decode_image's first answer (session, four frames, six durations, loop count), session numbering, still
  images without a session, a rejected GIF, frames on request (forward, and back to earlier frames), ignored requests,
  a stopped session (a queued request cancelled), a second session still answering.
- End to end: `AnimatedDecodedImageData` made from decode_image's answer as SharedResourceRequest makes it, advancing
  a frame requests frames 4 and 5, which arrive in its pool through the plugin's callbacks.
- `loader/tests_loader_3`'s image test now fails on WebP bytes (it used a GIF signature), and its decode_image test
  checks that requests for a session that is not open queue nothing.

The oracle (local, `luce-browser-tools/oracles/luce-browser-engine/image_codecs`): `gen_cases.py` writes the synthetic
images, `oracle.cpp` (built by `build.sh` against the reference build's lagom libraries) prints what
`Gfx::ImageDecoder` makes of each file (frame count, animated, loop count, per-frame size, duration, pixel hash and
first pixels), `expected.txt` is its output.

## web_test

The pass counts do not change (Layout 864 of 922, Ref 609 of 820, Crash 41 of 52, Screenshot 30 of 67, before and
after), and the expected-failures lists stay as they are: the copied tests that load GIF or BMP images (`data:` GIFs in
five Layout tests, `bmp-load-as-unpremultiplied-alpha` in Ref) still stop at `Fetch::Fetching::fetch` (p2c) before an
image reaches the plugin.

## Deviations and notes

- Decoding runs on the event loop's next turn, not on ImageDecoder's thread pool; a decode or frame request blocks
  that turn while it runs.
- `on_animation_decode_failed` is reported only if luce-gif fails to render a frame, which cannot happen for a session
  it opened (frames are checked when the animation opens).
- EXIF resolution scaling is not read (scale 1), as in p2d. ICC profiles and cICP are read since
  p2/icc (see DESIGN.md §7.1, *Color management*).
