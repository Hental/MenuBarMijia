import Foundation

public enum HabitSharing: Equatable, Sendable {
    case off, on
}

public enum CommandMention: Equatable, Sendable {
    case none
    case utterance(String)
}

public enum StoredHabitShare: Equatable, Sendable {
    case absent, off, on
}

public struct HabitShareResolution: Equatable, Sendable {
    public var sharing: HabitSharing
    public var persistOff: Bool

    public init(sharing: HabitSharing, persistOff: Bool) {
        self.sharing = sharing
        self.persistOff = persistOff
    }
}

public func resolveHabitSharing(_ stored: StoredHabitShare) -> HabitShareResolution {
    switch stored {
    case .absent:
        return HabitShareResolution(sharing: .off, persistOff: true)
    case .off:
        return HabitShareResolution(sharing: .off, persistOff: false)
    case .on:
        return HabitShareResolution(sharing: .on, persistOff: false)
    }
}

public func shareHabitSentence(
    sharing: HabitSharing,
    memory: UserHabitMemory,
    devices: [SmartDevice],
    scenes: [HomeScene],
    mention: CommandMention,
    now: Date
) -> String {
    guard sharing == .on else { return "" }
    guard case .utterance(let raw) = mention else { return "" }
    let utterance = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !utterance.isEmpty else { return "" }
    let ids = mentionedTargets(utterance, devices: devices, scenes: scenes)
    guard !ids.isEmpty else { return "" }

    let bucket = UserHabitMemory.TimeBucket.from(date: now)
    var parts: [String] = []

    var bucketTitles: [String] = []
    for entry in memory.entries where entry.bucket == bucket && ids.contains(entry.targetId) {
        guard let operation = UserHabitMemory.decodeOperation(entry.operationKey),
              let title = UserHabitMemory.suggestionTitle(
                for: DeviceIntent(targetId: entry.targetId, operation: operation),
                devices: devices,
                scenes: scenes
              ) else { continue }
        bucketTitles.append("\(title)(\(entry.count)次)")
        if bucketTitles.count == 4 { break }
    }
    if !bucketTitles.isEmpty {
        parts.append("\(bucket.rawValue)常做：\(bucketTitles.joined(separator: "、"))")
    }

    var phraseBits: [String] = []
    for phrase in memory.phrases {
        guard !phrase.targets.isEmpty else { continue }
        var titles: [String] = []
        var qualified = true
        for target in phrase.targets {
            guard ids.contains(target.targetId),
                  let operation = UserHabitMemory.decodeOperation(target.operationKey),
                  let title = UserHabitMemory.suggestionTitle(
                    for: DeviceIntent(targetId: target.targetId, operation: operation),
                    devices: devices,
                    scenes: scenes
                  ) else {
                qualified = false
                break
            }
            titles.append(title)
        }
        guard qualified else { continue }
        phraseBits.append("「\(phrase.phrase)」→\(titles.joined(separator: "+"))")
        if phraseBits.count == 4 { break }
    }
    if !phraseBits.isEmpty {
        parts.append("个人口头禅：\(phraseBits.joined(separator: "；"))")
    }

    if let last = memory.lastAction,
       now.timeIntervalSince(last.recordedAt) <= UserHabitMemory.sequenceBoostWindow,
       let next = memory.sequences.first(where: { $0.afterKey == last.key }),
       ids.contains(last.targetId),
       ids.contains(next.targetId),
       let previousOperation = UserHabitMemory.decodeOperation(last.operationKey),
       let nextOperation = UserHabitMemory.decodeOperation(next.operationKey),
       let previousTitle = UserHabitMemory.suggestionTitle(
        for: DeviceIntent(targetId: last.targetId, operation: previousOperation),
        devices: devices,
        scenes: scenes
       ),
       let nextTitle = UserHabitMemory.suggestionTitle(
        for: DeviceIntent(targetId: next.targetId, operation: nextOperation),
        devices: devices,
        scenes: scenes
       ) {
        parts.append("刚做完\(previousTitle)后常做：\(nextTitle)(\(next.count)次)")
    }

    return parts.joined(separator: "。")
}

private struct HabitNeedle {
    var text: String
    var ids: Set<String>
}

private func mentionedTargets(_ utterance: String, devices: [SmartDevice], scenes: [HomeScene]) -> Set<String> {
    var idsByText: [String: Set<String>] = [:]

    func absorb(_ raw: String, _ ids: Set<String>) {
        let folded = asciiCasefold(raw)
        guard folded.utf16.count >= 2, !ids.isEmpty else { return }
        idsByText[folded, default: []].formUnion(ids)
    }

    for device in devices {
        absorb(device.name, [device.id])
    }
    for scene in scenes {
        absorb(scene.name, [scene.id])
    }
    for device in devices {
        absorb(device.roomName, [device.id])
    }

    var baseIds: [String: Set<String>] = [:]
    for device in devices {
        guard let base = roomStrippedBase(name: device.name, roomName: device.roomName) else { continue }
        let folded = asciiCasefold(base)
        guard folded.utf16.count >= 2 else { continue }
        baseIds[folded, default: []].insert(device.id)
    }
    for (base, ids) in baseIds where ids.count == 1 {
        idsByText[base, default: []].formUnion(ids)
    }

    let needles = idsByText.map { HabitNeedle(text: $0.key, ids: $0.value) }.sorted { lhs, rhs in
        let leftCount = lhs.text.utf16.count
        let rightCount = rhs.text.utf16.count
        if leftCount != rightCount { return leftCount > rightCount }
        return utf16Descending(lhs.text, rhs.text)
    }

    let haystack = Array(asciiCasefold(utterance).utf16)
    var accepted: [(start: Int, end: Int)] = []
    var ids: Set<String> = []
    for needle in needles {
        let units = Array(needle.text.utf16)
        let starts = nonOverlappingOccurrences(haystack, units, accepted)
        guard !starts.isEmpty else { continue }
        for start in starts {
            accepted.append((start, start + units.count))
        }
        ids.formUnion(needle.ids)
    }
    return ids
}

private func roomStrippedBase(name: String, roomName: String) -> String? {
    guard !roomName.isEmpty, name.hasPrefix(roomName) else { return nil }
    let base = String(name.dropFirst(roomName.count))
    return base.isEmpty ? nil : base
}

private func asciiCasefold(_ text: String) -> String {
    var scalars: [Unicode.Scalar] = []
    scalars.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
        if scalar.value >= 65 && scalar.value <= 90 {
            scalars.append(UnicodeScalar(scalar.value + 32)!)
        } else {
            scalars.append(scalar)
        }
    }
    return String(String.UnicodeScalarView(scalars))
}

private func utf16Descending(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf16)
    let right = Array(rhs.utf16)
    let count = min(left.count, right.count)
    for index in 0..<count where left[index] != right[index] {
        return left[index] > right[index]
    }
    return left.count > right.count
}

private func nonOverlappingOccurrences(
    _ haystack: [UInt16],
    _ needle: [UInt16],
    _ accepted: [(start: Int, end: Int)]
) -> [Int] {
    guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
    let last = haystack.count - needle.count
    var index = 0
    var starts: [Int] = []
    while index <= last {
        if haystack[index..<(index + needle.count)].elementsEqual(needle) {
            let end = index + needle.count
            let overlaps = accepted.contains { span in index < span.end && span.start < end }
            if !overlaps && hasAsciiWordBoundary(haystack, needle: needle, start: index) {
                starts.append(index)
            }
        }
        index += 1
    }
    return starts
}

/// English names are matched as whole words so a room named "Den" does not match inside
/// "garden". Chinese names keep substring matching because they have no word separators.
private func hasAsciiWordBoundary(_ haystack: [UInt16], needle: [UInt16], start: Int) -> Bool {
    guard let first = needle.first, let lastUnit = needle.last else { return false }
    let end = start + needle.count
    let leftOk = !isAsciiWordUnit(first) || start == 0 || !isAsciiWordUnit(haystack[start - 1])
    let rightOk = !isAsciiWordUnit(lastUnit) || end == haystack.count || !isAsciiWordUnit(haystack[end])
    return leftOk && rightOk
}

private func isAsciiWordUnit(_ unit: UInt16) -> Bool {
    (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit)
}
