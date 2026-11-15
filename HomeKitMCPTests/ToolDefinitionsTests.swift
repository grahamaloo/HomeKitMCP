import MCP
import Testing
@testable import HomeKitMCP

struct ToolDefinitionsTests {

    @Test func allToolsCount() {
        #expect(ToolDefinitions.all.count == 10)
    }

    @Test func toolNamesAreCorrect() {
        let names = ToolDefinitions.all.map(\.name)
        #expect(names == [
            "list_homes", "list_rooms", "list_devices", "get_device_state", "control_device",
            "batch_control_devices", "batch_get_device_state", "control_devices_by_filter",
            "list_scenes", "execute_scene",
        ])
    }

    @Test func allToolsHaveDescriptions() {
        for tool in ToolDefinitions.all {
            #expect(tool.description != nil, "Tool '\(tool.name)' is missing a description")
            if let desc = tool.description {
                #expect(!desc.isEmpty, "Tool '\(tool.name)' has an empty description")
            }
        }
    }

    @Test func allToolsHaveObjectSchema() {
        for tool in ToolDefinitions.all {
            // Each schema should be an object containing "type": "object"
            if case .object(let schema) = tool.inputSchema {
                #expect(schema["type"] == .string("object"),
                        "Tool '\(tool.name)' schema type should be 'object'")
            } else {
                Issue.record("Tool '\(tool.name)' inputSchema is not an object")
            }
        }
    }

    @Test func getDeviceStateHasIdAndNameProperties() {
        let tool = ToolDefinitions.getDeviceState
        if case .object(let schema) = tool.inputSchema,
           case .object(let properties) = schema["properties"]
        {
            #expect(properties["id"] != nil, "get_device_state should have an 'id' property")
            #expect(properties["name"] != nil, "get_device_state should have a 'name' property")
            // Neither id nor name is individually required — at least one must be provided at runtime
            #expect(schema["required"] == nil, "get_device_state should not have required fields (id-or-name validated at runtime)")
        } else {
            Issue.record("getDeviceState inputSchema is not an object")
        }
    }

    @Test func controlDeviceRequiresAction() {
        let tool = ToolDefinitions.controlDevice
        if case .object(let schema) = tool.inputSchema,
           case .object(let properties) = schema["properties"]
        {
            #expect(properties["id"] != nil, "control_device should have an 'id' property")
            #expect(properties["name"] != nil, "control_device should have a 'name' property")
            #expect(schema["required"] == .array([.string("action")]))
        } else {
            Issue.record("controlDevice inputSchema is not an object")
        }
    }

    @Test func controlDeviceActionHasEnumValues() {
        let tool = ToolDefinitions.controlDevice
        if case .object(let schema) = tool.inputSchema,
           case .object(let properties) = schema["properties"],
           case .object(let actionProp) = properties["action"],
           case .array(let enumValues) = actionProp["enum"]
        {
            let actions = enumValues.compactMap { value -> String? in
                if case .string(let s) = value { return s }
                return nil
            }
            let expected = [
                "on", "off", "toggle",
                "set_brightness", "set_hue", "set_saturation", "set_color",
                "lock", "unlock",
                "open", "close",
                "set_temperature", "set_thermostat_mode",
            ]
            #expect(actions == expected)
        } else {
            Issue.record("Could not extract action enum values from controlDevice schema")
        }
    }

    @Test func listHomesHasNoProperties() {
        let tool = ToolDefinitions.listHomes
        if case .object(let schema) = tool.inputSchema,
           case .object(let properties) = schema["properties"]
        {
            #expect(properties.isEmpty, "list_homes should have no properties")
        } else {
            Issue.record("list_homes inputSchema is not structured as expected")
        }
    }

    @Test func listRoomsHasHomeProperty() {
        let tool = ToolDefinitions.listRooms
        if case .object(let schema) = tool.inputSchema,
           case .object(let properties) = schema["properties"]
        {
            #expect(properties["home"] != nil, "list_rooms should have a 'home' property")
        } else {
            Issue.record("list_rooms inputSchema is not structured as expected")
        }
    }

    @Test func listDevicesHasThreeFilterProperties() {
        let tool = ToolDefinitions.listDevices
        if case .object(let schema) = tool.inputSchema,
           case .object(let properties) = schema["properties"]
        {
            #expect(properties["home"] != nil, "list_devices should have a 'home' property")
            #expect(properties["room"] != nil, "list_devices should have a 'room' property")
            #expect(properties["type"] != nil, "list_devices should have a 'type' property")
            #expect(properties.count == 3, "list_devices should have exactly 3 properties")
        } else {
            Issue.record("list_devices inputSchema is not structured as expected")
        }
    }
}
