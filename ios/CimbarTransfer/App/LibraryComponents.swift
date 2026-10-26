import SwiftUI

// 「我的文件」用到的行、空状态、提示条和长按菜单

/// 没有文件时不显示搜索框：对空列表搜索没有意义
struct LibrarySearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索")
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.style == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.style == .success ? Color.green : Color.orange)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
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
    var onDetail: (() -> Void)?

    @ScaledMetric(relativeTo: .body) private var thumbnailSide: CGFloat = 46

    /// 今天/昨天收到的只显示时间（分组标题已经说明了日期），更早的显示日期
    private var dateText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(file.receivedAt) || calendar.isDateInYesterday(file.receivedAt) {
            return file.receivedAt.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(file.receivedAt, equalTo: Date(), toGranularity: .year) {
            return file.receivedAt.formatted(.dateTime.month(.abbreviated).day())
        }
        return file.receivedAt.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            FileThumbnailView(
                url: file.url,
                cacheKey: "row-\(file.fileName)-\(file.modifiedAt.timeIntervalSince1970)",
                cornerRadius: 10
            )
            .frame(width: thumbnailSide, height: thumbnailSide)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isNew {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("新")
                    }
                    // 中间截断：长文件名也能看到扩展名
                    Text(file.displayName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("\(file.sizeDescription) · \(dateText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if !isSelecting, let onDetail {
                // 行点按是「预览」；简介页需要一个显式可见的入口，
                // 不能只藏在长按菜单里（chevron 的导航语义与预览行为矛盾）
                Button(action: onDetail) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("简介")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isSelecting)
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
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Brand.glow.opacity(0.25), radius: 16, y: 4)
                .accessibilityHidden(true)
            Text("还没有收到文件")
                .font(.title3.weight(.semibold))
                .padding(.top, 6)
            Text("扫描别人屏幕上的动画码，收到的文件会出现在这里。")
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("撤销", action: onUndo)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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

/// 长按菜单。图片/视频/PDF 带大图预览，其余类型用系统默认的行预览
struct FileContextMenu<MenuItems: View>: ViewModifier {
    let file: CachedReceivedFile
    let isEnabled: Bool
    @ViewBuilder let menuItems: () -> MenuItems

    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else if ThumbnailLoader.supportsLargePreview(fileExtension: file.fileExtension) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileThumbnailView(
                url: file.url,
                cacheKey: "preview-\(file.fileName)-\(file.modifiedAt.timeIntervalSince1970)",
                cornerRadius: 0,
                generationSide: 600
            )
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
    }
}
