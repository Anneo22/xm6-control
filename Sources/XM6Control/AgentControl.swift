import Foundation
import Combine
import Darwin
import SonyHeadphonesKit

/// Local requests share the app's existing controller and Bluetooth permission.
/// A readback, rather than an optimistic UI value or transport ACK, confirms a write.
@MainActor
final class AgentControl {
    private let controller: HeadphonesController
    private var task: Task<Void, Never>?
    private let directory: URL

    init(controller: HeadphonesController, directory: URL = FileManager.default.temporaryDirectory
         .appendingPathComponent("XM6Control-\(getuid())", isDirectory: true)) {
        self.controller = controller
        self.directory = directory
    }

    func start() {
        guard task == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { return }
        } catch { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(250))
                await self.processNextRequest()
            }
        }
    }

    private struct Request: Decodable {
        let id: String
        let command: String
        let value: String?
        let createdAt: Double
    }

    func processNextRequest() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .creationDateKey])) ?? []
        guard let file = files.sorted(by: {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
        })
            .first(where: { $0.lastPathComponent.hasSuffix(".request.json") &&
                UUID(uuidString: String($0.lastPathComponent.dropLast(".request.json".count))) != nil }) else { return }
        let id = String(file.lastPathComponent.dropLast(".request.json".count))
        guard UUID(uuidString: id) != nil else { return }
        let resultURL = directory.appendingPathComponent("\(id).response.json")
        // Removing the request prevents a crash or a second polling pass from replaying a write.
        var result: [String: Any]
        do {
            let metadata = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard metadata.isSymbolicLink != true, (metadata.fileSize ?? Int.max) <= 16_384 else {
                throw ControlError.invalidRequest
            }
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: file))
            try FileManager.default.removeItem(at: file)
            guard request.id == id, abs(Date().timeIntervalSince1970 - request.createdAt) < 60,
                  request.command == "status" || request.command == "quality" else {
                throw ControlError.invalidRequest
            }
            result = try await execute(request)
        } catch {
            try? FileManager.default.removeItem(at: file)
            result = ["ok": false, "error": error.localizedDescription]
        }
        result["id"] = id
        result["reportedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            try? data.write(to: resultURL, options: .atomic)
        }
    }

    private enum ControlError: LocalizedError {
        case invalidRequest, unsupported, unavailableWrite, noReadback, writeUnconfirmed
        var errorDescription: String? {
            switch self {
            case .invalidRequest: return "Invalid local control request. Use xm6control status or quality quality|stable."
            case .unsupported: return "The headphones did not report support for this sound-quality mode."
            case .unavailableWrite: return "Low latency is not available through this Mac control interface. Use quality or stable."
            case .noReadback: return "No fresh quality-mode reply from the headphones. Close Sony Sound Connect on the phone, then retry."
            case .writeUnconfirmed: return "The command was sent, but the headphones did not confirm the requested mode. Check xm6control status before retrying a write."
            }
        }
    }

    private func execute(_ request: Request) async throws -> [String: Any] {
        let desired: SoundQualityMode?
        if request.command == "quality" {
            guard let value = request.value,
                  let mode = SoundQualityMode.allCases.first(where: { $0.commandValue == value }) else {
                throw ControlError.invalidRequest
            }
            guard mode.canWriteLocally else { throw ControlError.unavailableWrite }
            desired = mode
        } else {
            guard request.value == nil else { throw ControlError.invalidRequest }
            desired = nil
        }

        var observed: SoundQualityMode?
        var observedAt: Date?
        let readSubscription = controller.$soundQuality.dropFirst().sink { mode in
            observed = mode
            observedAt = mode == nil ? nil : Date()
        }
        defer { readSubscription.cancel() }
        controller.refreshSoundQuality()
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while observed == nil || controller.supportedSoundQualityModes == nil {
            guard ContinuousClock.now < deadline else { throw ControlError.noReadback }
            try await Task.sleep(for: .milliseconds(100))
        }

        guard let current = observed, let receipt = observedAt else { throw ControlError.noReadback }
        guard Date().timeIntervalSince1970 < request.createdAt + 25 else { throw ControlError.invalidRequest }
        guard let desired else { return snapshot(quality: current, observedAt: receipt, changed: false) }
        guard controller.supportedSoundQualityModes?.contains(desired) == true else {
            throw ControlError.unsupported
        }
        if desired == current { return snapshot(quality: current, observedAt: receipt, changed: false) }

        // This publisher is updated only by device replies. Retain a confirmation
        // even if the expected audio reconnect clears the controller's live state.
        var latestReport: SoundQualityMode?
        var latestReceipt: Date?
        let writeSubscription = controller.$soundQuality.dropFirst().sink { mode in
            if let mode { latestReport = mode; latestReceipt = Date() }
        }
        defer { writeSubscription.cancel() }
        guard controller.setSoundQuality(desired) else { throw ControlError.unsupported }
        let writeDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        var refreshed = false
        while latestReport != desired {
            guard ContinuousClock.now < writeDeadline else { throw ControlError.writeUnconfirmed }
            try await Task.sleep(for: .milliseconds(100))
            if !refreshed && controller.connectionState == .connected {
                controller.refreshSoundQuality()
                refreshed = true
            }
        }
        guard let latestReceipt else { throw ControlError.writeUnconfirmed }
        return snapshot(quality: desired, observedAt: latestReceipt, changed: true)
    }

    private func snapshot(quality: SoundQualityMode, observedAt: Date, changed: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "ok": true, "confirmed": true, "quality": quality.commandValue,
            "changed": changed, "connection": String(describing: controller.connectionState),
            "qualityObservedAt": ISO8601DateFormatter().string(from: observedAt),
        ]
        if let modes = controller.supportedSoundQualityModes { result["supportedQualityModes"] = modes.map(\.commandValue) }
        if let modes = controller.supportedSoundQualityModes { result["writableQualityModes"] = modes.filter(\.canWriteLocally).map(\.commandValue) }
        var cached: [String: Any] = [:]
        if let battery = controller.battery { cached["batteryPercent"] = battery.level }
        if let ambient = controller.ambientSound {
            cached["noiseControl"] = String(describing: ambient.mode)
            cached["ambientLevel"] = ambient.level
        }
        if let mode = controller.listeningMode { cached["listeningMode"] = String(describing: mode) }
        result["cachedState"] = cached
        return result
    }
}
