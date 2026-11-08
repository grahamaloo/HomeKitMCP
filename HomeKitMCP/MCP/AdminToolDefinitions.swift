import MCP

/// Tools backed by `HomeKitAdministering`. Write tools preview unless `confirm` is true.
enum AdminToolDefinitions {
    private static func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static let confirm = prop("boolean", "Apply the change. Omitted or false = preview only, nothing is changed.")

    private static func tool(_ name: String, _ description: String, _ props: [String: Value], required: [String], write: Bool = true) -> Tool {
        var p = props
        if write { p["confirm"] = confirm }
        return Tool(
            name: name,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(p),
                "required": .array(required.map { .string($0) }),
            ])
        )
    }

    static let all: [Tool] = [
        tool("audit_home",
             "Read-only full dump of a home: rooms, zones, accessories with every service and characteristic (with ids), scenes with their actions, and automations with triggers, conditions and scenes. Use the ids from here for all write tools.",
             ["home": prop("string", "Home name. Omit for all homes."),
              "read_values": prop("boolean", "Read live values from reachable devices (slower). Default false = cached values.")],
             required: [], write: false),
        tool("rename_accessory",
             "Rename an accessory. By default also renames its services that carry the accessory's old name (that is what the Home app tiles show).",
             ["id": prop("string", "Accessory id"),
              "name": prop("string", "New name"),
              "rename_matching_services": prop("boolean", "Also rename services named like the accessory. Default true.")],
             required: ["id", "name"]),
        tool("rename_service",
             "Rename a single service (one tile of a multi-function accessory, e.g. the light vs. the switch of a relay).",
             ["id": prop("string", "Service id"), "name": prop("string", "New name")],
             required: ["id", "name"]),
        tool("move_accessory",
             "Assign an accessory to another room in its home.",
             ["id": prop("string", "Accessory id"), "room": prop("string", "Target room name")],
             required: ["id", "room"]),
        tool("rename_scene",
             "Rename a scene.",
             ["id": prop("string", "Scene id"), "name": prop("string", "New name")],
             required: ["id", "name"]),
        tool("delete_scene",
             "Delete a user-defined scene. Built-in scenes cannot be deleted. Reports automations that use it.",
             ["id": prop("string", "Scene id")],
             required: ["id"]),
        tool("set_scene_action",
             "Add or update one action in a scene: set a characteristic to a target value (e.g. a TV's Active to 0). Value is checked against the characteristic's format and range. Does NOT work on an automation's built-in action list (editable:false in audit_home); Apple restricts those to the Home app.",
             ["scene_id": prop("string", "Scene id"),
              "characteristic_id": prop("string", "Characteristic id (from audit_home)"),
              "value": .object(["description": .string("Target value: boolean, number or string depending on the characteristic")])],
             required: ["scene_id", "characteristic_id", "value"]),
        tool("remove_scene_action",
             "Remove the action for one characteristic from a scene.",
             ["scene_id": prop("string", "Scene id"),
              "characteristic_id": prop("string", "Characteristic id the action writes")],
             required: ["scene_id", "characteristic_id"]),
        tool("set_automation_enabled",
             "Enable or disable an automation.",
             ["id": prop("string", "Automation id"), "enabled": prop("boolean", "true to enable, false to disable")],
             required: ["id", "enabled"]),
        tool("set_automation_weekdays",
             "Restrict an event-based automation (incl. ones made in the Home app, e.g. people arrive/leave) to certain weekdays. Empty list or all 7 = every day.",
             ["id": prop("string", "Automation id"),
              "weekdays": .object(["type": .string("array"), "items": .object(["type": .string("integer")]), "description": .string("1 = Sunday ... 7 = Saturday")])],
             required: ["id", "weekdays"]),
        tool("rename_automation",
             "Rename an automation.",
             ["id": prop("string", "Automation id"), "name": prop("string", "New name")],
             required: ["id", "name"]),
        tool("delete_automation",
             "Delete an automation. Its scenes are kept.",
             ["id": prop("string", "Automation id")],
             required: ["id"]),
        tool("add_room_to_zone",
             "Add a room to a zone (e.g. a floor). A room can be in several zones.",
             ["room": prop("string", "Room name"), "zone": prop("string", "Zone name"),
              "home": prop("string", "Home name. Default: primary home.")],
             required: ["room", "zone"]),
        tool("remove_room_from_zone",
             "Remove a room from a zone.",
             ["room": prop("string", "Room name"), "zone": prop("string", "Zone name"),
              "home": prop("string", "Home name. Default: primary home.")],
             required: ["room", "zone"]),
        tool("create_scene",
             "Create a scene from characteristic writes. Values are checked against format and range. Rolled back if any action fails.",
             ["name": prop("string", "Scene name (must be unique in the home)"),
              "home": prop("string", "Home name. Default: primary home."),
              "actions": .object([
                  "type": .string("array"),
                  "description": .string("[{characteristic_id, value}], ids from audit_home"),
                  "items": .object(["type": .string("object")]),
              ])],
             required: ["name", "actions"]),
        tool("attach_scene_to_automation",
             "Make an existing automation also run an existing (normal, visible) scene.",
             ["automation_id": prop("string", "Automation id"), "scene_id": prop("string", "Scene id")],
             required: ["automation_id", "scene_id"]),
        tool("create_automation",
             """
             Create an automation that runs existing scenes (create them first with create_scene). \
             Events (any one fires it): {type:"time", hour, minute} | {type:"sun", event:"sunrise"|"sunset", offset_minutes} | \
             {type:"threshold", characteristic_id, above?, below?} (fires when the value crosses into the range, e.g. above 25 = rises above 25) | \
             {type:"value", characteristic_id, value}. \
             Conditions (all must hold): {type:"characteristic", characteristic_id, operator:"=="|"!="|"<"|"<="|">"|">=", value} | \
             {type:"after"|"before", hour, minute} | {type:"after_sun"|"before_sun", event, offset_minutes}. \
             Needs a home hub for sensor triggers. Rolled back if any step fails.
             """,
             ["name": prop("string", "Automation name (must be unique in the home)"),
              "home": prop("string", "Home name. Default: primary home."),
              "scene_ids": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Scenes to run")]),
              "events": .object(["type": .string("array"), "items": .object(["type": .string("object")]), "description": .string("Trigger events, see tool description")]),
              "conditions": .object(["type": .string("array"), "items": .object(["type": .string("object")]), "description": .string("Optional conditions, ANDed")]),
              "weekdays": .object(["type": .string("array"), "items": .object(["type": .string("integer")]), "description": .string("Optional, 1 = Sunday ... 7 = Saturday. Omit for every day.")]),
              "enabled": prop("boolean", "Enable right away. Default true.")],
             required: ["name", "scene_ids", "events"]),
    ]
}
