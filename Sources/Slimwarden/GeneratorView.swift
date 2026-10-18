import SlimwardenCore
import SwiftUI

struct GeneratorView: View {
    @Environment(AppModel.self) private var model
    @State private var current = ""

    var body: some View {
        @Bindable var model = model
        if model.phase != .unlocked {
            ContentUnavailableView("Vault is locked", systemImage: "lock",
                                   description: Text("Unlock the vault to use the generator and its history."))
        } else {
            Form {
                Section {
                    HStack {
                        Text(current)
                            .font(.title3.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { current = model.generate() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Regenerate")
                        Button { model.copy(current); model.recordGenerated(current) } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy")
                    }
                    .buttonStyle(.borderless)
                }
                Section {
                    LabeledContent("Length: \(model.generatorOptions.length)") {
                        Slider(value: Binding(get: { Double(model.generatorOptions.length) },
                                              set: { model.generatorOptions.length = Int($0) }),
                               in: 6...64, step: 1)
                    }
                    Toggle("A–Z", isOn: $model.generatorOptions.uppercase)
                    Toggle("a–z", isOn: $model.generatorOptions.lowercase)
                    Toggle("0–9", isOn: $model.generatorOptions.digits)
                    Toggle("!@#$%^&*", isOn: $model.generatorOptions.symbols)
                    Toggle("Avoid ambiguous characters", isOn: $model.generatorOptions.avoidAmbiguous)
                }
                Section {
                    if model.generatorHistory.isEmpty {
                        Text("Nothing generated yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.generatorHistory) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.value).font(.body.monospaced()).textSelection(.enabled).lineLimit(1)
                                Text(entry.date, format: .dateTime.day().month().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { model.copy(entry.value) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    HStack {
                        Text("History")
                        Spacer()
                        if !model.generatorHistory.isEmpty {
                            Button("Clear") { model.clearGeneratorHistory() }.buttonStyle(.link)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { if current.isEmpty { current = model.generate() } }
            .onChange(of: model.generatorOptions) {
                current = PasswordGenerator.generate(model.generatorOptions)
                model.persistGenerator()
            }
        }
    }
}
