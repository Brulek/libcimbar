# ThirdParty

## opencv2.xcframework (4.12.0)

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
