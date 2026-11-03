import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// #146: room aliases and order are pure defaults-backed data; the panel only applies them.
struct RoomPrefsTests {
    private func rooms() -> [RoomArea] {
        [
            RoomArea(id: "living", name: "客厅", sortOrder: 1),
            RoomArea(id: "bedroom", name: "卧室", sortOrder: 2),
            RoomArea(id: "study", name: "书房", sortOrder: 3)
        ]
    }

    @Test("Room aliases and order round-trip through their defaults strings")
    func encodersRoundTrip() {
        let aliases = ["living": "大厅", "study": "工作间"]
        #expect(RoomPrefs.decodeAliases(RoomPrefs.encodeAliases(aliases)) == aliases)

        let order = ["study", "living", "bedroom"]
        #expect(RoomPrefs.decodeOrder(RoomPrefs.encodeOrder(order)) == order)
    }

    @Test("Malformed room defaults decode as empty instead of throwing")
    func malformedDefaultsDecodeEmpty() {
        #expect(RoomPrefs.decodeAliases("not json") == [:])
        #expect(RoomPrefs.decodeOrder("{]") == [])
        #expect(RoomPrefs.decodeAliases("") == [:])
        #expect(RoomPrefs.decodeOrder("") == [])
    }

    @Test("Blank aliases are dropped on encode and never resolve")
    func blankAliasesAreIgnored() {
        let encoded = RoomPrefs.encodeAliases(["living": "  ", "study": "工作间"])
        #expect(RoomPrefs.decodeAliases(encoded) == ["study": "工作间"])
        #expect(RoomPrefs.alias(for: "living", in: ["living": " "]) == nil)
        #expect(RoomPrefs.alias(for: "missing", in: ["living": "大厅"]) == nil)
        #expect(RoomPrefs.alias(for: "living", in: ["living": "  大厅  "]) == "大厅")
    }

    @Test("Alias resolution keeps the saved display name and ignores unknown room ids")
    func aliasResolution() {
        let aliases = ["living": "大厅"]
        #expect(RoomPrefs.alias(for: "living", in: aliases) == "大厅")
        #expect(RoomPrefs.alias(for: "bedroom", in: aliases) == nil)
        #expect(RoomPrefs.alias(for: "ghost", in: aliases) == nil)
    }

    @Test("Custom order sorts known rooms and leaves unlisted rooms in their incoming order")
    func customOrder() {
        let ordered = RoomPrefs.apply(order: ["study", "living"], to: rooms())
        #expect(ordered.map(\.id) == ["study", "living", "bedroom"])
        #expect(ordered.map(\.name) == ["书房", "客厅", "卧室"])
    }

    @Test("No saved preferences keep the incoming room order untouched")
    func emptyOrderKeepsDefaultAppearance() {
        let input = rooms()
        #expect(RoomPrefs.apply(order: [], to: input) == input)
    }

    @Test("Unknown ids in the saved order are ignored")
    func unknownIdsAreIgnored() {
        let ordered = RoomPrefs.apply(order: ["ghost", "bedroom", "also-ghost"], to: rooms())
        #expect(ordered.map(\.id) == ["bedroom", "living", "study"])
    }

    @Test("A room that disappears keeps its alias and returns to its saved slot")
    func missingRoomKeepsPreferences() {
        let aliasesRaw = RoomPrefs.encodeAliases(["living": "大厅", "ghost": "旧房间"])
        let orderRaw = RoomPrefs.encodeOrder(["bedroom", "ghost", "living"])
        let aliases = RoomPrefs.decodeAliases(aliasesRaw)
        let order = RoomPrefs.decodeOrder(orderRaw)

        let visibleNow = [RoomArea(id: "living", name: "客厅"), RoomArea(id: "bedroom", name: "卧室")]
        #expect(RoomPrefs.apply(order: order, to: visibleNow).map(\.id) == ["bedroom", "living"])

        // A room that was never part of the saved order waits after the ranked ones.
        #expect(RoomPrefs.apply(order: order, to: rooms()).map(\.id) == ["bedroom", "living", "study"])

        // The missing room comes back: its alias and its slot between bedroom and living survive.
        let returned = rooms() + [RoomArea(id: "ghost", name: "旧房间")]
        #expect(RoomPrefs.apply(order: order, to: returned).map(\.id) == ["bedroom", "ghost", "living", "study"])
        #expect(RoomPrefs.decodeOrder(orderRaw) == ["bedroom", "ghost", "living"])
        #expect(RoomPrefs.alias(for: "ghost", in: aliases) == "旧房间")
    }

    @Test("Reset clears aliases and order so the default room strip returns")
    func resetClearsPreferences() {
        let cleared = RoomPrefs.reset()
        #expect(RoomPrefs.decodeAliases(cleared.aliases) == [:])
        #expect(RoomPrefs.decodeOrder(cleared.order) == [])
        #expect(RoomPrefs.apply(order: RoomPrefs.decodeOrder(cleared.order), to: rooms()) == rooms())
        #expect(RoomPrefs.alias(for: "living", in: RoomPrefs.decodeAliases(cleared.aliases)) == nil)
    }

    @Test("Seeded order appends visible rooms without dropping an id whose room is missing")
    func seededOrderKeepsStaleIds() {
        let seeded = RoomPrefs.seededOrder(["bedroom", "ghost"], rooms: rooms())
        #expect(seeded == ["bedroom", "ghost", "living", "study"])
    }

    @Test("Moving a room next to a target reorders the saved list")
    func moveRelativeToTarget() {
        let order = ["living", "bedroom", "study"]
        #expect(RoomPrefs.move(order, id: "study", relativeTo: "living", after: false) == ["study", "living", "bedroom"])
        #expect(RoomPrefs.move(order, id: "study", relativeTo: "living", after: true) == ["living", "study", "bedroom"])
        #expect(RoomPrefs.move(order, id: "study", relativeTo: "bedroom", after: true) == ["living", "bedroom", "study"])
        // Unknown ids and self-targets are no-ops.
        #expect(RoomPrefs.move(order, id: "ghost", relativeTo: "living", after: true) == order)
        #expect(RoomPrefs.move(order, id: "living", relativeTo: "ghost", after: true) == order)
        #expect(RoomPrefs.move(order, id: "living", relativeTo: "living", after: true) == order)
    }

    @Test("Shift moves one visible slot and skips rooms that are temporarily missing")
    func shiftSkipsMissingRooms() {
        let order = ["living", "ghost", "bedroom", "study"]
        let visible: Set<String> = ["living", "bedroom", "study"]

        #expect(RoomPrefs.shift(order, id: "living", by: 1, visible: visible) == ["bedroom", "ghost", "living", "study"])
        #expect(RoomPrefs.shift(order, id: "study", by: -1, visible: visible) == ["living", "ghost", "study", "bedroom"])
        // At the visible edges nothing moves.
        #expect(RoomPrefs.shift(order, id: "living", by: -1, visible: visible) == order)
        #expect(RoomPrefs.shift(order, id: "study", by: 1, visible: visible) == order)
        // A hidden id cannot be shifted, and delta 0 is a no-op.
        #expect(RoomPrefs.shift(order, id: "ghost", by: 1, visible: visible) == order)
        #expect(RoomPrefs.shift(order, id: "living", by: 0, visible: visible) == order)
    }
}
