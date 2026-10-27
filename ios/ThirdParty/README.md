# ThirdParty

## opencv2.xcframework (4.12.0)

> **获取方式（2026-07-12 起框架不入 git）**：GitHub 100MB 单文件限制，二进制已从 git 历史剥离。
> 新机克隆后任选其一恢复本目录：
> 1. 从本仓库 GitHub Release `frameworks-v1` 下载 `opencv2.xcframework.zip`，解压到 `ios/ThirdParty/`；
> 2. 按下文构建方法自建。
>
> 许可：OpenCV 4.12.0 依 Apache License 2.0；框架里内置的 libjpeg-turbo、libpng、libwebp、zlib、protobuf、ade、Flatbuffers 各有其许可，全文见同一 Release 里的 `OPENCV-LICENSES.txt`。

- `ios-arm64`：设备切片。二进制来自原始 opencv2.framework（官方 iOS 包）的 arm64 切片
  （`lipo -thin arm64`），字节与替换前完全一致；Headers/Resources 原样保留（全模块头）。
- `ios-arm64-simulator`：自建切片，仅含 app 实际依赖的 core + imgproc（及内建 3rdparty）。
  构建方法（opencv 4.12.0 源码）：

  ```bash
  python3 platforms/ios/build_framework.py <out> \
    --iphonesimulator_archs arm64 --framework_name opencv2 \
    --build_only_specified_archs --without objc \
    --without calib3d --without dnn --without features2d --without flann \
    --without gapi --without highgui --without imgcodecs --without ml \
    --without objdetect --without photo --without stitching --without video --without videoio
  ```

  然后 `xcodebuild -create-xcframework -framework <device> -framework <sim> -output opencv2.xcframework`。

模拟器切片只用于开发调试；App Store 产物只包含设备切片，与历史版本一致。
