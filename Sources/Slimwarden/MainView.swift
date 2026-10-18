import SlimwardenCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } content: {
            ItemListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let item = model.selectedItem {
                ItemDetailView(item: item)
                    .id(item.id)
            } else {
                Text("No item selected").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search vault")
        .sheet(item: $model.editing) { request in
            EditItemView(request: request)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(CipherType.allCases, id: \.self) { type in
                        Button { model.startCreating(type) } label: { Label(type.title, systemImage: type.symbol) }
                    }
                } label: {
                    Label("New", systemImage: "plus")
                } primaryAction: {
                    model.startCreating()
                }
                Button { openWindow(id: "generator") } label: { Label("Generator", systemImage: "wand.and.stars") }
                Button { model.lock() } label: { Label("Lock", systemImage: "lock") }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.filter }, set: { model.filter = $0 ?? .all })) {
            Section {
                row(.all, "All items", "tray.full")
                row(.favorites, "Favorites", "star")
                row(.totp, "One-time password", "clock.badge.checkmark")
            }
            Section("Types") {
                ForEach(CipherType.allCases, id: \.self) { type in
                    if model.count(.type(type)) > 0 { row(.type(type), type.title, type.symbol) }
                }
            }
            Section {
                ForEach(model.folders) { folder in
                    row(.folder(folder.id), folder.name, "folder")
                        .contextMenu {
                            Button("Rename…") { folderName = folder.name; renaming = folder }
                            Button("Delete…", role: .destructive) { deleting = folder }
                        }
                }
                row(.noFolder, "No folder", "folder.badge.minus")
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { folderName = ""; creatingFolder = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New folder")
                }
            }
            Section {
                row(.trash, "Trash", "trash")
            }
        }
        .safeAreaInset(edge: .bottom) { SyncStatusView().padding(10) }
        .alert("New folder", isPresented: $creatingFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { model.createFolder(folderName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $folderName)
            Button("Rename") { if let renaming { model.renameFolder(renaming, to: folderName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete folder “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Folder", role: .destructive) { if let deleting { model.deleteFolder(deleting) } }
        } message: {
            let count = deleting.map { model.count(.folder($0.id)) } ?? 0
            Text(count == 0 ? "The folder is empty." : "Its \(count) items will move to “No folder”. Items are not deleted.")
        }
    }

    @State private var creatingFolder = false
    @State private var renaming: Folder?
    @State private var deleting: Folder?
    @State private var folderName = ""

    private func row(_ filter: SidebarFilter, _ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .badge(model.count(filter))
            .tag(filter)
    }
}

struct SyncStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if model.syncing {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            } else if model.offline {
                Image(systemName: "icloud.slash").foregroundStyle(.orange)
                Text("Offline · cached")
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                if let date = model.lastSync {
                    Text("Synced \(date, format: .relative(presentation: .named))")
                } else {
                    Text("Up to date")
                }
            }
            Spacer()
            Button { Task { await model.sync() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.syncing)
                .help("Sync now (⌘R)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct ItemListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.visibleItems
        List(selection: $model.selection) {
            ForEach(items) { item in
                ItemRow(item: item)
                    .tag(item.id)
                    .contextMenu { ItemActions(item: item) }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "No items" : "No results",
                                       systemImage: model.search.isEmpty ? "tray" : "magnifyingglass")
            }
        }
        .navigationTitle("\(items.count) items")
        .onChange(of: model.search) {
            // Keep the first match selected so ⇧⌘C works right after typing.
            if !model.search.isEmpty, let first = model.visibleItems.first,
               !model.visibleItems.contains(where: { $0.id == model.selection }) {
                model.selection = first.id
            }
        }
    }
}

struct ItemRow: View {
    let item: VaultItem

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(item: item, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !item.totp.isEmpty {
                Image(systemName: "clock").foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ItemActions: View {
    @Environment(AppModel.self) private var model
    let item: VaultItem

    var body: some View {
        if !item.username.isEmpty { Button("Copy Username") { model.copy(item.username) } }
        if !item.password.isEmpty { Button("Copy Password") { model.copy(item.password) } }
        if let totp = TOTP(item.totp) { Button("Copy One-Time Code") { model.copy(totp.code()) } }
        if let uri = item.uris.first { Button("Copy URL") { model.copy(uri) } }
        Divider()
        if item.deletedDate == nil {
            Button(item.favorite ? "Unpin from Favorites" : "Pin to Favorites") { model.toggleFavorite(item) }
            Menu("Move to Folder") {
                Button("No folder") { model.move(item, to: nil) }.disabled(item.folderId == nil)
                Divider()
                ForEach(model.folders) { folder in
                    Button(folder.name) { model.move(item, to: folder.id) }.disabled(item.folderId == folder.id)
                }
            }
            Button("Edit") { model.startEditing(item) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(item) }
        } else {
            Button("Restore") { model.restore(item) }
        }
    }
}
