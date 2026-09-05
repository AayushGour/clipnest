# PP-OCRv5 model files — NOT VENDORED YET (blocking `clipnest-ocr-data`)

This directory is intentionally empty (aside from this file) as of this packaging
pass. `debian/rules`' `override_dh_auto_install` checks for the four files below and
**fails the build loudly** (not silently, and not by shipping an empty/broken
`clipnest-ocr-data`) if any are missing:

```
det.onnx    PP-OCRv5 mobile detection model    (~4.7MB per the OCR plan)
rec.onnx    PP-OCRv5 mobile recognition model  (~16MB per the OCR plan)
cls.onnx    PP-OCRv5 text-line orientation classifier (~0.96MB per the OCR plan)
dict.txt    Character dictionary for CTCDecoder.greedyDecode
```

These exact four filenames are **load-bearing** — they must match
`Sources/ClipnestLinuxOCR/Runtime/ModelLocating.swift`'s
`StandardOCRModelLocator.locate()` exactly:

```
/usr/share/clipnest-ocr/models/det.onnx
/usr/share/clipnest-ocr/models/rec.onnx
/usr/share/clipnest-ocr/models/cls.onnx
/usr/share/clipnest-ocr/models/dict.txt
```

(Note the install path says `clipnest-ocr`, not `clipnest-ocr-data` — that constant is
frozen in Swift source, not a packaging choice; `clipnest-ocr-data` is simply the .deb
that populates that shared directory. See that file's own doc comment: "UNVERIFIED
against an actual `clipnest-ocr` packaging spec... treat this constant as the
documented assumption to reconcile" — this packaging pass reconciles it by matching the
path exactly, not by changing it.)

## Why devops did not fetch these

Unlike `packaging/linux/vendor/onnxruntime/` (a well-documented, versioned, public C
API library with a stable ABI — see that directory's own `SOURCE.md`), PP-OCRv5's ONNX
export has real, code-shaped conventions this packaging task cannot verify from the
outside: exact input tensor shape/normalization
(`Sources/ClipnestLinuxOCR/Decode/ImagePreprocessing.swift`), the DB post-processing
box-decoding assumptions (`Sources/ClipnestLinuxOCR/Detection/DBPostProcess.swift`), and
the character-dictionary line-ordering/blank-index convention
`CTCDecoder.greedyDecode` and `CharacterDictionary` assume. Grabbing "a" PP-OCRv5 ONNX
export from the wrong source/conversion pipeline risks silently mismatched tensors —
producing garbage recognized text rather than a build failure, which is worse than this
loud, explicit gap.

## What needs to happen next

Whoever owns `ClipnestLinuxOCR` (or the architect) should supply:
1. The exact model source (e.g. PaddleOCR's own PP-OCRv5 release, or a specific ONNX
   conversion of it) verified against this project's own preprocessing/decode code.
2. A pinned version + SHA-256 per file, recorded here (mirroring
   `packaging/linux/vendor/onnxruntime/SOURCE.md`'s pattern) once sourced.
3. The four files above dropped into this directory, then `git add`ed — `debian/rules`
   picks them up automatically once present; no packaging changes needed.
