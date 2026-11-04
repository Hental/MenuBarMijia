import SwiftUI
import AppKit
import MijiaCore

extension ControlCenterPanel {
    // MARK: - Layout Editing

    func editable(_ device: SmartDevice) -> LayoutEditable {
        LayoutEditable(
            deviceId: device.id,
            size: tileSize(device),
            isDragging: draggingId == device.id,
            isResizing: activeResize?.deviceId == device.id,
            dragOffset: dragOffset(for: device.id),
            onCycleSize: { cycleSize(device) },
            onBeginResize: { beginResizeIfNeeded(device.id) },
            onResizeDrag: { translation in updateResize(device.id, translation: translation) },
            onEndResize: { translation, samples in endResize(device.id, translation: translation, samples: samples) },
            onRename: { layoutUI.renamingDeviceId = device.id }
        )
    }

    // MARK: - Room Strip Editing (#146)

    enum RoomSpace {
        static let name = "room_pills"
    }

    var roomAliases: [String: String] { RoomPrefs.decodeAliases(roomAliasesRaw) }

    /// Rooms with the saved order applied; saved ids for rooms that vanished are ignored.
    var displayRooms: [RoomArea] {
        RoomPrefs.apply(order: RoomPrefs.decodeOrder(roomOrderRaw), to: store.rooms)
    }

    func roomDisplayTitle(_ room: RoomArea) -> String {
        RoomPrefs.alias(for: room.id, in: roomAliases) ?? L10n.displayRoomName(room.name)
    }

    /// The All-Off button names the selected room; a saved alias wins over the snapshot name.
    var allOffScopeDisplayName: String? {
        guard case .room(let id) = store.listCut,
              let room = store.rooms.first(where: { $0.id == id }) else {
            return store.allOffScopeName
        }
        return roomDisplayTitle(room)
    }

    /// Saved order seeded with every visible room, so a move never drops an id whose room is
    /// temporarily missing from the snapshot.
    var currentRoomOrder: [String] {
        RoomPrefs.seededOrder(RoomPrefs.decodeOrder(roomOrderRaw), rooms: store.rooms)
    }

    func roomId(at point: CGPoint) -> String? {
        roomFrames.first { $0.value.contains(point) }?.key
    }

    func roomPhase(_ id: String) -> Double {
        Double(abs(id.hashValue % 97)) / 97 * .pi * 2
    }

    /// Long press enters room edit mode; while editing, a drag reorders rooms. Mirrors the tile
    /// container gesture so both strips behave the same way.
    var roomStripGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(RoomSpace.name))
            .onChanged { value in
                guard !search.isSearching else { return }
                let moved = hypot(value.translation.width, value.translation.height)
                if isEditingRooms {
                    if draggingRoomId == nil, moved > 3, let id = roomId(at: value.startLocation) {
                        beginRoomDrag(id, at: value.startLocation)
                    }
                    if let id = draggingRoomId {
                        roomDragLocation = value.location
                        swapRoomIfNeeded(dragged: id, at: value.location)
                    }
                    return
                }
                if roomPressTask == nil, !roomPressCancelled, moved <= 8, let id = roomId(at: value.startLocation) {
                    let start = value.startLocation
                    roomPressTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled else { return }
                        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isEditingLayout = false
                            draggingId = nil
                            activeResize = nil
                            store.expandedDeviceId = nil
                            isEditingRooms = true
                        }
                        beginRoomDrag(id, at: start)
                    }
                } else if moved > 8 {
                    roomPressTask?.cancel()
                    roomPressCancelled = true
                }
            }
            .onEnded { _ in
                roomPressTask?.cancel()
                roomPressTask = nil
                roomPressCancelled = false
                lastRoomSwapTarget = nil
                guard draggingRoomId != nil else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    draggingRoomId = nil
                    roomDragLocation = nil
                }
            }
    }

    func beginRoomDrag(_ id: String, at start: CGPoint) {
        let origin = roomFrames[id]?.minX ?? start.x
        roomGrabOffset = start.x - origin
        roomDragLocation = start
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { draggingRoomId = id }
    }

    /// Horizontal offset that keeps the picked-up pill under the pointer after a reorder.
    func roomDragOffset(for id: String) -> CGFloat {
        guard draggingRoomId == id, let location = roomDragLocation, let frame = roomFrames[id] else { return 0 }
        return location.x - roomGrabOffset - frame.minX
    }

    func swapRoomIfNeeded(dragged: String, at location: CGPoint) {
        guard Date().timeIntervalSince(lastRoomSwapAt) > 0.2 else { return }
        guard let target = roomFrames.first(where: { $0.key != dragged && $0.value.contains(location) })?.key else { return }
        let after = location.x > (roomFrames[target]?.midX ?? location.x)
        let slot = "\(target)|\(after)"
        guard slot != lastRoomSwapTarget else { return }
        let order = RoomPrefs.move(currentRoomOrder, id: dragged, relativeTo: target, after: after)
        guard order != currentRoomOrder else { return }
        lastRoomSwapTarget = slot
        lastRoomSwapAt = Date()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            roomOrderRaw = RoomPrefs.encodeOrder(order)
        }
    }

    /// "Move Left" / "Move Right" for a room pill's context menu.
    func moveRoom(_ id: String, by delta: Int) {
        let order = RoomPrefs.shift(
            currentRoomOrder,
            id: id,
            by: delta,
            visible: Set(store.rooms.map(\.id))
        )
        guard order != currentRoomOrder else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            roomOrderRaw = RoomPrefs.encodeOrder(order)
        }
    }

    func resetRoomPrefs() {
        let cleared = RoomPrefs.reset()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            roomAliasesRaw = cleared.aliases
            roomOrderRaw = cleared.order
            layoutUI.renamingRoomId = nil
        }
    }

    // MARK: - Page Sections (favorites, custom groups, ungrouped)

    struct PageSection: Identifiable {
        let id: String
        let title: String?
        let devices: [SmartDevice]
        /// Custom group id when the section is a user group (enables rename / reorder / delete).
        let groupId: String?
    }

    var groups: [DeviceGroup] { GroupPrefs.groups(groupsRaw) }
    var groupMap: [String: String] { liveGroupMap ?? GroupPrefs.map(groupMapRaw) }
    var collapsedGroups: Set<String> { GroupPrefs.set(collapsedRaw) }

    /// Collapse state is per page: folding "更多设备" in All must not hide "其他" in a room.
    func collapseKey(_ section: PageSection) -> String { "\(layoutScope)|\(section.id)" }

    /// "All": 常用 first, then each custom group, then the rest. A room: custom groups then 其他;
    /// without any group in the room it is one untitled section, as before.
    var pageSections: [PageSection] {
        let known = Set(groups.map(\.id))
        let map = groupMap.filter { known.contains($0.value) }
        let order = currentOrder
        var sections: [PageSection] = []
        let pool: [SmartDevice]
        if store.selectedRoomId == nil {
            if !store.favoriteDevices.isEmpty {
                let orderedFavs = DeviceLayoutPrefs.apply(order: order, to: store.favoriteDevices)
                sections.append(PageSection(id: "fav", title: L10n.tr("常用控制", "Favorites"), devices: orderedFavs, groupId: nil))
            }
            pool = store.nonFavoriteDevices
        } else {
            pool = store.visibleDevices
        }
        for group in groups {
            let members = DeviceLayoutPrefs.apply(order: order, to: pool.filter { map[$0.id] == group.id })
            if !members.isEmpty {
                sections.append(PageSection(id: group.id, title: group.name, devices: members, groupId: group.id))
            }
        }
        let rest = DeviceLayoutPrefs.apply(order: order, to: pool.filter { map[$0.id] == nil })
        if !rest.isEmpty {
            // Several Mi Cloud accounts in one panel: devices stay grouped under the account that
            // owns them. Other backends have no account to group by, even when Mi accounts remain
            // signed in.
            let accountIds = Set(store.miAccounts.map(\.id))
            let hasAccountOwnedDevices = rest.contains { device in
                guard let accountId = device.accountId else { return false }
                return accountIds.contains(accountId)
            }
            if store.miAccounts.count > 1,
               store.selectedRoomId == nil,
               store.homeBackend != .demo,
               store.homeBackend == .xiaomiCloud || hasAccountOwnedDevices {
                for account in store.miAccounts {
                    let members = rest.filter { $0.accountId == account.id }
                    if !members.isEmpty {
                        sections.append(PageSection(
                            id: "account:\(account.id)",
                            title: account.displayName,
                            devices: members,
                            groupId: nil
                        ))
                    }
                }
                let unowned = rest.filter { device in
                    guard let accountId = device.accountId else { return true }
                    return !accountIds.contains(accountId)
                }
                if !unowned.isEmpty {
                    sections.append(PageSection(id: "rest", title: L10n.tr("其他", "Other"), devices: unowned, groupId: nil))
                }
            } else {
                let titled = !sections.isEmpty
                let title: String? = store.selectedRoomId == nil
                    ? (sections.isEmpty ? L10n.tr("全屋设备", "All Devices") : L10n.tr("更多设备", "More Devices"))
                    : (titled ? L10n.tr("其他", "Other") : nil)
                sections.append(PageSection(id: "rest", title: title, devices: rest, groupId: nil))
            }
        }
        return sections
    }

    /// Section key used to detect a drag into a different section.
    func sectionKey(of id: String) -> String {
        if store.selectedRoomId == nil, store.favoriteDeviceIds.contains(id) { return "fav" }
        let known = Set(groups.map(\.id))
        if let g = groupMap[id], known.contains(g) { return g }
        return "rest"
    }

    /// Files `dragged` into `target`'s section (favorites and/or custom group).
    func adoptSection(of target: String, for dragged: String) {
        let from = sectionKey(of: dragged), to = sectionKey(of: target)
        guard from != to else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            if store.selectedRoomId == nil, (from == "fav") != (to == "fav") {
                store.toggleFavorite(dragged)
            }
            if to != "fav" {
                var map = groupMap
                map[dragged] = to == "rest" ? nil : to
                liveGroupMap = map
                groupMapRaw = GroupPrefs.encode(map)
            }
        }
    }

    func groupHeader(_ section: PageSection) -> some View {
        let collapsed = collapsedGroups.contains(collapseKey(section))
        let accent = Color.accentColor
        return Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                var set = collapsedGroups
                if collapsed { set.remove(collapseKey(section)) } else { set.insert(collapseKey(section)) }
                collapsedRaw = GroupPrefs.encode(set)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .foregroundStyle(hoveredHeader == section.id ? accent : Color.secondary)
                Text(section.title ?? "")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(hoveredHeader == section.id ? accent : Color.secondary)
                Text("\(section.devices.count)")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(section.devices.count)))
                    .foregroundStyle(.secondary.opacity(0.8))
                if section.groupId != nil {
                    Capsule(style: .continuous)
                        .fill(accent.opacity(hoveredHeader == section.id ? 0.35 : 0.18))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredHeader = $0 ? section.id : (hoveredHeader == section.id ? nil : hoveredHeader) }
        .animation(.easeOut(duration: 0.15), value: hoveredHeader)
        .contextMenu {
            if let gid = section.groupId {
                Button { layoutUI.renamingGroupId = gid } label: { Label(L10n.tr("重命名", "Rename"), systemImage: "pencil") }
                Button { moveGroup(gid, by: -1) } label: { Label(L10n.tr("上移分组", "Move Up"), systemImage: "arrow.up") }
                Button { moveGroup(gid, by: 1) } label: { Label(L10n.tr("下移分组", "Move Down"), systemImage: "arrow.down") }
                Divider()
                Button(role: .destructive) { deleteGroup(gid) } label: { Label(L10n.tr("删除分组", "Delete Group"), systemImage: "trash") }
            }
        }
        .padding(.bottom, -3)
    }

    func moveGroup(_ id: String, by delta: Int) {
        var list = groups
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { groupsRaw = GroupPrefs.encode(list) }
    }

    func deleteGroup(_ id: String) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            groupsRaw = GroupPrefs.encode(groups.filter { $0.id != id })
            let map = groupMap.filter { $0.value != id }
            liveGroupMap = map
            groupMapRaw = GroupPrefs.encode(map)
        }
    }

    /// Name prompt overlay for creating (and filing a device into) or renaming a group.
    @ViewBuilder
    var groupPromptOverlay: some View {
        if let deviceId = layoutUI.newGroupForDevice {
            promptBackdrop {
                GroupNamePrompt(title: L10n.tr("新建分组", "New Group"), name: "") { name in
                    let group = DeviceGroup(id: UUID().uuidString, name: name)
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        groupsRaw = GroupPrefs.encode(groups + [group])
                        var map = groupMap
                        map[deviceId] = group.id
                        liveGroupMap = map
                        groupMapRaw = GroupPrefs.encode(map)
                        layoutUI.newGroupForDevice = nil
                    }
                } onCancel: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { layoutUI.newGroupForDevice = nil }
                }
            }
        } else if let did = layoutUI.renamingDeviceId, let dev = store.devices.first(where: { $0.id == did }) {
            let currentAliases = GroupPrefs.map(aliasesRaw)
            let originalName = store.originalDeviceName(for: did) ?? dev.name
            promptBackdrop {
                GroupNamePrompt(
                    title: L10n.tr("重命名设备", "Rename Device"),
                    name: currentAliases[did] ?? dev.name,
                    placeholder: originalName,
                    onReset: currentAliases[did] != nil ? {
                        var aliases = GroupPrefs.map(aliasesRaw)
                        aliases.removeValue(forKey: did)
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                            aliasesRaw = GroupPrefs.encode(aliases)
                            store.applyDeviceAliases(aliases)
                            layoutUI.renamingDeviceId = nil
                        }
                    } : nil
                ) { name in
                    var aliases = GroupPrefs.map(aliasesRaw)
                    // Saving the original Mi Home name clears the alias.
                    aliases[did] = name == originalName ? nil : name
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        aliasesRaw = GroupPrefs.encode(aliases)
                        store.applyDeviceAliases(aliases)
                        layoutUI.renamingDeviceId = nil
                    }
                } onCancel: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { layoutUI.renamingDeviceId = nil }
                }
            }
        } else if let rid = layoutUI.renamingRoomId, let room = store.rooms.first(where: { $0.id == rid }) {
            let currentAliases = RoomPrefs.decodeAliases(roomAliasesRaw)
            let originalName = room.name
            promptBackdrop {
                GroupNamePrompt(
                    title: L10n.tr("重命名房间", "Rename Room"),
                    name: RoomPrefs.alias(for: rid, in: currentAliases) ?? L10n.displayRoomName(originalName),
                    placeholder: L10n.displayRoomName(originalName),
                    onReset: currentAliases[rid] != nil ? {
                        var aliases = RoomPrefs.decodeAliases(roomAliasesRaw)
                        aliases.removeValue(forKey: rid)
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                            roomAliasesRaw = RoomPrefs.encodeAliases(aliases)
                            layoutUI.renamingRoomId = nil
                        }
                    } : nil
                ) { name in
                    var aliases = RoomPrefs.decodeAliases(roomAliasesRaw)
                    // Saving the original room name clears the alias.
                    aliases[rid] = name == L10n.displayRoomName(originalName) ? nil : name
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        roomAliasesRaw = RoomPrefs.encodeAliases(aliases)
                        layoutUI.renamingRoomId = nil
                    }
                } onCancel: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { layoutUI.renamingRoomId = nil }
                }
            }
        } else if let gid = layoutUI.renamingGroupId, let group = groups.first(where: { $0.id == gid }) {
            promptBackdrop {
                GroupNamePrompt(title: L10n.tr("重命名分组", "Rename Group"), name: group.name) { name in
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        groupsRaw = GroupPrefs.encode(groups.map { $0.id == gid ? DeviceGroup(id: gid, name: name) : $0 })
                        layoutUI.renamingGroupId = nil
                    }
                } onCancel: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { layoutUI.renamingGroupId = nil }
                }
            }
        }
    }

    func promptBackdrop<C: View>(
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder _ content: () -> C
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial))
                .overlay(Color.black.opacity(reduceTransparency ? 0.32 : 0.18))
                .ignoresSafeArea()
                .onTapGesture {
                    if let onDismiss {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            layoutUI.newGroupForDevice = nil
                            layoutUI.renamingGroupId = nil
                            layoutUI.renamingDeviceId = nil
                            layoutUI.renamingRoomId = nil
                        }
                    }
                }
                .transition(.opacity)
            content()
                .transition(.scale(scale: 0.88).combined(with: .opacity))
        }
    }

    // MARK: - Container Drag (survives card reordering)

    /// Lives on the tile container, not on a card: a card's own gesture is cancelled the moment the
    /// card moves to a new slot, which froze the drag right after each swap.
    var tileDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(TileSpace.name))
            .onChanged { d in
                // A filtered list is ranked, not ordered: the long-press "edit layout" would let a
                // search result be dragged into the saved order. Cards stay tappable instead.
                guard !search.isSearching else { return }
                let moved = hypot(d.translation.width, d.translation.height)
                if isEditingLayout {
                    if let resizingId = activeResize?.deviceId ?? resizeHandleCardId(at: d.startLocation) {
                        beginResizeIfNeeded(resizingId)
                        updateResize(resizingId, translation: d.translation)
                        return
                    }
                }
                if draggingId == nil {
                    if isEditingLayout {
                        if moved > 3, let id = cardId(at: d.startLocation) { beginDrag(id, at: d.startLocation) }
                    } else if pressTask == nil, !pressCancelled, let id = cardId(at: d.startLocation) {
                        let start = d.startLocation
                        pressTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(450))
                            guard !Task.isCancelled else { return }
                            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                store.expandedDeviceId = nil
                                isEditingRooms = false
                                isEditingLayout = true
                            }
                            beginDrag(id, at: start)
                        }
                    } else if moved > 8 {
                        // Moving before the hold completes is an ordinary drag (e.g. dimming).
                        pressTask?.cancel()
                        pressCancelled = true
                    }
                }
                if let id = draggingId {
                    dragLocation = d.location
                    swapIfNeeded(dragged: id, at: d.location)
                }
            }
            .onEnded { d in
                pressTask?.cancel()
                pressTask = nil
                pressCancelled = false
                lastSwapTarget = nil
                if let resizingId = activeResize?.deviceId {
                    endResize(resizingId, translation: d.translation, samples: [])
                    return
                }
                guard draggingId != nil else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    draggingId = nil
                    dragLocation = nil
                }
            }
    }

    func cardId(at point: CGPoint) -> String? {
        tileFrames.first { $0.value.contains(point) }?.key
    }

    /// Hit-tests the 28×28 bottom-right corner arc resize handle in `TileSpace.name`.
    func resizeHandleCardId(at point: CGPoint) -> String? {
        for (id, frame) in tileFrames {
            let handleRect = CGRect(x: frame.maxX - 24, y: frame.maxY - 24, width: 28, height: 28)
            if handleRect.contains(point) {
                return id
            }
        }
        return nil
    }

    func beginResizeIfNeeded(_ deviceId: String) {
        guard activeResize == nil,
              let device = store.devices.first(where: { $0.id == deviceId }) else { return }
        activeResize = ActiveTileResize(deviceId: deviceId, startSize: tileSize(device), didStep: false)
    }

    func updateResize(_ deviceId: String, translation: CGSize) {
        guard let current = activeResize,
              current.deviceId == deviceId,
              let device = store.devices.first(where: { $0.id == deviceId }) else { return }
        let target = TileResizeGestureMath.targetSize(
            startSize: current.startSize,
            translation: translation,
            isCompactGrid: store.isCompactGridMode
        )
        if target != tileSize(device) {
            activeResize?.didStep = true
            setTileSize(target, for: device, playHaptic: true)
        }
    }

    func endResize(_ deviceId: String, translation: CGSize, samples: [TileResizeGestureMath.ResizeSample]) {
        guard let current = activeResize, current.deviceId == deviceId else { return }
        withAnimation(AppleMotion.snappySpring) {
            activeResize = nil
        }
        let moved = hypot(translation.width, translation.height)
        guard let device = store.devices.first(where: { $0.id == deviceId }) else { return }
        if !current.didStep, moved < 5 {
            cycleSize(device)
        } else if !current.didStep {
            // QuotaKeeper-style flick: release velocity projects onto at most one step.
            let velocity = TileResizeGestureMath.releaseVelocity(samples, now: Date.timeIntervalSinceReferenceDate)
            let projection = TileResizeGestureMath.projectedOffset(velocity: velocity)
            let target = TileResizeGestureMath.targetSize(
                startSize: current.startSize,
                translation: CGSize(width: translation.width + projection.width, height: translation.height + projection.height),
                isCompactGrid: store.isCompactGridMode
            )
            if target != tileSize(device) {
                setTileSize(target, for: device, playHaptic: true)
            }
        }
    }

    func beginDrag(_ id: String, at start: CGPoint) {
        let origin = tileFrames[id]?.origin ?? start
        grabOffset = CGSize(width: start.x - origin.x, height: start.y - origin.y)
        dragLocation = start
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { draggingId = id }
    }

    /// Decides where the dragged card should go: before or after the card under the pointer (top
    /// half / left half means before), or first when the pointer is above every card. The same
    /// slot never fires twice in a row and swaps are at least 0.25s apart, since frames animate
    /// after each move and could otherwise ping-pong.
    func swapIfNeeded(dragged: String, at location: CGPoint) {
        guard Date().timeIntervalSince(lastSwapAt) > 0.25 else { return }
        let others = tileFrames.filter { $0.key != dragged }
        guard !others.isEmpty else { return }

        let target: String
        let after: Bool
        if let top = others.min(by: { $0.value.minY < $1.value.minY }), location.y < top.value.minY {
            target = top.key
            after = false
        } else if let hit = others.first(where: { $0.value.contains(location) }) {
            let f = hit.value
            target = hit.key
            if location.y < f.minY + f.height * 0.3 {
                after = false
            } else if location.y > f.maxY - f.height * 0.3 {
                after = true
            } else {
                after = location.x > f.midX
            }
        } else {
            return
        }

        let slot = "\(target)|\(after)"
        guard slot != lastSwapTarget else { return }
        lastSwapTarget = slot
        lastSwapAt = Date()
        // Dropping onto a card in another section (常用 / a group / ungrouped) moves the card into it.
        adoptSection(of: target, for: dragged)
        moveDevice(dragged, relativeTo: target, after: after)
    }

    /// Offset that keeps the picked-up card under the pointer even after its slot moves.
    func dragOffset(for id: String) -> CGSize {
        guard draggingId == id, let loc = dragLocation, let frame = tileFrames[id] else { return .zero }
        return CGSize(width: loc.x - grabOffset.width - frame.minX, height: loc.y - grabOffset.height - frame.minY)
    }

    /// Moves `dragged` to `target`'s slot in the saved order (seeded from the full device list).
    var currentOrder: [String] { liveOrder ?? DeviceLayoutPrefs.decodeOrder(orderRaw) }

    func moveDevice(_ dragged: String, relativeTo target: String, after: Bool) {
        var order = currentOrder
        for id in store.devices.map(\.id) where !order.contains(id) { order.append(id) }
        guard order.contains(dragged), order.contains(target) else { return }
        order.removeAll { $0 == dragged }
        guard let t = order.firstIndex(of: target) else { return }
        order.insert(dragged, at: after ? t + 1 : t)
        guard order != currentOrder else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            liveOrder = order
            if store.favoriteDeviceIds.contains(dragged) {
                store.favoriteOrder = order.filter { store.favoriteDeviceIds.contains($0) }
            }
        }
        orderRaw = DeviceLayoutPrefs.encodeOrder(order)
    }

    func cycleSize(_ device: SmartDevice) {
        let next: TileSize
        switch tileSize(device) {
        case .half: next = .full
        case .full: next = .panel
        case .panel, .auto: next = .half
        }
        setTileSize(next, for: device, playHaptic: true)
    }

    func setTileSize(_ next: TileSize, for device: SmartDevice, playHaptic: Bool) {
        guard tileSize(device) != next else { return }
        var sizes = liveSizes ?? DeviceLayoutPrefs.decode(tileSizesRaw)
        sizes[DeviceLayoutPrefs.scopedKey(id: device.id, scope: layoutScope)] = next
        if playHaptic {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        withAnimation(AppleMotion.snappySpring) {
            store.expandedDeviceId = nil
            liveSizes = sizes
        }
        tileSizesRaw = DeviceLayoutPrefs.encode(sizes)
    }

    var doneEditingButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isEditingLayout = false
                isEditingRooms = false
                draggingId = nil
                activeResize = nil
                draggingRoomId = nil
                roomDragLocation = nil
            }
        } label: {
            Text(L10n.tr("完成", "Done")).font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
        }
        .buttonStyle(PillActionButtonStyle(isSelected: true))
        .keyboardShortcut(.defaultAction)
    }

    func usesClimatePanel(_ device: SmartDevice) -> Bool {
        tileSize(device) != .half
    }

    /// The device's card size with `.auto` resolved; full and panel sizes take a whole row.
    func tileSize(_ device: SmartDevice) -> TileSize {
        DeviceLayoutPrefs.resolved(
            liveSizes.map { DeviceLayoutPrefs.lookup($0, id: device.id, scope: layoutScope) }
                ?? DeviceLayoutPrefs.cachedSize(raw: tileSizesRaw, id: device.id, scope: layoutScope),
            device: device,
            compactGrid: store.isCompactGridMode,
            climatePanel: climatePanelModule
        )
    }

    // MARK: - Device Collection (flow layout with per-card spans)

    /// Column span out of 6 for each device: half = 3, full/panel = 6; Bento alternates 4+2 and 2+2+2.
    func spans(for devices: [SmartDevice]) -> [String: Int] {
        var result: [String: Int] = [:]
        for dev in devices {
            let size = tileSize(dev)
            let isTransientlyExpanded = !isEditingLayout && store.expandedDeviceId == dev.id
            result[dev.id] = (size == .half && !isTransientlyExpanded) ? 3 : 6
        }
        return result
    }

    /// Cards for one collection. Search results pass `sortByUserOrder: false`, so rank wins over the
    /// saved layout order.
    @ViewBuilder
    func deviceCollectionView(
        devices: [SmartDevice],
        showRoomBadge: Bool,
        quickIndexMap: [String: Int],
        highlightId: String? = nil,
        sortByUserOrder: Bool = true
    ) -> some View {
        let aliases = GroupPrefs.map(aliasesRaw)
        let source = sortByUserOrder
            ? DeviceLayoutPrefs.apply(order: currentOrder, to: devices)
            : devices
        let ordered = source.map { dev -> SmartDevice in
            guard let alias = aliases[dev.id] else { return dev }
            var d = dev
            d.name = alias
            return d
        }
        let spanMap = spans(for: ordered)
        // Every card is its own child keyed by device id, so a reorder slides cards instead of rebuilding rows.
        TileFlowLayout(spacing: 7) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, dev in
                let span = spanMap[dev.id] ?? 6
                DeviceCardView(
                    device: dev,
                    store: store,
                    showRoomBadge: showRoomBadge,
                    isCompactTile: span < 6,
                    quickIndex: quickIndexMap[dev.id],
                    isBentoTile: false
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .modifier(editable(dev))
                .overlay {
                    if highlightId == dev.id {
                        RoundedRectangle(
                            cornerRadius: PanelLook.tileRadius,
                            style: .continuous
                        )
                        .strokeBorder(
                            Color.accentColor.opacity(0.85),
                            lineWidth: 1.6
                        )
                        .allowsHitTesting(false)
                    }
                }
                // Measured outside the jiggle/drag effects: those transforms would otherwise change the
                // reported frame every animation frame and re-layout the whole panel continuously.
                .background {
                    GeometryReader { geo in
                        let f = geo.frame(in: .named(TileSpace.name))
                        let g = geo.frame(in: .global)
                        Color.clear
                            .preference(
                                key: TileFramesKey.self,
                                value: [dev.id: CGRect(x: f.minX.rounded(), y: f.minY.rounded(), width: f.width.rounded(), height: f.height.rounded())]
                            )
                            .onAppear { LayoutUIState.shared.cardGlobalFrames[dev.id] = g }
                            .onChange(of: g) { _, newFrame in LayoutUIState.shared.cardGlobalFrames[dev.id] = newFrame }
                    }
                }
                .layoutValue(key: TileSpanKey.self, value: span)
            }
        }
        .animation(AppleMotion.snappySpring, value: ordered.map { "\($0.id):\(spanMap[$0.id] ?? 6)" })
        .id("rows")
    }
}
