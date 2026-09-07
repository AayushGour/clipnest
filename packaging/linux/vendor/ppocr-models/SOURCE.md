# Vendored PP-OCRv5 model files — provenance

Why vendored at all: same reasoning as
`packaging/linux/vendor/onnxruntime/SOURCE.md` — Launchpad's PPA build farm
has no network access during a build (a Launchpad-documented property of the
build farm, not an assumption), and this package builds as `3.0 (native)`
(see `debian/source/format` — one monorepo, no separate `.orig.tar.gz`/
`get-orig-source` step), so every file `clipnest-ocr-data` installs must
already be present in the *source* tree before `dpkg-buildpackage`/Launchpad
ever runs. `fetch.sh` is the one-time (or per-version-bump) step a maintainer
runs **with network access, before** committing — see that script's own
header.

## What's here, and why these four files specifically

`Sources/ClipnestLinuxOCR/OCRPipeline.swift` runs a three-model PP-OCRv5
pipeline (detection → text-line orientation classification → CTC
recognition) plus a character dictionary the recognition head's output
indices are mapped through:

- `det.onnx` (~4.6MB) — PP-OCRv5 mobile text **det**ection model. Consumed
  by `OrtSessionSet.runDetection` (`Sources/ClipnestLinuxOCR/Runtime/
  OrtSession.swift`); output shape/layout assumed by `TensorReshaping
  .probabilityMap` and `DBPostProcess.findTextBoxes`.
- `rec.onnx` (~15.9MB) — PP-OCRv5 mobile text **rec**ognition (CRNN + CTC)
  model. Consumed by `OrtSessionSet.runRecognition`; input shape `[N, 3, 48,
  W]` matches `TextLineCropper.recognitionInputHeight = 48` exactly; output
  is **18385** classes (see "The 18385-class convention" below).
- `cls.onnx` (~0.97MB) — PP-LCNet x0.25 text-line orientation **cls**assifier
  (upright vs 180°-rotated). Only loaded/run when `OCRTierConfiguration
  .runsOrientationClassifier` is true for the active tier.
- `dict.txt` (~74KB, 18383 lines, UTF-8, one character per line, LF-
  terminated) — the character dictionary `CharacterDictionary.load(path:)`
  reads and `CTCDecoder.greedyDecode` maps `rec.onnx`'s recognition class
  indices through.

All four are installed to `/usr/share/clipnest-ocr/models/` by
`debian/rules`' `override_dh_auto_install` — see `Sources/ClipnestLinuxOCR/
Runtime/ModelLocating.swift`'s `StandardOCRModelLocator.installRoot`, which
this path must (and does) match exactly.

## Provenance (real, verified at vendoring time — not assumed)

- **Upstream conversion:** RapidOCR's official ModelScope-hosted ONNX export
  of Baidu's PaddleOCR PP-OCRv5, pinned at RapidOCR release tag `v3.9.2`
  (`github.com/RapidAI/RapidOCR`, tag `v3.9.2`).
- **Fetched from the real ModelScope asset URLs** (HTTP 200, real file
  bytes — not a guess):
  - `https://modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv5/det/ch_PP-OCRv5_det_mobile.onnx`
  - `https://modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile.onnx`
  - `https://modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv5/cls/ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx`
  - `https://modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/paddle/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile/ppocrv5_dict.txt`
- **SHA-256 of each file actually vendored into this tree** (also cross-
  verified against RapidOCR's own `default_models.yaml` at tag `v3.9.2` —
  the checksums that authoritative file itself publishes for these exact
  model paths):
  - `det.onnx`: `4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae`
  - `rec.onnx`: `5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5`
  - `cls.onnx`: `54379ae5174d026780215fc748a7f31910dee36818e63d49e17dc598ecc82df7`
  - `dict.txt`: `d1979e9f794c464c0d2e0b70a7fe14dd978e9dc644c0e71f14158cdf8342af1b`
- **License: Apache-2.0.** PP-OCRv5's model weights and training code are
  published by the PaddlePaddle Authors under Apache-2.0
  (`github.com/PaddlePaddle/PaddleOCR`, confirmed via GitHub's license API:
  `spdx_id: Apache-2.0`). RapidOCR's own ONNX conversion/hosting code and
  repository are also Apache-2.0 (`github.com/RapidAI/RapidOCR`, same
  confirmation; `Copyright (c) 2021 RapidOCR Authors` per that repo's own
  `LICENSE` file). See `debian/copyright`'s `packaging/linux/vendor/
  ppocr-models/*` stanza for the full license text as shipped.

## The 18385-class convention (why `CharacterDictionary.load` appends a space)

`rec.onnx`'s recognition head emits **18385** output classes, but `dict.txt`
has only **18383** lines — `18383 + 1 (CTC blank) = 18384 ≠ 18385`. This is
not a mismatched/wrong file: PP-OCRv5's `rec.onnx` was exported with
PaddleOCR's `use_space_char=True` training config, which appends one
**additional** literal-space class AFTER the dictionary's own characters
(see `ppocr/postprocess/rec_postprocess.py`'s `BaseRecLabelDecode.__init__`
+ `CTCLabelDecode.add_special_char`: final class layout is `[blank] +
dict.txt's 18383 lines + [" "]` = 18385). `CharacterDictionary.load(path:)`
(`Sources/ClipnestLinuxOCR/Recognition/CharacterDictionary.swift`) applies
this exact convention at load time — see that function's own doc comment,
and `Tests/ClipnestPlatformLinuxTests/OCRCharacterDictionaryTests.swift` for
the regression tests this fixed (T-OCR9).

## Why an on-device OCR model can be vendored at all under this product's
no-network policy

Nothing here is ever downloaded by the running app — `clipnest-ocr-data` is
a static data package built into the `.deb` at packaging time, from files
already sitting in this git tree, exactly like `packaging/linux/vendor/
onnxruntime`. The app's own privacy promise ("the only network traffic is
an optional, once-a-day GitHub release check") is unaffected: OCR inference
reads these files from `/usr/share/clipnest-ocr/models/` on disk, never
fetches or updates them.

## Repo-size note (logged decision, not a silent choice)

Vendoring these four files adds roughly 22MB to this git tree (`rec.onnx`
~15.9MB is the majority). Same trade-off already logged for
`packaging/linux/vendor/onnxruntime` — committed here because Launchpad's
PPA builders have no network access at build time — flagged for the
architect/user, not decided unilaterally as final; see that directory's own
SOURCE.md "Repo-size note" for the full discussion (Git LFS / a release-
asset-fetched vendor cache are the two alternatives on the table for later).
