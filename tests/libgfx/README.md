# Ladybird's LibGfx test inputs (BMP, CUR, GIF, ICO, ICC, WebP, APNG)

The BMP, CUR, GIF, ICO and WebP files and the two APNG files (`png/apng-*.png`) of Ladybird's
`Tests/LibGfx/test-inputs`, and the images with ICC
profiles (`icc/icc-v2.png`, `icc/icc-v4.jpg`, and `jpg/gradient_empty_icc.jpg` as
`icc/gradient_empty_icc.jpg`), copied from Ladybird at
the commit in `../libweb/PIN` (`47c82b38d0`), without `bmp/top-down.bmp` (590 KB; a small top-down
bitmap stands in) and `webp/4.webp` and `webp/4-with-8-partitions.webp` (180 KB each; luce-webp's
own tests decode them). Ladybird's tests are under the BSD 2-Clause License in `LICENSE`. The image codec
plugin's tests (`src/web/platform/tests_image_codec_plugin_luce.lucb`, regions p2img and p2/icc, and
`tests_image_codec_plugin_luce_webp.lucb`, p2/webp) decode them as `Tests/LibGfx/TestImageDecoder.cpp`
does, and check the color spaces of the ICC images.
