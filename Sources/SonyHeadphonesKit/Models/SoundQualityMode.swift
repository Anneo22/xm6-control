import Foundation

/// Bluetooth connection preference reported by the AUDIO quality parameter.
/// This is a preference, not a report of the active Bluetooth codec.
public enum SoundQualityMode: UInt8, CaseIterable, Sendable, Identifiable {
    case quality = 0x00
    case stable = 0x01
    case lowLatency = 0x02

    public var id: UInt8 { rawValue }

    /// Keep low-latency reports readable, but expose only live-verified writes.
    /// The XM6 advertises low latency even when this control path rejects it.
    public var canWriteLocally: Bool { self != .lowLatency }

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
