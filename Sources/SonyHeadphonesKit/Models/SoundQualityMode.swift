import Foundation

/// Bluetooth connection preference reported by the AUDIO quality parameter.
/// This is a preference, not a report of the active Bluetooth codec.
public enum SoundQualityMode: UInt8, CaseIterable, Sendable, Identifiable {
    case quality = 0x00
    case stable = 0x01
    case lowLatency = 0x02

    public var id: UInt8 { rawValue }

    public var label: String {
        switch self {
        case .quality: return "Prioritize Sound Quality"
        case .stable: return "Prioritize Stable Connection"
        case .lowLatency: return "Prioritize Low Latency"
        }
    }

    public var commandValue: String {
        switch self {
        case .quality: return "quality"
        case .stable: return "stable"
        case .lowLatency: return "low-latency"
        }
    }
}
