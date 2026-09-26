import BluetoothInspectorKit
import SwiftUI

/// Local name, favorite, notes and "forget" for a device.
struct DeviceNotesView: View {
    @Environment(AppModel.self) private var model
    let id: DeviceID
    @State private var customName = ""
    @State private var notes = ""
    @State private var confirmForget = false

    var body: some View {
        let workspace = model.workspace
        let saved = workspace.history[id]
        Form {
            Section {
                TextField("Local Name", text: $customName, prompt: Text(saved?.name ?? workspace.device(id)?.name ?? "Unnamed"))
                    .onSubmit { workspace.rename(id, to: customName) }
                Toggle("Favorite", isOn: Binding(get: { saved?.isFavorite ?? false }, set: { workspace.setFavorite(id, $0) }))
            } header: {
                Text("Saved Device")
            } footer: {
                Text("The local name is only stored on this Mac and never written to the device.")
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
            }

            if let saved {
                Section("History") {
                    InfoRow("First Seen", DisplayFormatting.dateTime(saved.firstSeen))
                    InfoRow("Last Seen", DisplayFormatting.dateTime(saved.lastSeen))
                    InfoRow("Transport", saved.transport.longTitle)
                    InfoRow("Manufacturer", saved.manufacturer ?? "—")
                    InfoRow("Known Services", saved.knownServices.map(\.displayName).joined(separator: ", "))
                }
                Section {
                    Button("Forget This Device…", role: .destructive) { confirmForget = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            customName = saved?.customName ?? ""
            notes = saved?.notes ?? ""
        }
        .onChange(of: notes) {
            guard notes != (workspace.history[id]?.notes ?? "") else { return }
            workspace.setNotes(id, notes)
        }
        .onDisappear {
            if customName != (workspace.history[id]?.customName ?? "") { workspace.rename(id, to: customName) }
        }
        .confirmationDialog("Forget this device?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) {
                workspace.forget(id)
                customName = ""
                notes = ""
            }
        } message: {
            Text("Removes the local name, notes, favorite status and history for this device. The device itself is not affected.")
        }
    }
}
