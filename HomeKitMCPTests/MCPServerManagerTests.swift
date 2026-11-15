import Foundation
import MCP
import Testing
@testable import HomeKitMCP

@MainActor
struct MCPServerManagerTests {

    // MARK: - Helpers

    private func makeSUT() -> (manager: MCPServerManager, mock: MockHomeKitManager) {
        let mock = MockHomeKitManager()
        let manager = MCPServerManager(homeKitManager: mock, startServer: false)
        return (manager, mock)
    }

    // MARK: - Tool Routing

    @Test func listHomesRoutesToHomeKitManager() async {
        let (manager, mock) = makeSUT()
        mock.stubbedHomes = [
            ["name": "My Home", "isPrimary": true, "roomCount": 3, "accessoryCount": 5],
        ]

        let params = CallTool.Parameters(name: "list_homes", arguments: [:])
        let result = await manager.handleToolCall(params)

        #expect(mock.listHomesCalled)
        #expect(result.isError != true)
    }

    @Test func listRoomsPassesHomeName() async {
        let (manager, mock) = makeSUT()
        mock.stubbedRooms = [
            ["name": "Bedroom", "home": "My Home", "deviceCount": 2],
        ]

        let params = CallTool.Parameters(name: "list_rooms", arguments: ["home": .string("My Home")])
        let result = await manager.handleToolCall(params)

        #expect(mock.listRoomsCalledWith == .some("My Home"))
        #expect(result.isError != true)
    }

    @Test func listRoomsPassesNilWhenNoHome() async {
        let (manager, mock) = makeSUT()
        mock.stubbedRooms = []

        let params = CallTool.Parameters(name: "list_rooms", arguments: [:])
        _ = await manager.handleToolCall(params)

        // listRoomsCalledWith is String?? — .some(nil) means it was called with nil
        #expect(mock.listRoomsCalledWith == .some(nil))
    }

    @Test func listDevicesPassesAllFilters() async {
        let (manager, mock) = makeSUT()
        mock.stubbedDevices = []

        let params = CallTool.Parameters(
            name: "list_devices",
            arguments: [
                "home": .string("My Home"),
                "room": .string("Kitchen"),
                "type": .string("light"),
            ]
        )
        _ = await manager.handleToolCall(params)

        #expect(mock.listDevicesCalledWith?.homeName == "My Home")
        #expect(mock.listDevicesCalledWith?.roomName == "Kitchen")
        #expect(mock.listDevicesCalledWith?.type == "light")
    }

    @Test func getDeviceStatePassesNameAndOptionals() async {
        let (manager, mock) = makeSUT()
        mock.stubbedDeviceState = [
            "name": "Lamp",
            "reachable": true,
            "properties": [:] as [String: Any],
        ]

        let params = CallTool.Parameters(
            name: "get_device_state",
            arguments: ["name": .string("Lamp"), "home": .string("Home")]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.getDeviceStateCalledWith?.id == nil)
        #expect(mock.getDeviceStateCalledWith?.name == "Lamp")
        #expect(mock.getDeviceStateCalledWith?.homeName == "Home")
        #expect(mock.getDeviceStateCalledWith?.roomName == nil)
        #expect(result.isError != true)
    }

    @Test func controlDevicePassesAllParams() async {
        let (manager, mock) = makeSUT()
        mock.stubbedControlResult = ["success": true, "device": "Lamp", "action": "on"]

        let params = CallTool.Parameters(
            name: "control_device",
            arguments: [
                "name": .string("Lamp"),
                "action": .string("on"),
                "home": .string("Home"),
                "room": .string("Bedroom"),
            ]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.controlDeviceCalledWith?.id == nil)
        #expect(mock.controlDeviceCalledWith?.name == "Lamp")
        #expect(mock.controlDeviceCalledWith?.action == "on")
        #expect(mock.controlDeviceCalledWith?.homeName == "Home")
        #expect(mock.controlDeviceCalledWith?.roomName == "Bedroom")
        #expect(result.isError != true)
    }

    // MARK: - ID-based Lookup

    @Test func getDeviceStatePassesId() async {
        let (manager, mock) = makeSUT()
        mock.stubbedDeviceState = [
            "name": "Lamp",
            "reachable": true,
            "properties": [:] as [String: Any],
        ]

        let params = CallTool.Parameters(
            name: "get_device_state",
            arguments: ["id": .string("ABCD-1234")]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.getDeviceStateCalledWith?.id == "ABCD-1234")
        #expect(mock.getDeviceStateCalledWith?.name == nil)
        #expect(result.isError != true)
    }

    @Test func controlDevicePassesId() async {
        let (manager, mock) = makeSUT()
        mock.stubbedControlResult = ["success": true, "device": "Lamp", "action": "on"]

        let params = CallTool.Parameters(
            name: "control_device",
            arguments: ["id": .string("ABCD-1234"), "action": .string("on")]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.controlDeviceCalledWith?.id == "ABCD-1234")
        #expect(mock.controlDeviceCalledWith?.name == nil)
        #expect(mock.controlDeviceCalledWith?.action == "on")
        #expect(result.isError != true)
    }

    @Test func getDeviceStateIdTakesPrecedenceOverName() async {
        let (manager, mock) = makeSUT()
        mock.stubbedDeviceState = [
            "name": "Lamp",
            "reachable": true,
            "properties": [:] as [String: Any],
        ]

        let params = CallTool.Parameters(
            name: "get_device_state",
            arguments: ["id": .string("ABCD-1234"), "name": .string("Lamp")]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.getDeviceStateCalledWith?.id == "ABCD-1234")
        #expect(mock.getDeviceStateCalledWith?.name == "Lamp")
        #expect(result.isError != true)
    }

    // MARK: - Unknown Tool

    @Test func unknownToolReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(name: "nonexistent_tool", arguments: [:])
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("Unknown tool"))
        } else {
            Issue.record("Expected text content in error result")
        }
    }

    // MARK: - Missing Required Parameters

    @Test func getDeviceStateMissingIdAndNameReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(name: "get_device_state", arguments: [:])
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("'id' or 'name'"))
        }
    }

    @Test func controlDeviceMissingIdAndNameReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(name: "control_device", arguments: ["action": .string("on")])
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("'id' or 'name'"))
        }
    }

    @Test func controlDeviceMissingActionReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(name: "control_device", arguments: ["name": .string("Lamp")])
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("Missing required parameter: action"))
        }
    }

    // MARK: - Error Propagation

    @Test func getDeviceStateErrorPropagates() async {
        let (manager, mock) = makeSUT()
        mock.getDeviceStateError = HomeKitError.deviceNotFound("Ghost")

        let params = CallTool.Parameters(name: "get_device_state", arguments: ["name": .string("Ghost")])
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("Device 'Ghost' not found"))
        }
    }

    @Test func controlDeviceUnreachableErrorPropagates() async {
        let (manager, mock) = makeSUT()
        mock.controlDeviceError = HomeKitError.deviceUnreachable("Dead Bulb")

        let params = CallTool.Parameters(
            name: "control_device",
            arguments: ["name": .string("Dead Bulb"), "action": .string("on")]
        )
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("not reachable"))
        }
    }

    @Test func controlDeviceUnknownActionErrorPropagates() async {
        let (manager, mock) = makeSUT()
        mock.controlDeviceError = HomeKitError.unknownAction("explode")

        let params = CallTool.Parameters(
            name: "control_device",
            arguments: ["name": .string("Lamp"), "action": .string("explode")]
        )
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("Unknown action"))
        }
    }

    @Test func controlDeviceInvalidValueErrorPropagates() async {
        let (manager, mock) = makeSUT()
        mock.controlDeviceError = HomeKitError.invalidValue("brightness requires an integer 0-100")

        let params = CallTool.Parameters(
            name: "control_device",
            arguments: ["name": .string("Lamp"), "action": .string("set_brightness"), "value": .string("abc")]
        )
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("Invalid value"))
        }
    }

    // MARK: - Batch Control Devices

    @Test func batchControlDevicesRoutesCommands() async {
        let (manager, mock) = makeSUT()
        mock.stubbedBatchControlResult = [
            ["success": true, "device": "Lamp", "action": "off"],
            ["success": true, "device": "Fan", "action": "on"],
        ]

        let params = CallTool.Parameters(
            name: "batch_control_devices",
            arguments: [
                "commands": .array([
                    .object(["name": .string("Lamp"), "action": .string("off")]),
                    .object(["name": .string("Fan"), "action": .string("on")]),
                ]),
            ]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.batchControlDevicesCalledWith?.count == 2)
        #expect(result.isError != true)
    }

    @Test func batchControlDevicesEmptyCommandsReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(
            name: "batch_control_devices",
            arguments: ["commands": .array([])]
        )
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("commands"))
        }
    }

    @Test func batchControlDevicesMissingCommandsReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(name: "batch_control_devices", arguments: [:])
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
    }

    // MARK: - Batch Get Device State

    @Test func batchGetDeviceStateRoutesDevices() async {
        let (manager, mock) = makeSUT()
        mock.stubbedBatchGetDeviceStateResult = [
            ["success": true, "name": "Lamp", "reachable": true, "properties": [:] as [String: Any]],
            ["success": true, "name": "Fan", "reachable": true, "properties": [:] as [String: Any]],
        ]

        let params = CallTool.Parameters(
            name: "batch_get_device_state",
            arguments: [
                "devices": .array([
                    .object(["name": .string("Lamp")]),
                    .object(["name": .string("Fan"), "room": .string("Bedroom")]),
                ]),
            ]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.batchGetDeviceStateCalledWith?.count == 2)
        #expect(result.isError != true)
    }

    @Test func batchGetDeviceStateEmptyDevicesReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(
            name: "batch_get_device_state",
            arguments: ["devices": .array([])]
        )
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("devices"))
        }
    }

    @Test func batchGetDeviceStateMissingDevicesReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(name: "batch_get_device_state", arguments: [:])
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
    }

    // MARK: - Control Devices by Filter

    @Test func controlDevicesByFilterRoutesParams() async {
        let (manager, mock) = makeSUT()
        mock.stubbedControlByFilterResult = [
            ["success": true, "device": "Bedroom Light", "action": "off"],
        ]

        let params = CallTool.Parameters(
            name: "control_devices_by_filter",
            arguments: [
                "action": .string("off"),
                "room": .string("Bedroom"),
                "type": .string("light"),
            ]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.controlDevicesByFilterCalledWith?.roomName == "Bedroom")
        #expect(mock.controlDevicesByFilterCalledWith?.type == "light")
        #expect(mock.controlDevicesByFilterCalledWith?.action == "off")
        #expect(result.isError != true)
    }

    @Test func controlDevicesByFilterMissingActionReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(
            name: "control_devices_by_filter",
            arguments: ["room": .string("Bedroom")]
        )
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("action"))
        }
    }

    @Test func controlDevicesByFilterNoFilterReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(
            name: "control_devices_by_filter",
            arguments: ["action": .string("off")]
        )
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("filter"))
        }
    }

    @Test func controlDevicesByFilterPassesValue() async {
        let (manager, mock) = makeSUT()
        mock.stubbedControlByFilterResult = [
            ["success": true, "device": "Living Room Light", "action": "set_brightness"],
        ]

        let params = CallTool.Parameters(
            name: "control_devices_by_filter",
            arguments: [
                "action": .string("set_brightness"),
                "type": .string("light"),
                "value": .int(75),
            ]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.controlDevicesByFilterCalledWith?.action == "set_brightness")
        #expect(mock.controlDevicesByFilterCalledWith?.value as? Int == 75)
        #expect(result.isError != true)
    }

    // MARK: - List Scenes

    @Test func listScenesPassesHomeName() async {
        let (manager, mock) = makeSUT()
        mock.stubbedScenes = [
            ["name": "Good Night", "home": "My Home", "actionCount": 3, "type": "sleep"],
        ]

        let params = CallTool.Parameters(name: "list_scenes", arguments: ["home": .string("My Home")])
        let result = await manager.handleToolCall(params)

        #expect(mock.listScenesCalledWith == .some("My Home"))
        #expect(result.isError != true)
    }

    @Test func listScenesPassesNilWhenNoHome() async {
        let (manager, mock) = makeSUT()
        mock.stubbedScenes = []

        let params = CallTool.Parameters(name: "list_scenes", arguments: [:])
        _ = await manager.handleToolCall(params)

        #expect(mock.listScenesCalledWith == .some(nil))
    }

    // MARK: - Execute Scene

    @Test func executeScenePassesNameAndHome() async {
        let (manager, mock) = makeSUT()
        mock.stubbedExecuteSceneResult = ["success": true, "scene": "Good Night", "home": "My Home"]

        let params = CallTool.Parameters(
            name: "execute_scene",
            arguments: ["name": .string("Good Night"), "home": .string("My Home")]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.executeSceneCalledWith?.name == "Good Night")
        #expect(mock.executeSceneCalledWith?.homeName == "My Home")
        #expect(mock.executeSceneCalledWith?.id == nil)
        #expect(result.isError != true)
    }

    @Test func executeScenePassesId() async {
        let (manager, mock) = makeSUT()
        mock.stubbedExecuteSceneResult = ["success": true, "scene": "Good Night", "home": "My Home"]

        let params = CallTool.Parameters(
            name: "execute_scene",
            arguments: ["id": .string("ABCD-1234")]
        )
        let result = await manager.handleToolCall(params)

        #expect(mock.executeSceneCalledWith?.id == "ABCD-1234")
        #expect(mock.executeSceneCalledWith?.name == nil)
        #expect(result.isError != true)
    }

    @Test func executeSceneMissingIdAndNameReturnsError() async {
        let (manager, _) = makeSUT()

        let params = CallTool.Parameters(name: "execute_scene", arguments: [:])
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("'id' or 'name'"))
        }
    }

    @Test func executeSceneNotFoundErrorPropagates() async {
        let (manager, mock) = makeSUT()
        mock.executeSceneError = HomeKitError.sceneNotFound("Ghost Scene")

        let params = CallTool.Parameters(
            name: "execute_scene",
            arguments: ["name": .string("Ghost Scene")]
        )
        let result = await manager.handleToolCall(params)

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("Scene 'Ghost Scene' not found"))
        }
    }

    // MARK: - Value Conversion

    @Test func convertValueNull() async {
        let (manager, _) = makeSUT()
        let result = manager.convertValue(.null)
        #expect(result is NSNull)
    }

    @Test func convertValueBool() async {
        let (manager, _) = makeSUT()
        let result = manager.convertValue(.bool(true))
        #expect(result as? Bool == true)
    }

    @Test func convertValueInt() async {
        let (manager, _) = makeSUT()
        let result = manager.convertValue(.int(42))
        #expect(result as? Int == 42)
    }

    @Test func convertValueDouble() async {
        let (manager, _) = makeSUT()
        let result = manager.convertValue(.double(3.14))
        #expect(result as? Double == 3.14)
    }

    @Test func convertValueString() async {
        let (manager, _) = makeSUT()
        let result = manager.convertValue(.string("hello"))
        #expect(result as? String == "hello")
    }

    @Test func convertValueStringifiedJsonObjectIsParsed() async {
        let (manager, _) = makeSUT()
        let result = manager.convertValue(.string("{\"hue\": 200, \"saturation\": 50}"))
        let dict = result as? [String: Any]
        #expect(dict != nil)
        #expect(dict?["hue"] as? Int == 200)
        #expect(dict?["saturation"] as? Int == 50)
    }

    @Test func convertValuePlainStringStaysString() async {
        let (manager, _) = makeSUT()
        // A string that is NOT valid JSON should remain a string
        let result = manager.convertValue(.string("just text"))
        #expect(result as? String == "just text")
    }

    @Test func convertValueArray() async {
        let (manager, _) = makeSUT()
        let result = manager.convertValue(.array([.int(1), .int(2), .int(3)]))
        let arr = result as? [Any]
        #expect(arr?.count == 3)
        #expect(arr?[0] as? Int == 1)
        #expect(arr?[2] as? Int == 3)
    }

    @Test func convertValueObject() async {
        let (manager, _) = makeSUT()
        let result = manager.convertValue(.object(["key": .string("value"), "num": .int(42)]))
        let dict = result as? [String: Any]
        #expect(dict?["key"] as? String == "value")
        #expect(dict?["num"] as? Int == 42)
    }

    // MARK: - Response Format

    @Test func successfulListHomesReturnsValidJson() async {
        let (manager, mock) = makeSUT()
        mock.stubbedHomes = [
            ["name": "My Home", "isPrimary": true, "roomCount": 3, "accessoryCount": 5],
        ]

        let params = CallTool.Parameters(name: "list_homes", arguments: [:])
        let result = await manager.handleToolCall(params)

        #expect(result.isError != true)
        if case .text(let text, _, _) = result.content.first {
            // Should be valid JSON
            let data = text.data(using: .utf8)!
            let parsed = try? JSONSerialization.jsonObject(with: data)
            #expect(parsed != nil, "Response should be valid JSON")
            #expect(text.contains("My Home"))
        } else {
            Issue.record("Expected text content in result")
        }
    }
}
