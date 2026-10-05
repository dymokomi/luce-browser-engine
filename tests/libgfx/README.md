# Ladybird's LibGfx test inputs (BMP, CUR, GIF, ICO)

The BMP, CUR, GIF and ICO files of Ladybird's `Tests/LibGfx/test-inputs`, copied from Ladybird at
the commit in `../libweb/PIN` (`47c82b38d0`), without `bmp/top-down.bmp` (590 KB; a small top-down
bitmap stands in). Ladybird's tests are under the BSD 2-Clause License in `LICENSE`. The image codec
plugin's tests (`src/web/platform/tests_image_codec_plugin_luce.lucb`, region p2img) decode them as
`Tests/LibGfx/TestImageDecoder.cpp` does.
