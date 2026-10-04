import SwiftUI
import SonyHeadphonesKit

struct SoundQualityPicker: View {
    @EnvironmentObject private var controller: HeadphonesController

    var body: some View {
        if let current = controller.soundQuality,
           let modes = controller.supportedSoundQualityModes, modes.contains(current) {
            Picker("Quality", selection: Binding(
                get: { controller.soundQuality ?? current },
                set: { controller.setSoundQuality($0) }
            )) {
                ForEach(modes.filter(\.canWriteLocally)) { mode in Text(mode.label).tag(mode) }
                if !current.canWriteLocally {
                    Text("\(current.label) (read only)").tag(current).disabled(true)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Bluetooth sound quality")
        } else {
            HStack {
                Text("Quality not reported").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Read") { controller.refreshSoundQuality() }
                    .controlSize(.small)
            }
        }
    }
}
