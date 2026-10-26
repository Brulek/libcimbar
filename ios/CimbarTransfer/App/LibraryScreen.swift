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
        case .nameAscending:  return "abc"
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
    @State private var isSelecting: Bool = false
    @State private var selectedIDs: Set<String> = []
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
            .modifier(RenameAlertModifier(
                renameTarget: $renameTarget,
                renameText: $renameText,
                onCommitRename: commitRename
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
        .safeAreaInset(edge: .bottom) {
            if let pending = store.pendingDeletion {
                UndoBar(message: pending.message) {
                    withAnimation { store.undoPendingDeletion() }
                }
                .id(pending.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: store.pendingDeletion?.id)
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
        // 多选时底部是操作栏；iOS 26 的悬浮标签栏会和它挤在同一行、挡住中间的按钮，
        // 和「照片」「文件」一样选择期间收起标签栏
        .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
        .refreshable {
            store.refresh(cleanup: false)
        }
        .onChange(of: store.feedback) { feedback in
            guard let feedback, feedback.source == .delete else { return }
            presentToast(SaveToast(message: feedback.message, style: .failure))
            store.clearFeedback()
        }
        #if DEBUG
        .onChange(of: store.cachedFiles.first?.id) { _ in
            if DemoContent.opensDetail, detailTarget == nil {
                detailTarget = sorted(store.cachedFiles).first
            }
        }
        #endif
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

                if selectedFiles.contains(where: { PhotoLibrarySaver.canSave(extension: $0.fileExtension) }) {
                    Button {
                        Task { await saveSelectedToPhotos() }
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .accessibilityLabel("把所选照片和视频存到相册")
                }

                Spacer()
                Text(selectedIDs.isEmpty ? String(localized: "选择文件") : String(localized: "已选 \(selectedIDs.count) 个"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Spacer()

                Button(role: .destructive) {
                    deleteSelected()
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
                    delete(file)
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
            if TextClipboard.canCopy(fileExtension: file.fileExtension, size: file.fileSize) {
                Button {
                    if TextClipboard.copy(file.url) {
                        presentToast(SaveToast(message: String(localized: "已复制文字"), style: .success))
                    }
                } label: { Label("复制文字", systemImage: "doc.on.doc") }
            }
            Button {
                beginRename(file)
            } label: { Label("重命名", systemImage: "pencil") }
            Button {
                detailTarget = file
            } label: { Label("简介", systemImage: "info.circle") }
            Divider()
            Button(role: .destructive) {
                delete(file)
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

    // 不再弹确认框：先从列表移走，底部给几秒「撤销」
    private func delete(_ file: CachedReceivedFile) {
        withAnimation {
            store.deleteWithUndo(ids: [file.id], message: String(localized: "已删除「\(file.displayName)」"))
        }
    }

    private func deleteSelected() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        withAnimation {
            store.deleteWithUndo(ids: ids, message: String(localized: "已删除 \(ids.count) 个文件"))
        }
        endSelection()
    }

    /// 多选里只存图片/视频，其余类型跳过；一次权限申请，逐个写入
    @MainActor
    private func saveSelectedToPhotos() async {
        let media = selectedFiles.filter { PhotoLibrarySaver.canSave(extension: $0.fileExtension) }
        var saved = 0
        for file in media {
            do {
                try await PhotoLibrarySaver.save(fileURL: file.url)
                saved += 1
            } catch {
                if PhotoLibrarySaver.isPermissionDenied(error) {
                    photoPermissionAlert = true
                    return
                }
            }
        }
        let failed = media.count - saved
        presentToast(SaveToast(
            message: failed == 0
                ? String(localized: "已存 \(saved) 个到相册")
                : String(localized: "已存 \(saved) 个，\(failed) 个没能存入"),
            style: failed == 0 ? .success : .failure
        ))
        if failed == 0 { endSelection() }
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
