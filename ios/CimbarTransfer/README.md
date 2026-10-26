# CimbarTransfer / 萤传 (iOS)

这是一个面向 `libcimbar` 的 iOS 接收端客户端：

- 通过相机扫描 `cimbar` 动画码（发送端：<https://cimbar.org>）
- 使用原生 `libcimbar` 解码链路重组文件
- 解码后在 iOS 原生侧落盘并调用系统分享

## 功能

**扫码页**
- 自动识别发送端模式（B / Bm / Bu / 4C）：逐帧轮换候选模式，解出数据即锁定，顶部显示「自动 · B」；
  传输中途解不出数据约 3 秒后，每隔几帧用别的模式试一帧（不动已有进度），发送端中途换模式也能跟上
- 手电筒、1×/2× 快速变焦（也可捏合，双击复位）、轻点对焦
- 底部面板一次只说一件事：等待 → 接收中（百分比、剩余时间）→ 动画码离开取景框 → 出错重扫 → 完成
- 取景框边线随进度点亮（绿=在读、琥珀=码不在、橙=停滞），与底部进度条同色
- 码离开取景框时进度保留；停滞 5s/12s 分级提示
- 完成卡片：预览 / 存相册（照片视频）或复制文字（小文本）或存到文件（其他）/ 分享 / 继续接收，显示用时；接收完成即暂停解码链省电。压缩包不给「预览」（系统预览只有图标），只有一个网址的文本第一个按钮是「打开链接」
- 收到图片 / 视频 / PDF 后，打勾动画结束会把缩略图放进取景框（文档保留页面顶部），点一下即预览；小文本直接把开头几段文字显示在取景框里，单行短文字居中放大
- 收到小文本文件（txt/md/csv/json 等，≤512 KB）可一键「复制文字」，UTF-8、UTF-16、GB18030 都能读
- 同一次传输再收一遍（点「继续接收」时发送端还在放同一个文件）不另存副本，复用已保存的文件
- 空闲自动暂停：90 秒没扫到码（传输中断 5 分钟、收完 45 秒）关相机、恢复自动锁屏，点「继续扫描」恢复
- 「怎么发送文件」说明页，可复制或分享 cimbar.org 网址
- 相机被其他 App 占用、设备过热时在面板上说明原因；媒体服务重置后自动重启
- 适配「减弱动态效果」、动态字体（大字号下按钮改竖排）、VoiceOver（每 25% 播报一次进度）

**我的文件**
- 按「今天 / 昨天 / 近 7 天 / 更早」分组；右上角「…」菜单里选择与排序（最新 / 最早 / 名称 / 大小 / 类型，类型按照片和视频、文档、音频、压缩包、其他分组；排序会记住）
- 标签角标只数上次打开之后收到的文件，对应的行前有圆点
- 图片/视频/PDF、Office/iWork 文档真实缩略图；长按有大图预览和菜单（含存到「文件」）；iPad 分屏时可把文件拖进别的 App；预览可左右滑动切换文件，左上角有关闭按钮
- 多选：全选、批量分享、批量存到相册、批量存到「文件」、批量删除；左滑删除/分享，右滑存到相册（图片和视频）
- 删除不弹确认框：底部 6 秒「撤销」，过时或 App 退到后台才真正删除（「清空所有文件」仍需确认）
- 简介页：大图、预览（或打开链接）/分享/存相册（或复制文字、存到文件）/重命名、类型/大小/接收时间、开了自动清理时的删除日期、图片尺寸/音视频时长/PDF 页数、SHA-256（可复制）
- 重命名只改名字部分，扩展名自动保留并同步改磁盘文件名

**设置**
- 解码模式（默认自动识别）、高清采集（1080p）
- 提示音 / 振动 / 照片和视频自动存到相册 / 收到后自动打开「我的文件」
- 已用空间、自动清理（从不 / 30 天 / 7 天，按接收时间）、在「文件」App 中查看、清空
- 帮助：怎么发送文件、查看引导；关于页里是隐私政策、用户协议、开源许可

**其他**
- 「快捷指令」/ Spotlight / Siri / 操作按钮：「扫码接收文件」直接打开扫码页；「最近收到的文件」把最新文件交给快捷指令继续处理（Siri 短语在 `Support/*.lproj/AppShortcuts.strings`）
- 品牌琥珀色主题，iOS 26 起相机浮层用液态玻璃；iPad 上（iOS 17+）列表限制在可读宽度

## 截图

模拟器截图（中/英、深/浅色、iPhone/iPad）见 [docs/screenshots/](docs/screenshots/)。
App Store 尺寸的原图（6.9 寸 iPhone、13 寸 iPad）放在资料区 `~/Documents/Developer/CimbarTransfer/App Store截图/`。

## 目录

- `App/`: SwiftUI 应用代码、原生扫码流程、文件缓存与分享逻辑
- `Tests/`: 端到端解码自测（不是 Xcode 测试 target，见下文）
- `scripts/`: 图标生成、本地化同步、挂接新源文件、解码自测
- `project.yml`: XcodeGen 项目描述（改动 build settings 时需与 `project.pbxproj` 保持同步）

## 本地生成工程并运行

```bash
cd ios/CimbarTransfer
open CimbarTransfer.xcodeproj
```

1. 打开工程后选择真机运行（建议 iPhone）。
2. 首次启动允许相机权限。
3. 对准发送端屏幕，进度到 100% 后在完成卡片里预览或分享。

> 仓库中的 `CimbarTransfer.xcodeproj` 可直接打开；新增源文件用 `scripts/add_swift_file.py` 挂接。

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

## 本地化

界面文案以中文为源语言写在代码里，英文在 `Support/Localizable.xcstrings`。改完文案后：

```bash
# 1. 编译时打开字符串提取（模拟器 Debug）
xcodebuild -project CimbarTransfer.xcodeproj -scheme CimbarTransfer \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES build
# 2. 列出缺英文的键和不再使用的键
python3 scripts/l10n_sync.py
# 3. 写入翻译（JSON：{中文键: 英文}，复数写成 {"one":…, "other":…}），并清掉不用的键
python3 scripts/l10n_sync.py --apply en.json --prune
```

## 测试与调试

- **端到端解码自测**：`scripts/run_decode_selftest.sh`（需要一台已启动的模拟器）。用 libcimbar 自带的编码器把 24 KB 数据编成每种模式的动画码，套进 720×1280 的相机画布，交给 `NativeCimbarDecoder` 解码并逐字节核对；覆盖自动识别四种模式、手动模式、模式不匹配、拍摄质量变差（倾斜/模糊/偏暗/噪点，自动与手动所需帧数相同）、取景框里没有码不误锁、同一文件收两遍不存副本、发送端中途换模式、码离开很久再回来接着收、压缩后不到一帧的小文本四种模式都能收。`--dump-frame out.png` 可导出一帧真实动画码，`--dump-transfer` 导出整段传输给 Debug 模拟相机用。
- **Debug 启动参数**（只在 Debug 构建里生效）：
  - `-InitialTab library|settings`：初始标签
  - `-SeedDemoFiles YES`：往接收目录写几份示例文件；`-DemoNow 09:41` 让它们按今天 9:41 往前排
  - `-DemoScan waiting|receiving|lost|stalled|error|paused|done|done-text`：扫码页跳过相机直接展示某个状态；App 容器 `Library/Caches/demo-screen.png` 存在时画成取景框里的发送端屏幕
  - `-DemoFrames <目录>[:<目录>…]`：模拟相机。先用 `scripts/run_decode_selftest.sh --dump-transfer <目录> <模式值> <文件>` 把一个文件导出成整段动画码帧，App 按 15 fps 回放给真实的解码链，进度、完成、重复文件、发送端换模式都能在模拟器里走一遍；`-DemoFramesFPS 3` 调慢回放
  - `-DemoDetail YES`：直接打开最新文件的简介页
  - `-DemoUndoWindow 30`：把删除后的撤销窗口拉长到 30 秒（手动点测时用）
- **新增源文件**：`python3 scripts/add_swift_file.py Foo.swift` 把 `App/Foo.swift` 挂进工程；`--resource` 挂 `Support/` 下的资源，`--localized` 挂 `Support/<语言>.lproj/` 下的本地化文件。不要用 `xcodegen generate` 重建：会丢掉 knownRegions 里的 en，英文本地化失效。

## 说明

该 iOS 客户端当前直接走原生相机采集与 `libcimbar` 解码链路，接收完成后将文件落到 `Documents/CimbarTransfer/Inbox`（可在系统「文件」App 中浏览），并通过系统分享面板导出。旧版本写入的 `Library/Caches/CimbarTransfer/ReceivedFiles` 会在启动时自动迁移。

上游 `src/lib/cimbar_js/cimbar_recv_js.cpp` 为 iOS 做了两处适配：
`sync_thread_config()`（`Config::active_conf` 是 thread_local，GCD 队列不保证线程固定）
与按模式缓存的 `Decoder`（每种模式各缓存一个：避免每帧重建、重复解码符号 tile，
自动识别逐帧轮换模式时也不用重建）。
Debug 配置下原生解码链以 `-O2` 编译（Swift 保持 `-Onone`），否则真机调试时扫码性能严重失真。
