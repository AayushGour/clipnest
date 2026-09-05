# Vendored ONNX Runtime (CPU) — provenance

Why vendored at all: Ubuntu's archives do not carry `onnxruntime`/`libonnxruntime-dev`
(verified — not in jammy/noble main/universe as of this packaging pass), and Launchpad's
PPA build farm has **no network access during a build** (a Launchpad-documented property
of the build farm, not an assumption). Both the header (`onnxruntime_c_api.h`, included
unconditionally by `Sources/COnnxRuntime/shim.h`) and the shared library
(`libonnxruntime.so.1`, hard-linked via that same target's `module.modulemap` —
`link "onnxruntime"`) must therefore already be present in the *source* package before
`dpkg-buildpackage`/Launchpad ever runs; nothing under `debian/rules` may `curl`/`wget`
anything. This package is built as `3.0 (native)` (see `debian/source/format` — this is
one monorepo, not an upstream-plus-Debian-delta split), so there is no separate
`.orig.tar.gz`/`get-orig-source` step: everything under this directory is just part of
the one source tree `dpkg-buildpackage` archives directly. `fetch.sh` is the one-time (or
per-version-bump) step a maintainer runs **with network access, before** committing —
see that script's own header.

## What's here, and why

Only the CPU-inference-relevant subset of each official release tarball — not the full
~lib/cmake, pkgconfig, or GPU/TensorRT/DirectML provider files this project never
loads (`OnnxTextRecognizer`/`OrtSession` call the C API directly for the default CPU
execution provider only — see `Sources/ClipnestLinuxOCR/Runtime/OrtSession.swift`).

- `<arch>/include/` — the full upstream `include/` tree (~1.0MB, text headers only),
  copied whole rather than cherry-picked, because `onnxruntime_c_api.h` pulls in
  `onnxruntime_error_code.h` and `onnxruntime_ep_c_api.h` transitively and neither this
  packaging task nor a quick grep is a reliable way to enumerate every header ONNX
  Runtime's own headers might reach for in a future point release.
- `<arch>/lib/libonnxruntime.so.1.28.1` — the real shared object (the thing that answers
  `OrtGetApiBase()`). ~23MB (amd64) / ~21MB (arm64), stripped, dynamically linked;
  verified via `file(1)` against the actual ELF header at vendoring time (correct
  x86-64 / aarch64 machine type, not a placeholder).
- `<arch>/lib/libonnxruntime.so.1` — the SONAME symlink upstream itself ships (relative,
  `-> libonnxruntime.so.1.28.1`), needed at runtime since `COnnxRuntime` hard-links
  against SONAME `libonnxruntime.so.1`, not the versioned filename.
- `<arch>/lib/libonnxruntime_providers_shared.so` — ~14KB, included for cheap insurance
  even though the default CPU execution provider does not require it (it's only
  `dlopen`ed by ONNX Runtime when a pluggable out-of-tree execution provider —
  CUDA/TensorRT/etc — is explicitly registered, which this CPU-only OCR pipeline never
  does; see D47 in `.claude/project-context.md` — "ONNX-based CPU OCR").
- `<arch>/LICENSE` — upstream's own MIT license text, copied verbatim (feeds
  `debian/copyright`'s `clipnest-ocr` paragraph).

Deliberately NOT vendored: `lib/libonnxruntime.so` (unversioned dev symlink — build-time
only, and `packaging/linux/vendor/onnxruntime/fetch.sh` recreates it locally rather than
shipping a second symlink pointing at the same target), `lib/cmake/`, `lib/pkgconfig/`
(no `pkgConfig:` on the `COnnxRuntime` `systemLibrary` target — see `Package.swift`'s own
comment on that target), `Privacy.md`, `ThirdPartyNotices.txt`, `GIT_COMMIT_ID`, `README.md`.

## Provenance (real, verified at vendoring time — not assumed)

- Upstream: `github.com/microsoft/onnxruntime`, release `v1.28.1`.
- License: MIT (Microsoft Corporation) — full text at `<arch>/LICENSE`.
- Fetched from the real GitHub Releases asset URLs (HTTP 200 confirmed, not a guess):
  - `https://github.com/microsoft/onnxruntime/releases/download/v1.28.1/onnxruntime-linux-x64-1.28.1.tgz`
  - `https://github.com/microsoft/onnxruntime/releases/download/v1.28.1/onnxruntime-linux-aarch64-1.28.1.tgz`
- SHA-256 of the **whole upstream tarballs** actually downloaded (re-verify with `fetch.sh`
  before ever bumping the pinned version):
  - `onnxruntime-linux-x64-1.28.1.tgz`: `2529aef968d0ad0603365054bc46ebefa7f0fe3bc12f28c5f729c99ddffe2a81`
  - `onnxruntime-linux-aarch64-1.28.1.tgz`: `53bab9a5c6ae198b7be75663b780c64caa388d30257fac458c71fbff0a82e98e`
- SHA-256 of the extracted `lib/libonnxruntime.so.1.28.1` actually vendored into this tree:
  - amd64: `e38d2cec3d582c41786bdd428865fc017145599666cb7c82410e52496e7e066d`
  - arm64: `0ce5f75809ba44fdc766b64edf8961014f0ab7ea3686b1be466a61f1474918ac`

## Repo-size note (logged decision, not a silent choice)

Vendoring these binaries adds roughly 24MB (amd64) + 21MB (arm64) to this git tree —
committed here because the alternative (fetching at `dpkg-buildpackage` time) does not
work on Launchpad's PPA builders at all, and fetching only inside `release-linux.yml`
(GitHub Actions, which does have network) would leave the PPA path permanently broken.
This trade-off — and the option of moving to Git LFS or a separate release-asset-fetched
vendor cache later — is flagged for the architect/user in this task's handoff, not
decided unilaterally as final.
