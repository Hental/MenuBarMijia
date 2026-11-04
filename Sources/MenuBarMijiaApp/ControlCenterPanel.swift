import SwiftUI
import AppKit
import Carbon
import MijiaCore

public struct ControlCenterPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PanelPrefs.climatePanelKey) var climatePanelModule: Bool = true
    @AppStorage(DeviceLayoutPrefs.storageKey) var tileSizesRaw: String = "{}"
    @AppStorage(DeviceLayoutPrefs.orderKey) var orderRaw: String = "[]"
    @State var isEditingLayout = false
    @State var draggingId: String?
    @State var activeResize: ActiveTileResize?
    // In-memory mirrors of the saved order/sizes: @AppStorage publishes changes outside the
    // current animation transaction, so moves made through it alone snap instead of sliding.
    @State var liveOrder: [String]?
    @State var liveSizes: [String: TileSize]?
    @State var tileFrames: [String: CGRect] = [:]
    @State var dragLocation: CGPoint?
    @State var grabOffset: CGSize = .zero
    @State var lastSwapTarget: String?
    @State var lastSwapAt: Date = .distantPast
    @State var pressTask: Task<Void, Never>?
    @State var pressCancelled = false
    @State var pendingScrollToDeviceId: String?
    @AppStorage(GroupPrefs.groupsKey) var groupsRaw: String = "[]"
    @AppStorage(GroupPrefs.mapKey) var groupMapRaw: String = "{}"
    @AppStorage(GroupPrefs.collapsedKey) var collapsedRaw: String = "[]"
    @State var liveGroupMap: [String: String]?
    @State var hoveredHeader: String?
    @AppStorage(GroupPrefs.aliasesKey) var aliasesRaw: String = "{}"
    // #146: room aliases and order, separate from device prefs so a room rename never touches devices.
    @AppStorage(RoomPrefs.aliasesKey) var roomAliasesRaw: String = "{}"
    @AppStorage(RoomPrefs.orderKey) var roomOrderRaw: String = "[]"
    @State var isEditingRooms = false
    @State var draggingRoomId: String?
    @State var roomDragLocation: CGPoint?
    @State var roomGrabOffset: CGFloat = 0
    @State var roomFrames: [String: CGRect] = [:]
    @State var lastRoomSwapAt: Date = .distantPast
    @State var lastRoomSwapTarget: String?
    @State var roomPressTask: Task<Void, Never>?
    @State var roomPressCancelled = false
    @State var layoutUI = LayoutUIState.shared
    /// #60: type-to-search. The query lives outside `@State` because the app-wide key monitor
    /// (`PanelSearchKeyboard`) has to read and write it before AppKit dispatches the event.
    @State var search = PanelSearchState.shared
    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.effectiveReduceMotion) var reduceMotion
    @Environment(\.effectiveReduceTransparency) var reduceTransparency
    /// Opens the ⌘, Settings window; the popover no longer hosts the long form (#42).
    @Environment(\.openSettings) var openSettings
    /// Drives the open animation; reset whenever the menu-bar window closes so every open replays it.
    @State var isPresented = false
    /// Re-centers the active room pill when the user taps an already-selected pill after scrolling.
    @State var roomScrollTrigger = 0
    @State var kindScrollTrigger = 0

    /// Card sizes are remembered per page: a room id, or "all" for the overview.
    var layoutScope: String { store.selectedRoomId ?? "all" }
    @AppStorage(PanelHeight.storageKey) private var panelHeightRaw: String = PanelHeight.standard.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @Namespace private var roomPillNamespace
    public let store: HomeStore

    private static let panelWidth: CGFloat = 376
    private var panelHeight: CGFloat { (PanelHeight(rawValue: panelHeightRaw) ?? .standard).points }
    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .system }
    /// The panel sets `panelRoot` on its own body, so it cannot read that environment back;
    /// resolve the effective scheme locally (#51).
    var effectiveScheme: ColorScheme { appearance.colorScheme ?? colorScheme }

    public init(store: HomeStore) {
        self.store = store
    }
    public var body: some View {
        let _ = (store.effectiveLanguage, store.selectedRoomId, store.rooms.count)
        ZStack(alignment: .bottom) {
            if store.showsFullOnboardingGuide {
                OnboardingGuideView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                mainDashboard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            overlayNotifications

            groupPromptOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.isShowingMiReauth, store.homeBackend == .xiaomiCloud {
                miReauthOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        // Keep the in-memory mirrors in step with edits made elsewhere (card context menus).
        .onChange(of: groupMapRaw) { _, raw in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { liveGroupMap = GroupPrefs.map(raw) }
        }
        .onChange(of: tileSizesRaw) { _, raw in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { liveSizes = DeviceLayoutPrefs.decode(raw) }
        }
        .onChange(of: store.favoriteOrder) { _, favOrder in
            guard !favOrder.isEmpty else { return }
            var order = currentOrder
            guard !order.isEmpty else { return }
            let favSet = Set(favOrder)
            var favIdx = 0
            for i in order.indices where favSet.contains(order[i]) {
                if favIdx < favOrder.count {
                    order[i] = favOrder[favIdx]
                    favIdx += 1
                }
            }
            if order != currentOrder {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { liveOrder = order }
                orderRaw = DeviceLayoutPrefs.encodeOrder(order)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: layoutUI.newGroupForDevice)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: layoutUI.renamingGroupId)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: layoutUI.renamingDeviceId)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: layoutUI.renamingRoomId)
        // #41: the context menu's "Edit Layout" replaces the 0.6 s long-press for keyboard/VoiceOver users.
        .onChange(of: layoutUI.isEditingLayoutRequested) { _, requested in
            guard requested else { return }
            layoutUI.isEditingLayoutRequested = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                store.expandedDeviceId = nil
                isEditingRooms = false
                isEditingLayout = true
            }
        }
        // Room preferences survive a room disappearing; only the open prompt cannot.
        .onChange(of: store.rooms.map(\.id)) { _, ids in
            if let rid = layoutUI.renamingRoomId, !ids.contains(rid) {
                layoutUI.renamingRoomId = nil
            }
        }
        .frame(width: Self.panelWidth, height: panelHeight)
        .onChange(of: panelHeightRaw) { _, _ in syncMenuBarWindowSize() }
        .onChange(of: store.lastAssistantActionAt) { _, date in
            UndoAvailabilityTracker.shared.syncAction(at: date)
        }
        .onChange(of: store.assistantState) { _, state in
            switch state {
            case .done:
                SoundFeedback.playSuccess()
            case .failed:
                SoundFeedback.playFailure()
            default:
                break
            }
        }
        // #45: the only place that sees every error toast is the panel root.
        .onChange(of: store.toastNotice?.id) { _, _ in
            AppDiagnosticsLog.shared.record(store.toastNotice)
            // #54: failures get an audible cue when the user opted into feedback sounds.
            if store.toastNotice?.isError == true {
                SoundFeedback.playFailure()
            }
        }
        // Frequently opened utility: show immediately, including keyboard invocation.
        .onReceive(NotificationCenter.default.publisher(for: MenuBarPanelController.didShowNotification)) { _ in
            UndoAvailabilityTracker.shared.syncAction(at: store.lastAssistantActionAt)
            isPresented = true
        }
        .onAppear {
            UndoAvailabilityTracker.shared.syncAction(at: store.lastAssistantActionAt)
            SettingsWindowOpener.shared.open = { openSettings() }
            syncMenuBarWindowSize()
            isPresented = true
        }
        // The panel tree survives a close, so a half-typed query would come back on the next open.
        .onReceive(NotificationCenter.default.publisher(for: MenuBarPanelController.didHideNotification)) { _ in
            isPresented = false
            search.end()
            isSearchFieldFocused = false
        }
        // Leaving search puts the caret back on the panel, so Esc closes it instead of resigning the field.
        .onChange(of: search.isSearching) { _, searching in
            if searching {
                // The query bar replaces the room strip; reordering underneath it would be invisible.
                isEditingRooms = false
                draggingRoomId = nil
                roomDragLocation = nil
            } else {
                isSearchFieldFocused = false
            }
        }
        // #180: typing a query — through the key monitor or the field — ticks the guide's search step.
        .onChange(of: search.query) { _, query in
            if !query.isEmpty { store.recordOnboardingMilestone(.searchedDevice) }
        }
        // Mi cloud polls every 6 s only while the panel is on screen (#26).
        .onChange(of: isPresented) { _, visible in store.setPanelVisible(visible) }
        .onDisappear { store.setPanelVisible(false) }
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .environment(\.isEditingLayout, isEditingLayout)
        .panelRoot()
        .task {
            await store.checkForUpdatesIfNeeded()
        }
    }

    private func syncMenuBarWindowSize() {
        MenuBarPanelController.shared.updatePanelSize(width: Self.panelWidth, height: panelHeight)
    }

    // MARK: - Main Dashboard

    private var mainDashboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            topHeroHeader
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // #180 review: after connecting, the lessons stay above the dashboard so search and
            // All Off/Undo can be tried while these instructions are still on screen.
            if store.showsOnboardingChecklist {
                OnboardingChecklistCard(
                    store: store,
                    onBeginSearch: { withAnimation(AppleMotion.snappySpring) { search.begin() } }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(AppleMotion.drawerTransition)
            }

            if store.miSessionShowsExpired || store.miSessionExpiringSoonDate != nil {
                miSessionExpiryBanner
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(AppleMotion.drawerTransition)
            }

            if store.isShowingAssistantBar {
                AssistantCommandBar(store: store)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(AppleMotion.drawerTransition)
            }

            if let suggestion = store.pendingHAAddressSuggestion {
                haAddressSuggestionBanner(suggestion)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(AppleMotion.drawerTransition)
            }

            if store.showQuickActionsBar {
                quickActionsAndScenesBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(AppleMotion.drawerTransition)
            }

            // #60: while a search is open the query bar replaces the room pills, so the empty-query
            // layout is untouched and results are not silently narrowed by the selected room.
            if search.isSearching {
                searchBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(AppleMotion.drawerTransition)
            } else {
                listFilterBars
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()
                .overlay(Color.primary.opacity(0.07))

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    let sections = pageSections
                    let quickIndexMap = Dictionary(
                        uniqueKeysWithValues: sections.flatMap(\.devices).prefix(9).enumerated().map { ($1.id, $0 + 1) }
                    )

                    VStack(alignment: .leading, spacing: 11) {
                        if search.isSearching {
                            searchResultsList(results: searchResults)
                        } else if store.visibleDevices.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(sections) { section in
                                if section.title != nil {
                                    groupHeader(section)
                                }
                                if !collapsedGroups.contains(collapseKey(section)) {
                                    deviceCollectionView(
                                        devices: section.devices,
                                        showRoomBadge: store.selectedRoomId == nil,
                                        quickIndexMap: quickIndexMap
                                    )
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .offset(y: -8)),
                                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                                    ))
                                }
                            }
                        }
                    }
                    .coordinateSpace(name: TileSpace.name)
                    // Cards stop hit-testing in edit mode; the container must still catch the press.
                    .contentShape(Rectangle())
                    .simultaneousGesture(tileDragGesture)
                    .onPreferenceChange(TileFramesKey.self) { frames in
                        if frames != tileFrames { tileFrames = frames }
                    }
                    .padding(.horizontal, 13)
                    .padding(.top, 10)
                    .padding(.bottom, store.undoBanner != nil || store.toastNotice != nil ? 48 : 12)
                }
                .onChange(of: pendingScrollToDeviceId) { _, targetId in
                    guard let targetId else { return }
                    pendingScrollToDeviceId = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        withAnimation(AppleMotion.snappySpring) {
                            scrollProxy.scrollTo(targetId, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            footerBar
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .animation(AppleMotion.snappySpring, value: store.isShowingAssistantBar)
    }

    // MARK: - Search (#60)

    /// Ranked results for the current query. While the bar is open but still empty, every searchable
    /// device is listed in the panel's own order, so opening search never reshuffles the page.
    private var searchResults: [SmartDevice] {
        search.results(store: store)
    }

    private var searchBar: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous)
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(
                L10n.tr("搜索设备、房间或拼音首字母（sfd → 书房灯）", "Search devices, rooms or pinyin initials (sfd → 书房灯)"),
                text: Binding(
                    get: { search.query },
                    set: { search.query = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))
            .focused($isSearchFieldFocused)
            .onSubmit { submitSearch() }
            .onChange(of: isSearchFieldFocused) { _, focused in search.isFieldFocused = focused }

            if !search.query.isEmpty {
                Button {
                    withAnimation(AppleMotion.snappySpring) { search.query = "" }
                    search.focusRequest &+= 1
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("清空搜索", "Clear search")))
            }

            Text(searchCountLabel)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(shape.fill(Color.primary.opacity(0.06)))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(isSearchFieldFocused ? 0.55 : 0.16), lineWidth: DesignTokens.hairline))
        .onChange(of: search.focusRequest) { _, _ in
            Task { @MainActor in isSearchFieldFocused = true }
        }
        .onAppear {
            if search.focusRequest > 0 { Task { @MainActor in isSearchFieldFocused = true } }
        }
        .accessibilityElement(children: .contain)
        .panelHelp(L10n.tr(
            "打字即可过滤；⌘F 聚焦搜索框，↑↓ 选择，回车开关，→ 展开详情，Esc 清空后再按 Esc 关闭面板",
            "Type to filter; ⌘F focuses the field, ↑↓ selects, Return toggles, → expands, Esc clears, then closes"
        ))
    }

    private var searchCountLabel: String {
        let count = searchResults.count
        return count == 1 ? L10n.tr("1 台", "1 device") : L10n.tr("\(count) 台", "\(count) devices")
    }

    /// Return inside the field: same rules as the global key monitor (toggle, or run an instruction).
    private func submitSearch() {
        let results = searchResults
        if search.isExplicitSelection, let device = search.selected(in: results) {
            toggleSearchResult(device)
            return
        }
        if PanelSearch.kind(of: search.query, devices: store.devices, scenes: store.scenes) == .command {
            PanelSearchKeyboard.runCommand(search.query, store: store, state: search)
            return
        }
        guard let device = search.selected(in: results) else { return }
        toggleSearchResult(device)
    }

    private func toggleSearchResult(_ device: SmartDevice) {
        withAnimation(AppleMotion.snappySpring) { _ = store.togglePrimary(device) }
        if device.isOnline { SoundFeedback.playSuccess() }
    }

    @ViewBuilder
    private func searchResultsList(results: [SmartDevice]) -> some View {
        if results.isEmpty {
            VStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DesignTokens.TypeSize.reading))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("没有匹配的设备", "No matching devices"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                if PanelSearch.kind(of: search.query, devices: store.devices, scenes: store.scenes) == .command {
                    Text(L10n.tr("回车把这句交给助手执行", "Press Return to run this as a command"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                } else {
                    Text(search.query.isEmpty
                        ? L10n.tr("输入设备名、房间或拼音首字母", "Type a device, room or pinyin initials")
                        : L10n.tr("试试房间名「书房」或首字母「sfd」", "Try a room (书房) or initials (sfd)"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            let quickIndexMap = Dictionary(
                uniqueKeysWithValues: results.prefix(9).enumerated().map { ($1.id, $0 + 1) }
            )
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.tr("搜索结果", "Results"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 3)

                // The highlight is the keyboard selection, drawn as the card's own focus ring would be.
                deviceCollectionView(
                    devices: results,
                    showRoomBadge: true,
                    quickIndexMap: quickIndexMap,
                    highlightId: search.selected(in: results)?.id,
                    sortByUserOrder: false
                )
            }
        }
    }

}

// MARK: - Search State (#60)

/// The panel's search, shared between the SwiftUI tree and the app-wide key monitor.
///
/// The panel keeps arrow keys, Return, Esc, Space and the 1–9 shortcuts in
/// `HotkeyAndNotificationManager`'s local key monitor, which runs before any SwiftUI view can see
/// the event. So the query cannot live in `@State` alone: it has to be readable (and writable) from
/// that monitor, while the field itself stays a normal `TextField` so IME, paste and selection work.
@MainActor
@Observable
final class PanelSearchState {
    static let shared = PanelSearchState()

    /// What the user typed. Empty means "no query" but says nothing about whether the bar is open.
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            // A new query restarts the highlight at the best match.
            selectionId = nil
            isExplicitSelection = false
        }
    }
    /// The bar is on screen: ⌘F opens it without a query.
    var isActive = false
    /// Bumped to move the caret into the field; the panel focuses on every change.
    var focusRequest = 0
    /// The search field itself is first responder, so AppKit inserts text instead of the monitor.
    var isFieldFocused = false
    /// Highlighted result, or `nil` for "the best match".
    private(set) var selectionId: String?
    /// The user moved the highlight, so Return acts on it even when the text reads like a command.
    private(set) var isExplicitSelection = false

    var isSearching: Bool { isActive || !query.isEmpty }

    func begin() {
        isActive = true
        focusRequest &+= 1
    }

    /// Esc step one: drop the query and leave search mode. The next Esc closes the panel.
    func clear() {
        end()
    }

    func end() {
        query = ""
        selectionId = nil
        isExplicitSelection = false
        isActive = false
        isFieldFocused = false
    }

    /// Devices in the order the panel draws them, so ties keep the on-screen order.
    func devices(store: HomeStore) -> [SmartDevice] {
        let order = DeviceLayoutPrefs.decodeOrder(
            UserDefaults.standard.string(forKey: DeviceLayoutPrefs.orderKey) ?? "[]"
        )
        return DeviceLayoutPrefs.apply(order: order, to: store.devices)
    }

    /// Search results for the current query: hidden and (optionally) offline devices are excluded,
    /// the room filter is not applied, and ranked matches come first.
    func results(store: HomeStore) -> [SmartDevice] {
        let aliases = GroupPrefs.map(UserDefaults.standard.string(forKey: GroupPrefs.aliasesKey) ?? "{}")
        return PanelSearch.results(
            query,
            devices: devices(store: store),
            hiddenIds: store.hiddenDeviceIds,
            hideOffline: store.hideOfflineDevices,
            aliases: aliases
        )
    }

    /// The highlighted device: the user's pick while it is still visible, else the best match.
    func selected(in results: [SmartDevice]) -> SmartDevice? {
        if let selectionId, let picked = results.first(where: { $0.id == selectionId }) { return picked }
        return results.first
    }

    /// ↑/↓ through the results, wrapping at both ends.
    func moveSelection(_ delta: Int, in results: [SmartDevice]) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectionId } ?? (delta > 0 ? -1 : 0)
        var next = current + delta
        if next < 0 { next = results.count - 1 }
        if next >= results.count { next = 0 }
        selectionId = results[next].id
        isExplicitSelection = true
    }
}

/// Routes key presses into the panel's search before the panel's own shortcuts run (#60).
///
/// Returns `true` when the key belonged to the search and must not reach the existing keyboard
/// ladder (device focus, quick-index digits, "/" for the assistant, "v" for dictation). With no
/// search open and nothing typed, every key returns `false`, so the panel behaves exactly as before.
@MainActor
enum PanelSearchKeyboard {
    /// Narrows an `NSEvent` down to the keys the search cares about.
    static func key(for event: NSEvent) -> PanelSearchKey? {
        let flags = event.modifierFlags
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let option = flags.contains(.option)

        let kind: PanelSearchKey.Kind
        switch Int(event.keyCode) {
        case kVK_UpArrow: kind = .up
        case kVK_DownArrow: kind = .down
        case kVK_LeftArrow: kind = .left
        case kVK_RightArrow: kind = .right
        case kVK_Return, kVK_ANSI_KeypadEnter: kind = .return
        case kVK_Escape: kind = .escape
        case kVK_Tab: kind = .tab
        case kVK_Delete: kind = .delete
        default:
            // Only unmodified (or shift-modified) printing keys count as typing.
            guard !control, !option else { return nil }
            guard let characters = event.characters, !characters.isEmpty else { return nil }
            guard characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            kind = .character(characters)
        }
        return PanelSearchKey(kind: kind, hasCommand: command, hasControl: control, hasOption: option)
    }

    /// A text field other than the search field (assistant bar, layout rename) owns the keyboard.
    private static var isOtherFieldFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    /// Handles the event and reports whether it was consumed.
    @discardableResult
    static func handle(_ event: NSEvent, store: HomeStore, state: PanelSearchState = .shared) -> Bool {
        // The Settings window and every other window keep their own typing.
        guard MenuBarPanelController.shared.isPanelWindow(NSApp.keyWindow) else { return false }
        guard let key = key(for: event) else { return false }

        // A text field that is not the search field (assistant bar, layout rename) owns the keyboard.
        if isOtherFieldFocused, !state.isFieldFocused { return false }

        let results = state.isSearching ? state.results(store: store) : []
        let context = PanelSearchContext(
            query: state.query,
            isSearching: state.isSearching,
            isFieldFocused: state.isFieldFocused,
            hasSelection: state.selected(in: results) != nil,
            hasExplicitSelection: state.isExplicitSelection,
            queryKind: state.isSearching
                ? PanelSearch.kind(of: state.query, devices: store.devices, scenes: store.scenes)
                : .filter
        )

        switch PanelSearch.action(for: key, context: context) {
        case .ignore:
            return false

        case .appendQuery(let text):
            state.query += text
            state.begin()
            return true

        case .deleteBackward:
            if !state.query.isEmpty { state.query.removeLast() }
            state.begin()
            return true

        case .clearQuery:
            state.clear()
            // Hand the keyboard back so the next Esc reaches the panel's own ladder (which closes it)
            // instead of the text-field guard that only resigns first responder.
            if isOtherFieldFocused { NSApp.keyWindow?.makeFirstResponder(nil) }
            return true

        case .focusField:
            state.begin()
            return true

        case .moveSelection(let delta):
            state.moveSelection(delta, in: results)
            return true

        case .toggleSelection:
            guard let device = state.selected(in: results) else { return false }
            withAnimation(AppleMotion.snappySpring) { _ = store.togglePrimary(device) }
            if device.isOnline { SoundFeedback.playSuccess() }
            return true

        case .expandSelection:
            guard let device = state.selected(in: results) else { return false }
            withAnimation(AppleMotion.snappySpring) { store.toggleExpanded(device.id) }
            return true

        case .runCommand:
            runCommand(state.query, store: store, state: state)
            return true
        }
    }

    /// Return on an instruction: the pre-typed query goes through the same path as the assistant bar,
    /// so local parsing, demo mode, API keys and cloud consent all behave as before.
    static func runCommand(_ text: String, store: HomeStore, state: PanelSearchState = .shared) {
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }
        state.end()
        store.presentAssistantBar()
        Task { @MainActor in
            await store.runAssistantCommand(utterance)
        }
    }
}

/// iOS-style jiggle for room pills in edit mode (#146), phase-shifted per room so neighbours do
/// not swing in sync. Reduce Motion keeps the strip still.
struct RoomPillJiggle: ViewModifier {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let active: Bool
    let phase: Double

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                content.rotationEffect(.degrees(sin(t * 2 * .pi * 3.2 + phase) * 0.9))
            }
        } else {
            content
        }
    }
}
