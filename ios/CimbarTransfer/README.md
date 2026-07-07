# CimbarTransfer (iOS)

这是一个面向 `libcimbar` 的 iOS 接收端客户端：

- 通过相机扫描 `cimbar` 动画码
- 使用原生 `libcimbar` 解码链路重组文件
- 解码后在 iOS 原生侧落盘并调用系统分享

## 目录

- `App/`: SwiftUI 应用代码、原生扫码流程、文件缓存与分享逻辑
- `project.yml`: XcodeGen 项目描述

## 本地生成工程并运行

```bash
cd ios/CimbarTransfer
xcodegen generate
open CimbarTransfer.xcodeproj
```

1. 打开工程后选择真机运行（建议 iPhone）。
2. 首次启动允许相机权限。
3. 对准发送端屏幕，解码完成后点击“分享文件”。

## 构建命令（CLI）

```bash
cd ios/CimbarTransfer
xcodegen generate
xcodebuild -project CimbarTransfer.xcodeproj -scheme CimbarTransfer -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## 说明

该 iOS 客户端当前直接走原生相机采集与 `libcimbar` 解码链路，接收完成后将文件落到 `Documents/CimbarTransfer/Inbox`（可在系统「文件」App 中浏览），并通过系统分享面板导出。旧版本写入的 `Library/Caches/CimbarTransfer/ReceivedFiles` 会在启动时自动迁移。
