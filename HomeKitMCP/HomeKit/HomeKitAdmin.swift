import CoreFoundation
import Foundation
import HomeKit

/// Home administration: a full read-only audit plus edits to names, rooms, scenes and automations.
///
/// Every write tool is a preview unless it is called with `confirm: true`. Writes address objects
/// by uniqueIdentifier only (from `audit_home`), never by name, so a duplicate name can't hit the
/// wrong object.
@MainActor
protocol HomeKitAdministering {
    func handleAdminTool(_ name: String, _ args: [String: Any]) async throws -> Any?
}

struct AdminError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension HomeKitManager: HomeKitAdministering {
    /// Returns nil when `name` is not an admin tool.
    func handleAdminTool(_ name: String, _ args: [String: Any]) async throws -> Any? {
        let confirm = args["confirm"] as? Bool ?? false
        switch name {
        case "audit_home":
            return await auditHomes(homeName: args["home"] as? String, readValues: args["read_values"] as? Bool ?? false)

        case "rename_accessory":
            let a = try accessory(args["id"])
            let newName = try string(args["name"], "name")
            let alsoServices = args["rename_matching_services"] as? Bool ?? true
            let old = a.name
            var changes: [String] = []
            if old != newName { changes.append("accessory '\(old)' -> '\(newName)'") }
            let services = alsoServices
                ? a.services.filter { $0.name == old && $0.serviceType != HMServiceTypeAccessoryInformation && $0.name != newName }
                : []
            for s in services { changes.append("service '\(s.name)' [\(s.localizedDescription)] -> '\(newName)'") }
            if confirm {
                if old != newName { try await a.updateName(newName) }
                for s in services { try await s.updateName(newName) }
            }
            return result(confirm, changes)

        case "rename_service":
            let s = try service(args["id"])
            let newName = try string(args["name"], "name")
            let changes = s.name == newName ? [] :
                ["service '\(s.name)' [\(s.localizedDescription)] on '\(s.accessory?.name ?? "?")' -> '\(newName)'"]
            if confirm, !changes.isEmpty { try await s.updateName(newName) }
            return result(confirm, changes)

        case "move_accessory":
            let a = try accessory(args["id"])
            let home = try homeOf(a)
            let roomName = try string(args["room"], "room")
            let room: HMRoom
            if roomName.localizedCaseInsensitiveCompare(home.roomForEntireHome().name) == .orderedSame
                || roomName.localizedCaseInsensitiveCompare("Default Room") == .orderedSame {
                room = home.roomForEntireHome()
            } else if let r = home.rooms.first(where: { $0.name.localizedCaseInsensitiveCompare(roomName) == .orderedSame }) {
                room = r
            } else {
                throw AdminError("room '\(roomName)' not found in home '\(home.name)'. Rooms: \(home.rooms.map(\.name).joined(separator: ", "))")
            }
            let changes = a.room?.uniqueIdentifier == room.uniqueIdentifier ? [] :
                ["'\(a.name)': room '\(a.room?.name ?? "?")' -> '\(room.name)'"]
            if confirm, !changes.isEmpty { try await home.assignAccessory(a, to: room) }
            return result(confirm, changes)

        case "rename_scene":
            let (set, home) = try actionSet(args["id"])
            let newName = try string(args["name"], "name")
            if home.actionSets.contains(where: { $0 !== set && $0.name.localizedCaseInsensitiveCompare(newName) == .orderedSame }) {
                throw AdminError("scene name '\(newName)' already in use")
            }
            let changes = set.name == newName ? [] : ["scene '\(set.name)' -> '\(newName)'"]
            if confirm, !changes.isEmpty { try await set.updateName(newName) }
            return result(confirm, changes)

        case "delete_scene":
            let (set, home) = try actionSet(args["id"])
            guard set.actionSetType == HMActionSetTypeUserDefined else {
                throw AdminError("'\(set.name)' is a built-in scene (\(set.actionSetType)); HomeKit does not allow deleting it")
            }
            let users = home.triggers.filter { $0.actionSets.contains { $0.uniqueIdentifier == set.uniqueIdentifier } }
            var changes = ["delete scene '\(set.name)' (\(set.actions.count) action(s))"]
            for t in users { changes.append("note: used by automation '\(t.name)', which loses this scene") }
            if confirm { try await home.removeActionSet(set) }
            return result(confirm, changes)

        case "set_scene_action":
            let (set, _) = try actionSet(args["scene_id"])
            let c = try characteristic(args["characteristic_id"])
            guard c.properties.contains(HMCharacteristicPropertyWritable) else {
                throw AdminError("\(label(c)) is not writable")
            }
            let value = try coerce(args["value"], for: c)
            let existing = writeActions(set).first { $0.characteristic.uniqueIdentifier == c.uniqueIdentifier }
            var changes: [String] = []
            if let existing {
                if !(existing.targetValue as AnyObject).isEqual(value) {
                    changes.append("scene '\(set.name)': \(label(c)) \(existing.targetValue) -> \(value)")
                    if confirm { try await existing.updateTargetValue(value) }
                }
            } else {
                changes.append("scene '\(set.name)': add \(label(c)) = \(value)")
                if confirm { try await set.addAction(HMCharacteristicWriteAction(characteristic: c, targetValue: value)) }
            }
            return result(confirm, changes)

        case "remove_scene_action":
            let (set, _) = try actionSet(args["scene_id"])
            let cid = try string(args["characteristic_id"], "characteristic_id")
            guard let w = writeActions(set).first(where: { $0.characteristic.uniqueIdentifier.uuidString == cid }) else {
                throw AdminError("scene '\(set.name)' has no action for characteristic \(cid)")
            }
            let changes = ["scene '\(set.name)': remove \(label(w.characteristic)) = \(w.targetValue)"]
            if confirm { try await set.removeAction(w) }
            return result(confirm, changes)

        case "set_automation_enabled":
            let (t, _) = try trigger(args["id"])
            guard let enabled = args["enabled"] as? Bool else { throw AdminError("missing boolean 'enabled'") }
            let changes = t.isEnabled == enabled ? [] : ["automation '\(t.name)': enabled \(t.isEnabled) -> \(enabled)"]
            if confirm, !changes.isEmpty { try await t.enable(enabled) }
            return result(confirm, changes)

        case "set_automation_weekdays":
            // Works on Home-app automations too: it changes the trigger, not its (trigger-owned) actions.
            let (t, _) = try trigger(args["id"])
            guard let et = t as? HMEventTrigger else { throw AdminError("'\(t.name)' is not an event-based automation") }
            let weekdays = Array(Set((args["weekdays"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })).sorted()
            guard weekdays.allSatisfy({ (1...7).contains($0) }) else { throw AdminError("weekdays are 1 (Sunday) ... 7 (Saturday)") }
            let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let fmt: ([Int]) -> String = { $0.isEmpty || $0.count == 7 ? "every day" : $0.map { names[$0] }.joined(separator: ",") }
            let current = (et.recurrences ?? []).compactMap(\.weekday).sorted()
            let changes = fmt(current) == fmt(weekdays) ? [] : ["automation '\(t.name)': days \(fmt(current)) -> \(fmt(weekdays))"]
            if confirm, !changes.isEmpty {
                let wasEnabled = et.isEnabled
                try await et.updateRecurrences(weekdays.isEmpty || weekdays.count == 7 ? nil : weekdays.map { DateComponents(weekday: $0) })
                // Seen 2026-11-08: HomeKit disables the trigger when its recurrences change. Restore it.
                if wasEnabled, !et.isEnabled { try await et.enable(true) }
            }
            return result(confirm, changes)

        case "rename_automation":
            let (t, home) = try trigger(args["id"])
            let newName = try string(args["name"], "name")
            if home.triggers.contains(where: { $0 !== t && $0.name.localizedCaseInsensitiveCompare(newName) == .orderedSame }) {
                throw AdminError("automation name '\(newName)' already in use")
            }
            let changes = t.name == newName ? [] : ["automation '\(t.name)' -> '\(newName)'"]
            if confirm, !changes.isEmpty { try await t.updateName(newName) }
            return result(confirm, changes)

        case "delete_automation":
            let (t, home) = try trigger(args["id"])
            let changes = ["delete automation '\(t.name)' (enabled=\(t.isEnabled), scenes: \(t.actionSets.map(\.name)))"]
            if confirm { try await home.removeTrigger(t) }
            return result(confirm, changes)

        case "add_room_to_zone", "remove_room_from_zone":
            let home = try homeArg(args["home"])
            let r = try room(try string(args["room"], "room"), in: home)
            let z = try zone(try string(args["zone"], "zone"), in: home)
            let has = z.rooms.contains { $0.uniqueIdentifier == r.uniqueIdentifier }
            let adding = name == "add_room_to_zone"
            var changes: [String] = []
            if adding, !has {
                changes.append("zone '\(z.name)': add room '\(r.name)'")
                let others = home.zones.filter { $0 !== z && $0.rooms.contains { $0.uniqueIdentifier == r.uniqueIdentifier } }
                for o in others { changes.append("note: '\(r.name)' stays in zone '\(o.name)' as well") }
                if confirm { try await z.addRoom(r) }
            } else if !adding, has {
                changes.append("zone '\(z.name)': remove room '\(r.name)'")
                if confirm { try await z.removeRoom(r) }
            }
            return result(confirm, changes)

        case "create_scene":
            let home = try homeArg(args["home"])
            let sceneName = try string(args["name"], "name")
            if home.actionSets.contains(where: { $0.name.localizedCaseInsensitiveCompare(sceneName) == .orderedSame }) {
                throw AdminError("scene name '\(sceneName)' already in use")
            }
            let specs = args["actions"] as? [[String: Any]] ?? []
            guard !specs.isEmpty else { throw AdminError("'actions' must list at least one {characteristic_id, value}") }
            var writes: [(HMCharacteristic, NSCopying)] = []
            for s in specs {
                let c = try characteristic(s["characteristic_id"], in: home)
                guard c.properties.contains(HMCharacteristicPropertyWritable) else { throw AdminError("\(label(c)) is not writable") }
                if writes.contains(where: { $0.0.uniqueIdentifier == c.uniqueIdentifier }) { throw AdminError("\(label(c)) listed twice") }
                writes.append((c, try coerce(s["value"], for: c)))
            }
            var changes = ["create scene '\(sceneName)' in '\(home.name)'"]
            changes += writes.map { "  \(label($0.0)) = \($0.1)" }
            var out = result(confirm, changes)
            if confirm {
                let set = try await home.addActionSet(named: sceneName)
                do {
                    for (c, v) in writes { try await set.addAction(HMCharacteristicWriteAction(characteristic: c, targetValue: v)) }
                } catch {
                    try? await home.removeActionSet(set)
                    throw AdminError("creating scene failed, rolled back: \(error.localizedDescription)")
                }
                out["id"] = set.uniqueIdentifier.uuidString
            }
            return out

        case "attach_scene_to_automation":
            let (t, home) = try trigger(args["automation_id"])
            let (set, setHome) = try actionSet(args["scene_id"])
            guard setHome === home else { throw AdminError("scene and automation are in different homes") }
            let changes = t.actionSets.contains(where: { $0.uniqueIdentifier == set.uniqueIdentifier }) ? [] :
                ["automation '\(t.name)': also run scene '\(set.name)'"]
            if confirm, !changes.isEmpty { try await t.addActionSet(set) }
            return result(confirm, changes)

        case "create_automation":
            let home = try homeArg(args["home"])
            let autoName = try string(args["name"], "name")
            if home.triggers.contains(where: { $0.name.localizedCaseInsensitiveCompare(autoName) == .orderedSame }) {
                throw AdminError("automation name '\(autoName)' already in use")
            }
            let sceneIds = (args["scene_ids"] as? [Any] ?? []).compactMap { $0 as? String }
            guard !sceneIds.isEmpty else { throw AdminError("'scene_ids' must list at least one scene (create one with create_scene)") }
            var sets: [HMActionSet] = []
            for sid in sceneIds {
                guard let s = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(sid) == .orderedSame }) else {
                    throw AdminError("scene \(sid) not found among the scenes of '\(home.name)'")
                }
                sets.append(s)
            }
            let eventSpecs = args["events"] as? [[String: Any]] ?? []
            guard !eventSpecs.isEmpty else { throw AdminError("'events' must list at least one trigger event") }
            var events: [HMEvent] = []
            var whenText: [String] = []
            for e in eventSpecs { let (ev, t) = try makeEvent(e, home); events.append(ev); whenText.append(t) }
            var preds: [NSPredicate] = []
            var ifText: [String] = []
            for c in args["conditions"] as? [[String: Any]] ?? [] { let (p, t) = try makeCondition(c, home); preds.append(p); ifText.append(t) }
            let weekdays = (args["weekdays"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            guard weekdays.allSatisfy({ (1...7).contains($0) }) else { throw AdminError("weekdays are 1 (Sunday) ... 7 (Saturday)") }
            let enabled = args["enabled"] as? Bool ?? true
            let predicate: NSPredicate? = preds.isEmpty ? nil
                : preds.count == 1 ? preds[0] : NSCompoundPredicate(andPredicateWithSubpredicates: preds)
            let changes = [
                "create automation '\(autoName)' in '\(home.name)'",
                "  when: " + whenText.joined(separator: " OR "),
                "  only if: " + (ifText.isEmpty ? "always" : ifText.joined(separator: " AND ")),
                "  days: " + (weekdays.isEmpty ? "every day" : weekdays.map(String.init).joined(separator: ",")),
                "  runs: " + sets.map { "'\($0.name)'" }.joined(separator: ", "),
                "  enabled: \(enabled)",
            ]
            var out = result(confirm, changes)
            if confirm {
                let trigger = HMEventTrigger(
                    name: autoName, events: events, end: nil,
                    recurrences: weekdays.isEmpty ? nil : weekdays.map { DateComponents(weekday: $0) },
                    predicate: predicate)
                try await home.addTrigger(trigger)
                do {
                    for s in sets { try await trigger.addActionSet(s) }
                    if enabled { try await trigger.enable(true) }
                } catch {
                    try? await home.removeTrigger(trigger)
                    throw AdminError("creating automation failed, rolled back: \(error.localizedDescription)")
                }
                out["id"] = trigger.uniqueIdentifier.uuidString
            }
            return out

        default:
            return nil
        }
    }

    // MARK: - Lookup

    private func allHomes() -> [HMHome] { homeManager?.homes ?? [] }

    private func string(_ v: Any?, _ field: String) throws -> String {
        guard let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AdminError("missing or empty '\(field)'")
        }
        return s
    }

    private func uuid(_ v: Any?, _ field: String) throws -> UUID {
        let s = try string(v, field)
        guard let u = UUID(uuidString: s) else { throw AdminError("'\(field)' is not a UUID: \(s)") }
        return u
    }

    private func accessory(_ v: Any?) throws -> HMAccessory {
        let id = try uuid(v, "id")
        for h in allHomes() { if let a = h.accessories.first(where: { $0.uniqueIdentifier == id }) { return a } }
        throw AdminError("accessory \(id) not found")
    }

    private func homeOf(_ a: HMAccessory) throws -> HMHome {
        guard let h = allHomes().first(where: { $0.accessories.contains { $0.uniqueIdentifier == a.uniqueIdentifier } }) else {
            throw AdminError("home of '\(a.name)' not found")
        }
        return h
    }

    private func service(_ v: Any?) throws -> HMService {
        let id = try uuid(v, "id")
        for h in allHomes() {
            for a in h.accessories {
                if let s = a.services.first(where: { $0.uniqueIdentifier == id }) { return s }
            }
        }
        throw AdminError("service \(id) not found")
    }

    private func characteristic(_ v: Any?) throws -> HMCharacteristic {
        let id = try uuid(v, "characteristic_id")
        for h in allHomes() {
            for a in h.accessories {
                for s in a.services {
                    if let c = s.characteristics.first(where: { $0.uniqueIdentifier == id }) { return c }
                }
            }
        }
        throw AdminError("characteristic \(id) not found")
    }

    /// Finds a scene. Hidden action sets owned by an automation made in the Home app are found too,
    /// but Apple only lets the Home app modify them (third-party writes fail with "Missing entitlement
    /// for API"), so writes reject them up front with an explanation.
    private func actionSet(_ v: Any?, forWrite: Bool = true) throws -> (HMActionSet, HMHome) {
        let id = try uuid(v, "id")
        for h in allHomes() {
            if let s = h.actionSets.first(where: { $0.uniqueIdentifier == id }) { return (s, h) }
            for t in h.triggers {
                if let s = t.actionSets.first(where: { $0.uniqueIdentifier == id }) {
                    if forWrite {
                        throw AdminError("""
                            \(id) is the built-in action list of automation '\(t.name)', made in the Home app. \
                            Apple only allows the Home app to edit it. Edit the automation in the Home app, \
                            or create_scene + attach_scene_to_automation.
                            """)
                    }
                    return (s, h)
                }
            }
        }
        throw AdminError("scene \(id) not found")
    }

    private func homeArg(_ v: Any?) throws -> HMHome {
        if let name = v as? String, !name.isEmpty {
            guard let h = allHomes().first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw AdminError("home '\(name)' not found")
            }
            return h
        }
        guard let h = homeManager?.primaryHome ?? allHomes().first else { throw AdminError("no home") }
        return h
    }

    private func room(_ name: String, in home: HMHome) throws -> HMRoom {
        guard let r = home.rooms.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw AdminError("room '\(name)' not found in home '\(home.name)'. Rooms: \(home.rooms.map(\.name).joined(separator: ", "))")
        }
        return r
    }

    private func zone(_ name: String, in home: HMHome) throws -> HMZone {
        guard let z = home.zones.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw AdminError("zone '\(name)' not found in home '\(home.name)'. Zones: \(home.zones.map(\.name).joined(separator: ", "))")
        }
        return z
    }

    private func characteristic(_ v: Any?, in home: HMHome) throws -> HMCharacteristic {
        let c = try characteristic(v)
        guard let a = c.service?.accessory, home.accessories.contains(where: { $0.uniqueIdentifier == a.uniqueIdentifier }) else {
            throw AdminError("\(label(c)) is not in home '\(home.name)'")
        }
        return c
    }

    private func number(_ v: Any?, _ field: String) throws -> Double {
        if let b = v as? Bool { return b ? 1 : 0 }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let d = Double(s) { return d }
        throw AdminError("'\(field)' must be a number")
    }

    private func clock(_ spec: [String: Any]) throws -> DateComponents {
        let h = Int(try number(spec["hour"], "hour"))
        let m = Int((spec["minute"] as? NSNumber)?.intValue ?? 0)
        guard (0...23).contains(h), (0...59).contains(m) else { throw AdminError("invalid time \(h):\(m)") }
        return DateComponents(hour: h, minute: m)
    }

    private func significant(_ spec: [String: Any]) throws -> (HMSignificantTimeEvent, String) {
        let which = try string(spec["event"], "event").lowercased()
        guard which == "sunrise" || which == "sunset" else { throw AdminError("event must be sunrise or sunset") }
        let offset = Int((spec["offset_minutes"] as? NSNumber)?.intValue ?? 0)
        let ev = HMSignificantTimeEvent(significantEvent: which == "sunrise" ? .sunrise : .sunset,
                                        offset: offset == 0 ? nil : DateComponents(minute: offset))
        return (ev, offset == 0 ? which : "\(which) \(offset > 0 ? "+" : "")\(offset) min")
    }

    private func hhmm(_ c: DateComponents) -> String { String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }

    private func makeEvent(_ spec: [String: Any], _ home: HMHome) throws -> (HMEvent, String) {
        switch try string(spec["type"], "events[].type") {
        case "time":
            let t = try clock(spec)
            return (HMCalendarEvent(fire: t), "at \(hhmm(t))")
        case "sun":
            let (ev, text) = try significant(spec)
            return (ev, "at \(text)")
        case "threshold":
            let c = try characteristic(spec["characteristic_id"], in: home)
            guard c.properties.contains(HMCharacteristicPropertySupportsEventNotification) else {
                throw AdminError("\(label(c)) does not send change notifications, it cannot trigger an automation")
            }
            let above = spec["above"].map { try? number($0, "above") } ?? nil
            let below = spec["below"].map { try? number($0, "below") } ?? nil
            let range: HMNumberRange
            switch (above, below) {
            case let (a?, b?): range = HMNumberRange(minValue: NSNumber(value: a), maxValue: NSNumber(value: b))
            case let (a?, nil): range = HMNumberRange(minValue: NSNumber(value: a))
            case let (nil, b?): range = HMNumberRange(maxValue: NSNumber(value: b))
            default: throw AdminError("threshold needs 'above' and/or 'below'")
            }
            let text = [above.map { "rises above \($0)" }, below.map { "falls below \($0)" }].compactMap { $0 }.joined(separator: " / ")
            return (HMCharacteristicThresholdRangeEvent(characteristic: c, thresholdRange: range), "when \(label(c)) \(text)")
        case "value":
            let c = try characteristic(spec["characteristic_id"], in: home)
            guard c.properties.contains(HMCharacteristicPropertySupportsEventNotification) else {
                throw AdminError("\(label(c)) does not send change notifications, it cannot trigger an automation")
            }
            let v = try coerce(spec["value"], for: c)
            return (HMCharacteristicEvent(characteristic: c, triggerValue: v), "when \(label(c)) becomes \(v)")
        case let other:
            throw AdminError("unknown event type '\(other)' (time, sun, threshold, value)")
        }
    }

    private func makeCondition(_ spec: [String: Any], _ home: HMHome) throws -> (NSPredicate, String) {
        switch try string(spec["type"], "conditions[].type") {
        case "characteristic":
            let c = try characteristic(spec["characteristic_id"], in: home)
            let ops: [String: NSComparisonPredicate.Operator] = [
                "==": .equalTo, "!=": .notEqualTo, "<": .lessThan, "<=": .lessThanOrEqualTo,
                ">": .greaterThan, ">=": .greaterThanOrEqualTo,
            ]
            let opText = try string(spec["operator"], "operator")
            guard let op = ops[opText] else { throw AdminError("operator must be one of \(ops.keys.sorted())") }
            let v = try coerce(spec["value"], for: c)
            return (HMEventTrigger.predicateForEvaluatingTrigger(c, relatedBy: op, toValue: v), "\(label(c)) \(opText) \(v)")
        case "after":
            let t = try clock(spec)
            return (HMEventTrigger.predicateForEvaluatingTrigger(occurringAfter: t), "after \(hhmm(t))")
        case "before":
            let t = try clock(spec)
            return (HMEventTrigger.predicateForEvaluatingTrigger(occurringBefore: t), "before \(hhmm(t))")
        case "after_sun":
            let (ev, text) = try significant(spec)
            return (HMEventTrigger.predicateForEvaluatingTriggerOccurring(afterSignificantEvent: ev), "after \(text)")
        case "before_sun":
            let (ev, text) = try significant(spec)
            return (HMEventTrigger.predicateForEvaluatingTriggerOccurring(beforeSignificantEvent: ev), "before \(text)")
        case let other:
            throw AdminError("unknown condition type '\(other)' (characteristic, after, before, after_sun, before_sun)")
        }
    }

    private func trigger(_ v: Any?) throws -> (HMTrigger, HMHome) {
        let id = try uuid(v, "id")
        for h in allHomes() { if let t = h.triggers.first(where: { $0.uniqueIdentifier == id }) { return (t, h) } }
        throw AdminError("automation \(id) not found")
    }

    private func writeActions(_ set: HMActionSet) -> [HMCharacteristicWriteAction<NSCopying>] {
        set.actions.compactMap { $0 as? HMCharacteristicWriteAction<NSCopying> }
    }

    private func result(_ confirm: Bool, _ changes: [String]) -> [String: Any] {
        [
            "applied": confirm && !changes.isEmpty,
            "preview": !confirm,
            "changes": changes.isEmpty ? ["no change"] : changes,
            "hint": confirm ? "" : "Nothing was changed. Call again with confirm: true to apply.",
        ]
    }

    /// Converts a JSON value to the NSNumber/NSString the characteristic's format expects, checking bounds.
    private func coerce(_ v: Any?, for c: HMCharacteristic) throws -> NSCopying {
        guard let v, !(v is NSNull) else { throw AdminError("missing 'value'") }
        let format = c.metadata?.format
        if format == HMCharacteristicMetadataFormatString {
            guard let s = v as? String else { throw AdminError("\(label(c)) expects a string") }
            return s as NSString
        }
        if format == HMCharacteristicMetadataFormatBool {
            switch v {
            case let b as Bool: return NSNumber(value: b)
            case let n as NSNumber: return NSNumber(value: n.intValue != 0)
            case let s as String where ["true", "1", "on"].contains(s.lowercased()): return NSNumber(value: true)
            case let s as String where ["false", "0", "off"].contains(s.lowercased()): return NSNumber(value: false)
            default: throw AdminError("\(label(c)) expects a boolean")
            }
        }
        let d: Double
        switch v {
        case let b as Bool: d = b ? 1 : 0
        case let n as NSNumber: d = n.doubleValue
        case let s as String: guard let x = Double(s) else { throw AdminError("\(label(c)) expects a number") }; d = x
        default: throw AdminError("\(label(c)) expects a number")
        }
        if let mn = c.metadata?.minimumValue?.doubleValue, d < mn { throw AdminError("\(d) is below min \(mn) for \(label(c))") }
        if let mx = c.metadata?.maximumValue?.doubleValue, d > mx { throw AdminError("\(d) is above max \(mx) for \(label(c))") }
        if let valid = c.metadata?.validValues, !valid.isEmpty, !valid.contains(where: { $0.doubleValue == d }) {
            throw AdminError("\(d) is not one of the valid values \(valid) for \(label(c))")
        }
        return format == HMCharacteristicMetadataFormatFloat ? NSNumber(value: d) : NSNumber(value: Int(d))
    }

    // MARK: - Audit (read-only)

    private func auditHomes(homeName: String?, readValues: Bool) async -> [String: Any] {
        var homes: [[String: Any]] = []
        for home in allHomes() where homeName == nil || home.name.localizedCaseInsensitiveCompare(homeName!) == .orderedSame {
            homes.append(await auditHome(home, readValues: readValues))
        }
        return ["homes": homes]
    }

    private func auditHome(_ home: HMHome, readValues: Bool) async -> [String: Any] {
        var accessories: [[String: Any]] = []
        for a in home.accessories { accessories.append(await auditAccessory(a, readValues: readValues)) }
        return [
            "name": home.name,
            "isPrimary": home == homeManager?.primaryHome,
            "homeHubState": hubState(home.homeHubState),
            "rooms": home.rooms.map { ["name": $0.name, "id": $0.uniqueIdentifier.uuidString, "accessories": $0.accessories.map(\.name)] as [String: Any] },
            "zones": home.zones.map { ["name": $0.name, "rooms": $0.rooms.map(\.name)] as [String: Any] },
            "accessories": accessories,
            "scenes": home.actionSets.map { auditActionSet($0) },
            "automations": home.triggers.map { auditTrigger($0) },
        ]
    }

    private func auditAccessory(_ a: HMAccessory, readValues: Bool) async -> [String: Any] {
        var services: [[String: Any]] = []
        for s in a.services where s.serviceType != HMServiceTypeAccessoryInformation {
            var chars: [[String: Any]] = []
            for c in s.characteristics {
                var ci: [String: Any] = [
                    "name": c.localizedDescription,
                    "id": c.uniqueIdentifier.uuidString,
                    "type": c.characteristicType,
                    "writable": c.properties.contains(HMCharacteristicPropertyWritable),
                ]
                if c.properties.contains(HMCharacteristicPropertyReadable) {
                    if readValues && a.isReachable { try? await c.readValue() }
                    if let v = c.value { ci["value"] = jsonSafe(v) }
                }
                if let md = c.metadata {
                    var m: [String: Any] = [:]
                    if let v = md.format { m["format"] = v }
                    if let v = md.minimumValue { m["min"] = v }
                    if let v = md.maximumValue { m["max"] = v }
                    if let v = md.validValues { m["validValues"] = v }
                    if let v = md.units { m["units"] = v }
                    if !m.isEmpty { ci["metadata"] = m }
                }
                chars.append(ci)
            }
            services.append([
                "name": s.name,
                "id": s.uniqueIdentifier.uuidString,
                "type": s.localizedDescription,
                "isPrimary": s.isPrimaryService,
                "isUserInteractive": s.isUserInteractive,
                "characteristics": chars,
            ])
        }
        return [
            "name": a.name,
            "id": a.uniqueIdentifier.uuidString,
            "room": a.room?.name ?? "Default Room",
            "category": a.category.localizedDescription,
            "manufacturer": a.manufacturer ?? NSNull(),
            "model": a.model ?? NSNull(),
            "firmware": a.firmwareVersion ?? NSNull(),
            "reachable": a.isReachable,
            "bridged": a.isBridged,
            "services": services,
        ]
    }

    private func auditActionSet(_ s: HMActionSet) -> [String: Any] {
        var d: [String: Any] = [
            "name": s.name,
            "id": s.uniqueIdentifier.uuidString,
            "type": s.actionSetType,
            "actions": s.actions.map { action -> [String: Any] in
                if let w = action as? HMCharacteristicWriteAction<NSCopying> {
                    var t = characteristicLabel(w.characteristic)
                    t["targetValue"] = jsonSafe(w.targetValue)
                    return t
                }
                return ["kind": String(describing: type(of: action)), "description": String(describing: action)]
            },
        ]
        if let le = s.lastExecutionDate { d["lastExecutionDate"] = iso(le) }
        return d
    }

    private func auditTrigger(_ t: HMTrigger) -> [String: Any] {
        var d: [String: Any] = [
            "name": t.name,
            "id": t.uniqueIdentifier.uuidString,
            "enabled": t.isEnabled,
            "class": String(describing: type(of: t)),
            // Automations made in the Home app own hidden action sets (named by UUID, absent from
            // home.actionSets); show their actions in full so they can be edited by id.
            "scenes": t.actionSets.map { s -> [String: Any] in
                var d = auditActionSet(s)
                if s.actionSetType == HMActionSetTypeTriggerOwned { d["editable"] = false }
                return d
            },
        ]
        if let lf = t.lastFireDate { d["lastFireDate"] = iso(lf) }
        if let tt = t as? HMTimerTrigger {
            d["fireDate"] = iso(tt.fireDate)
            if let r = tt.recurrence { d["recurrence"] = dc(r) }
        }
        if let et = t as? HMEventTrigger {
            d["events"] = et.events.map { auditEvent($0) }
            d["endEvents"] = et.endEvents.map { auditEvent($0) }
            if let p = et.predicate { d["condition"] = p.predicateFormat }
            if let r = et.recurrences { d["weekdays"] = r.compactMap(\.weekday) }
            d["executeOnce"] = et.executeOnce
        }
        return d
    }

    private func auditEvent(_ e: HMEvent) -> [String: Any] {
        var d: [String: Any] = ["class": String(describing: type(of: e))]
        if let s = e as? HMSignificantTimeEvent {
            d["significantEvent"] = s.significantEvent.rawValue
            if let o = s.offset { d["offset"] = dc(o) }
        } else if let c = e as? HMCalendarEvent {
            d["time"] = dc(c.fireDateComponents)
        } else if let r = e as? HMCharacteristicThresholdRangeEvent {
            d.merge(characteristicLabel(r.characteristic)) { a, _ in a }
            d["min"] = r.thresholdRange.minValue ?? NSNull()
            d["max"] = r.thresholdRange.maxValue ?? NSNull()
        } else if let c = e as? HMCharacteristicEvent<NSCopying> {
            d.merge(characteristicLabel(c.characteristic)) { a, _ in a }
            if let v = c.triggerValue { d["triggerValue"] = jsonSafe(v) }
        } else if let p = e as? HMPresenceEvent {
            d["presenceEventType"] = p.presenceEventType.rawValue
            d["presenceUserType"] = p.presenceUserType.rawValue
        } else if let du = e as? HMDurationEvent {
            d["duration"] = du.duration
        } else {
            d["description"] = String(describing: e)
        }
        return d
    }

    private func characteristicLabel(_ c: HMCharacteristic) -> [String: Any] {
        [
            "accessory": c.service?.accessory?.name ?? NSNull(),
            "accessoryId": c.service?.accessory?.uniqueIdentifier.uuidString ?? NSNull(),
            "room": c.service?.accessory?.room?.name ?? NSNull(),
            "service": c.service?.name ?? NSNull(),
            "characteristic": c.localizedDescription,
            "characteristicId": c.uniqueIdentifier.uuidString,
        ]
    }

    private func label(_ c: HMCharacteristic) -> String {
        "\(c.service?.accessory?.name ?? "?") / \(c.service?.name ?? "?") / \(c.localizedDescription)"
    }

    private func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let d as Date: return iso(d)
        case let c as DateComponents: return dc(c)
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? n.boolValue : n
        case let s as String: return s
        case let d as Data: return d.base64EncodedString()
        case let a as [Any]: return a.map { jsonSafe($0) }
        default: return String(describing: v)
        }
    }

    private func dc(_ c: DateComponents) -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = c.weekday { d["weekday"] = v }
        if let v = c.hour { d["hour"] = v }
        if let v = c.minute { d["minute"] = v }
        if let v = c.second { d["second"] = v }
        return d
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: d)
    }

    private func hubState(_ s: HMHomeHubState) -> String {
        switch s {
        case .notAvailable: "notAvailable"
        case .connected: "connected"
        case .disconnected: "disconnected"
        @unknown default: "unknown(\(s.rawValue))"
        }
    }
}
