import Foundation
import Testing
@testable import MijiaCore

/// #113: the zero-delay Top-4 proactive suggestion engine.
/// The same phase order and filters are mirrored in `windows/src/core/assistant.ts`
/// and pinned by `Tests/Fixtures/habit_golden.json`.
struct ProactiveSuggestionEngineTests {
    private let evening = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 21, minute: 30))!

    private let ceiling = SmartDevice(
        id: "dev_ceiling", name: "客厅吸顶灯", roomId: "ke_ting", roomName: "客厅",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.ceiling", isOn: true, brightnessPercent: 80, availableEffects: ["Day", "Night"]))
    )
    private let floorLamp = SmartDevice(
        id: "dev_floor_lamp", name: "落地灯", roomId: "ke_ting", roomName: "客厅",
        model: "yeelink.light.lamp1", isOnline: true,
        kind: .light(LightSpec(entityId: "light.floor", isOn: true))
    )
    private let deskLamp = SmartDevice(
        id: "dev_desk_lamp", name: "书房台灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(entityId: "light.desk", isOn: false))
    )
    private let ac = SmartDevice(
        id: "dev_ac", name: "客厅空调", roomId: "ke_ting", roomName: "客厅",
        model: "xiaomi.aircondition.mt0", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.ac", isOn: true, hvacMode: "cool",
            availableModes: ["off", "cool", "heat", "dry", "fan_only", "auto"],
            targetTemperature: 25, currentTemperature: 29.5
        ))
    )
    private let plug = SmartDevice(
        id: "dev_plug", name: "路由器插座", roomId: "ke_ting", roomName: "客厅",
        model: "chuangmi.plug.m3", isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.plug", isOn: true))
    )
    private let sensor = SmartDevice(
        id: "dev_sensor", name: "温湿度计", roomId: "ke_ting", roomName: "客厅",
        model: "miaomiaoce.sensor_ht.t1", isOnline: true,
        kind: .sensor(SensorSpec(temperature: 29.5, humidity: 60))
    )

    private var devices: [SmartDevice] {
        [ceiling, floorLamp, deskLamp, ac, plug, sensor]
    }

    private func operationKeys(of suggestion: AssistantSuggestion) -> [String] {
        suggestion.intents.compactMap { UserHabitMemory.encodeOperation($0.operation) }
    }

    @Test("Pads to four actionable suggestions from favorites, environment, builtins, and active devices")
    func padsToFour() {
        let memory = UserHabitMemory()
        let readings = [EnvironmentReading(id: "r1", label: "温湿度计", roomName: "客厅", temperature: 29.5, humidity: 60)]

        let suggestions = L10n.$overrideTemperatureUnit.withValue(.celsius) {
            memory.topSuggestions(
                for: evening,
                devices: devices,
                scenes: [],
                favoriteIds: ["dev_floor_lamp", "dev_desk_lamp"],
                environmentReadings: readings
            )
        }

        // Phase order: favorites (in starred order) → environment (hot room → 26 °C) → 全屋关灯 builtin.
        // The plug is never reached: four slots fill first.
        #expect(suggestions.count == 4)
        #expect(suggestions.map(\.id) == [
            "fav:dev_floor_lamp:off",
            "fav:dev_desk_lamp:on",
            "env:dev_ac:temp:26",
            "builtin:lightsOff",
        ])
        #expect(operationKeys(of: suggestions[0]) == ["power:off"])
        #expect(suggestions[0].intents[0].targetId == "dev_floor_lamp")
        #expect(operationKeys(of: suggestions[1]) == ["power:on"])
        #expect(suggestions[1].intents[0].targetId == "dev_desk_lamp")
        #expect(operationKeys(of: suggestions[2]) == ["temp:26"])
        #expect(operationKeys(of: suggestions[3]) == ["power:off", "power:off"])
        #expect(suggestions[3].intents.map(\.targetId) == ["dev_ceiling", "dev_floor_lamp"])
    }

    @Test("Favorite padding skips devices the assistant cannot power")
    func favoritePaddingSkipsNonToggleableDevices() {
        let memory = UserHabitMemory()
        let fridge = SmartDevice(
            id: "dev_fridge", name: "双开门冰箱", roomId: "ke_ting", roomName: "客厅",
            model: "xiaomi.fridge.dual", isOnline: true,
            kind: .fridge(FridgeSpec(
                modeEntityId: nil,
                currentMode: "normal",
                availableModes: ["normal"],
                fridgeCurrentTemp: 4.0,
                fridgeTargetTemp: 4.0,
                fridgeTargetEntityId: nil,
                freezerCurrentTemp: nil,
                freezerTargetTemp: -18,
                freezerTargetEntityId: nil
            ))
        )
        let onLight = SmartDevice(
            id: "dev_light", name: "客厅吸顶灯", roomId: "ke_ting", roomName: "客厅",
            model: "yeelink.light.ceiling20", isOnline: true,
            kind: .light(LightSpec(entityId: "light.ceiling", isOn: true, brightnessPercent: 80))
        )
        let readings = [EnvironmentReading(id: "r1", label: "温湿度计", roomName: "客厅", temperature: 29.5, humidity: 60)]

        let suggestions = memory.topSuggestions(
            for: evening,
            devices: [fridge, onLight],
            scenes: [],
            favoriteIds: ["dev_fridge"],
            environmentReadings: readings
        )

        // The fridge never becomes a suggestion even though it is starred and online.
        #expect(suggestions.map(\.id) == ["active:\(onLight.id):off"])
    }

    @Test("Ranks learned habit entries first and never suggests an already-active state")
    func habitsFirstAndNoRedundantActions() {
        var memory = UserHabitMemory()
        memory.record(
            utterance: nil,
            intents: [DeviceIntent(targetId: "dev_desk_lamp", operation: .power(true))],
            devices: devices,
            scenes: [],
            now: evening
        )

        let suggestions = memory.topSuggestions(
            for: evening,
            devices: devices,
            scenes: [],
            favoriteIds: ["dev_desk_lamp"]
        )

        // The habit turns the desk lamp on; the favorite toggle for the same lamp would be
        // the same action and is deduplicated by targetId. Remaining slots fill from the
        // 全屋关灯 builtin (ceiling + floor lamp are on) and then active-device power-off.
        #expect(suggestions.count == 4)
        #expect(operationKeys(of: suggestions[0]) == ["power:on"])
        #expect(suggestions[0].intents[0].targetId == "dev_desk_lamp")
        #expect(suggestions[1].id == "builtin:lightsOff")
        #expect(operationKeys(of: suggestions[2]) == ["power:off"])
        #expect(suggestions[2].intents[0].targetId == "dev_ac")
        #expect(operationKeys(of: suggestions[3]) == ["power:off"])
        #expect(suggestions[3].intents[0].targetId == "dev_plug")
    }

    @Test("Cold room suggests heating and every suggestion stays actionable")
    func coldRoomSuggestsHeating() {
        let memory = UserHabitMemory()
        let coldAC = SmartDevice(
            id: "dev_ac", name: "客厅空调", roomId: "ke_ting", roomName: "客厅",
            model: "xiaomi.aircondition.mt0", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.ac", isOn: true, hvacMode: "heat",
                availableModes: ["off", "cool", "heat"],
                targetTemperature: 18, currentTemperature: 12
            ))
        )
        let readings = [EnvironmentReading(id: "r1", label: "温湿度计", roomName: "客厅", temperature: 12, humidity: 40)]

        let suggestions = memory.topSuggestions(
            for: evening,
            devices: [coldAC],
            scenes: [],
            environmentReadings: readings
        )

        #expect(operationKeys(of: suggestions[0]) == ["temp:22"])
        #expect(suggestions[0].intents[0].targetId == "dev_ac")
    }

    @Test("Returns nothing without controllable online devices")
    func emptyWithoutDevices() {
        let memory = UserHabitMemory()
        let readings = [EnvironmentReading(id: "r1", label: "温湿度计", roomName: "客厅", temperature: 29.5, humidity: 60)]

        #expect(memory.topSuggestions(for: evening, devices: [], scenes: [], environmentReadings: readings).isEmpty)

        let offline = SmartDevice(
            id: "dev_ac", name: "客厅空调", roomId: "ke_ting", roomName: "客厅",
            model: "xiaomi.aircondition.mt0", isOnline: false,
            kind: .climate(ClimateSpec(entityId: "climate.ac", isOn: true, hvacMode: "cool", availableModes: ["off", "cool"], targetTemperature: 25))
        )
        #expect(memory.topSuggestions(for: evening, devices: [offline], scenes: [], environmentReadings: readings).isEmpty)
    }

    @Test("Habit entries still win and the engine caps at the requested limit")
    func habitLimitStillApplies() {
        var memory = UserHabitMemory()
        for _ in 0..<2 {
            memory.record(
                utterance: nil,
                intents: [
                    DeviceIntent(targetId: "dev_ceiling", operation: .lightEffect("Night")),
                    DeviceIntent(targetId: "dev_floor_lamp", operation: .power(false)),
                ],
                devices: devices,
                scenes: [],
                now: evening
            )
        }

        let suggestions = memory.topSuggestions(for: evening, devices: devices, scenes: [], limit: 2)

        // Habit suggestions come first and the limit caps before padding starts.
        #expect(suggestions.count == 2)
        #expect(operationKeys(of: suggestions[0]) == ["effect:Night"])
        #expect(operationKeys(of: suggestions[1]) == ["power:off"])
        #expect(suggestions[1].intents[0].targetId == "dev_floor_lamp")
    }
}
