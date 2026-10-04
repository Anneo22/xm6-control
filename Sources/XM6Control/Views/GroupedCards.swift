import SwiftUI

/// Sound-shaping controls on one surface. Listening mode and the equalizer both
/// answer "how should this sound", so grouping them keeps the dashboard from
/// reading as an undifferentiated stack of panels.
struct SoundCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                ListeningModeSection()
                Divider()
                EqualizerSection()
                Divider()
                CardSection("Bluetooth Quality", icon: "antenna.radiowaves.left.and.right") {
                    VStack(alignment: .leading, spacing: 8) {
                        SoundQualityPicker()
                        Text("Changing this may briefly interrupt audio.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Set-once preferences on one surface, ranked below the controls above them.
struct BehaviorCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SpeakToChatSection()
                Divider()
                WearDetectionSection()
            }
        }
    }
}
