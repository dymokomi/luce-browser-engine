# Synthetic WebP and APNG images

Small images the image codec plugin's WebP and APNG tests
(`src/web/platform/tests_image_codec_plugin_luce_webp.lucb`) decode beside Ladybird's test inputs:
made by luce-webp's and luce-png's fixture generators (luce-browser-tools `oracles/luce-webp/gen_corpus.py`
with libwebp 1.6.0's cwebp, img2webp, gif2webp and webpmux; `oracles/luce-png/apng/gen_apng.py` with
Pillow and a chunk writer) from synthetic pictures and Pillow's test GIFs (Pillow's license, HPND).
The tests compare every frame with what Ladybird's ImageDecoder makes of the same file
(`oracles/luce-browser-engine/image_codecs`).
