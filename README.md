# Lumen (萤传) and libcimbar

This repository holds **Lumen**, an iPhone and iPad app that receives files over animated color codes, together with the copy of **libcimbar** it is built on.

libcimbar is written by [sz3](https://github.com/sz3) and contributors: see [sz3/libcimbar](https://github.com/sz3/libcimbar) for the project, its documentation and its full history. The libcimbar sources here were copied from upstream in 2026 (closest upstream commit: `3fd07ff`) without that history, so `git log` and `git blame` in this repository do not show who wrote them.

| Path | What it is |
|---|---|
| `src/`, `web/`, `test/`, `bitmap/` | libcimbar sources (MPL-2.0), with the changes listed below |
| `ios/CimbarTransfer/` | the Lumen app: SwiftUI, camera capture and the native libcimbar decoder ([README](ios/CimbarTransfer/README.md), in Chinese) |
| `ios/ThirdParty/` | how to get the OpenCV framework the app links against |

The upstream CMake build, wasm packaging, sample images and documentation are not included; the app builds with Xcode only.

## Changes to libcimbar

All under the MPL-2.0, like the rest of libcimbar:

- `src/lib/cimbar_js/cimbar_recv_js.cpp`, `cimbar_recv_js.h`: thread-local config is synced per call (GCD queues don't pin threads); one cached decoder per mode, so automatic mode detection can switch modes frame by frame; `cimbard_set_decode_mode_keep_sink()` changes mode without dropping fountain chunks already received.
- `src/lib/fountain/fountain_decoder_sink.h`: `recover()` checks that the slot still holds the same file, and marks a file done only when recovery succeeded.
- `src/third_party_lib/wirehair/gf256.cpp`: unused-variable warnings.
- `web/recv.js`: error message and early return when reassembly fails.

## License

- libcimbar sources: [Mozilla Public License 2.0](LICENSE).
- Third-party libraries under `src/third_party_lib/`: their own licenses, in each directory.
- The Lumen app in `ios/CimbarTransfer/`, including its name, icon and artwork: all rights reserved, see [its LICENSE](ios/CimbarTransfer/LICENSE).

Lumen is an independent app. It is not affiliated with cimbar.org.

---

**中文简介**：本仓库是 iOS 应用「萤传」（Lumen）的代码，连同它所用的 libcimbar 源码。libcimbar 的作者是 [sz3](https://github.com/sz3/libcimbar)，这里的源码是 2026 年从上游复制来的（不含上游提交历史），为 iOS 改过的几个文件见上面「Changes to libcimbar」，都依 MPL-2.0 公开。萤传本身的代码、名称、图标和图稿保留所有权利。
