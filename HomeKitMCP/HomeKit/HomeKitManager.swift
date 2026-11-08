import Foundation
import HomeKit

@MainActor
final class HomeKitManager: NSObject {
    private(set) var homeManager: HMHomeManager?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var isReady = false

    override init() {
        super.init()
    }

    func start() async {
        guard homeManager == nil else { return }
        let manager = HMHomeManager()
        manager.delegate = self
        homeManager = manager
        Log.info("HomeKitManager: waiting for homes to load...")

        if !isReady {
            await withCheckedContinuation { continuation in
                readyContinuation = continuation
            }
        }
        Log.info("HomeKitManager: ready with \(manager.homes.count) home(s)")
    }

    // MARK: - Homes

    func listHomes() -> [[String: Any]] {
        guard let manager = homeManager else { return [] }
        return manager.homes.map { home in
            [
                "name": home.name,
                "isPrimary": home == manager.primaryHome,
                "roomCount": home.rooms.count,
                "accessoryCount": home.accessories.count,
            ] as [String: Any]
        }
    }

    // MARK: - Rooms

    func listRooms(homeName: String?) -> [[String: Any]] {
        let homes = matchingHomes(name: homeName)
        return homes.flatMap { home in
            home.rooms.map { room in
                [
                    "name": room.name,
                    "home": home.name,
                    "deviceCount": room.accessories.count,
                ] as [String: Any]
            }
        }
    }

    // MARK: - Devices

    func listDevices(homeName: String?, roomName: String?, type: String?) -> [[String: Any]] {
        let accessories = matchingAccessories(homeName: homeName, roomName: roomName)
        return accessories.compactMap { (accessory: HMAccessory) -> [String: Any]? in
            let deviceType = self.deviceType(for: accessory)
            if let type = type, deviceType.lowercased() != type.lowercased() {
                return nil
            }
            return [
                "name": accessory.name,
                "room": accessory.room?.name ?? "Default Room",
                "home": self.homeNameForAccessory(accessory),
                "type": deviceType,
                "reachable": accessory.isReachable,
                "uniqueIdentifier": accessory.uniqueIdentifier.uuidString,
            ] as [String: Any]
        }
    }

    // MARK: - Device State

    func getDeviceState(id: String?, name: String?, homeName: String?, roomName: String?) async throws -> [String: Any] {
        guard let accessory = resolveAccessory(id: id, name: name, homeName: homeName, roomName: roomName) else {
            throw HomeKitError.deviceNotFound(id ?? name ?? "unknown")
        }

        var properties: [String: Any] = [:]

        for service in accessory.services {
            for characteristic in service.characteristics {
                if characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                    do {
                        try await characteristic.readValue()
                        if let key = characteristicKey(for: characteristic),
                           let value = characteristic.value
                        {
                            properties[key] = formatValue(value, for: characteristic)
                        }
                    } catch {
                        Log.debug("Failed to read \(characteristic.characteristicType): \(error)")
                    }
                }
            }
        }

        return [
            "name": accessory.name,
            "room": accessory.room?.name ?? "Default Room",
            "home": homeNameForAccessory(accessory),
            "type": deviceType(for: accessory),
            "reachable": accessory.isReachable,
            "properties": properties,
        ] as [String: Any]
    }

    // MARK: - Device Control

    func controlDevice(
        id: String?,
        name: String?,
        homeName: String?,
        roomName: String?,
        action: String,
        value: Any?
    ) async throws -> [String: Any] {
        let identifier = id ?? name ?? "unknown"
        guard let accessory = resolveAccessory(id: id, name: name, homeName: homeName, roomName: roomName) else {
            throw HomeKitError.deviceNotFound(identifier)
        }
        guard accessory.isReachable else {
            throw HomeKitError.deviceUnreachable(identifier)
        }

        switch action.lowercased() {
        case "on":
            try await setPowerState(accessory: accessory, on: true)
        case "off":
            try await setPowerState(accessory: accessory, on: false)
        case "toggle":
            let currentState = try await getPowerState(accessory: accessory)
            try await setPowerState(accessory: accessory, on: !currentState)
        case "set_brightness":
            guard let brightness = intValue(value) else {
                throw HomeKitError.invalidValue("brightness requires an integer 0-100")
            }
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeBrightness,
                                        value: max(0, min(100, brightness)))
        case "set_hue":
            guard let hue = doubleValue(value) else {
                throw HomeKitError.invalidValue("hue requires a number 0-360")
            }
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeHue,
                                        value: max(0, min(360, hue)))
        case "set_saturation":
            guard let saturation = doubleValue(value) else {
                throw HomeKitError.invalidValue("saturation requires a number 0-100")
            }
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeSaturation,
                                        value: max(0, min(100, saturation)))
        case "set_color":
            guard let colorDict = value as? [String: Any],
                  let hue = doubleValue(colorDict["hue"]),
                  let saturation = doubleValue(colorDict["saturation"])
            else {
                throw HomeKitError.invalidValue("set_color requires {hue: 0-360, saturation: 0-100}")
            }
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeHue,
                                        value: max(0, min(360, hue)))
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeSaturation,
                                        value: max(0, min(100, saturation)))
        case "lock":
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeTargetLockMechanismState,
                                        value: HMCharacteristicValueLockMechanismState.secured.rawValue)
        case "unlock":
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeTargetLockMechanismState,
                                        value: HMCharacteristicValueLockMechanismState.unsecured.rawValue)
        case "open":
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeTargetDoorState,
                                        value: HMCharacteristicValueDoorState.open.rawValue)
        case "close":
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeTargetDoorState,
                                        value: HMCharacteristicValueDoorState.closed.rawValue)
        case "set_temperature":
            guard let temp = doubleValue(value) else {
                throw HomeKitError.invalidValue("set_temperature requires a number (celsius)")
            }
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeTargetTemperature,
                                        value: temp)
        case "set_thermostat_mode":
            guard let modeStr = value as? String else {
                throw HomeKitError.invalidValue("set_thermostat_mode requires: off, heat, cool, auto")
            }
            let mode: Int = switch modeStr.lowercased() {
            case "off": HMCharacteristicValueHeatingCooling.off.rawValue
            case "heat": HMCharacteristicValueHeatingCooling.heat.rawValue
            case "cool": HMCharacteristicValueHeatingCooling.cool.rawValue
            case "auto": HMCharacteristicValueHeatingCooling.auto.rawValue
            default: throw HomeKitError.invalidValue("Unknown mode: \(modeStr). Use off/heat/cool/auto")
            }
            try await setCharacteristic(accessory: accessory,
                                        type: HMCharacteristicTypeTargetHeatingCooling,
                                        value: mode)
        default:
            throw HomeKitError.unknownAction(action)
        }

        return [
            "success": true,
            "device": accessory.name,
            "action": action,
            "value": value ?? NSNull(),
        ] as [String: Any]
    }

    // MARK: - Batch Control

    func batchControlDevices(commands: [[String: Any]]) async -> [[String: Any]] {
        var results: [[String: Any]] = []
        for command in commands {
            let id = command["id"] as? String
            let name = command["name"] as? String
            guard id != nil || name != nil else {
                results.append(["success": false, "error": "Each command requires 'id' or 'name'"])
                continue
            }
            guard let action = command["action"] as? String else {
                results.append(["success": false, "device": id ?? name ?? "unknown", "error": "Missing required field: action"])
                continue
            }
            let home = command["home"] as? String
            let room = command["room"] as? String
            let value = command["value"]

            do {
                let result = try await controlDevice(id: id, name: name, homeName: home, roomName: room, action: action, value: value)
                results.append(result)
            } catch {
                results.append([
                    "success": false,
                    "device": id ?? name ?? "unknown",
                    "action": action,
                    "error": error.localizedDescription,
                ])
            }
        }
        return results
    }

    func batchGetDeviceState(devices: [[String: Any]]) async -> [[String: Any]] {
        var results: [[String: Any]] = []
        for device in devices {
            let id = device["id"] as? String
            let name = device["name"] as? String
            guard id != nil || name != nil else {
                results.append(["success": false, "error": "Each device requires 'id' or 'name'"])
                continue
            }
            let home = device["home"] as? String
            let room = device["room"] as? String

            do {
                var state = try await getDeviceState(id: id, name: name, homeName: home, roomName: room)
                state["success"] = true
                results.append(state)
            } catch {
                results.append([
                    "success": false,
                    "device": id ?? name ?? "unknown",
                    "error": error.localizedDescription,
                ])
            }
        }
        return results
    }

    func controlDevicesByFilter(
        homeName: String?,
        roomName: String?,
        type: String?,
        action: String,
        value: Any?
    ) async -> [[String: Any]] {
        let accessories = matchingAccessories(homeName: homeName, roomName: roomName)
        let filtered = accessories.filter { accessory in
            guard let type else { return true }
            return deviceType(for: accessory).lowercased() == type.lowercased()
        }

        if filtered.isEmpty {
            return [["success": false, "error": "No devices matched the given filters"]]
        }

        var results: [[String: Any]] = []
        for accessory in filtered {
            do {
                let result = try await controlDevice(
                    id: accessory.uniqueIdentifier.uuidString,
                    name: nil,
                    homeName: nil,
                    roomName: nil,
                    action: action,
                    value: value
                )
                results.append(result)
            } catch {
                results.append([
                    "success": false,
                    "device": accessory.name,
                    "action": action,
                    "error": error.localizedDescription,
                ])
            }
        }
        return results
    }

    // MARK: - Scenes

    func listScenes(homeName: String?) -> [[String: Any]] {
        let homes = matchingHomes(name: homeName)
        return homes.flatMap { home in
            home.actionSets.map { actionSet in
                var info: [String: Any] = [
                    "name": actionSet.name,
                    "home": home.name,
                    "uniqueIdentifier": actionSet.uniqueIdentifier.uuidString,
                    "actionCount": actionSet.actions.count,
                ]
                if let type = actionSetType(for: actionSet) {
                    info["type"] = type
                }
                return info
            }
        }
    }

    func executeScene(name: String?, homeName: String?, id: String?) async throws -> [String: Any] {
        guard let actionSet = resolveActionSet(name: name, homeName: homeName, id: id) else {
            throw HomeKitError.sceneNotFound(id ?? name ?? "unknown")
        }
        guard let home = homeForActionSet(actionSet) else {
            throw HomeKitError.sceneNotFound(id ?? name ?? "unknown")
        }

        try await home.executeActionSet(actionSet)

        return [
            "success": true,
            "scene": actionSet.name,
            "home": home.name,
        ] as [String: Any]
    }

    // MARK: - Private: Scene Helpers

    private func resolveActionSet(name: String?, homeName: String?, id: String?) -> HMActionSet? {
        if let id, let uuid = UUID(uuidString: id) {
            return findActionSetById(uuid)
        }
        if let name {
            return findActionSet(name: name, homeName: homeName)
        }
        return nil
    }

    private func findActionSetById(_ uuid: UUID) -> HMActionSet? {
        guard let manager = homeManager else { return nil }
        for home in manager.homes {
            if let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier == uuid }) {
                return actionSet
            }
        }
        return nil
    }

    private func findActionSet(name: String, homeName: String?) -> HMActionSet? {
        let homes = matchingHomes(name: homeName)
        for home in homes {
            if let actionSet = home.actionSets.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                return actionSet
            }
        }
        return nil
    }

    private func homeForActionSet(_ actionSet: HMActionSet) -> HMHome? {
        guard let manager = homeManager else { return nil }
        return manager.homes.first { home in
            home.actionSets.contains(where: { $0.uniqueIdentifier == actionSet.uniqueIdentifier })
        }
    }

    private func actionSetType(for actionSet: HMActionSet) -> String? {
        switch actionSet.actionSetType {
        case HMActionSetTypeWakeUp: return "wake_up"
        case HMActionSetTypeSleep: return "sleep"
        case HMActionSetTypeHomeDeparture: return "home_departure"
        case HMActionSetTypeHomeArrival: return "home_arrival"
        case HMActionSetTypeUserDefined: return "user_defined"
        default: return nil
        }
    }

    // MARK: - Private: Lookup Helpers

    private func matchingHomes(name: String?) -> [HMHome] {
        guard let manager = homeManager else { return [] }
        if let name = name {
            return manager.homes.filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
        return manager.homes
    }

    private func matchingAccessories(homeName: String?, roomName: String?) -> [HMAccessory] {
        let homes = matchingHomes(name: homeName)
        var accessories: [HMAccessory] = []
        for home in homes {
            if let roomName = roomName {
                let rooms = home.rooms.filter {
                    $0.name.localizedCaseInsensitiveCompare(roomName) == .orderedSame
                }
                for room in rooms {
                    accessories.append(contentsOf: room.accessories)
                }
            } else {
                accessories.append(contentsOf: home.accessories)
            }
        }
        return accessories
    }

    private func findAccessory(name: String, homeName: String?, roomName: String?) -> HMAccessory? {
        let candidates = matchingAccessories(homeName: homeName, roomName: roomName)
        return candidates.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private func findAccessoryById(_ id: String) -> HMAccessory? {
        guard let manager = homeManager, let uuid = UUID(uuidString: id) else { return nil }
        for home in manager.homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
                return accessory
            }
        }
        return nil
    }

    private func resolveAccessory(id: String?, name: String?, homeName: String?, roomName: String?) -> HMAccessory? {
        if let id {
            return findAccessoryById(id)
        }
        if let name {
            return findAccessory(name: name, homeName: homeName, roomName: roomName)
        }
        return nil
    }

    private func homeNameForAccessory(_ accessory: HMAccessory) -> String {
        guard let manager = homeManager else { return "Unknown" }
        for home in manager.homes {
            if home.accessories.contains(where: { $0.uniqueIdentifier == accessory.uniqueIdentifier }) {
                return home.name
            }
        }
        return "Unknown"
    }

    // MARK: - Private: Characteristic Helpers

    private func findCharacteristic(accessory: HMAccessory, type: String) -> HMCharacteristic? {
        for service in accessory.services {
            for characteristic in service.characteristics where characteristic.characteristicType == type {
                return characteristic
            }
        }
        return nil
    }

    private func setCharacteristic(accessory: HMAccessory, type: String, value: Any) async throws {
        guard let characteristic = findCharacteristic(accessory: accessory, type: type) else {
            throw HomeKitError.characteristicNotFound(type)
        }
        guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            throw HomeKitError.characteristicReadOnly(type)
        }
        try await characteristic.writeValue(value)
    }

    private func setPowerState(accessory: HMAccessory, on: Bool) async throws {
        try await setCharacteristic(accessory: accessory,
                                    type: HMCharacteristicTypePowerState,
                                    value: on)
    }

    private func getPowerState(accessory: HMAccessory) async throws -> Bool {
        guard let characteristic = findCharacteristic(accessory: accessory, type: HMCharacteristicTypePowerState)
        else {
            throw HomeKitError.characteristicNotFound("power state")
        }
        try await characteristic.readValue()
        return characteristic.value as? Bool ?? false
    }

    // MARK: - Private: Type Detection

    private func deviceType(for accessory: HMAccessory) -> String {
        for service in accessory.services {
            switch service.serviceType {
            case HMServiceTypeLightbulb: return "light"
            case HMServiceTypeSwitch: return "switch"
            case HMServiceTypeOutlet: return "outlet"
            case HMServiceTypeFan: return "fan"
            case HMServiceTypeThermostat: return "thermostat"
            case HMServiceTypeLockMechanism: return "lock"
            case HMServiceTypeGarageDoorOpener: return "garage_door"
            case HMServiceTypeTemperatureSensor: return "temperature_sensor"
            case HMServiceTypeHumiditySensor: return "humidity_sensor"
            case HMServiceTypeMotionSensor: return "motion_sensor"
            case HMServiceTypeContactSensor: return "contact_sensor"
            case HMServiceTypeOccupancySensor: return "occupancy_sensor"
            case HMServiceTypeWindow: return "window"
            case HMServiceTypeWindowCovering: return "window_covering"
            case HMServiceTypeDoor: return "door"
            default: continue
            }
        }
        return "unknown"
    }

    // MARK: - Private: Value Formatting

    private func characteristicKey(for characteristic: HMCharacteristic) -> String? {
        switch characteristic.characteristicType {
        case HMCharacteristicTypePowerState: return "power"
        case HMCharacteristicTypeBrightness: return "brightness"
        case HMCharacteristicTypeHue: return "hue"
        case HMCharacteristicTypeSaturation: return "saturation"
        case HMCharacteristicTypeCurrentTemperature: return "currentTemperature"
        case HMCharacteristicTypeTargetTemperature: return "targetTemperature"
        case HMCharacteristicTypeCurrentRelativeHumidity: return "humidity"
        case HMCharacteristicTypeTargetHeatingCooling: return "thermostatMode"
        case HMCharacteristicTypeCurrentHeatingCooling: return "currentThermostatMode"
        case HMCharacteristicTypeCurrentLockMechanismState: return "lockState"
        case HMCharacteristicTypeTargetLockMechanismState: return "lockTargetState"
        case HMCharacteristicTypeCurrentDoorState: return "doorState"
        case HMCharacteristicTypeTargetDoorState: return "doorTargetState"
        case HMCharacteristicTypeMotionDetected: return "motionDetected"
        case HMCharacteristicTypeContactState: return "contactState"
        case HMCharacteristicTypeOccupancyDetected: return "occupancyDetected"
        case HMCharacteristicTypeRotationSpeed: return "fanSpeed"
        case HMCharacteristicTypeName: return nil  // skip, already in top-level
        default: return nil
        }
    }

    private func formatValue(_ value: Any, for characteristic: HMCharacteristic) -> Any {
        switch characteristic.characteristicType {
        case HMCharacteristicTypeCurrentLockMechanismState:
            guard let raw = value as? Int else { return value }
            return switch raw {
            case HMCharacteristicValueLockMechanismState.unsecured.rawValue: "unlocked"
            case HMCharacteristicValueLockMechanismState.secured.rawValue: "locked"
            case HMCharacteristicValueLockMechanismState.jammed.rawValue: "jammed"
            case HMCharacteristicValueLockMechanismState.unknown.rawValue: "unknown"
            default: "unknown"
            }
        case HMCharacteristicTypeCurrentDoorState:
            guard let raw = value as? Int else { return value }
            return switch raw {
            case HMCharacteristicValueDoorState.open.rawValue: "open"
            case HMCharacteristicValueDoorState.closed.rawValue: "closed"
            case HMCharacteristicValueDoorState.opening.rawValue: "opening"
            case HMCharacteristicValueDoorState.closing.rawValue: "closing"
            case HMCharacteristicValueDoorState.stopped.rawValue: "stopped"
            default: "unknown"
            }
        case HMCharacteristicTypeTargetHeatingCooling, HMCharacteristicTypeCurrentHeatingCooling:
            guard let raw = value as? Int else { return value }
            return switch raw {
            case HMCharacteristicValueHeatingCooling.off.rawValue: "off"
            case HMCharacteristicValueHeatingCooling.heat.rawValue: "heat"
            case HMCharacteristicValueHeatingCooling.cool.rawValue: "cool"
            case HMCharacteristicValueHeatingCooling.auto.rawValue: "auto"
            default: "unknown"
            }
        default:
            return value
        }
    }

    // MARK: - Private: Value Conversion

    private func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }
}

// MARK: - HomeKitProviding

extension HomeKitManager: HomeKitProviding {}

// MARK: - HMHomeManagerDelegate

extension HomeKitManager: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            Log.info("HomeKitManager: homes updated (\(manager.homes.count) home(s))")
            isReady = true
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }
}

// MARK: - Errors

enum HomeKitError: LocalizedError {
    case deviceNotFound(String)
    case deviceUnreachable(String)
    case characteristicNotFound(String)
    case characteristicReadOnly(String)
    case invalidValue(String)
    case unknownAction(String)
    case sceneNotFound(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let name): "Device '\(name)' not found"
        case .deviceUnreachable(let name): "Device '\(name)' is not reachable"
        case .characteristicNotFound(let type): "Characteristic '\(type)' not found on device"
        case .characteristicReadOnly(let type): "Characteristic '\(type)' is read-only"
        case .invalidValue(let msg): "Invalid value: \(msg)"
        case .unknownAction(let action): "Unknown action: '\(action)'"
        case .sceneNotFound(let name): "Scene '\(name)' not found"
        }
    }
}
