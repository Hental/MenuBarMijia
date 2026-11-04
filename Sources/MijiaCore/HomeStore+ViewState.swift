import Foundation

// Keyboard navigation, favorites, and visibility state (#48).
extension HomeStore {
    // MARK: - Keyboard Navigation & Quick Number Shortcuts

    public func selectQuickIndex(_ oneBasedIndex: Int) {
        let list = orderedVisibleDevices
        let idx = oneBasedIndex - 1
        guard idx >= 0 && idx < list.count else { return }
        togglePrimary(list[idx])
    }

    public func moveFocus(delta: Int) {
        let list = orderedVisibleDevices
        guard !list.isEmpty else {
            focusedDeviceId = nil
            return
        }
        guard let currentId = focusedDeviceId,
              let curIdx = list.firstIndex(where: { $0.id == currentId }) else {
            focusedDeviceId = delta >= 0 ? list.first?.id : list.last?.id
            return
        }
        let nextIdx = (curIdx + delta + list.count) % list.count
        focusedDeviceId = list[nextIdx].id
    }

    public func toggleFocusedDevice() {
        let list = orderedVisibleDevices
        guard !list.isEmpty else { return }
        if let fid = focusedDeviceId, let dev = list.first(where: { $0.id == fid }) {
            togglePrimary(dev)
        } else if let first = list.first {
            focusedDeviceId = first.id
            togglePrimary(first)
        }
    }

    public func adjustFocusedDevice(delta: Int) {
        guard let fid = focusedDeviceId,
              let dev = devices.first(where: { $0.id == fid }) else { return }

        if expandedDeviceId != dev.id {
            let canExpand: Bool = switch dev.kind {
            case .sensor: true
            default: dev.hasDetailDrawer
            }
            if delta > 0 && canExpand {
                expandedDeviceId = dev.id
            }
            return
        }

        switch dev.kind {
        case .light(let s):
            let current = s.brightnessPercent ?? (s.isOn ? 80 : 0)
            let next = max(1, min(100, current + delta * 10))
            setLightBrightness(dev.id, percent: next)
        case .climate:
            stepClimateTemperature(dev.id, delta: Double(delta) * 1.0)
        case .speaker(let s):
            setSpeakerVolume(dev.id, percent: max(0, min(100, s.volumePercent + delta * 10)))
        case .tv(let s):
            setSpeakerVolume(dev.id, percent: max(0, min(100, s.volumePercent + delta * 10)))
        case .cover(let s) where s.positionWritable:
            let current = s.positionPercent ?? 0
            setCoverPosition(dev.id, percent: max(0, min(100, current + delta * 10)))
        default:
            if delta < 0 {
                expandedDeviceId = nil
            }
        }
    }

    public var selectedRoomId: String? {
        if case .room(let id) = listCut { return id }
        return nil
    }

    @discardableResult
    public func selectRoom(_ roomId: String?) -> Bool {
        let next: DeviceListCut = roomId.map(DeviceListCut.room) ?? .all
        guard listCut != next else { return false }
        listCut = next
        return true
    }

    public func selectKind(_ tag: DeviceKindTag) {
        guard listCut != .kind(tag) else { return }
        listCut = .kind(tag)
    }

    /// Cycles the room filter (nil = All, then each room). `order` is the display order the panel
    /// shows; ids that no longer match a room are ignored, and without `order` the provider order
    /// is used. Keeping one implementation means Tab follows the visible pills.
    public func cycleRoom(delta: Int = 1, order: [String]? = nil) {
        let known = Set(rooms.map(\.id))
        var seen = Set<String>()
        let ids = (order ?? rooms.map(\.id)).filter { known.contains($0) && seen.insert($0).inserted }
        let options: [String?] = [nil] + ids
        guard options.count > 1 else { return }
        let curIdx = options.firstIndex(where: { $0 == selectedRoomId }) ?? 0
        let nextIdx = (curIdx + delta + options.count) % options.count
        selectRoom(options[nextIdx])
    }

    // MARK: - User Actions & Optimistic State Mutations

    public func toggleFavorite(_ deviceId: String) {
        if favoriteDeviceIds.contains(deviceId) {
            favoriteDeviceIds.remove(deviceId)
            favoriteOrder.removeAll { $0 == deviceId }
        } else {
            favoriteDeviceIds.insert(deviceId)
            if !favoriteOrder.contains(deviceId) {
                favoriteOrder.append(deviceId)
            }
        }
    }

    public func moveFavorite(deviceId: String, direction: Int) {
        var currentIds = favoriteDevices.map(\.id)
        for id in favoriteOrder where favoriteDeviceIds.contains(id) && !currentIds.contains(id) {
            currentIds.append(id)
        }
        guard let idx = currentIds.firstIndex(of: deviceId) else { return }
        let targetIdx = idx + direction
        guard targetIdx >= 0 && targetIdx < currentIds.count else { return }
        currentIds.swapAt(idx, targetIdx)
        favoriteOrder = currentIds
    }

    public func hideDevice(_ deviceId: String) {
        hiddenDeviceIds.insert(deviceId)
        if expandedDeviceId == deviceId {
            expandedDeviceId = nil
        }
        if focusedDeviceId == deviceId {
            focusedDeviceId = nil
        }
    }

    public func unhideDevice(_ deviceId: String) {
        hiddenDeviceIds.remove(deviceId)
    }

    public func toggleExpanded(_ deviceId: String) {
        if expandedDeviceId == deviceId {
            expandedDeviceId = nil
        } else {
            expandedDeviceId = deviceId
        }
    }
}
