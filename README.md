# Lumen (萤传) and libcimbar

This repository holds **Lumen**, an iPhone and iPad app that receives files over animated color codes, together with the copy of **libcimbar** it is built on.

libcimbar is written by [sz3](https://github.com/sz3) and contributors: see [sz3/libcimbar](https://github.com/sz3/libcimbar) for the project, its documentation and its full history. The libcimbar sources here were copied from upstream in 2026 (closest upstream commit: `3fd07ff`) without that history, so `git log` and `git blame` in this repository do not show who wrote them.

| Path | What it is |
|---|---|
| `src/`, `web/`, `test/`, `bitmap/` | libcimbar sources (MPL-2.0; the bundled third-party code keeps its own licenses, see below), with the changes listed below |
| `ios/CimbarTransfer/` | the Lumen app: SwiftUI, camera capture and the native libcimbar decoder ([README](ios/CimbarTransfer/README.md), in Chinese) |
| `ios/ThirdParty/` | how to get the OpenCV framework the app links against |

The upstream top-level CMake build, its packaging scripts, the sample images and the documentation are not included. The per-directory `CMakeLists.txt` files and `web/wasmgz.sh` are left over from upstream and unused here: the app builds with Xcode only.

## Changes to libcimbar

Under the MPL-2.0, like the rest of libcimbar:

- `src/lib/cimbar_js/cimbar_recv_js.cpp`, `cimbar_recv_js.h`:
  - the thread-local config is re-synced before decode work (GCD queues don't pin threads);
  - one cached decoder per mode, so automatic mode detection can switch modes frame by frame without rebuilding it;
  - new `cimbard_set_decode_mode_keep_sink()`: switches the per-frame decode mode without touching the fountain sink, so automatic detection can try another mode on a stalled transfer; a probe that finds data is followed by `cimbard_reset()`, and the file is received again in the new mode;
  - new `cimbard_reset()`: drops in-progress streams, completed file ids and reassembled contents;
  - reassembly recovers into a scratch buffer and commits only on success (fixes a use-after-free of the decompressor's view);
  - new error codes: -16 when the decompressor can't be initialised, -15 from `cimbard_decompress_read()` for a corrupt stream;
  - debug output compiles out under `CIMBARD_NO_DEBUG`.
- `src/lib/fountain/fountain_decoder_sink.h`: `recover()` checks that the slot's stream has the expected file size (the same check `decode_frame()` uses), and marks a file done only when recovery succeeded, so a failed recover leaves the stream receivable instead of discarding it.
- `web/recv.js`: error message and early return when reassembly fails.

Under wirehair's BSD-3-Clause license: `src/third_party_lib/wirehair/gf256.cpp`, `[[maybe_unused]]` on `CpuHasNeon64` (declared in three preprocessor branches) to silence a warning.

## License

- libcimbar sources: [Mozilla Public License 2.0](LICENSE).
- Third-party libraries under `src/third_party_lib/`: their own licenses, in each directory. `test/catch.hpp` is Catch2 under the [Boost Software License 1.0](test/LICENSE_1_0.txt).
- The Lumen app in `ios/CimbarTransfer/`, including its name, icon and artwork: all rights reserved, see [its LICENSE](ios/CimbarTransfer/LICENSE).

Lumen is an independent app. It is not affiliated with cimbar.org.

---

**中文简介**：本仓库是 iOS 应用「萤传」（Lumen）的代码，连同它所用的 libcimbar 源码。libcimbar 的作者是 [sz3](https://github.com/sz3/libcimbar)，这里的源码是 2026 年从上游复制来的（不含上游提交历史），改过的几个文件见上面「Changes to libcimbar」，依各自的许可公开（libcimbar 的文件是 MPL-2.0，wirehair 的 gf256.cpp 是 BSD-3-Clause）。萤传本身的代码、名称、图标和图稿保留所有权利。
