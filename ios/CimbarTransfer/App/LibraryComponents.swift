import SwiftUI

// 「我的文件」用到的行、空状态、提示条和长按菜单

/// 没有文件时不显示搜索框：对空列表搜索没有意义
struct LibrarySearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "文件名或内容")
        } else {
            content
        }
    }
}

struct SaveToast: Identifiable, Equatable {
    enum Style { case success, failure }
    let id = UUID()
    let message: String
    let style: Style
}

struct ToastView: View {
    let toast: SaveToast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.style == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.style == .success ? Color.green : Color.orange)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                // 大字号下两行放不下：不截，整句显示；多行时胶囊改成圆角矩形
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: dynamicTypeSize.isAccessibilitySize ? 22 : 999, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

struct LibraryRow: View {
    let file: CachedReceivedFile
    let isNew: Bool
    let isSelecting: Bool
    let isSelected: Bool
    /// 列表按日期分组时，「昨天」已经写在分组标题上
    var dayShownInHeader = false
    /// 按内容搜到时命中的那一行，和搜索词（在行里加粗）
    var contentMatch: String?
    var searchQuery = ""
    /// ⓘ 的点按区域跟着字号放大，至少 44pt
    @ScaledMetric(relativeTo: .title3) private var detailSide: CGFloat = 44

    private var highlightedMatch: AttributedString {
        var text = AttributedString(contentMatch ?? "")
        if !searchQuery.isEmpty,
           let range = text.range(of: searchQuery, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) {
            text[range].font = .footnote.weight(.semibold)
            text[range].foregroundColor = .primary
        }
        return text
    }
    /// 「今天/昨天」相对哪一天算：由列表传入，过了午夜会换，行跟着重画
    var referenceDay = Date()
    var onDetail: (() -> Void)?

    @ScaledMetric(relativeTo: .body) private var thumbnailSide: CGFloat = 46
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 今天的只显示时间；昨天的在没有日期分组时加「昨天」；更早的显示日期
    private var dateText: String {
        let calendar = Calendar.current
        let time = file.receivedAt.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(file.receivedAt, inSameDayAs: referenceDay) {
            return time
        }
        // 按名称/大小/类型排序或搜索时没有「昨天」分组标题，光写时间会被当成今天
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDay),
           calendar.isDate(file.receivedAt, inSameDayAs: yesterday) {
            return dayShownInHeader ? time : String(localized: "昨天 \(time)")
        }
        if calendar.isDate(file.receivedAt, equalTo: referenceDay, toGranularity: .year) {
            return file.receivedAt.formatted(.dateTime.month(.abbreviated).day())
        }
        return file.receivedAt.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // 辅助功能字号下缩略图和 ⓘ 放上面一行，名字和信息独占整行宽度，
                // 否则放大后的缩略图把名字挤成一行一个字（「邮件」「文件」也这样排）
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        selectionMark
                        thumbnail
                        Spacer(minLength: 0)
                        detailButton
                    }
                    details
                }
            } else {
                HStack(spacing: 12) {
                    selectionMark
                    thumbnail
                    details
                    Spacer(minLength: 0)
                    detailButton
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isSelecting)
    }

    @ViewBuilder
    private var selectionMark: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .font(.title3)
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private var thumbnail: some View {
        FileThumbnailView(
            url: file.url,
            cacheKey: "row-\(file.fileName)-\(file.modifiedAt.timeIntervalSince1970)",
            cornerRadius: 10
        )
        .frame(width: thumbnailSide, height: thumbnailSide)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isNew {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("新")
                }
                // 中间截断：长文件名也能看到扩展名。辅助功能字号下一行只剩几个字，允许折行
                Text(file.displayName)
                    .font(.body)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
            }
            Text("\(file.sizeDescription) · \(dateText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let contentMatch {
                HStack(spacing: 4) {
                    Image(systemName: "text.magnifyingglass")
                    Text(highlightedMatch)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("内容：\(contentMatch)")
            }
        }
    }

    @ViewBuilder
    private var detailButton: some View {
        if !isSelecting, let onDetail {
            // 行点按是「预览」；简介页需要一个显式可见的入口，
            // 不能只藏在长按菜单里（chevron 的导航语义与预览行为矛盾）
            Button(action: onDetail) {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: max(44, detailSide), height: max(44, detailSide))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("简介")
        }
    }
}

struct SearchEmptyRow: View {
    let query: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("没有找到“\(query)”")
                .font(.headline)
            Text("换个关键词试试")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
    }
}

struct LibraryEmptyState: View {
    let onGoToScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .accessibilityIgnoresInvertColors()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Brand.glow.opacity(0.25), radius: 16, y: 4)
                .accessibilityHidden(true)
            Text("还没有收到文件")
                .font(.title3.weight(.semibold))
                .padding(.top, 6)
            Text("扫描屏幕上的动画码，收到的文件会出现在这里。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button(action: onGoToScan) {
                Label("去扫码", systemImage: "viewfinder")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Brand.ink)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RenameAlertModifier: ViewModifier {
    @Binding var renameTarget: CachedReceivedFile?
    @Binding var renameText: String
    let onCommitRename: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("文件名", text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存", action: onCommitRename)
                    // 空名一定会失败，别让人点了再看报错
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) { renameTarget = nil }
            } message: {
                RenameHint(fileExtension: renameTarget?.fileExtension ?? "")
            }
    }
}

/// 删除后底部的「撤销」条；撤销窗口由 store 计时，这里只负责展示
struct UndoBar: View {
    let message: String
    let onUndo: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                // 大字号下一行只剩几个字：允许折三行，文件名照旧从中间省略
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("撤销", action: onUndo)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: dynamicTypeSize.isAccessibilitySize ? 22 : 999, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 16)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("撤销"), onUndo)
    }
}

/// 重命名弹窗的说明：告诉用户哪个扩展名会被保留
struct RenameHint: View {
    let fileExtension: String

    var body: some View {
        if fileExtension.isEmpty {
            Text("输入新的文件名")
        } else {
            Text("扩展名 .\(fileExtension) 会保留")
        }
    }
}

/// 长按菜单。图片/视频/PDF 带大图预览，小文本把文字摊开，其余类型用系统默认的行预览
struct FileContextMenu<MenuItems: View>: ViewModifier {
    let file: CachedReceivedFile
    let isEnabled: Bool
    @ViewBuilder let menuItems: () -> MenuItems

    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else if ThumbnailLoader.supportsLargePreview(fileExtension: file.fileExtension)
                    || TextClipboard.canCopy(fileExtension: file.fileExtension, size: file.fileSize)
                    || FileContextPreview.isZip(file) {
            content.contextMenu {
                menuItems()
            } preview: {
                FileContextPreview(file: file)
            }
        } else {
            content.contextMenu {
                menuItems()
            }
        }
    }
}

private struct FileContextPreview: View {
    let file: CachedReceivedFile
    @State private var snippet: String?
    @State private var loaded = false

    private var isText: Bool {
        TextClipboard.canCopy(fileExtension: file.fileExtension, size: file.fileSize)
    }

    /// zip 的大图预览是包里的文件列表：比一个压缩包图标有用
    static func isZip(_ file: CachedReceivedFile) -> Bool {
        file.fileExtension.lowercased() == "zip"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isText || Self.isZip(file) {
                    if loaded {
                        TextRevealPage(snippet: snippet, fileExtension: file.fileExtension, side: 300)
                    } else {
                        Color(white: 0.97)
                    }
                } else {
                    FileThumbnailView(
                        url: file.url,
                        cacheKey: "preview-\(file.fileName)-\(file.modifiedAt.timeIntervalSince1970)",
                        cornerRadius: 0,
                        generationSide: 600
                    )
                }
            }
            .frame(width: 300, height: 300)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.sizeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(width: 300)
        .task(id: file.id) {
            // 最大 512 KB、可能要猜编码，放后台读
            let url = file.url
            if Self.isZip(file) {
                snippet = await Task.detached(priority: .userInitiated) { () -> String? in
                    guard let listing = ZipListing.read(url, maxNames: 9), listing.fileCount > 0 else { return nil }
                    // 一屏放得下十行左右：列 9 个，多出来的留一行写总数
                    var lines = listing.names
                    if listing.fileCount > lines.count {
                        lines.append(String(localized: "共 \(listing.fileCount) 个文件"))
                    }
                    return lines.joined(separator: "\n")
                }.value
                loaded = true
                return
            }
            guard isText else { return }
            snippet = await Task.detached(priority: .userInitiated) { TextClipboard.snippet(url) }.value
            loaded = true
        }
    }
}
