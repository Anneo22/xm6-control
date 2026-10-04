import XCTest
@testable import XM6Control
@testable import SonyHeadphonesKit

private final class LocalTestConnection: HeadphonesConnection {
    var onEvent: ((RFCOMMConnectionEvent) -> Void)?
    var qualityGet: (() -> Void)?
    var qualitySet: ((UInt8) -> Void)?
    func connect(toDeviceAddress address: String) { onEvent?(.opened) }
    func disconnect() {}
    func reply(_ payload: [UInt8]) {
        onEvent?(.dataReceived(SonyMessage(type: .command1, sequenceNumber: 0, payload: payload).encode()))
    }
    func write(_ bytes: [UInt8]) {
        for message in FrameParser().feed(bytes) where message.type != .ack {
            onEvent?(.dataReceived(SonyMessage(type: .ack, sequenceNumber: message.sequenceNumber ^ 1, payload: []).encode()))
            switch message.payload {
            case [0x00, 0x00]: reply([1, 0, 0, 0, 0, 0, 0, 0])
            case [0xe0, 5]: reply([0xe1, 5, 3, 0, 1, 2, 0])
            case [0xe6, 5]: qualityGet?()
            default:
                if message.payload.count == 3 && message.payload.prefix(2) == [0xe8, 5] {
                    qualitySet?(message.payload[2])
                }
            }
        }
    }
}

@MainActor
final class AgentControlTests: XCTestCase {
    private func fixture() async throws -> (HeadphonesController, LocalTestConnection, AgentControl, URL) {
        let connection = LocalTestConnection()
        let controller = HeadphonesController(connection: connection, pairedDevices: {
            [PairedDeviceInfo(id: "fixture", name: "WH-1000XM6")]
        })
        controller.releaseWhenIdle = true
        connection.qualityGet = { connection.reply([0xe7, 5, 0]) }
        controller.autoConnect()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.soundQuality, .quality)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return (controller, connection, AgentControl(controller: controller, directory: directory), directory)
    }

    private func request(_ directory: URL, value: String? = nil) throws -> URL {
        let id = UUID().uuidString
        var body: [String: Any] = ["id": id, "command": value == nil ? "status" : "quality",
                                   "createdAt": Date().timeIntervalSince1970]
        if let value { body["value"] = value }
        try JSONSerialization.data(withJSONObject: body).write(to: directory.appendingPathComponent("\(id).request.json"))
        return directory.appendingPathComponent("\(id).response.json")
    }

    func testContradictoryDeviceReportDoesNotConfirmWrite() async throws {
        let (controller, connection, service, directory) = try await fixture()
        defer { controller.disconnect(); try? FileManager.default.removeItem(at: directory) }
        connection.qualitySet = { mode in
            connection.reply([0xe9, 5, mode])
            connection.reply([0xe9, 5, 2])
        }
        connection.qualityGet = { connection.reply([0xe7, 5, controller.soundQuality?.rawValue ?? 0]) }
        let response = try request(directory, value: "stable")
        await service.processNextRequest()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any])
        XCTAssertEqual(body["ok"] as? Bool, false)
        XCTAssertNil(body["confirmed"])
        XCTAssertEqual(controller.soundQuality, .lowLatency)
    }

    func testQualityFromResetSessionCannotConfirmStatus() async throws {
        let (controller, connection, service, directory) = try await fixture()
        defer { controller.disconnect(); try? FileManager.default.removeItem(at: directory) }
        connection.qualityGet = {
            connection.qualityGet = nil
            connection.reply([0xe7, 5, 0])
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                controller.disconnect()
                controller.autoConnect()
            }
        }
        let response = try request(directory)
        await service.processNextRequest()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any])
        XCTAssertEqual(body["ok"] as? Bool, false)
        XCTAssertNil(body["confirmed"])
        XCTAssertNil(controller.soundQuality)
        XCTAssertNotNil(controller.supportedSoundQualityModes)
    }
}
