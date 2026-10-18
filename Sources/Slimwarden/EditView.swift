import SlimwardenCore
import SwiftUI

struct EditItemView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var request: AppModel.EditRequest
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if request.original == nil {
                        Picker("Type", selection: typeBinding) {
                            ForEach(CipherType.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    TextField("Name", text: $request.draft.name)
                    Picker("Folder", selection: $request.draft.folderId) {
                        Text("No folder").tag(String?.none)
                        ForEach(model.folders) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Toggle("Pin to favorites", isOn: $request.draft.favorite)
                }

                let defs = request.draft.type.fields
                if !defs.isEmpty {
                    Section {
                        ForEach(defs) { def in
                            EditFieldRow(def: def, value: valueBinding(def.key)) {
                                let value = model.generate()
                                model.recordGenerated(value)
                                request.draft.values[def.key] = value
                            }
                        }
                    }
                }

                if request.draft.type == .login {
                    Section("Websites") {
                        ForEach(request.draft.uris.indices, id: \.self) { i in
                            HStack {
                                TextField("URL", text: $request.draft.uris[i], prompt: Text("https://example.com"))
                                Button { request.draft.uris.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        Button("Add website") { request.draft.uris.append("") }
                    }
                }

                Section("Custom fields") {
                    ForEach($request.draft.fields) { $field in
                        HStack {
                            TextField("Name", text: $field.name).frame(maxWidth: 160)
                            if field.type == .linked {
                                Text("Linked field").foregroundStyle(.secondary)
                            } else if field.type == .boolean {
                                Toggle("", isOn: Binding(get: { field.value == "true" },
                                                         set: { field.value = $0 ? "true" : "false" }))
                            } else {
                                TextField("Value", text: $field.value)
                                    .font(field.type == .hidden ? .body.monospaced() : .body)
                            }
                            Picker("", selection: $field.type) {
                                ForEach(CipherType.customFieldTypes, id: \.self) { Text($0.title).tag($0) }
                            }
                            .frame(width: 100)
                            .disabled(field.type == .linked)
                            Button { request.draft.fields.removeAll { $0.id == field.id } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add field") { request.draft.fields.append(CustomField(name: "", value: "", type: .text)) }
                }

                Section("Notes") {
                    TextEditor(text: $request.draft.notes)
                        .font(.body)
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let original = request.original, original.passkeyCount > 0 || original.attachmentCount > 0 {
                    Text("Passkeys and attachments are kept as-is").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    saving = true
                    Task {
                        if await model.save(request) { dismiss() }
                        saving = false
                    }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(saving)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 640)
    }

    private var typeBinding: Binding<CipherType> {
        Binding(get: { request.draft.type }, set: { type in
            request.draft.type = type
            request.draft.uris = type == .login ? (request.draft.uris.isEmpty ? [""] : request.draft.uris) : []
        })
    }

    private func valueBinding(_ key: String) -> Binding<String> {
        Binding(get: { request.draft.values[key] ?? "" }, set: { request.draft.values[key] = $0 })
    }
}

extension CipherType {
    static let customFieldTypes: [CustomFieldType] = [.text, .hidden, .boolean, .linked]
}

struct EditFieldRow: View {
    let def: FieldDef
    @Binding var value: String
    let generate: () -> Void
    @State private var revealed = false

    var body: some View {
        HStack {
            if def.kind.isMultiline {
                VStack(alignment: .leading) {
                    Text(def.label).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $value).font(.body.monospaced()).frame(minHeight: 60)
                }
            } else if def.kind == .hidden && !revealed {
                SecureField(def.label, text: $value)
            } else {
                TextField(def.label, text: $value)
                    .font(def.kind == .hidden || def.kind == .totp ? .body.monospaced() : .body)
            }
            if def.kind == .hidden {
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
            }
            if def.key == "password" {
                Button(action: generate) { Image(systemName: "wand.and.stars") }
                    .buttonStyle(.borderless)
                    .help("Generate password")
            }
        }
    }
}
