import SwiftUI
import AppKit
import MijiaCore

extension ControlCenterPanel {
    // MARK: - Mi Session Expiry (#181)

    var miSessionExpiryBanner: some View {
        let expired = store.miSessionShowsExpired
        let dateText = store.miSessionExpiringSoonDate?
            .formatted(date: .abbreviated, time: .omitted) ?? ""
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: expired ? "exclamationmark.triangle.fill" : "clock")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(expired ? Color.orange : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(expired
                    ? L10n.tr("米家登录已过期", "Xiaomi Home session expired")
                    : L10n.tr("米家登录将在 \(dateText) 到期", "Xiaomi Home sign-in expires \(dateText)"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                Text(expired
                    ? L10n.tr("设备控制已暂停，扫码后恢复", "Device controls are paused; scan to restore them")
                    : L10n.tr("提前扫码可以避免控制中断", "Scan now to avoid an interruption"))
                    .font(.system(size: DesignTokens.TypeSize.micro))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button(expired
                ? L10n.tr("扫码重新登录", "Scan to sign in")
                : L10n.tr("现在重新扫码", "Re-scan now")) {
                withAnimation(AppleMotion.snappySpring) { store.presentMiReauth() }
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(in: shape)
    }

    var miReauthOverlay: some View {
        promptBackdrop(onDismiss: {
            withAnimation(AppleMotion.snappySpring) { store.dismissMiReauth() }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(store.miSessionShowsExpired
                        ? L10n.tr("米家登录已过期", "Xiaomi Home session expired")
                        : L10n.tr("扫码登录米家账号", "Sign in to Xiaomi Home"))
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    Spacer()
                    Button {
                        withAnimation(AppleMotion.snappySpring) { store.dismissMiReauth() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.tr("关闭", "Close")))
                }

                MiAccountSection(store: store, autoStartsQRLogin: true, showsRegionPicker: false)
            }
            .padding(14)
            .frame(maxWidth: 332)
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.20), radius: 14, y: 5)
            .padding(16)
        }
    }

    // MARK: - 1. Hero Header & Live Environment Chips

    var topHeroHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "house.fill")
                    .font(.system(size: DesignTokens.TypeSize.title, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        LinearGradient(colors: [.orange, DesignTokens.active],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        homeTitle

                        if store.homeBackend == .demo {
                            Text(L10n.tr("演示预览", "Demo"))
                                .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))
                                .panelHelp(L10n.tr(
                                    "正在使用内置虚拟设备，完全离线，不联网。可在设置里切回真实账号。",
                                    "Using built-in virtual devices, fully offline. Switch back to a real account in Settings."
                                ))
                        }
                    }

                    Text(statusSummaryText)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        store.presentAssistantBar(startVoice: true)
                    }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .frame(width: 26, height: 24)
                        .adaptiveGlass(in: Capsule(style: .continuous), interactive: true)
                        .listeningPulse(SpeechInputController.shared.isListening, color: .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("语音指令", "Voice command")))
                .accessibilityHint(Text(L10n.tr("点击后直接说话控制设备", "Click, then speak to control devices")))
                .panelHelp(L10n.tr("语音指令：点击直接说话控制设备（快捷键 V）", "Voice command: click to speak (shortcut V)"))

                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        if store.isShowingAssistantBar {
                            store.dismissAssistantBar()
                        } else {
                            store.presentAssistantBar()
                        }
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(store.isShowingAssistantBar ? Color.white : Color.primary.opacity(0.78))
                        .frame(width: 26, height: 24)
                        .background {
                            if store.isShowingAssistantBar {
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor)
                                    .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 1.5)
                            }
                        }
                        .modifier(
                            ChipSurface(
                                shape: Capsule(style: .continuous),
                                tint: nil,
                                interactive: true,
                                clear: false,
                                isHidden: store.isShowingAssistantBar
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("AI 指令", "AI command")))
                .accessibilityHint(Text(L10n.tr("用一句话控制设备", "Control devices with natural language")))
                .panelHelp(L10n.tr("AI 指令：用一句话控制设备（快捷键 /）", "AI command: control devices with natural language (shortcut /)"))

                if isEditingLayout || isEditingRooms {
                    doneEditingButton
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else if !store.allOffTargets.isEmpty {
                    // The label says what will be switched off (#23); a hold confirms.
                    let count = store.allOffTargets.count
                    HoldToConfirmButton(
                        title: allOffScopeDisplayName.map { L10n.tr("全关 \($0)", "All Off \($0)") } ?? L10n.tr("全关", "All Off"),
                        count: count,
                        onConfirm: {
                            withAnimation(AppleMotion.snappySpring) { store.turnAllOff() }
                            SoundFeedback.playSuccess()
                        },
                        onTap: {
                            store.showToast(
                                L10n.tr("按住 0.6 秒关闭这 \(count) 台（插座、扫地机默认不参与）", "Hold 0.6s to turn off these \(count) (plugs and vacuums are left out by default)"),
                                isError: false
                            )
                        }
                    )
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }

            environmentStatusLine
        }
    }

    /// Dashboard title; with several Mi Homes it becomes a menu that switches between them. Several
    /// signed-in accounts list their homes under the account that owns them.
    @ViewBuilder
    var homeTitle: some View {
        if store.homes.count > 1 {
            Menu {
                Button {
                    store.selectMiHome(nil)
                } label: {
                    Label(L10n.tr("全部家庭", "All Homes"), systemImage: store.selectedMiHomeId == nil ? "checkmark" : "")
                }
                Divider()
                if store.miAccounts.count > 1 {
                    ForEach(store.miAccounts) { account in
                        let accountHomes = store.homes.filter { $0.accountId == account.id }
                        if !accountHomes.isEmpty {
                            Section {
                                ForEach(accountHomes) { home in
                                    homeMenuButton(home)
                                }
                            } header: {
                                Text(account.displayName)
                            }
                        }
                    }
                } else {
                    ForEach(store.homes) { home in
                        homeMenuButton(home)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedHomeTitle)
                        .font(.system(size: DesignTokens.TypeSize.title, weight: .bold))
                        .tracking(-0.2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .panelHelp(L10n.tr("切换家庭", "Switch home"))
        } else {
            Text(store.homeName)
                .font(.system(size: DesignTokens.TypeSize.title, weight: .bold))
                .tracking(-0.2)
        }
    }

    func homeMenuButton(_ home: HomeOption) -> some View {
        Button {
            store.selectMiHome(home.id)
        } label: {
            Label(
                "\(home.name)  \(home.deviceCount)",
                systemImage: store.selectedMiHomeId == home.id ? "checkmark" : ""
            )
        }
    }

    var selectedHomeTitle: String {
        if let id = store.selectedMiHomeId, let home = store.homes.first(where: { $0.id == id }) {
            return home.name
        }
        return store.homeName
    }

    /// One quiet line instead of a row of capsules: 客厅 25.5°C · 52% ⚡ 18W.
    @ViewBuilder
    var environmentStatusLine: some View {
        // One representative reading keeps the line quiet: the selected room's reading first,
        // then the user's preferred menu-bar temperature source (#103).
        let selectedRoomId = store.selectedRoomId
        let selectedRoomName = store.rooms.first { $0.id == selectedRoomId }?.name
        let roomDeviceIds = selectedRoomId.map { roomId in
            Set(store.devices.filter { $0.roomId == roomId }.map(\.id))
        }
        let reading = store.environmentReadings.first { env in
            roomDeviceIds?.contains(env.id) == true
        } ?? store.environmentReadings.first { env in
            selectedRoomName != nil && env.roomName == selectedRoomName
        } ?? store.preferredEnvironmentReading
        let watts = store.totalPowerWatts

        if store.deviceValuesAreStale {
            Text(L10n.tr("可能过期", "Possibly stale"))
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)
        } else if let reading, reading.temperature != nil || reading.humidity != nil || watts >= 1 {
            HStack(spacing: 6) {
                Button {
                    handleEnvironmentChipTap(reading)
                } label: {
                    HStack(spacing: 5) {
                        Text(L10n.displayRoomName(reading.label))
                            .foregroundStyle(.secondary)
                        if let t = reading.temperature {
                            Text(L10n.temperatureValue(t, fractionDigits: 1) + "°")
                                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                        }
                        if let h = reading.humidity {
                            Text(String(format: "%.0f%%", h))
                                .foregroundStyle(DesignTokens.Orb.climate)
                        }
                    }
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .monospacedDigit()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .panelHelp(L10n.tr("点击定位并展开温湿度折线", "Click to locate and expand sensor chart"))

                if watts >= 1 {
                    Text("·").foregroundStyle(.secondary.opacity(0.6))
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                            .foregroundStyle(DesignTokens.Orb.plug)
                        Text(String(format: "%.0fW", watts))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DesignTokens.Orb.plug)
                    }
                }

                Spacer(minLength: 0)
            }
            .lineLimit(1)
        }
    }

    func handleEnvironmentChipTap(_ env: EnvironmentReading) {
        withAnimation(AppleMotion.snappySpring) {
            if search.isSearching {
                search.clear()
            }
            if store.hiddenDeviceIds.contains(env.id) {
                store.unhideDevice(env.id)
            }
            if !store.filteredDevices.contains(where: { $0.id == env.id }) {
                store.selectRoom(nil)
            }
            for section in pageSections where section.devices.contains(where: { $0.id == env.id }) {
                let key = collapseKey(section)
                var set = collapsedGroups
                if set.contains(key) {
                    set.remove(key)
                    collapsedRaw = GroupPrefs.encode(set)
                }
            }
            store.toggleExpanded(env.id)
            if store.expandedDeviceId == env.id {
                pendingScrollToDeviceId = env.id
            }
        }
    }

    var statusSummaryText: String {
        if isEditingRooms {
            return L10n.tr("拖动房间排序，点铅笔图标改名", "Drag rooms to reorder, tap the pencil to rename")
        }
        if isEditingLayout {
            return L10n.tr("拖动卡片排序，点右下角圆弧手柄改大小", "Drag to reorder, drag or tap the corner handle to resize")
        }
        if store.activeDeviceCount > 0 {
            return L10n.tr(
                "\(store.activeDeviceCount) 台设备开启， \(store.onlineDeviceCount) 台在线",
                "\(store.activeDeviceCount) active, \(store.onlineDeviceCount) online"
            )
        }
        return L10n.tr(
            "全屋设备待机， \(store.onlineDeviceCount) 台实时在线",
            "All standby, \(store.onlineDeviceCount) online"
        )
    }

    // MARK: - 1B. Quick Actions & HA Scenes Strip

    /// Scene strip: equal-width glass pills, four across when there are four or fewer.
    var quickActionsAndScenesBar: some View {
        let itemCount = QuickAction.allCases.count + store.scenes.count
        return Group {
            if itemCount <= 4 {
                scenePillRow(expand: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    scenePillRow(expand: false)
                        .horizontalWheelScroll()
                }
            }
        }
    }

    func scenePillRow(expand: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(QuickAction.allCases) { action in
                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        _ = store.executeQuickAction(action)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: action.sfSymbolName)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(ScenePalette.tint(for: action.visualCategory))
                        Text(action.title)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillActionButtonStyle())
                .frame(maxWidth: expand ? .infinity : nil)
            }

            ForEach(store.scenes) { scene in
                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        _ = store.triggerScene(scene)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: scene.iconName)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(ScenePalette.tint(for: scene.visualCategory))
                        Text(scene.name)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillActionButtonStyle())
                .frame(maxWidth: expand ? .infinity : nil)
            }
        }
    }

    // MARK: - 2. Room Filter Strip & Grid Toggle

    var roomPillsRow: some View {
        HStack(spacing: 5) {
            roomPill(title: L10n.tr("全部", "All"), roomId: nil)
            ForEach(displayRooms) { room in
                roomPillRowItem(room)
            }
            if isEditingRooms {
                Button {
                    resetRoomPrefs()
                } label: {
                    Label(L10n.tr("重置", "Reset"), systemImage: "arrow.counterclockwise")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .lineLimit(1)
                }
                .buttonStyle(PillActionButtonStyle())
                .accessibilityHint(Text(L10n.tr("清除房间名称和顺序", "Clears room names and order")))
                .panelHelp(L10n.tr("恢复房间原名与默认顺序", "Restore original room names and order"))
                .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
        }
        .animation(AppleMotion.snappySpring, value: displayRooms.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isEditingRooms)
    }

    func roomPillRowItem(_ room: RoomArea) -> some View {
        roomPill(title: roomDisplayTitle(room), roomId: room.id)
            .id(room.id)
            .offset(x: roomDragOffset(for: room.id))
            // Measured outside the drag offset and the jiggle, like device cards: those transforms
            // would otherwise feed back into `roomDragOffset` (the reported frame would already
            // include the offset) and the pill would jump.
            .background {
                GeometryReader { geo in
                    let frame = geo.frame(in: .named(RoomSpace.name))
                    Color.clear.preference(
                        key: RoomFramesKey.self,
                        value: [room.id: CGRect(
                            x: frame.minX.rounded(),
                            y: frame.minY.rounded(),
                            width: frame.width.rounded(),
                            height: frame.height.rounded()
                        )]
                    )
                }
            }
            .zIndex(draggingRoomId == room.id ? 2 : 0)
    }

    func scrollRoomStrip(using proxy: ScrollViewProxy, roomId: String?, animated: Bool) {
        let target = roomId ?? "roomsStart"
        let anchor: UnitPoint = roomId == nil ? .leading : .center
        if animated && !reduceMotion {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                proxy.scrollTo(target, anchor: anchor)
            }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
    }

    var listFilterBars: some View {
        VStack(alignment: .leading, spacing: 6) {
            roomFilterBar
            if showsKindRow { kindFilterBar }
        }
    }

    var showsKindRow: Bool {
        if case .kind = store.listCut { return true }
        return store.kindChips.count >= 2
    }

    func scrollKindStrip(using proxy: ScrollViewProxy, tag: DeviceKindTag) {
        if reduceMotion {
            proxy.scrollTo(tag, anchor: .center)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                proxy.scrollTo(tag, anchor: .center)
            }
        }
    }

    var kindFilterBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.kindChips, id: \.self) { tag in
                        kindPill(tag)
                            .id(tag)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .horizontalWheelScroll()
            }
            .defaultScrollAnchor(.leading)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: store.listCut) { _, cut in
                guard case .kind(let tag) = cut else { return }
                scrollKindStrip(using: proxy, tag: tag)
            }
            .onChange(of: kindScrollTrigger) { _, _ in
                guard case .kind(let tag) = store.listCut else { return }
                scrollKindStrip(using: proxy, tag: tag)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.0), location: 0.0),
                        .init(color: .black, location: 0.035),
                        .init(color: .black, location: 0.86),
                        .init(color: .black.opacity(0.0), location: 1.0)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
        }
        .background(segmentedTrack, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(segmentedTrackRim, lineWidth: DesignTokens.hairline)
        }
        .clipShape(Capsule(style: .continuous))
    }

    @ViewBuilder
    func kindPill(_ tag: DeviceKindTag) -> some View {
        if let hint = tag.chipHint {
            kindPillButton(tag).panelHelp(hint)
        } else {
            kindPillButton(tag)
        }
    }

    func kindPillButton(_ tag: DeviceKindTag) -> some View {
        let isSelected = store.listCut == .kind(tag)
        let surface = TileSurface(isActive: true, scheme: effectiveScheme)
        return Button {
            withAnimation(AppleMotion.snappySpring) {
                if store.listCut == .kind(tag) {
                    kindScrollTrigger &+= 1
                } else {
                    store.selectKind(tag)
                }
            }
        } label: {
            Text(tag.chipTitle)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? surface.ink : Color.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(surface.fill)
                            .shadow(color: .black.opacity(effectiveScheme == .dark ? 0.28 : 0.10), radius: 2, y: 1)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(AppleMotion.snappySpring, value: isSelected)
    }

    var roomFilterBar: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        Color.clear.frame(width: 0, height: 1).id("roomsStart")
                        roomPillsRow
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                            .coordinateSpace(name: RoomSpace.name)
                            .simultaneousGesture(roomStripGesture)
                            .onPreferenceChange(RoomFramesKey.self) { frames in
                                if frames != roomFrames { roomFrames = frames }
                            }
                    }
                    .horizontalWheelScroll()
                }
                .defaultScrollAnchor(.leading)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                // The menu-bar window restores a stale horizontal offset on reopen; snap back to
                // the start (or the selected room) so the first pill is not half scrolled out.
                .onChange(of: isPresented) { _, shown in
                    guard shown else { return }
                    scrollRoomStrip(using: proxy, roomId: store.selectedRoomId, animated: false)
                }
                .onAppear {
                    scrollRoomStrip(using: proxy, roomId: store.selectedRoomId, animated: false)
                }
                .onChange(of: store.selectedRoomId) { _, id in
                    scrollRoomStrip(using: proxy, roomId: id, animated: true)
                }
                .onChange(of: roomScrollTrigger) { _, _ in
                    scrollRoomStrip(using: proxy, roomId: store.selectedRoomId, animated: true)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.0), location: 0.0),
                            .init(color: .black, location: 0.035),
                            .init(color: .black, location: 0.86),
                            .init(color: .black.opacity(0.0), location: 1.0)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            }
            .background(segmentedTrack, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(segmentedTrackRim, lineWidth: DesignTokens.hairline)
            }
            .clipShape(Capsule(style: .continuous))

            gridToggleButtons
        }
    }

    var segmentedTrack: Color {
        effectiveScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.055)
    }

    var segmentedTrackRim: Color {
        effectiveScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.04)
    }

    var gridToggleButtons: some View {
        HStack(spacing: 5) {
            toggleChip(
                isOn: store.isCompactGridMode,
                onSymbol: "rectangle.grid.2x2.fill",
                offSymbol: "rectangle.grid.1x2.fill",
                onLabel: L10n.tr("紧凑双列视图", "Compact two-column view"),
                help: store.isCompactGridMode
                    ? L10n.tr("当前：双列紧凑磁贴（点击切换单列）", "2-column compact tiles (click for single column)")
                    : L10n.tr("点击切换双列紧凑磁贴视图", "Switch to 2-column compact tiles")
            ) {
                store.isCompactGridMode.toggle()
            }

            toggleChip(
                isOn: store.hideOfflineDevices,
                onSymbol: "wifi",
                offSymbol: "wifi.slash",
                onLabel: L10n.tr("只显示在线设备", "Show online devices only"),
                help: store.hideOfflineDevices
                    ? L10n.tr("当前只显示在线设备（点击显示全部）", "Showing online devices only (click to show all)")
                    : L10n.tr("点击隐藏未通电/离线设备", "Hide offline/unplugged devices")
            ) {
                store.hideOfflineDevices.toggle()
            }
        }
    }

    func toggleChip(
        isOn: Bool,
        onSymbol: String,
        offSymbol: String,
        onLabel: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(AppleMotion.snappySpring) { action() }
        } label: {
            Image(systemName: isOn ? onSymbol : offSymbol)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.78))
                .frame(width: 26, height: 24)
                .background {
                    if isOn {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    }
                }
                .modifier(
                    ChipSurface(
                        shape: Capsule(style: .continuous),
                        tint: nil,
                        interactive: true,
                        clear: false,
                        isHidden: isOn
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(onLabel))
        .accessibilityAddTraits(isOn ? AccessibilityTraits.isSelected : [])
        .panelHelp(help)
    }

    func selectRoom(_ roomId: String?, animation: Animation) {
        withAnimation(animation) {
            if !store.selectRoom(roomId) { roomScrollTrigger &+= 1 }
        }
    }

    @ViewBuilder
    func roomPill(title: String, roomId: String?) -> some View {
        let isSelected = roomId == nil
            ? store.listCut == .all
            : store.selectedRoomId == roomId
        let isEditable = isEditingRooms && roomId != nil
        // The selected pill is a lit tile of its own, so its label takes the tile's ink: a dark
        // capsule in dark mode would otherwise keep the light-mode platter ink.
        let surface = TileSurface(isActive: true, scheme: effectiveScheme)
        let content = HStack(spacing: 4) {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? surface.ink : Color.secondary)
            if isEditable, let roomId {
                // #146: an explicit pencil so the edit-mode pill never doubles as "rename" on a
                // long-press release.
                Button {
                    layoutUI.renamingRoomId = roomId
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                        .foregroundStyle(isSelected ? surface.ink : Color.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("重命名房间", "Rename Room")))
                .panelHelp(L10n.tr("重命名这个房间", "Rename this room"))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background {
            if isSelected {
                Capsule(style: .continuous)
                    .fill(surface.fill)
                    .shadow(color: .black.opacity(effectiveScheme == .dark ? 0.28 : 0.10), radius: 2, y: 1)
            }
        }
        .contentShape(Capsule(style: .continuous))

        Group {
            if roomId == nil || !isEditingRooms {
                Button {
                    selectRoom(roomId, animation: AppleMotion.snappySpring)
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .animation(AppleMotion.snappySpring, value: isSelected)
        .contextMenu {
            if let roomId {
                Button {
                    layoutUI.renamingRoomId = roomId
                } label: {
                    Label(L10n.tr("重命名房间…", "Rename Room…"), systemImage: "pencil")
                }
                Button {
                    moveRoom(roomId, by: -1)
                } label: {
                    Label(L10n.tr("左移", "Move Left"), systemImage: "arrow.left")
                }
                .disabled(displayRooms.first?.id == roomId)
                Button {
                    moveRoom(roomId, by: 1)
                } label: {
                    Label(L10n.tr("右移", "Move Right"), systemImage: "arrow.right")
                }
                .disabled(displayRooms.last?.id == roomId)
                Divider()
                Button {
                    resetRoomPrefs()
                } label: {
                    Label(L10n.tr("重置房间名称与顺序", "Reset Room Names & Order"), systemImage: "arrow.counterclockwise")
                }
            }
        }
        .accessibilityHint(Text(isEditable
            ? L10n.tr("点按铅笔改名，拖动调整顺序", "Tap the pencil to rename, drag to reorder")
            : L10n.tr("切换到该房间", "Show this room")))
        .modifier(RoomPillJiggle(active: isEditable && draggingRoomId != roomId, phase: roomPhase(roomId ?? "")))
    }

    func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.80))
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 3)
        .padding(.bottom, -3)
    }

    var disconnectedEmptyBackend: HomeBackend {
        if store.hasMiSource && !store.hasHASource { return .xiaomiCloud }
        if store.hasHASource && !store.hasMiSource { return .homeAssistant }
        return store.homeBackend
    }

    var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: DesignTokens.TypeSize.reading))
                .foregroundStyle(.secondary)
            if case .disconnected = store.connectionStatus {
                Text(
                    store.isDualSourceActive
                        ? L10n.tr("尚未连接到 Home Assistant 或米家云端", "Not connected to Home Assistant or Xiaomi Cloud")
                        : (disconnectedEmptyBackend == .xiaomiCloud
                            ? L10n.tr("尚未登录米家云端账号", "Not signed in to Xiaomi Cloud")
                            : L10n.tr("尚未连接到 Home Assistant", "Not connected to Home Assistant"))
                )
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(
                    store.isDualSourceActive
                        ? L10n.tr("请检查两端配置，或在偏好设置中查看连接状态", "Check both configurations, or review connection status in Preferences")
                        : (disconnectedEmptyBackend == .xiaomiCloud
                            ? L10n.tr("无需额外部署服务器，使用手机「米家」App 扫码即可同步设备", "Scan with the Mi Home app on your phone to sync devices without a server")
                            : L10n.tr("点击下方按钮配置服务器地址与令牌，或切换为手机米家扫码直连", "Configure your server URL and token below, or switch to Xiaomi Cloud QR login"))
                )
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button(L10n.tr("打开新手引导", "Setup Guide")) {
                        withAnimation(AppleMotion.snappySpring) {
                            store.reopenOnboarding()
                        }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                    Button {
                        presentSettingsWindow()
                    } label: {
                        Text(L10n.tr("偏好设置", "Preferences"))
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
                .padding(.top, 2)
            } else if store.hasReceivedInitialSnapshot && store.devices.isEmpty {
                // Synced but nothing came back: say so instead of spinning on "syncing" forever (#134).
                Text(L10n.tr("同步完成，但没有拉取到可显示的设备", "Synced, but no devices to show"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr(
                    "请确认手机米家 App 里这个账号能看到设备（被共享的家庭也算）。仍然为空，请在偏好设置里「复制诊断信息」反馈。",
                    "Check that this account can see devices in the Mi Home app (shared homes included). If it is still empty, use Copy Diagnostics in Preferences and report it."
                ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button(L10n.tr("重新同步", "Sync Again")) {
                        store.refreshNow()
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                    Button {
                        presentSettingsWindow()
                    } label: {
                        Text(L10n.tr("偏好设置", "Preferences"))
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
                .padding(.top, 2)
            } else {
                Group {
                    if case .kind = store.listCut {
                        Text(store.hideOfflineDevices
                            ? L10n.tr("这一类暂无通电在线的设备", "Nothing of this type is online")
                            : L10n.tr("这一类暂无设备", "Nothing of this type"))
                    } else {
                        Text(
                            store.hideOfflineDevices
                                ? L10n.tr("该房间暂无通电在线的设备", "No online devices in this room")
                                : store.hasReceivedInitialSnapshot
                                    ? L10n.tr("这个房间暂无设备", "No devices in this room")
                                    : L10n.tr("正在同步设备列表…", "Syncing devices…")
                        )
                    }
                }
                .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))
                .foregroundStyle(.secondary)
                if store.hideOfflineDevices {
                    Button(L10n.tr("显示离线设备", "Show Offline Devices")) {
                        withAnimation(AppleMotion.snappySpring) {
                            store.hideOfflineDevices = false
                        }
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Home Assistant Address Question (#18)

    /// The app never moves the token to a new address by itself; it asks here first.
    func haAddressSuggestionBanner(_ instance: HADiscoveredInstance) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        let place = instance.locationName.isEmpty || instance.locationName == "Home Assistant"
            ? instance.hostAndPort
            : "\(instance.locationName)（\(instance.hostAndPort)）"
        return VStack(alignment: .leading, spacing: 6) {
            Label(
                L10n.tr("连不上 Home Assistant。发现了 \(place)，要切换过去吗？", "Can't reach Home Assistant. Found \(place). Switch to it?"),
                systemImage: "questionmark.circle.fill"
            )
            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
            Text(L10n.tr(
                "切换后会把访问令牌发给这个地址。不认识这个地址就点「不切换」。",
                "Switching sends your access token to this address. If you don't recognize it, choose Don't Switch."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(L10n.tr("切换", "Switch")) {
                    withAnimation(AppleMotion.snappySpring) { store.acceptHAAddressSuggestion() }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                Button(L10n.tr("不切换", "Don't Switch")) {
                    withAnimation(AppleMotion.snappySpring) { store.dismissHAAddressSuggestion() }
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(in: shape)
    }

    // MARK: - 3. Floating Undo & Toast Banner

    @ViewBuilder
    var overlayNotifications: some View {
        if let banner = store.undoBanner {
            let bannerShape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
            HStack(spacing: 10) {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: DesignTokens.TypeSize.body))

                Text(banner.title)
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))

                Spacer()

                Button(L10n.tr("撤销", "Undo")) {
                    withAnimation(AppleMotion.snappySpring) {
                        _ = store.undoTurnAllOff()
                    }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: DesignTokens.active))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .adaptiveGlass(in: bannerShape)
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
            .padding(.horizontal, 14)
            .padding(.bottom, 42)
            // #53: reading the banner must not cost the undo. Leaving restarts the full window.
            .onHover { hovering in
                if hovering {
                    store.pauseUndoBannerCountdown()
                } else {
                    store.resumeUndoBannerCountdown()
                }
            }
            .transition(AppleMotion.drawerTransition)
        } else if let toast = store.toastNotice {
            let toastShape = Capsule(style: .continuous)
            HStack(spacing: 6) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? .orange : .green)
                    .font(.system(size: DesignTokens.TypeSize.caption))

                Text(toast.message)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .adaptiveGlass(in: toastShape)
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
            .padding(.bottom, 42)
            .transition(AppleMotion.drawerTransition)
        }
    }

    // MARK: - 4. Footer Status Bar

    var footerBar: some View {
        HStack(spacing: 8) {
            BreathingDot(
                color: statusDotColor,
                animate: statusDotColor == .green
            )
            .id(statusDotColor)

            Text(statusFooterLabel)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let release = store.updateState.badgeRelease {
                Button {
                    if store.updateState.isReadyToRelaunch {
                        withAnimation(AppleMotion.snappySpring) {
                            store.confirmRelaunchForUpdate()
                        }
                    } else {
                        SettingsWindowOpener.shared.show(tab: .about)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(
                            systemName: store.updateState.isReadyToRelaunch
                                ? "arrow.triangle.2.circlepath.circle.fill"
                                : "arrow.down.circle.fill"
                        )
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        Text(updateBadgeTitle(for: release))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .monospacedDigit()
                    }
                }
                .buttonStyle(
                    PillActionButtonStyle(
                        isSelected: true,
                        tintColor: store.updateState.isReadyToRelaunch ? .green : .accentColor
                    )
                )
                .panelHelp(
                    store.updateState.isReadyToRelaunch
                        ? L10n.tr("点击立即重启并完成 v\(release.version) 更新", "Click to relaunch and finish updating to v\(release.version)")
                        : L10n.tr("发现新版本 v\(release.version)，点击直接打开更新", "New version v\(release.version) available")
                )
            }

            // #53: once the banner is gone the assistant action is still undoable for ten minutes.
            if store.undoBanner == nil,
               !store.isShowingAssistantBar,
               UndoAvailabilityTracker.shared.isAvailable {
                Button {
                    store.presentAssistantBar()
                    Task { await UndoAvailabilityTracker.shared.performUndo(store: store) }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.72))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("撤销上一步", "Undo last action")))
                .panelHelp(L10n.tr("撤销上一步（10 分钟内有效）", "Undo the last assistant action (valid for 10 minutes)"))
            }

            // #60: the panel has no visible search field until you type, so the footer advertises it.
            if !search.isSearching {
                Button {
                    search.begin()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.72))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("搜索设备", "Search devices")))
                .panelHelp(L10n.tr("搜索设备、房间或拼音首字母（⌘F）", "Search devices, rooms or pinyin initials (⌘F)"))
            }

            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.tr("立即同步", "Refresh now")))
            .panelHelp(L10n.tr("立即同步最新状态", "Refresh device states now"))

            Button {
                presentSettingsWindow()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.tr("打开设置", "Open Settings")))
            .panelHelp(L10n.tr("偏好设置与连接配置（⌘,）", "Preferences & connection settings (⌘,)"))

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.tr("退出应用", "Quit App")))
            .panelHelp(L10n.tr("完全退出 MenuBarMijia（⌘Q）", "Quit MenuBarMijia (⌘Q)"))
        }
    }

    /// `openSettings` is the supported way to reveal the Settings scene from a MenuBarExtra.
    func presentSettingsWindow() {
        SettingsWindowOpener.shared.show()
    }

    func updateBadgeTitle(for release: AppRelease) -> String {
        switch store.updateState {
        case .readyToRelaunch:
            return L10n.tr("重启更新 v\(release.version)", "Relaunch v\(release.version)")
        case .downloading(_, let progress):
            if let fraction = progress.fractionCompleted {
                return L10n.tr("下载 \(Int(fraction * 100))%", "DL \(Int(fraction * 100))%")
            }
            return L10n.tr("下载中…", "Downloading…")
        case .verifying:
            return L10n.tr("校验中…", "Verifying…")
        default:
            return L10n.tr("更新 v\(release.version)", "Update v\(release.version)")
        }
    }

    var statusDotColor: Color {
        switch store.connectionStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }

    var statusFooterLabel: String {
        if let dual = store.dualSourceStatusSummary { return dual }
        switch store.connectionStatus {
        case .connected:
            if store.homeBackend == .demo {
                return L10n.tr("虚拟设备，离线运行", "Virtual devices, offline")
            }
            if store.connectedBackends.contains(.homeAssistant) && store.connectedBackends.contains(.xiaomiCloud) {
                return L10n.tr("HA + 米家云 (\(store.serverHostSummary))", "HA + Xiaomi Cloud (\(store.serverHostSummary))")
            }
            if store.connectedBackends.contains(.xiaomiCloud) {
                return L10n.tr("\(store.serverHostSummary)，Miot 直连", "\(store.serverHostSummary), MIoT Direct")
            }
            return L10n.tr("HA 实时连接 (\(store.serverHostSummary))", "HA Live (\(store.serverHostSummary))")
        case .connecting:
            return L10n.tr("正在连接 (\(store.serverHostSummary))…", "Connecting (\(store.serverHostSummary))…")
        case .disconnected(let reason):
            return L10n.tr("未连接：\(reason)", "Disconnected: \(reason)")
        }
    }
}
