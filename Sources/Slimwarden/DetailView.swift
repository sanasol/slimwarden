import SlimwardenCore
import SwiftUI

struct ItemDetailView: View {
    @Environment(AppModel.self) private var model
    let item: VaultItem
    @State private var confirmTrash = false
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ItemIcon(item: item, size: 44)
                    VStack(alignment: .leading) {
                        Text(item.name).font(.title2.bold()).textSelection(.enabled)
                        Text([item.type.title, model.folderName(item.folderId)].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                if item.decryptionFailed {
                    Label("Some fields could not be decrypted", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            let defs = item.type.fields.filter { !(item.values[$0.key] ?? "").isEmpty }
            if !defs.isEmpty {
                Section {
                    ForEach(defs) { def in
                        if def.kind == .totp {
                            TOTPRow(secret: item.values[def.key] ?? "")
                        } else {
                            FieldRow(label: def.label, value: item.values[def.key] ?? "", kind: def.kind)
                        }
                    }
                }
            }

            if !item.uris.isEmpty {
                Section("Websites") {
                    ForEach(Array(item.uris.enumerated()), id: \.offset) { _, uri in
                        FieldRow(label: "URL", value: uri, kind: .text, link: URL(string: uri.contains("://") ? uri : "https://\(uri)"))
                    }
                }
            }

            if !item.fields.isEmpty {
                Section("Custom fields") {
                    ForEach(item.fields) { field in
                        FieldRow(label: field.name.isEmpty ? field.type.title : field.name,
                                 value: field.type == .linked ? "Linked field" : field.value,
                                 kind: field.type == .hidden ? .hidden : .text)
                    }
                }
            }

            if !item.notes.isEmpty {
                Section("Notes") {
                    FieldRow(label: nil, value: item.notes, kind: .multiline)
                }
            }

            if !item.passwordHistory.isEmpty {
                Section {
                    DisclosureGroup("Password history (\(item.passwordHistory.count))") {
                        ForEach(item.passwordHistory) { entry in
                            FieldRow(label: entry.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "",
                                     value: entry.password, kind: .hidden)
                        }
                    }
                }
            }

            Section {
                if item.passkeyCount > 0 { LabeledContent("Passkeys", value: "\(item.passkeyCount)") }
                if item.attachmentCount > 0 { LabeledContent("Attachments", value: "\(item.attachmentCount) (open in web vault)") }
                if let d = item.revisionDate { LabeledContent("Modified", value: d.formatted(date: .long, time: .shortened)) }
                if let d = item.creationDate { LabeledContent("Created", value: d.formatted(date: .long, time: .shortened)) }
                if let d = item.deletedDate { LabeledContent("Deleted", value: d.formatted(date: .long, time: .shortened)) }
            }
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup {
                if item.deletedDate == nil {
                    Button { model.toggleFavorite(item) } label: {
                        Label(item.favorite ? "Unpin" : "Pin", systemImage: item.favorite ? "star.fill" : "star")
                    }
                    .help(item.favorite ? "Unpin from favorites" : "Pin to favorites")
                    Button { model.startEditing(item) } label: { Label("Edit", systemImage: "pencil") }
                    Button { confirmTrash = true } label: { Label("Delete", systemImage: "trash") }
                } else {
                    Button { model.restore(item) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    Button { confirmDelete = true } label: { Label("Delete permanently", systemImage: "trash.slash") }
                }
            }
        }
        .confirmationDialog("Move “\(item.name)” to trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.trash(item) }
        } message: {
            Text("You can restore it from Trash.")
        }
        .confirmationDialog("Delete “\(item.name)” permanently?", isPresented: $confirmDelete) {
            Button("Delete Permanently", role: .destructive) { model.deletePermanently(item) }
        } message: {
            Text("This cannot be undone.")
        }
    }
}

struct FieldRow: View {
    @Environment(AppModel.self) private var model
    let label: String?
    let value: String
    let kind: FieldKind
    var link: URL? = nil
    @State private var revealed = false

    var body: some View {
        HStack(alignment: kind.isMultiline ? .top : .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if let label, !label.isEmpty {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                Group {
                    if kind.isSecret && !revealed {
                        Text(String(repeating: "•", count: min(max(value.count, 8), 24)))
                    } else {
                        Text(value)
                            .font(kind == .hidden || kind == .hiddenMultiline ? .body.monospaced() : .body)
                            .textSelection(.enabled)
                    }
                }
                .lineLimit(kind.isMultiline ? nil : 1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if kind.isSecret {
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .help(revealed ? "Hide" : "Reveal")
            }
            if let link {
                Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Open in browser")
            }
            Button { model.copy(value) } label: { Image(systemName: "doc.on.doc") }
                .help("Copy")
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.copy(value) }
    }
}

struct TOTPRow: View {
    @Environment(AppModel.self) private var model
    let secret: String

    var body: some View {
        if let totp = TOTP(secret) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let code = totp.code(at: context.date)
                let remaining = totp.secondsRemaining(at: context.date)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("One-time password").font(.caption).foregroundStyle(.secondary)
                        Text(formatted(code)).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: CGFloat(remaining) / CGFloat(totp.period))
                            .stroke(remaining <= 5 ? Color.red : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(remaining)").font(.caption2.monospacedDigit())
                    }
                    .frame(width: 26, height: 26)
                    Button { model.copy(code) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy code")
                }
                .buttonStyle(.borderless)
            }
        } else {
            FieldRow(label: "One-time password (invalid secret)", value: secret, kind: .hidden)
        }
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 6 || code.count == 8, code.allSatisfy(\.isNumber) else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<mid]) \(code[mid...])"
    }
}
