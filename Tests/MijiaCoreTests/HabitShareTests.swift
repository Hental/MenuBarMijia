import Foundation
import Testing
@testable import MijiaCore

struct HabitShareTests {
    private static func light(_ id: String, _ name: String, _ room: String, on: Bool = false) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: room, roomName: room,
            model: "test.light", isOnline: true,
            kind: .light(LightSpec(entityId: "light.\(id)", isOn: on))
        )
    }

    static let ceiling = light("dev_ceiling", "客厅吸顶灯", "客厅")
    static let study = light("dev_study", "书房台灯", "书房")
    static let ac = SmartDevice(
        id: "dev_ac", name: "客厅空调", roomId: "客厅", roomName: "客厅",
        model: "test.ac", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.ac", isOn: false, hvacMode: "off",
            availableModes: ["off", "cool"], targetTemperature: 26
        ))
    )
    static let devices = [ceiling, study, ac]

    static func evening() -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 21, minute: 30))!
    }

    static func baseMemory(
        phrases: [UserHabitMemory.PhraseMemory] = [],
        sequences: [UserHabitMemory.SequenceEntry] = [],
        lastAction: UserHabitMemory.LastAction? = nil
    ) -> UserHabitMemory {
        UserHabitMemory(
            entries: [
                .init(bucket: .evening, targetId: "dev_missing", operationKey: "power:off", count: 3),
                .init(bucket: .evening, targetId: "dev_ceiling", operationKey: "power:off", count: 3),
                .init(bucket: .evening, targetId: "dev_study", operationKey: "power:on", count: 3),
                .init(bucket: .evening, targetId: "dev_ac", operationKey: "power:on", count: 3),
            ],
            phrases: phrases,
            sequences: sequences,
            lastAction: lastAction
        )
    }

    static func sentence(
        _ mention: CommandMention,
        memory: UserHabitMemory? = nil,
        sharing: HabitSharing = .on,
        devices: [SmartDevice]? = nil,
        now: Date? = nil
    ) -> String {
        shareHabitSentence(
            sharing: sharing,
            memory: memory ?? baseMemory(),
            devices: devices ?? Self.devices,
            scenes: [],
            mention: mention,
            now: now ?? evening()
        )
    }

    @Test("Absent habit sharing resolves off and is persisted; an explicit bool is left alone")
    func resolveHabitSharingCases() {
        #expect(resolveHabitSharing(.absent) == HabitShareResolution(sharing: .off, persistOff: true))
        #expect(resolveHabitSharing(.off) == HabitShareResolution(sharing: .off, persistOff: false))
        #expect(resolveHabitSharing(.on) == HabitShareResolution(sharing: .on, persistOff: false))
    }

    @Test("The cloud sentence is empty unless sharing is on and the command names a device")
    func shareSentenceWorkedExample() {
        let now = Self.evening()
        #expect(Self.sentence(.utterance("关闭客厅吸顶灯"), sharing: .off, now: now) == "")
        #expect(Self.sentence(.none, now: now) == "")
        #expect(Self.sentence(.utterance("   "), now: now) == "")

        let ceilingOnly = Self.sentence(.utterance("关闭客厅吸顶灯"), now: now)
        #expect(ceilingOnly == "夜晚常做：关闭客厅吸顶灯(3次)")
        #expect(ceilingOnly.contains("夜晚常做："))
        #expect(ceilingOnly.contains("关闭客厅吸顶灯(3次)"))
        #expect(!ceilingOnly.contains("书房"))
        #expect(!ceilingOnly.contains("21:30"))
        #expect(!ceilingOnly.contains("dev_"))

        let studyRoom = Self.sentence(.utterance("书房有点热"), now: now)
        #expect(studyRoom == "夜晚常做：打开书房台灯(3次)")
        #expect(studyRoom.contains("打开书房台灯"))
        #expect(!studyRoom.contains("客厅"))

        let acOnly = Self.sentence(.utterance("打开空调"), now: now)
        #expect(acOnly == "夜晚常做：打开客厅空调(3次)")
        #expect(acOnly.contains("打开客厅空调"))
        #expect(!acOnly.contains("吸顶灯"))
        #expect(!acOnly.contains("台灯"))

        #expect(Self.sentence(.utterance("全屋关灯"), now: now) == "")

        let both = Self.sentence(.utterance("关闭客厅吸顶灯打开书房台灯"), now: now)
        #expect(both == "夜晚常做：关闭客厅吸顶灯(3次)、打开书房台灯(3次)")
        #expect(both.contains("关闭客厅吸顶灯"))
        #expect(both.contains("打开书房台灯"))
        #expect(!both.contains("dev_"))
        #expect(!both.contains("21:30"))
    }

    @Test("A shared room-stripped base is not a needle")
    func sharedBaseMatchesNothing() {
        let living = Self.light("living_lamp", "客厅台灯", "客厅")
        let studyLamp = Self.light("study_lamp", "书房台灯", "书房")
        let memory = UserHabitMemory(entries: [
            .init(bucket: .evening, targetId: "living_lamp", operationKey: "power:on", count: 3),
            .init(bucket: .evening, targetId: "study_lamp", operationKey: "power:on", count: 3),
        ])
        #expect(Self.sentence(.utterance("打开台灯"), memory: memory, devices: [living, studyLamp]) == "")
    }

    @Test("Phrases use titles for named targets, and empty targets never appear")
    func phraseClauseUsesTitles() {
        let now = Self.evening()
        let memory = Self.baseMemory(phrases: [
            .init(
                phrase: "看书",
                bucket: .evening,
                summary: "顺便关闭客厅吸顶灯",
                count: 4,
                targets: [.init(targetId: "dev_study", operationKey: "power:on")]
            ),
            .init(phrase: "空目标", bucket: .evening, summary: "打开书房台灯", count: 9, targets: []),
        ])
        let named = Self.sentence(.utterance("打开书房台灯"), memory: memory, now: now)
        #expect(named == "夜晚常做：打开书房台灯(3次)。个人口头禅：「看书」→打开书房台灯")
        #expect(!named.contains("顺便"))
        #expect(!named.contains("空目标"))

        let room = Self.sentence(.utterance("书房有点热"), memory: memory, now: now)
        #expect(room.contains("个人口头禅：「看书」→打开书房台灯"))
        #expect(room.contains("打开书房台灯"))
        #expect(!room.contains("客厅"))
        #expect(!room.contains("空目标"))

        let other = Self.sentence(.utterance("关闭客厅吸顶灯"), memory: memory, now: now)
        #expect(!other.contains("看书"))
        #expect(!other.contains("空目标"))

        var recorded = UserHabitMemory()
        recorded.record(
            utterance: "看书",
            intents: [DeviceIntent(targetId: "dev_study", operation: .power(true))],
            devices: Self.devices,
            scenes: [],
            now: now
        )
        #expect(recorded.phrases.first?.targets == [UserHabitMemory.PhraseTarget(targetId: "dev_study", operationKey: "power:on")])
    }

    @Test("A missing phrase target list decodes as empty")
    func missingPhraseTargetsDecodeEmpty() throws {
        let data = Data(#"{"phrase":"老的","bucket":"夜晚","summary":"关闭客厅吸顶灯","count":2}"#.utf8)
        let decoded = try JSONDecoder().decode(UserHabitMemory.PhraseMemory.self, from: data)
        #expect(decoded.targets.isEmpty)
    }

    @Test("A sequence is sent only when the command names both ends inside the hour")
    func sequenceClauseWindow() {
        let now = Self.evening()
        func memory(recordedAt: Date) -> UserHabitMemory {
            Self.baseMemory(
                sequences: [
                    .init(afterKey: "dev_study|power:on", targetId: "dev_ceiling", operationKey: "power:off", count: 2),
                ],
                lastAction: .init(targetId: "dev_study", operationKey: "power:on", recordedAt: recordedAt)
            )
        }
        let inside = memory(recordedAt: now.addingTimeInterval(-(30 * 60)))
        let both = Self.sentence(.utterance("关闭客厅吸顶灯打开书房台灯"), memory: inside, now: now)
        #expect(both == "夜晚常做：关闭客厅吸顶灯(3次)、打开书房台灯(3次)。刚做完打开书房台灯后常做：关闭客厅吸顶灯(2次)")
        #expect(both.contains("刚做完打开书房台灯后常做：关闭客厅吸顶灯(2次)"))

        let studyOnly = Self.sentence(.utterance("打开书房台灯"), memory: inside, now: now)
        #expect(!studyOnly.contains("刚做完"))
        let ceilingOnly = Self.sentence(.utterance("关闭客厅吸顶灯"), memory: inside, now: now)
        #expect(!ceilingOnly.contains("刚做完"))

        let outside = memory(recordedAt: now.addingTimeInterval(-(61 * 60)))
        let stale = Self.sentence(.utterance("关闭客厅吸顶灯打开书房台灯"), memory: outside, now: now)
        #expect(stale == "夜晚常做：关闭客厅吸顶灯(3次)、打开书房台灯(3次)")
        #expect(!stale.contains("刚做完"))
    }

    @Test("buildAssistantContext copies the share sentence and keeps the clock when nothing is named")
    @MainActor
    func assistantContextMatchesSentence() async throws {
        let now = Self.evening()
        let suite = "test.habitshare.context.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: Self.devices, scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.userHabitMemory = Self.baseMemory()
        store.habitSharing = .on
        let mention = CommandMention.utterance("关闭客厅吸顶灯")
        let context = store.buildAssistantContext(now: now, mention: mention)
        let sentence = shareHabitSentence(
            sharing: store.habitSharing,
            memory: store.userHabitMemory,
            devices: store.devices,
            scenes: store.scenes,
            mention: mention,
            now: now
        )
        #expect(context.habitSummary == sentence)
        #expect(sentence == "夜晚常做：关闭客厅吸顶灯(3次)")

        let idle = store.buildAssistantContext(now: now, mention: .none)
        #expect(idle.habitSummary.isEmpty)
        #expect(idle.timeSummary.contains("21:30"))
    }

    @Test("Sharing defaults off and is written false; learning still gates recording, not local chips")
    @MainActor
    func freshStoreKeepsSharingOff() async throws {
        let suite = "test.habitshare.fresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let ceiling = Self.light("dev_study_ceiling", "书房吸顶灯", "书房", on: true)
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [ceiling], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        #expect(store.isHabitLearningEnabled)
        #expect(store.habitSharing == .off)
        #expect(defaults.object(forKey: "assistant_habit_share_enabled") != nil)
        #expect(defaults.bool(forKey: "assistant_habit_share_enabled") == false)

        store.habitSharing = .on
        let second = HomeStore(provider: mock, defaultsSuiteName: suite)
        #expect(second.habitSharing == .on)
        #expect(defaults.bool(forKey: "assistant_habit_share_enabled") == true)

        let weirdSuite = "test.habitshare.weird.\(UUID().uuidString)"
        let weirdDefaults = UserDefaults(suiteName: weirdSuite)!
        weirdDefaults.removePersistentDomain(forName: weirdSuite)
        weirdDefaults.set("nope", forKey: "assistant_habit_share_enabled")
        let weird = HomeStore(provider: mock, defaultsSuiteName: weirdSuite)
        #expect(weird.habitSharing == .off)
        #expect(!(weirdDefaults.object(forKey: "assistant_habit_share_enabled") is String))
        #expect(weirdDefaults.bool(forKey: "assistant_habit_share_enabled") == false)

        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let now = Date()
        var memory = UserHabitMemory()
        memory.record(
            utterance: nil,
            intents: [DeviceIntent(targetId: ceiling.id, operation: .power(false))],
            devices: [ceiling],
            scenes: [],
            now: now
        )
        store.habitSharing = .off
        store.userHabitMemory = memory
        let chips = store.userHabitMemory.topSuggestions(for: now, devices: store.devices, scenes: store.scenes)
        #expect(chips.contains { $0.title == "关闭书房吸顶灯" })

        _ = await store.runAssistantCommand("关闭书房吸顶灯")
        #expect(store.userHabitMemory.entries.count == 1)
        store.isHabitLearningEnabled = false
        _ = await store.runAssistantCommand("打开书房吸顶灯")
        #expect(store.userHabitMemory.entries.count == 1)
        #expect(store.userHabitMemory.entries.first?.operationKey == "power:off")
    }
}
