import XCTest
@testable import SonyHeadphonesKit

private final class TestConnection: HeadphonesConnection {
    var onEvent: ((RFCOMMConnectionEvent) -> Void)?
    var addresses: [String] = []
    var closeCount = 0
    var messages: [SonyMessage] = []

    func connect(toDeviceAddress address: String) { addresses.append(address) }
    func disconnect() { closeCount += 1 }
    func write(_ bytes: [UInt8]) {
        messages.append(contentsOf: FrameParser().feed(bytes))
    }

    func reply(_ payload: [UInt8]) {
        onEvent?(.dataReceived(SonyMessage(type: .command1, sequenceNumber: 0, payload: payload).encode()))
    }

    func ack() {
        guard let sent = messages.last(where: { $0.type != .ack }) else { return }
        onEvent?(.dataReceived(SonyMessage(type: .ack, sequenceNumber: sent.sequenceNumber ^ 1, payload: []).encode()))
    }

    var payloads: [[UInt8]] { messages.filter { $0.type != .ack }.map(\.payload) }
}

@MainActor
final class HeadphonesControllerTests: XCTestCase {
    private func makeController() -> (HeadphonesController, TestConnection) {
        let connection = TestConnection()
        let controller = HeadphonesController(connection: connection, pairedDevices: {
            [PairedDeviceInfo(id: "test-device", name: "WH-1000XM6")]
        })
        controller.releaseWhenIdle = true
        return (controller, connection)
    }

    private func settle() async {
        // Only the delegate's main-actor hop runs here; idle deadlines use a virtual instant.
        try? await Task.sleep(for: .milliseconds(10))
    }

    private func handshake(_ connection: TestConnection) async {
        connection.onEvent?(.opened)
        await settle()
        connection.ack()
        await settle()
        connection.reply([0x01, 0, 0, 0, 0, 0, 0, 0])
        await settle()
    }

    private func drain(_ connection: TestConnection) async {
        for _ in 0..<20 {
            connection.ack()
            await settle()
        }
    }

    func testStartsDisconnectedAndVisibleSurfacesAcquireOnce() {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        XCTAssertTrue(connection.addresses.isEmpty)
        let main = UUID(), widget = UUID()
        controller.setControlSurface(main, visible: true)
        controller.setControlSurface(main, visible: true)
        controller.setControlSurface(widget, visible: true)
        XCTAssertEqual(connection.addresses, ["test-device"])
        controller.setControlSurface(main, visible: false)
        controller.disconnectIfIdle(now: .now.advanced(by: .seconds(100)))
        XCTAssertEqual(controller.connectionState, .connecting)
        controller.setControlSurface(widget, visible: false)
        controller.disconnectIfIdle(now: .now.advanced(by: .seconds(21)))
        XCTAssertEqual(controller.connectionState, .disconnected)
        XCTAssertEqual(connection.closeCount, 2)
    }

    func testDisconnectedCommandsWaitForHandshakeAndAreAppliedInOrder() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        controller.setListeningMode(.cinema)
        controller.setEqualizerPreset(.off)
        XCTAssertEqual(connection.addresses.count, 1)
        XCTAssertTrue(connection.messages.isEmpty)
        await handshake(connection)
        XCTAssertEqual(controller.connectionState, .connected)
        await drain(connection)
        XCTAssertEqual(Array(connection.payloads.prefix(4)), [
            SonyCommands.buildInit(),
            SonyCommands.buildBGMModeSet(enabled: false, roomSize: .middle),
            SonyCommands.buildUpmixCinemaSet(enabled: true),
            SonyCommands.buildEqualizerPresetSet(code: EqualizerPreset.off.rawValue, subtype: 0x04)
        ])
        XCTAssertTrue(connection.payloads.contains(SonyCommands.buildBatteryGet()))
        XCTAssertTrue(connection.payloads.contains(SonyCommands.buildDeviceListGet()))
    }

    func testEqualizerDragConnectsAndKeepsLatestCurve() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        controller.setEqualizerBands(Array(repeating: 1, count: 10))
        controller.setEqualizerBands(Array(repeating: 2, count: 10))
        try? await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(connection.addresses.count, 1)
        XCTAssertTrue(connection.messages.isEmpty)
        await handshake(connection)
        await drain(connection)
        XCTAssertTrue(connection.payloads.contains(SonyCommands.buildEqualizerBandsSet(bands: Array(repeating: 2, count: 10), subtype: 0x04)))
        XCTAssertFalse(connection.payloads.contains(SonyCommands.buildEqualizerBandsSet(bands: Array(repeating: 1, count: 10), subtype: 0x04)))
    }

    func testExplicitDisconnectCancelsCommandsAndLateCallbacks() async {
        let (controller, connection) = makeController()
        let surface = UUID()
        controller.setControlSurface(surface, visible: true)
        controller.setPauseWhenTakenOff(true)
        connection.onEvent?(.opened)
        controller.disconnect()
        await settle()
        controller.setControlSurface(surface, visible: true)
        XCTAssertEqual(controller.connectionState, .disconnected)
        XCTAssertEqual(connection.addresses.count, 1)
        XCTAssertTrue(connection.messages.isEmpty)
        controller.setControlSurface(surface, visible: false)
        controller.setControlSurface(surface, visible: true)
        await handshake(connection)
        await drain(connection)
        XCTAssertFalse(connection.payloads.contains(SonyCommands.buildPauseWhenTakenOffSet(true)))
        controller.disconnect()
    }

    func testFreshConnectionClearsCacheAndMirrorsOffWithoutStartupWrites() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        controller.autoConnect()
        await handshake(connection)
        connection.reply([Opcode.ambientSoundControlRet, 0x15, 1, 1, 1, 0, 12])
        await settle()
        XCTAssertEqual(controller.ambientSound?.level, 12)
        await drain(connection)
        controller.disconnect()
        XCTAssertNil(controller.ambientSound)
        controller.autoConnect()
        await handshake(connection)
        XCTAssertNil(controller.ambientSound)
        let off = AmbientSoundState(mode: .off, level: 0)
        connection.reply([Opcode.ambientSoundControlRet, 0x15, 1, 0, 0, 0, 0])
        await settle()
        await drain(connection)
        XCTAssertEqual(controller.ambientSound, off)
        XCTAssertEqual(connection.payloads.filter { $0 == SonyCommands.buildBatteryGet() }.count, 2)
        XCTAssertFalse(connection.payloads.contains { $0.first == Opcode.ambientSoundControlSet })
    }

    func testDroppedLinkReconnectsOnlyWhileUseContinues() async {
        let (controller, connection) = makeController()
        controller.setControlSurface(UUID(), visible: true)
        await handshake(connection)
        connection.onEvent?(.closed)
        await settle()
        XCTAssertEqual(connection.addresses.count, 2)
        XCTAssertEqual(controller.connectionState, .connecting)
        controller.disconnect()
        connection.onEvent?(.closed)
        await settle()
        XCTAssertEqual(connection.addresses.count, 2)
        XCTAssertEqual(controller.connectionState, .disconnected)
    }

    func testFailureClearsDeferredCommandAndUsesExistingErrorSurface() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        controller.setPauseWhenTakenOff(true)
        let message = RFCOMMConnection.channelOpenError(Int32(bitPattern: 0xe00002bc))
        connection.onEvent?(.failed(message))
        await settle()
        XCTAssertEqual(controller.lastError, message)
        XCTAssertTrue(message.contains("Sony Sound Connect"))
        XCTAssertEqual(controller.connectionState, .failed(message))
        controller.autoConnect()
        await handshake(connection)
        await drain(connection)
        XCTAssertFalse(connection.payloads.contains(SonyCommands.buildPauseWhenTakenOffSet(true)))
    }

    func testConnectionRetryPreservesQueuedCommands() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        controller.setPauseWhenTakenOff(true)
        controller.handleConnectTimeout()
        XCTAssertEqual(connection.addresses.count, 2)
        await handshake(connection)
        await drain(connection)
        XCTAssertEqual(connection.payloads.filter { $0 == SonyCommands.buildPauseWhenTakenOffSet(true) }.count, 1)
    }

    func testUnsentCommandsSurviveDropAndReconnectGetsFreshRetry() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        controller.setPauseWhenTakenOff(true)
        controller.setEqualizerPreset(.off)
        controller.handleConnectTimeout()
        await handshake(connection)
        connection.onEvent?(.closed)
        await settle()
        controller.handleConnectTimeout()
        XCTAssertEqual(connection.addresses.count, 4)
        XCTAssertEqual(controller.connectionState, .connecting)
        await handshake(connection)
        await drain(connection)
        XCTAssertTrue(connection.payloads.contains(SonyCommands.buildEqualizerPresetSet(code: EqualizerPreset.off.rawValue, subtype: 0x04)))
    }

    func testMissingInitAckDoesNotHoldCommandsForever() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        controller.setPauseWhenTakenOff(true)
        connection.onEvent?(.opened)
        await settle()
        connection.reply([0x01, 0, 0, 0, 0, 0, 0, 0])
        await settle()
        XCTAssertEqual(controller.connectionState, .connected)
        XCTAssertFalse(connection.payloads.contains(SonyCommands.buildPauseWhenTakenOffSet(true)))
        // Exercise the real timeout callback without waiting for the transport timeout.
        controller.handleAckTimeout()
        XCTAssertTrue(connection.payloads.contains(SonyCommands.buildPauseWhenTakenOffSet(true)))
        connection.ack()
        await settle()
        controller.disconnectIfIdle(now: .now.advanced(by: .seconds(21)))
        XCTAssertEqual(controller.connectionState, .disconnected)
    }

    func testEqualizerDebounceSurvivesConnectionRetry() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        controller.setEqualizerBands(Array(repeating: 3, count: 10))
        controller.handleConnectTimeout()
        try? await Task.sleep(for: .milliseconds(160))
        await handshake(connection)
        await drain(connection)
        XCTAssertTrue(connection.payloads.contains(SonyCommands.buildEqualizerBandsSet(bands: Array(repeating: 3, count: 10), subtype: 0x04)))
    }

    func testIdleExpiryFinishesCommandButDoesNotWaitForStateQueries() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        controller.setPauseWhenTakenOff(true)
        controller.disconnectIfIdle(now: .now.advanced(by: .seconds(21)))
        XCTAssertEqual(controller.connectionState, .connecting)
        await handshake(connection)
        controller.disconnectIfIdle(now: .now.advanced(by: .seconds(21)))
        XCTAssertEqual(controller.connectionState, .connected)
        connection.ack()
        await settle()
        controller.disconnectIfIdle(now: .now.advanced(by: .seconds(21)))
        XCTAssertEqual(controller.connectionState, .disconnected)
        XCTAssertTrue(connection.payloads.contains(SonyCommands.buildPauseWhenTakenOffSet(true)))
        XCTAssertFalse(connection.payloads.contains(SonyCommands.buildDeviceListGet()))
    }

    func testTimerReleasesAfterPendingCommandsSurviveDropPastDeadline() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        for index in 0..<10 { controller.setPauseWhenTakenOff(index.isMultiple(of: 2)) }
        await handshake(connection)
        let (idleController, idleConnection) = makeController()
        defer { idleController.disconnect() }
        let surface = UUID()
        idleController.setControlSurface(surface, visible: true)
        await handshake(idleConnection)
        await drain(idleConnection)
        idleController.setControlSurface(surface, visible: false)
        // Deliberately withhold ACKs. Ten user commands take longer than the grace
        // period at the normal three-second ACK timeout.
        try? await Task.sleep(for: ConnectionUsage.gracePeriod + .milliseconds(100))
        // With no queued work, the timer itself closes the other controller.
        XCTAssertEqual(idleController.connectionState, .disconnected)
        XCTAssertEqual(controller.connectionState, .connected)
        connection.onEvent?(.closed)
        await settle()
        XCTAssertEqual(controller.connectionState, .connecting)
        await handshake(connection)
        await drain(connection)
        // The ACK path must finish idle release itself, without another UI event.
        XCTAssertEqual(controller.connectionState, .disconnected)
        XCTAssertEqual(connection.payloads.filter { $0 == SonyCommands.buildPauseWhenTakenOffSet(true) }.count
            + connection.payloads.filter { $0 == SonyCommands.buildPauseWhenTakenOffSet(false) }.count, 10)
    }

    func testIdleReleaseRemembersManuallySelectedHeadset() {
        let connection = TestConnection()
        let controller = HeadphonesController(connection: connection, pairedDevices: { [] })
        defer { controller.disconnect() }
        controller.releaseWhenIdle = true
        controller.connect(toAddress: "renamed-headset", name: "My headphones")
        controller.disconnectIfIdle(now: .now.advanced(by: .seconds(21)))
        XCTAssertEqual(controller.connectionState, .disconnected)
        controller.setControlSurface(UUID(), visible: true)
        XCTAssertEqual(connection.addresses, ["renamed-headset", "renamed-headset"])
    }

    func testEnablingReleaseAcquiresForAlreadyVisibleSurface() {
        let connection = TestConnection()
        let controller = HeadphonesController(connection: connection, pairedDevices: {
            [PairedDeviceInfo(id: "test-device", name: "WH-1000XM6")]
        })
        defer { controller.disconnect() }
        controller.setControlSurface(UUID(), visible: true)
        XCTAssertTrue(connection.addresses.isEmpty)
        controller.releaseWhenIdle = true
        XCTAssertEqual(connection.addresses, ["test-device"])
    }

    func testDisablingReleaseConnectsAndPreservesStartupDefaults() async {
        let (controller, connection) = makeController()
        defer { controller.disconnect() }
        controller.releaseWhenIdle = false
        XCTAssertEqual(connection.addresses.count, 1)
        await handshake(connection)
        connection.reply([Opcode.ambientSoundControlRet, 0x15, 1, 0, 0, 0, 0])
        await settle()
        XCTAssertEqual(controller.ambientSound?.mode, .noiseCancelling)
        XCTAssertEqual(controller.ambientSound?.level, 15)
        controller.disconnectIfIdle(now: .now.advanced(by: .seconds(100)))
        XCTAssertEqual(controller.connectionState, .connected)
    }
}
