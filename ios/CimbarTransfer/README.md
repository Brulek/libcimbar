# CimbarTransfer / 萤传 (iOS)

这是一个面向 `libcimbar` 的 iOS 接收端客户端：

- 通过相机扫描 `cimbar` 动画码（发送端：<https://cimbar.org>）
- 使用原生 `libcimbar` 解码链路重组文件
- 解码后在 iOS 原生侧落盘并调用系统分享

## 功能

**扫码页**
- 手电筒开关、捏合变焦（双击复位）、轻点对焦
- 实时进度：解码百分比、已识别帧数、预计剩余时间
- 进度停滞 5s/12s 分级引导（对齐/靠近/防反光提示）
- 接收完成即暂停解码链省电；完成卡片支持预览/分享/存相册/继续扫码
- 适配「减弱动态效果」与动态字体

**我的文件**
- 图片/视频/PDF 真实缩略图，搜索与多种排序，多选批量删除
- 滑动操作：删除/重命名/分享/存到相册（重命名会同步改磁盘文件名）
- 文件详情页：原始文件名、接收时间、SHA-256 校验（可复制）

**设置**
- 解码模式：标准 Mode B / 兼容 4C / 兼容 8C / Mini / Micro（需与发送端一致）
- 高精度采集（1080p）开关
- 提示音/触觉反馈/接收后自动跳转
- 保留策略（永久 / 30 天 / 7 天，按接收时间计算）
- 在「文件」App 中直接打开接收目录

## 截图

模拟器验证截图（中/英、深/浅色、iPhone/iPad）见 [docs/screenshots/](docs/screenshots/)。

## 目录

- `App/`: SwiftUI 应用代码、原生扫码流程、文件缓存与分享逻辑
- `project.yml`: XcodeGen 项目描述（改动 build settings 时需与 `project.pbxproj` 保持同步）

## 本地生成工程并运行

```bash
cd ios/CimbarTransfer
xcodegen generate   # 可选：仓库内已提交生成好的 xcodeproj
open CimbarTransfer.xcodeproj
```

1. 打开工程后选择真机运行（建议 iPhone）。
2. 首次启动允许相机权限。
3. 对准发送端屏幕，解码完成后点击「分享文件」。

> 未安装 xcodegen 时也可以直接使用仓库中的 `CimbarTransfer.xcodeproj`；
> 新增源文件可用 Python 的 `pbxproj` 库挂接（`pip3 install --user pbxproj`）。

## 构建命令（CLI）

```bash
cd ios/CimbarTransfer
# 无签名编译验证（真机 SDK）
xcodebuild -project CimbarTransfer.xcodeproj -scheme CimbarTransfer \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

```bash
# 模拟器（arm64 原生，由 ../ThirdParty/opencv2.xcframework 的自建 sim 切片支持）
xcodebuild -project CimbarTransfer.xcodeproj -scheme CimbarTransfer \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

> 模拟器切片的构建方法见 `../ThirdParty/README.md`。无签名证书的机器上若
> CodeSign 报 “detritus not allowed”，对产物 `xattr -cr` 后手动 ad-hoc 签名即可。

## 说明

该 iOS 客户端当前直接走原生相机采集与 `libcimbar` 解码链路，接收完成后将文件落到 `Documents/CimbarTransfer/Inbox`（可在系统「文件」App 中浏览），并通过系统分享面板导出。旧版本写入的 `Library/Caches/CimbarTransfer/ReceivedFiles` 会在启动时自动迁移。

上游 `src/lib/cimbar_js/cimbar_recv_js.cpp` 为 iOS 做了两处适配：
`sync_thread_config()`（`Config::active_conf` 是 thread_local，GCD 队列不保证线程固定）
与按模式缓存的 `Decoder`（避免每帧重建、重复解码符号 tile）。
Debug 配置下原生解码链以 `-O2` 编译（Swift 保持 `-Onone`），否则真机调试时扫码性能严重失真。
