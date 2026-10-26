import SwiftUI

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case dateDescending
    case dateAscending
    case nameAscending
    case sizeDescending

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateDescending: return String(localized: "最新优先")
        case .dateAscending:  return String(localized: "最早优先")
        case .nameAscending:  return String(localized: "名称")
        case .sizeDescending: return String(localized: "大小")
        }
    }

    var symbol: String {
        switch self {
        case .dateDescending: return "arrow.down"
        case .dateAscending:  return "arrow.up"
        case .nameAscending:  return "textformat"
        case .sizeDescending: return "internaldrive"
        }
    }

    var isByDate: Bool {
        self == .dateDescending || self == .dateAscending
    }
}

/// 按接收日期分组的列表分段
private struct LibrarySection: Identifiable {
    let id: String
    let title: String?
    let files: [CachedReceivedFile]
}

struct LibraryScreen: View {
    @ObservedObject var store: ReceivedFileCacheStore
    let onShareFiles: ([URL]) -> Void
    let onPreviewFiles: ([URL], Int) -> Void
    /// 在此之后收到的文件标为新文件
    let newSince: Date
    let onGoToScan: () -> Void

    @AppStorage("org.cimbar.library-sort") private var sortOption: LibrarySortOption = .dateDescending
    @State private var searchText = ""
    @State private var renameTarget: CachedReceivedFile?
    @State private var renameText: String = ""
    @State private var deleteTarget: CachedReceivedFile?
    @State private var isSelecting: Bool = false
    @State private var selectedIDs: Set<String> = []
    @State private var bulkDeleteConfirm = false
    @State private var saveToast: SaveToast?
    @State private var photoPermissionAlert = false
    @State private var detailTarget: CachedReceivedFile?

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredFiles: [CachedReceivedFile] {
        let query = trimmedSearch
        let base: [CachedReceivedFile]
        if query.isEmpty {
            base = store.cachedFiles
        } else {
            base = store.cachedFiles.filter { file in
                file.displayName.localizedCaseInsensitiveContains(query)
                    || file.fileName.localizedCaseInsensitiveContains(query)
            }
        }
        return sorted(base)
    }

    private func sorted(_ files: [CachedReceivedFile]) -> [CachedReceivedFile] {
        switch sortOption {
        case .dateDescending: return files.sorted { $0.receivedAt > $1.receivedAt }
        case .dateAscending:  return files.sorted { $0.receivedAt < $1.receivedAt }
        case .nameAscending:  return files.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .sizeDescending: return files.sorted { $0.fileSize > $1.fileSize }
        }
    }

    /// 按日期排序时分成「今天 / 昨天 / 近 7 天 / 更早」，其余排序不分组
    private func sections(for files: [CachedReceivedFile]) -> [LibrarySection] {
        guard sortOption.isByDate, trimmedSearch.isEmpty else {
            return [LibrarySection(id: "all", title: nil, files: files)]
        }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        func bucket(_ date: Date) -> Int {
            if calendar.isDateInToday(date) { return 0 }
            if calendar.isDateInYesterday(date) { return 1 }
            if date >= weekAgo { return 2 }
            return 3
        }
        let titles = [
            String(localized: "今天"),
            String(localized: "昨天"),
            String(localized: "近 7 天"),
            String(localized: "更早"),
        ]
        var result: [LibrarySection] = []
        for file in files {
            let index = bucket(file.receivedAt)
            if result.last?.id == "bucket-\(index)" {
                let last = result.removeLast()
                result.append(LibrarySection(id: last.id, title: last.title, files: last.files + [file]))
            } else {
                result.append(LibrarySection(id: "bucket-\(index)", title: titles[index], files: [file]))
            }
        }
        return result
    }

    private var allVisibleSelected: Bool {
        let visible = Set(filteredFiles.map(\.id))
        return !visible.isEmpty && visible.isSubset(of: selectedIDs)
    }

    private var selectedFiles: [CachedReceivedFile] {
        filteredFiles.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        content
            .modifier(LibraryAlertsModifier(
                renameTarget: $renameTarget,
                renameText: $renameText,
                deleteTarget: $deleteTarget,
                bulkDeleteConfirm: $bulkDeleteConfirm,
                selectedCount: selectedIDs.count,
                onCommitRename: commitRename,
                onCommitSingleDelete: commitSingleDelete,
                onCommitBulkDelete: commitBulkDelete
            ))
    }

    private var content: some View {
        Group {
            if store.cachedFiles.isEmpty {
                LibraryEmptyState(onGoToScan: onGoToScan)
            } else {
                fileList
            }
        }
        .overlay(alignment: .top) {
            if let toast = saveToast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.spring(duration: 0.3), value: saveToast?.id)
        .navigationTitle("我的文件")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: Binding(
            get: { detailTarget != nil },
            set: { if !$0 { detailTarget = nil } }
        )) {
            if let target = detailTarget {
                FileDetailScreen(
                    store: store,
                    initialFile: target,
                    onShare: { onShareFiles([$0]) },
                    onPreview: { onPreviewFiles([$0], 0) }
                )
            }
        }
        .modifier(LibrarySearchModifier(isEnabled: !store.cachedFiles.isEmpty, text: $searchText))
        .toolbar { toolbarContent }
        .refreshable {
            store.refresh(cleanup: false)
        }
        .onChange(of: store.feedback) { feedback in
            guard let feedback, feedback.source == .delete else { return }
            presentToast(SaveToast(message: feedback.message, style: .failure))
            store.clearFeedback()
        }
        .onChange(of: store.cachedFiles) { files in
            // 已被删除的文件不能还算在选中项里，否则底栏计数与批量操作对不上
            let present = Set(files.map(\.id))
            selectedIDs.formIntersection(present)
            if files.isEmpty { isSelecting = false }
        }
        .alert("没能存到相册", isPresented: $photoPermissionAlert) {
            Button("去设置") { AppSettingsOpener.open() }
            Button("好", role: .cancel) {}
        } message: {
            Text("请在设置中允许萤传添加照片")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allVisibleSelected ? "取消全选" : "全选") {
                    if allVisibleSelected {
                        selectedIDs.subtract(filteredFiles.map(\.id))
                    } else {
                        selectedIDs.formUnion(filteredFiles.map(\.id))
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { endSelection() }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    onShareFiles(selectedFiles.map(\.url))
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享所选文件")
                .disabled(selectedIDs.isEmpty)

                Spacer()
                Text(selectedIDs.isEmpty ? String(localized: "选择文件") : String(localized: "已选 \(selectedIDs.count) 个"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()

                Button(role: .destructive) {
                    bulkDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除所选文件")
                .disabled(selectedIDs.isEmpty)
            }
        } else if !store.cachedFiles.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        withAnimation { isSelecting = true }
                    } label: {
                        Label("选择", systemImage: "checkmark.circle")
                    }
                    Section("排序") {
                        Picker("排序", selection: $sortOption) {
                            ForEach(LibrarySortOption.allCases) { option in
                                Label(option.displayName, systemImage: option.symbol).tag(option)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
    }

    private var fileList: some View {
        let files = filteredFiles
        let sections = sections(for: files)
        return List {
            if files.isEmpty {
                SearchEmptyRow(query: trimmedSearch)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.files) { file in
                        row(for: file, in: files)
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                    }
                } footer: {
                    if section.id == sections.last?.id, trimmedSearch.isEmpty {
                        Text(store.cacheSummary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: sortOption)
        .readableListWidth()
    }

    private func row(for file: CachedReceivedFile, in files: [CachedReceivedFile]) -> some View {
        Button {
            if isSelecting {
                toggleSelection(for: file.id)
            } else if let index = files.firstIndex(of: file) {
                // 传入当前列表，预览里可以左右滑动看相邻文件
                onPreviewFiles(files.map(\.url), index)
            }
        } label: {
            LibraryRow(
                file: file,
                isNew: file.receivedAt > newSince,
                isSelecting: isSelecting,
                isSelected: selectedIDs.contains(file.id),
                onDetail: { detailTarget = file }
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(isSelecting ? "轻点切换选中" : "轻点预览")
        .accessibilityAddTraits(isSelecting && selectedIDs.contains(file.id) ? [.isSelected] : [])
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelecting {
                Button(role: .destructive) {
                    deleteTarget = file
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    onShareFiles([file.url])
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isSelecting, PhotoLibrarySaver.canSave(extension: file.fileExtension) {
                Button {
                    Task { await saveImageToPhotos(file) }
                } label: {
                    Label("存到相册", systemImage: "photo.on.rectangle")
                }
                .tint(.pink)
            }
        }
        .modifier(FileContextMenu(file: file, isEnabled: !isSelecting) {
            Button {
                onShareFiles([file.url])
            } label: { Label("分享", systemImage: "square.and.arrow.up") }
            if PhotoLibrarySaver.canSave(extension: file.fileExtension) {
                Button {
                    Task { await saveImageToPhotos(file) }
                } label: { Label("存到相册", systemImage: "photo.on.rectangle") }
            }
            Button {
                beginRename(file)
            } label: { Label("重命名", systemImage: "pencil") }
            Button {
                detailTarget = file
            } label: { Label("简介", systemImage: "info.circle") }
            Divider()
            Button(role: .destructive) {
                deleteTarget = file
            } label: { Label("删除", systemImage: "trash") }
        })
    }

    private func toggleSelection(for id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func endSelection() {
        withAnimation {
            isSelecting = false
            selectedIDs.removeAll()
        }
    }

    private func beginRename(_ file: CachedReceivedFile) {
        renameTarget = file
        renameText = file.renameStem
    }

    private func commitRename() {
        defer { renameTarget = nil }
        guard let file = renameTarget else { return }
        store.rename(file: file, to: renameText) { renamed in
            // 空名/非法名/移动失败不能无声无息——弹窗已关，用 toast 告知
            if renamed == nil {
                presentToast(SaveToast(message: String(localized: "没能重命名，换个名称试试"), style: .failure))
            }
        }
    }

    private func commitSingleDelete() {
        defer { deleteTarget = nil }
        guard let file = deleteTarget else { return }
        store.deleteFiles(ids: [file.id])
    }

    private func commitBulkDelete() {
        store.deleteFiles(ids: selectedIDs)
        endSelection()
    }

    @MainActor
    private func saveImageToPhotos(_ file: CachedReceivedFile) async {
        do {
            try await PhotoLibrarySaver.save(fileURL: file.url)
            presentToast(SaveToast(message: String(localized: "已存到相册"), style: .success))
        } catch {
            // 权限被拒用 alert 给「去设置」补救入口；瞬时 toast 无法承载操作
            if PhotoLibrarySaver.isPermissionDenied(error) {
                photoPermissionAlert = true
                return
            }
            let message = (error as? LocalizedError)?.errorDescription ?? String(localized: "保存失败")
            presentToast(SaveToast(message: message, style: .failure))
        }
    }

    @MainActor
    private func presentToast(_ toast: SaveToast) {
        saveToast = toast
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run {
                if saveToast?.id == toast.id {
                    saveToast = nil
                }
            }
        }
    }
}

/// 没有文件时不显示搜索框：对空列表搜索没有意义
private struct LibrarySearchModifier: ViewModifier {
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

private struct ToastView: View {
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

private struct LibraryRow: View {
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

private struct SearchEmptyRow: View {
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

private struct LibraryEmptyState: View {
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

private struct LibraryAlertsModifier: ViewModifier {
    @Binding var renameTarget: CachedReceivedFile?
    @Binding var renameText: String
    @Binding var deleteTarget: CachedReceivedFile?
    @Binding var bulkDeleteConfirm: Bool
    let selectedCount: Int
    let onCommitRename: () -> Void
    let onCommitSingleDelete: () -> Void
    let onCommitBulkDelete: () -> Void

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
            .alert("删除这个文件？", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )) {
                Button("删除", role: .destructive, action: onCommitSingleDelete)
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                if let target = deleteTarget {
                    Text("「\(target.displayName)」删除后无法恢复。")
                }
            }
            .confirmationDialog("删除 \(selectedCount) 个文件？", isPresented: $bulkDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive, action: onCommitBulkDelete)
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后无法恢复。")
            }
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
private struct FileContextMenu<MenuItems: View>: ViewModifier {
    let file: CachedReceivedFile
    let isEnabled: Bool
    @ViewBuilder let menuItems: () -> MenuItems

    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else if ThumbnailLoader.supports(fileExtension: file.fileExtension) {
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
