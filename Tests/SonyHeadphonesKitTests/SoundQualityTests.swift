import XCTest
@testable import SonyHeadphonesKit

final class SoundQualityTests: XCTestCase {
    // Captured FW 3.1.5 payloads, independent of the command builders.
    private let capability: [UInt8] = [0xe1, 0x05, 0x03, 0x00, 0x01, 0x02, 0x00]
    private let quality: [UInt8] = [0xe7, 0x05, 0x00]

    func testCapturedReportsAndKnownNotifications() throws {
        XCTAssertEqual(SonyCommands.decodeSoundQualityCapability(capability), [.quality, .stable, .lowLatency])
        guard case .soundQualityCapability(let modes) = SonyEventDecoder.decode(payload: capability, messageType: .command1) else {
            return XCTFail("Captured capability did not produce its event")
        }
        XCTAssertEqual(modes, [.quality, .stable, .lowLatency])
        XCTAssertEqual(SonyCommands.decodeSoundQuality(quality), .quality)
        for (byte, expected): (UInt8, SoundQualityMode) in [(0, .quality), (1, .stable), (2, .lowLatency)] {
            for opcode: UInt8 in [0xe7, 0xe9] {
                let payload = opcode == 0xe7 ? [opcode, 0x05, byte] : [opcode, 0x05, byte, 0]
                XCTAssertEqual(SonyCommands.decodeSoundQuality(payload), expected)
                guard case .soundQuality(let mode) = SonyEventDecoder.decode(payload: payload, messageType: .command1) else {
                    return XCTFail("Known mode report did not produce its event")
                }
                XCTAssertEqual(mode, expected)
            }
        }
    }

    func testCapturedClassicLENotificationAndKnownSwitchingStreams() {
        // Independent FW 3.1.5 stable/quality captures. SET's trailer is not this stream field.
        XCTAssertEqual(SonyCommands.decodeSoundQuality([0xe9, 0x05, 1, 0]), .stable)
        XCTAssertEqual(SonyCommands.decodeSoundQuality([0xe9, 0x05, 0, 0]), .quality)
        for stream: UInt8 in 0...2 {
            XCTAssertEqual(SonyCommands.decodeSoundQuality([0xe9, 0x05, 2, stream]), .lowLatency)
        }
    }

    func testRejectsTruncatedUnknownAndMalformedCapabilities() {
        for length in 0..<capability.count {
            XCTAssertNil(SonyCommands.decodeSoundQualityCapability(Array(capability.prefix(length))))
        }
        let invalid: [[UInt8]] = [
            capability + [0],
            [0xe1, 0x05, 0x04, 0, 1, 2, 0], // wrong mode count
            [0xe1, 0x05, 0x03, 0, 1, 3, 0], // unknown mode
            [0xe1, 0x05, 0x03, 0, 1, 1, 0], // duplicate mode
            [0xe1, 0x05, 0x03, 0, 1, 2, 1], // missing exclusive list
            [0xe1, 0x05, 0x03, 0, 1, 2, 1, 0], // unimplemented exclusive list
            [0xe1, 0x04, 0x03, 0, 1, 2, 0],
            [0xe0, 0x05, 0x03, 0, 1, 2, 0],
        ]
        for payload in invalid {
            XCTAssertNil(SonyCommands.decodeSoundQualityCapability(payload), "\(payload)")
            XCTAssertNil(SonyEventDecoder.decode(payload: payload, messageType: .command1), "\(payload)")
        }
        // A valid empty capability means no supported modes, not invented defaults.
        XCTAssertEqual(SonyCommands.decodeSoundQualityCapability([0xe1, 0x05, 0, 0]), [])
        XCTAssertEqual(SonyCommands.decodeSoundQualityCapability([0xe1, 0x05, 1, 1, 0]), [.stable])
    }

    func testRejectsWrongOpcodeSubtypeLengthModeAndTable() {
        for length in 0..<quality.count {
            XCTAssertNil(SonyCommands.decodeSoundQuality(Array(quality.prefix(length))))
        }
        for payload: [UInt8] in [quality + [0], [0xe9, 0x05, 1], [0xe9, 0x05, 1, 3], [0xe9, 0x05, 1, 0, 0], [0xe7, 0x05, 3], [0xe7, 0x06, 0], [0xe8, 0x05, 0], [0xe3, 0x05, 0, 0]] {
            XCTAssertNil(SonyCommands.decodeSoundQuality(payload))
            XCTAssertNil(SonyEventDecoder.decode(payload: payload, messageType: .command1))
        }
        for payload in [capability, quality, [0xe9, 0x05, 1, 0]] {
            XCTAssertNil(SonyEventDecoder.decode(payload: payload, messageType: .command2))
            XCTAssertNil(SonyEventDecoder.decode(payload: payload, messageType: .ack))
        }
    }

    func testQueryAndLiveWriteBytesAndCommandNames() {
        XCTAssertEqual(SonyCommands.buildSoundQualityCapabilityGet(), [0xe0, 0x05])
        XCTAssertEqual(SonyCommands.buildSoundQualityGet(), [0xe6, 0x05])
        XCTAssertEqual(SonyCommands.buildSoundQualitySet(.quality), [0xe8, 0x05, 0, 1])
        XCTAssertEqual(SonyCommands.buildSoundQualitySet(.stable), [0xe8, 0x05, 1, 1])
        XCTAssertEqual(SonyCommands.buildSoundQualitySet(.lowLatency), [0xe8, 0x05, 2, 1])
        XCTAssertEqual(SoundQualityMode.allCases.map(\.commandValue), ["quality", "stable", "low-latency"])
        XCTAssertEqual(SoundQualityMode.allCases.map(\.label), ["Prioritize Sound Quality", "Prioritize Stable Connection", "Prioritize Low Latency"])
    }
}
