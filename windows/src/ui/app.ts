import { HomeAssistantClient, homeAssistantIdentity, homeAssistantCommand, parseCachedHAHome } from "../core/homeAssistant.js";
import type { SynthesizedHome } from "../core/models.js";
import { GrokBallView } from "./grokBall.js";
import {
  ASSISTANT_PROVIDER_PRESETS,
  IntentReply,
  IntentValidator,
  ModelIntentResolver,
  UserHabitMemory,
  buildAssistantContext,
  resolveHabitSharing,
  shareHabitSentence,
  habitActionable,
  inferAssistantPreset,
  assistantEndpointIdentity,
  endpointAllowsSendingSecrets,
  isLocalAssistantEndpoint,
  timeBucketLabel,
  partitionHabitReceipt,
  resolveGrokBallEmotion,
  type HabitEntry,
  type HabitLastAction,
  type HabitRecordingReceipt,
  type HabitSequenceEntry,
} from "../core/assistant.js";
import {
  type HttpRequest,
  type HttpResponse,
  type HttpTransport,
  MI_CLOUD_REGIONS,
  MiAccountLogin,
  MiCloudClient,
  MiCloudError,
  type MiDeviceRecord,
  type MiRoom,
  MiotCommandMapper,
  propKeyString,
  type MiotDeviceSpec,
  type MiotPropKey,
  MiotSpecResolver,
  MiotSynthesizer,
  type MiSession,
  type QRLoginTicket,
  maskedMiUserId,
  miCloudRegionLabel,
  normalizeMiCloudRegion,
} from "../core/miCloudClient.js";
import {
  type GitHubRelease,
  type UpdateState,
} from "../core/updateChecker.js";
import {
  CredentialVault,
  sessionWithoutPassToken,
} from "../core/secureStore.js";
import {
  type CameraStreamQuality,
  CAMERA_STREAM_QUALITIES,
  DEFAULT_CAMERA_STREAM_QUALITY,
  normalizeCameraStreamQuality,
  normalizeCameraStreamQualityMap,
} from "../core/cameraQuality.js";
import {
  type AssistantSuggestion,
  type DeviceCommand,
  type DeviceIntent,
  type EnvironmentReading,
  type HomeScene,
  type IntentPlan,
  type ScheduledCommand,
  type SmartDevice,
  allOffTargets,
  deviceEnvironmentReading,
  readMiotPower,
  environmentReadingPriority,
  isDeviceActiveOn,
  joinsAllOff,
  joinsAllOffByDefault,
  localizeNightShot,
  localizeAirQuality,
  localizeFanPreset,
  localizeFridgeMode,
} from "../core/models.js";
import {
  type AppAppearance,
  type AppSkin,
  type LayoutPrefs,
  type PanelAnchor,
  type PanelHeight,
  type PanelPlacement,
  type TileSize,
  APPEARANCES,
  DEFAULT_GLOBAL_SHORTCUT,
  PANEL_ANCHORS,
  PANEL_HEIGHTS,
  SKINS,
  TILE_SIZES,
  applyOrder,
  targetSize,
  releaseVelocity,
  projectedOffset,
  chosenSize,
  comfort,
  emptyLayoutPrefs,
  homeOptions,
  localizeEffect,
  localizeFanMode,
  moveInOrder,
  nextSize,
  pageSections,
  parsePanelPlacement,
  resolveAppearance,
  resolvedSize,
  scopedKey,
  spans,
  withAliases,
  type HomeOption,
} from "./panelPrefs.js";
import {
  type AppLanguage,
  type LanguagePreference,
  speechLocale,
  t,
} from "../core/i18n.js";
import {
  type TemperatureUnitPreference,
  displayStep,
  formatTemperatureValue,
  getTemperatureUnit,
  stepCelsius,
  temperatureSymbol,
  toCelsius,
} from "../core/temperature.js";
import {
  KIND_CHIP,
  filterByListCut,
  foldGroupedLights,
  kindChips,
  memberGroupOwners,
  showsKindRow,
  type DeviceKindTag,
  type DeviceListCut,
} from "./listCut.js";

import { SpeechRecognitionInstance, type ConnectionMode, type LearnedShortcut, type LoadedSettings, type PersistedSettings, type ReplyBannerState, type UndoAction, type UndoStep } from "./appTypes.js";
import { CAMERA_QUALITY_TITLES, CACHED_DEVICES_VERSION, LEGACY_STORAGE_KEY, SF_ICONS, STORAGE_KEY } from "./appConstants.js";
import { demoDevices, demoScenes } from "./demo.js";
import { createTransport, invokeTauriVoid } from "./transport.js";
import { loadSettings, upgradeCachedDevices } from "./settings.js";
import { CameraLiveController } from "./cameraLive.js";
import { renderDeviceTile as renderDeviceTileView, renderEnvironmentStrip as renderEnvironmentStripView } from "./deviceViews.js";
import { renderSettingsModal } from "./settingsViews.js";
import { bindEvents as bindEventsImpl } from "./bindEvents.js";
import { renderPanel } from "./panelView.js";
import { applyGlobalHotkey, applyInterfaceLanguage, applyTemperatureSetting, bindGlobalKeys, checkForAppUpdate, hydrateCredentials, initializeCredentials, openSettingsSheet, openUpdatePage, osLanguages, persistCredentials, restoreUpdateState, saveSettings, saveUpdateState, startTimerLoop, startUpdateInstall, submitServiceEndpoints } from "./appLifecycle.js";
import { handleNaturalCommand, learnShortcut } from "./naturalCommand.js";
import { buildInverseCommand, executeIntents, executeSingleCommand, habitSequences, lastHabitAction, readBackMatches, recordHabits, saveHabitMemory, unrecordHabits } from "./intentExecution.js";
import { bindLayoutGestures } from "./layoutGestures.js";
import { bindSettingsEvents } from "./settingsEvents.js";
import { hasMatchingDomShape, inputKeepsDraft, morphMatchingDom, parseSingleElement, waitForCameraFrameGap } from "./dom.js";
export { waitForCameraFrameGap } from "./dom.js";
function withReadPower(command: DeviceCommand, isOn: boolean): DeviceCommand {
  switch (command.kind) {
    case "setLightPower":
    case "setClimatePower":
    case "setFanPower":
    case "setSwitch":
      return { ...command, isOn };
    default:
      return command;
  }
}

export class MenuMijiaWindowsApp {
  public readonly loadedSettings: LoadedSettings = loadSettings();
  public settings: PersistedSettings = this.loadedSettings.settings;
  public readonly credentialVault = new CredentialVault();
  public lastSubmittedEndpoints: string | null = null;
  // Assigned in the constructor, after the interface language is resolved: the demo home is
  // generated per language (#52), so a field initializer would freeze the module default.
  public devices: SmartDevice[];
  public scenes: HomeScene[];
  public environmentReadings: EnvironmentReading[] = [];
  public listCut: DeviceListCut = { kind: "all" };

  public get selectedRoom(): string {
    return this.listCut.kind === "room" ? this.listCut.roomName : "全部";
  }

  public set selectedRoom(room: string) {
    this.listCut = !room || room === "全部"
      ? { kind: "all" }
      : { kind: "room", roomName: room };
  }

  public selectDeviceKind(tag: DeviceKindTag): void {
    this.listCut = { kind: "deviceKind", tag };
  }

  public kindTagFromDataset(value: string | undefined): DeviceKindTag | null {
    switch (value) {
      case "climate":
      case "light":
      case "plug":
      case "fan":
      case "vacuum":
      case "fridge":
      case "camera":
      case "sensor":
        return value;
      default:
        return null;
    }
  }

  public expandedDeviceId: string | null = null;
  public isShowingAssistantBar = true;
  public activeSheet: "none" | "onboarding" | "settings" = "none";
  private onboardingStep = 0;
  public replyBanner: ReplyBannerState | null = null;
  public haConnectionError: string | null = null;
  public waitingDeviceIds = new Set<string>();
  /** A Xiaomi refresh failed after devices were already on screen. */
  public cloudValuesStale = false;
  /** Member did → owning light-group did from the latest Xiaomi Cloud refresh (#214). */
  public groupOwnerByMemberDid = new Map<string, string>();
  /** A command waiting for the user to allow sending it to a cloud AI service (#20). */
  public pendingCloudConsent: { utterance: string; endpoint: string } | null = null;
  /** AI guesses that wait for a tap instead of running by themselves (#21). */
  public pendingSuggestions: AssistantSuggestion[] = [];
  /** AI-ranked proactive suggestions for the current ambient signature (#113). */
  public aiProactiveSuggestions: AssistantSuggestion[] | null = null;
  public aiProactiveSignature: string | null = null;
  private isRefreshingProactive = false;
  public isGrokBallStageExpanded = false;
  private readonly grokBall = new GrokBallView();
  public grokBallCelebrationUntil = 0;
  private grokBallPointerUntil = 0;
  public grokBallOnLeft = false;
  private panelGeometryUpdates: Promise<void> = Promise.resolve();
  /** Panel anchor the backend persists (#204); the window position itself is owned by Rust. */
  public panelAnchor: PanelAnchor = "auto";
  /** Earliest timestamp a failed background refresh may retry (Codex #116 review). */
  private proactiveRetryAfterMs: number | null = null;
  /** Cooldown before a failed background refresh retries (Codex #116 review). */
  private static readonly PROACTIVE_RETRY_COOLDOWN_MS = 5 * 60_000;
  public isResolvingIntent = false;
  public isSyncingCloud = false;
  private syncGeneration = 0;
  public lastCloudRefreshAt: number | null = null;
  public localControlRevision = 0;
  public sourceRevision = 0;
  /** A silent cloud result that is waiting for the user to finish interacting. */
  public pendingCloudRender = false;
  public endpointSubmission: Promise<unknown> = Promise.resolve();
  public pointerIsDown = false;
  public isListeningVoice = false;
  public scheduledCommands: ScheduledCommand[] = [];
  /** Timers that came due while the PC slept; they only run when the user taps 立即执行 (#22). */
  public missedScheduledCommands: ScheduledCommand[] = [];
  public lastUndoAction: UndoAction | null = null;
  public qrTicket: QRLoginTicket | null = null;
  public qrStatusText = t("点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。");
  public isPollingQR = false;
  /** Latest GitHub release found by the daily check (#39); shown in settings and the tray menu. */
  public availableUpdate: GitHubRelease | null = null;
  public updateState: UpdateState = { lastCheckedAtMs: null, release: null };
  public isCheckingUpdate = false;
  public isInstallingUpdate = false;
  public updateStatusMessage: { text: string; isError: boolean } | null = null;
  public readonly transport: HttpTransport = createTransport();
  public readonly specResolver: MiotSpecResolver;
  public readonly cameraLive: CameraLiveController;

  get cameraKeepAliveMs(): number { return this.cameraLive.cameraKeepAliveMs; }
  set cameraKeepAliveMs(ms: number) { this.cameraLive.cameraKeepAliveMs = ms; }
  private speechRecognition: SpeechRecognitionInstance | null = null;

  // Personalisation / layout editing state (see panelPrefs.ts).
  public homes: HomeOption[] = [];
  public isHomeMenuOpen = false;
  public isEditingLayout = false;
  public draggingId: string | null = null;
  public dragPointer: { x: number; y: number; grabX: number; grabY: number } | null = null;
  public lastSwap: { slot: string; at: number } | null = null;
  public ctxMenu: { x: number; y: number; deviceId?: string; groupId?: string } | null = null;
  private prompt: { kind: "newGroup"; deviceId: string } | { kind: "renameGroup"; groupId: string } | { kind: "renameDevice"; deviceId: string } | null = null;
  public animateEntrance = false;
  public poppedDeviceId: string | null = null;
  public dimPreview: { id: string; percent: number } | null = null;
  public suppressNextClick = false;
  public isRecordingHotkey = false;
  public hotkeyNeedsHint = false;
  public hotkeyRegistrationError: string | null = null;

  constructor(public readonly root: HTMLElement) {
    this.specResolver = new MiotSpecResolver(
      this.transport,
      undefined,
      this.settings.cachedModelTypes,
    );
    this.cameraLive = new CameraLiveController(this);

    this.applyInterfaceLanguage();
    this.applyTemperatureSetting();
    const haCache = this.settings.cachedHAHome?.identity === homeAssistantIdentity(this.settings.haBaseURL, this.settings.haToken) ? this.settings.cachedHAHome.home : null;
    this.devices = this.settings.connectionMode === "xiaomiCloud"
      ? structuredClone(this.settings.cachedXiaomiDevices)
      : this.settings.connectionMode === "homeAssistant" ? structuredClone(haCache?.devices ?? []) : demoDevices();
    this.scenes = this.settings.connectionMode === "homeAssistant" ? structuredClone(haCache?.scenes ?? []) : this.settings.connectionMode === "demo" ? demoScenes() : [];
    this.environmentReadings = this.settings.connectionMode === "homeAssistant" ? structuredClone(haCache?.environmentReadings ?? []) : [];
    this.initializeCredentials();
    this.submitServiceEndpoints();

    if (!this.settings.hasCompletedOnboarding && !this.settings.miSession) {
      this.activeSheet = "onboarding";
    }

    this.bindGlobalKeys();
    window.addEventListener("pointermove", (event) => {
      const rect = this.grokBall.element.getBoundingClientRect();
      this.grokBallPointerUntil = Date.now() + 1500;
      this.grokBall.setGaze((event.clientX - rect.left - rect.width / 2) / 160,
        (event.clientY - rect.top - rect.height / 2) / 160);
      this.syncGrokBallEmotion();
    });
    this.bindLayoutGestures();
    this.bindPanelDrag();
    this.bindOpenAnimation();
    window.addEventListener("menumijia:open-update", () => {
      this.openSettingsSheet();
    });
    this.applyPanelHeight();
    this.syncPanelPlacement();
    void this.applyGlobalHotkey();
    this.startTimerLoop();
    this.restoreUpdateState();
    this.render();

    if (this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession) {
      void this.refreshDevices();
    }
    // At most one GitHub request per local day, and only inside the packaged app (#39).
    void this.checkForAppUpdate(false);
  }

  private initializeCredentials(): void {
    initializeCredentials(this);
  }

  private async hydrateCredentials(): Promise<void> {
    return hydrateCredentials(this);
  }

  private async persistCredentials(): Promise<void> {
    return persistCredentials(this);
  }

  public saveSettings(forceSubmitEndpoints = false): void {
    saveSettings(this, forceSubmitEndpoints);
  }

  private static osLanguages(): string[] {
    return osLanguages();
  }

  public applyInterfaceLanguage(): void {
    applyInterfaceLanguage(this);
  }

  public applyTemperatureSetting(): void {
    applyTemperatureSetting(this);
  }

  private submitServiceEndpoints(force = false): void {
    submitServiceEndpoints(this, force);
  }

  private restoreUpdateState(): void {
    restoreUpdateState(this);
  }

  private saveUpdateState(): void {
    saveUpdateState(this);
  }

  public async checkForAppUpdate(manual: boolean): Promise<void> {
    return checkForAppUpdate(this, manual);
  }

  public openSettingsSheet(): void {
    openSettingsSheet(this);
  }

  public openUpdatePage(): void {
    openUpdatePage(this);
  }

  public async startUpdateInstall(): Promise<void> {
    return startUpdateInstall(this);
  }

  public async applyGlobalHotkey(): Promise<void> {
    return applyGlobalHotkey(this);
  }

  private bindGlobalKeys(): void {
    bindGlobalKeys(this);
  }

  private startTimerLoop(): void {
    startTimerLoop(this);
  }

  /** The tray popover hides when it loses focus, so focus means it is on screen. */
  public isPanelVisible(): boolean {
    return document.visibilityState !== "hidden" && document.hasFocus();
  }

  /** Background refreshes must not rebuild the panel while the user is mid-action. */
  public hasBlockingPanelInteraction(): boolean {
    return (
      this.activeSheet !== "none" ||
      this.pointerIsDown ||
      this.isListeningVoice ||
      this.draggingId !== null ||
      this.isEditingLayout ||
      this.isHomeMenuOpen ||
      this.ctxMenu !== null ||
      this.prompt !== null
    );
  }

  /** Applies a background result only when it cannot clear focus or cancel a pointer gesture. */
  private queueBackgroundRender(): void {
    if (this.hasBlockingPanelInteraction()) {
      this.pendingCloudRender = true;
      return;
    }
    this.render();
  }

  public get rooms(): string[] {
    const unique = Array.from(new Set(this.devices.map((d) => d.roomName)));
    return ["全部", ...unique];
  }

  private get filteredDevices(): SmartDevice[] {
    return filterByListCut(this.devices, this.listCut, this.settings.hideOfflineDevices);
  }

  /** Cards on screen: the list cut, plus folding member lights into a visible group card (#214). */
  private get presentationDevices(): SmartDevice[] {
    return this.foldGrouped(this.filteredDevices);
  }

  private foldGrouped(devices: readonly SmartDevice[]): SmartDevice[] {
    return this.settings.hideGroupedLights
      ? foldGroupedLights(devices, this.groupOwnerByMemberDid)
      : [...devices];
  }

  private get activeDeviceCount(): number {
    return this.devices.filter((d) => isDeviceActiveOn(d)).length;
  }

  private get onlineDeviceCount(): number {
    return this.devices.filter((d) => d.isOnline).length;
  }

  private get totalPowerWatts(): number {
    let watts = 0;
    for (const d of this.devices) {
      if (d.kind.kind === "plug" && d.kind.powerWatts && d.kind.powerWatts > 0) {
        watts += d.kind.powerWatts;
      }
    }
    return watts;
  }

  public get computedEnvironmentReadings(): EnvironmentReading[] {
    if (this.environmentReadings.length > 0) {
      const priorityById = new Map(
        this.devices.map((d) => [d.id, environmentReadingPriority(d.kind)]),
      );
      return [...this.environmentReadings].sort(
        (a, b) => (priorityById.get(a.id) ?? 0) - (priorityById.get(b.id) ?? 0),
      );
    }
    const out: Array<{ reading: EnvironmentReading; priority: number; index: number }> = [];
    for (let i = 0; i < this.devices.length; i++) {
      const d = this.devices[i]!;
      const reading = deviceEnvironmentReading(d);
      if (reading) {
        out.push({
          reading,
          priority: environmentReadingPriority(d.kind),
          index: i,
        });
      }
    }
    out.sort((a, b) => a.priority - b.priority || a.index - b.index);
    return out.map((item) => item.reading);
  }

  /**
   * Rooms of homes shared with this account name devices the unfiltered list leaves out; look them
   * up by did (#134). Dids the lookup cannot resolve (IR remotes, removed devices) are skipped on
   * silent refreshes so polling does not spend a request on them every time.
   */
  private unresolvedRoomDids = new Set<string>();

  private async withSharedHomeDevices(
    client: MiCloudClient,
    listed: MiDeviceRecord[],
    rooms: MiRoom[],
    retryUnresolved: boolean,
  ): Promise<MiDeviceRecord[]> {
    if (retryUnresolved) this.unresolvedRoomDids.clear();
    const listedDids = new Set(listed.map((d) => d.did));
    const missing = [...new Set(rooms.flatMap((r) => r.dids))]
      .filter((did) => !listedDids.has(did) && !this.unresolvedRoomDids.has(did))
      .sort();
    if (missing.length === 0) return listed;
    try {
      const extra = (await client.devicesByDids(missing)).filter((d) => !listedDids.has(d.did));
      const found = new Set(extra.map((d) => d.did));
      for (const did of missing) if (!found.has(did)) this.unresolvedRoomDids.add(did);
      return [...listed, ...extra];
    } catch (err) {
      if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
      return listed;
    }
  }

  public async refreshDevices(silent = false): Promise<void> {
    if (this.settings.connectionMode === "homeAssistant") return this.refreshHADevices(silent);
    if (!this.settings.miSession || this.settings.connectionMode !== "xiaomiCloud" || this.isSyncingCloud) return;
    const session = this.settings.miSession;
    const previousPresentation = this.cloudPresentationFingerprint();
    const previousStructure = this.cloudPanelStructureFingerprint();
    const staleBefore = this.cloudValuesStale;
    const stateRevisionAtStart = this.localControlRevision;
    const syncGen = ++this.syncGeneration;
    let presentationChanged = false;
    this.isSyncingCloud = true;
    this.lastCloudRefreshAt = Date.now();
    if (!silent) {
      this.render();
    }

    try {
      const client = new MiCloudClient(session, this.transport);
      const [listedDevices, allRooms] = await Promise.all([
        client.deviceList(),
        client.homeRooms().catch(() => []),
      ]);
      const allDevices = await this.withSharedHomeDevices(client, listedDevices, allRooms, !silent);
      const nextHomes = homeOptions(allRooms);
      if (this.cloudSnapshotIsStale(session, stateRevisionAtStart)) return;
      this.homes = applyOrder(this.homes.map((home) => home.id), nextHomes);
      const { devices: rawDevices, rooms } = this.filterBySelectedHome(allDevices, allRooms);
      const groupDids = rawDevices.map((device) => device.did).filter((did) => did.startsWith("group."));
      const membershipByGroup = groupDids.length > 0
        ? client.lightGroupMembers(groupDids).catch(() => new Map<string, string[]>())
        : Promise.resolve(new Map<string, string[]>());

      // Stage 1: Instant synthesis with cached/fallback specs so user sees their real devices immediately
      const stage1Specs = this.specResolver.exportCachedSpecs();
      const stage1Home = MiotSynthesizer.synthesize(
        rawDevices,
        rooms,
        stage1Specs,
        new Map<string, unknown>(),
      );
      if (stage1Home.devices.length > 0 && this.devices.length === 0) {
        this.devices = stage1Home.devices;
        presentationChanged = true;
        this.render();
      }

      // Stage 2: Resolve exact MIoT specs + fetch live device properties
      const specs = await this.specResolver.resolveForDevices(rawDevices);
      const propKeys: MiotPropKey[] = [];
      for (const dev of rawDevices) {
        const spec = specs[dev.model];
        if (spec) {
          propKeys.push(...MiotSynthesizer.requiredProps(dev, spec));
        }
      }

      let values: Map<string, unknown>;
      try {
        values =
          propKeys.length > 0
            ? await client.getProps(propKeys)
            : new Map<string, unknown>();
      } catch (error) {
        // A failed property read must not rebuild every device from defaults.
        if (!this.cloudSnapshotIsStale(session, stateRevisionAtStart)) {
          this.markCloudValuesStale();
        }
        throw error;
      }

      const home = MiotSynthesizer.synthesize(rawDevices, rooms, specs, values);
      const membersByGroup = await membershipByGroup;
      // An old refresh must not clear or set freshness for the connection that replaced it.
      if (this.cloudSnapshotIsStale(session, stateRevisionAtStart)) return;
      this.markCloudValuesFresh();
      this.groupOwnerByMemberDid = memberGroupOwners(membersByGroup);
      // Cloud list order is not a layout preference. Keep known devices in their
      // displayed order, use fresh values, drop removed ids and append new ones.
      this.devices = applyOrder(this.devices.map((device) => device.id), home.devices);
      const readingPriorityById = new Map(
        home.devices.map((device) => [device.id, environmentReadingPriority(device.kind)]),
      );
      this.environmentReadings = applyOrder(
        this.environmentReadings.map((reading) => reading.id),
        home.environmentReadings,
      ).sort(
        (a, b) => (readingPriorityById.get(a.id) ?? 0) - (readingPriorityById.get(b.id) ?? 0),
      );
      presentationChanged =
        presentationChanged || this.cloudPresentationFingerprint() !== previousPresentation;

      this.settings.cachedXiaomiDevices = this.devices;
      const knownModelTypes = this.specResolver.exportKnownModelTypes(
        rawDevices.map((d) => d.model),
      );
      const cacheChanged =
        JSON.stringify(knownModelTypes) !== JSON.stringify(this.settings.cachedModelTypes);
      this.settings.cachedModelTypes = knownModelTypes;
      if (presentationChanged || cacheChanged) {
        this.saveSettings();
      }

      if (!silent) {
        this.replyBanner = {
          text:
            home.devices.length > 0
              ? t("已同步 {count} 台真实米家设备", { count: home.devices.length })
              : t("当前小米账号下暂未发现米家设备"),
          source: t("米家云直连"),
        };
      }
    } catch (err) {
      if (!this.cloudSnapshotIsStale(session, stateRevisionAtStart)) {
        this.markCloudValuesStale();
      }
      if (!silent) {
        const msg = err instanceof Error ? err.message : String(err);
        this.replyBanner = {
          text: t("米家云同步失败：{message}", { message: msg }),
          source: t("连接异常"),
          isError: true,
        };
      }
    } finally {
      if (this.syncGeneration === syncGen) {
        this.isSyncingCloud = false;
        const staleChanged = staleBefore !== this.cloudValuesStale;
        if (!silent || staleChanged) {
          this.render();
        } else if (presentationChanged) {
          if (
            this.cloudPanelStructureFingerprint() !== previousStructure ||
            !this.patchCloudPresentation()
          ) {
            this.queueBackgroundRender();
          }
        }
      }
    }
  }

  public async refreshHADevices(silent = false): Promise<void> {
    if (this.settings.connectionMode !== "homeAssistant" || this.isSyncingCloud) return;
    const endpoint = this.settings.haBaseURL;
    const token = this.settings.haToken;
    const revision = this.localControlRevision;
    const syncGen = ++this.syncGeneration;
    const previousPresentation = this.cloudPresentationFingerprint();
    const previousStructure = this.cloudPanelStructureFingerprint();
    let failed = false;
    let shouldUpdateView = false;
    this.isSyncingCloud = true;
    this.lastCloudRefreshAt = Date.now();
    if (!silent && this.devices.length === 0) this.render();
    try {
      await this.endpointSubmission;
      const home = await new HomeAssistantClient(endpoint, token).snapshot();
      const identity = homeAssistantIdentity(endpoint, token);
      if (!identity) throw new Error("Invalid Home Assistant URL");
      if (this.settings.connectionMode !== "homeAssistant" || this.settings.haBaseURL !== endpoint || this.settings.haToken !== token || this.localControlRevision !== revision || this.syncGeneration !== syncGen) return;
      this.devices = applyOrder(this.devices.map((device) => device.id), home.devices);
      this.scenes = home.scenes;
      const readingPriorityById = new Map(
        home.devices.map((device) => [device.id, environmentReadingPriority(device.kind)]),
      );
      this.environmentReadings = applyOrder(
        this.environmentReadings.map((reading) => reading.id),
        home.environmentReadings,
      ).sort(
        (a, b) => (readingPriorityById.get(a.id) ?? 0) - (readingPriorityById.get(b.id) ?? 0),
      );
      const hadValidCache = this.settings.cachedHAHome?.identity === identity;
      const presentationChanged =
        this.cloudPresentationFingerprint() !== previousPresentation || this.haConnectionError !== null;
      this.settings.cachedHAHome = {identity,home:{...home,devices:this.devices,environmentReadings:this.environmentReadings}};
      if (this.haConnectionError !== null) failed = true;
      this.haConnectionError = null;
      if (presentationChanged || !hadValidCache) this.saveSettings();
      shouldUpdateView = !silent || presentationChanged;
    } catch (error) {
      if (this.settings.connectionMode !== "homeAssistant" || this.settings.haBaseURL !== endpoint || this.settings.haToken !== token || this.localControlRevision !== revision || this.syncGeneration !== syncGen) return;
      failed = true;
      shouldUpdateView = true;
      this.haConnectionError = error instanceof Error ? error.message : String(error);
    } finally {
      if (this.syncGeneration === syncGen) {
        this.isSyncingCloud = false;
        if (shouldUpdateView) {
          if (failed || this.devices.length === 0 || this.cloudPanelStructureFingerprint() !== previousStructure || !this.patchCloudPresentation()) this.queueBackgroundRender();
        }
      }
    }
  }

  /** Cloud state that affects the rendered panel; polling a matching snapshot is a visual no-op. */
  private cloudPresentationFingerprint(): string {
    return JSON.stringify({
      homes: this.homes,
      devices: this.devices,
      scenes: this.scenes,
      environmentReadings: this.environmentReadings,
      groupOwners: [...this.groupOwnerByMemberDid],
    });
  }

  private cloudSnapshotIsStale(session: MiSession, revision: number): boolean {
    return (
      this.settings.connectionMode !== "xiaomiCloud" ||
      this.settings.miSession !== session ||
      this.localControlRevision !== revision
    );
  }

  private cloudPanelStructureFingerprint(): string {
    const kindChipsForPanel = kindChips(
      this.devices,
      this.listCut,
      this.settings.hideOfflineDevices,
    );
    return JSON.stringify({
      homes: this.homes,
      scenes: this.scenes,
      kindChips: kindChipsForPanel,
      kindRowVisible: showsKindRow(kindChipsForPanel, this.listCut),
      groupOwners: [...this.groupOwnerByMemberDid],
      allOffTargets: this.settings.connectionMode === "homeAssistant" ? null : this.allOffTargets.map((device) => device.id),
      devices: this.devices.map((device) => {
        const kind = device.kind;
        const capabilities =
          kind.kind === "light"
            ? [kind.availableEffects, kind.minKelvin, kind.maxKelvin]
            : kind.kind === "climate"
              ? [kind.availableModes, kind.availableFanModes, kind.minTemp, kind.maxTemp, kind.step]
              : kind.kind === "fan"
                ? [kind.availablePresetModes]
                : kind.kind === "vacuum"
                  ? [kind.availableModes]
                  : kind.kind === "camera"
                    ? [kind.availableNightShots, kind.motionDetectionEntityId]
                    : [];
        return {
          id: device.id,
          name: device.name,
          roomId: device.roomId,
          roomName: device.roomName,
          model: device.model,
          category: kind.kind,
          capabilities,
          sensorShape:
            kind.kind === "sensor"
              ? [kind.temperature !== null, kind.humidity !== null, kind.battery !== null]
              : null,
        };
      }),
    });
  }

  private patchCloudPresentation(): boolean {
    if (
      this.isEditingLayout ||
      this.activeSheet !== "none" ||
      this.pointerIsDown ||
      this.draggingId !== null
    ) {
      return false;
    }

    const isAll = this.selectedRoom === "全部";
    const ordered = withAliases(this.layout, applyOrder(this.layout.order, this.presentationDevices));
    const sections = pageSections(this.layout, ordered, isAll);
    const desiredHeaders = sections.filter((section) => section.title !== null);
    const domHeaders = Array.from(this.root.querySelectorAll<HTMLElement>(".cc-group-header"));
    if (domHeaders.length !== desiredHeaders.length) return false;
    for (const section of desiredHeaders) {
      const header = domHeaders.find((element) => element.dataset.collapse === section.id);
      const count = header?.querySelector(".cc-group-count")?.textContent ?? "";
      if (!header || count !== String(section.devices.length)) return false;
    }
    const bento = this.skin === "bento" && this.settings.isCompactGridMode;
    const tilePatches: Array<{ current: HTMLElement; desired: Element }> = [];
    const unmatchedTileIds = new Set(
      Array.from(this.root.querySelectorAll<HTMLElement>("[data-tile-id]"), (element) => element.dataset.tileId ?? ""),
    );
    let index = 0;
    for (const section of sections) {
      if (this.layout.collapsed.includes(scopedKey(this.pageKey, section.id))) continue;
      const spanMap = spans(
        section.devices,
        (device) => (this.expandedDeviceId === device.id ? "full" : this.tileSize(device)),
        bento,
      );
      for (const device of section.devices) {
        unmatchedTileIds.delete(device.id);
        const current = Array.from(
          this.root.querySelectorAll<HTMLElement>("[data-tile-id]"),
        ).find((element) => element.dataset.tileId === device.id);
        const desired = parseSingleElement(
          this.renderDeviceTile(device, spanMap.get(device.id) ?? 6, index++),
        );
        if (!current || !desired || !hasMatchingDomShape(current, desired)) return false;
        tilePatches.push({ current, desired });
      }
    }
    if (unmatchedTileIds.size > 0) return false;
    for (const patch of tilePatches) morphMatchingDom(patch.current, patch.desired);
    if (this.settings.connectionMode === "homeAssistant") {
      const current = this.root.querySelector<HTMLElement>("#btn-all-off");
      const desired = parseSingleElement(this.renderAllOffControl());
      if (current && desired) {
        morphMatchingDom(current, desired);
      } else if (current) {
        current.remove();
      } else if (desired) {
        this.root.querySelector("#btn-hide-panel")?.before(desired);
        this.bindAllOffControl();
      }
    }

    const envHTML = this.renderEnvironmentStrip();
    const currentEnv = this.root.querySelector<HTMLElement>(".cc-env-strip");
    if (currentEnv) {
      const desiredEnv = parseSingleElement(envHTML);
      if (!desiredEnv) {
        currentEnv.remove();
      } else if (hasMatchingDomShape(currentEnv, desiredEnv)) {
        morphMatchingDom(currentEnv, desiredEnv);
      } else {
        currentEnv.replaceWith(desiredEnv);
      }
    } else if (envHTML) {
      this.root.querySelector(".cc-header-top")?.insertAdjacentHTML("afterend", envHTML);
    }

    const subtitle = this.root.querySelector<HTMLElement>(".cc-subtitle");
    if (subtitle) subtitle.textContent = this.statusSummaryText;
    this.root
      .querySelector<HTMLElement>(".cc-home-badge")
      ?.classList.toggle("is-active", this.activeDeviceCount > 0);
    const footerLabel = this.root.querySelector<HTMLElement>(".cc-footer-label");
    if (footerLabel) {
      footerLabel.textContent =
        this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession
          ? t("米家账号 {user} · {count} 台设备", {
              user: maskedMiUserId(this.settings.miSession.userId),
              count: this.devices.length,
            })
          : this.settings.connectionMode === "homeAssistant" ? `Home Assistant · ${this.devices.length}` : t("演示模式 · 未连接米家云");
    }
    this.syncGrokBallEmotion();
    return true;
  }

  /** Narrows cloud records and rooms to the selected Mi Home; split keys bring their parent panel along. */
  private filterBySelectedHome<D extends { readonly did: string; readonly splitParentDid?: string | null }, R extends { readonly homeId?: string; readonly dids: readonly string[] }>(
    devices: readonly D[],
    rooms: readonly R[],
  ): { devices: D[]; rooms: R[] } {
    const selected = this.settings.selectedHomeId;
    if (!selected || !this.homes.some((h) => h.id === selected)) return { devices: [...devices], rooms: [...rooms] };
    const homeRooms = rooms.filter((r) => r.homeId === selected);
    const dids = new Set(homeRooms.flatMap((r) => r.dids));
    const kept = devices.filter((d) => dids.has(d.did) || (d.splitParentDid ? dids.has(d.splitParentDid) : false));
    const parents = new Set(kept.map((d) => d.splitParentDid).filter((x): x is string => !!x));
    const withParents = devices.filter((d) => kept.includes(d) || parents.has(d.did));
    return { devices: withParents, rooms: homeRooms };
  }

  public selectHome(id: string | null): void {
    this.settings.selectedHomeId = id;
    this.isHomeMenuOpen = false;
    this.selectedRoom = "全部";
    // A different home is a different suggestion context even at the same ambient signature (Codex #116 review).
    this.aiProactiveSuggestions = null;
    this.aiProactiveSignature = null;
    this.isRefreshingProactive = false;
    this.proactiveRetryAfterMs = null;
    this.isGrokBallStageExpanded = false;
    this.grokBallCelebrationUntil = 0;
    this.applyPanelHeight();
    this.saveSettings();
    this.render();
    void this.refreshDevices(false);
  }

  public get homeTitle(): string {
    const h = this.homes.find((x) => x.id === this.settings.selectedHomeId);
    return h ? h.name : this.homes.length > 1 ? t("全部家庭") : t("我的米家");
  }

  /** Devices 全关 would switch off: on screen (current room), on, and taking part (#23). */
  private get allOffTargets(): SmartDevice[] {
    return allOffTargets(this.filteredDevices, this.settings.allOffOverrides);
  }

  public renderKindBar(): string {
    const chips = kindChips(this.devices, this.listCut, this.settings.hideOfflineDevices);
    if (!showsKindRow(chips, this.listCut)) return "";
    const buttons = chips.map((tag) => {
      const chip = KIND_CHIP[tag];
      const active = this.listCut.kind === "deviceKind" && this.listCut.tag === tag;
      const hint = chip.hint ? ` title="${this.escapeHtml(t(chip.hint))}"` : "";
      return `<button class="cc-room-pill${active ? " is-active" : ""}" data-kind="${tag}" aria-pressed="${active}"${hint}>${this.escapeHtml(t(chip.title))}</button>`;
    }).join("");
    return `<div class="cc-room-bar"><div class="cc-room-track"><div class="cc-room-scroll">${buttons}</div></div></div>`;
  }

  private allOffButtonText(count: number): string {
    if (this.listCut.kind === "all") return `${t("全关")} (${count})`;
    const scope = this.listCut.kind === "room"
      ? this.listCut.roomName
      : t(KIND_CHIP[this.listCut.tag].title);
    return `${t("全关·{room}", { room: this.escapeHtml(scope) })} (${count})`;
  }

  public renderAllOffControl(): string {
    if (this.isEditingLayout) return `<button class="cc-all-off-pill is-done" id="btn-done-editing" aria-label="${t("完成布局编辑")}">${t("完成")}</button>`;
    const count = this.allOffTargets.length;
    if (count === 0) return "";
    return `<button class="cc-all-off-pill is-hold" id="btn-all-off" title="${t("按住 0.6 秒关闭这 {count} 台（插座、扫地机默认不参与，可在设置里调整）", { count })}" aria-label="${t("全关，关闭 {count} 台设备，按住 0.6 秒确认", { count })}">
      <span class="cc-hold-fill"></span>
      ${SF_ICONS.power}
      <span>${this.allOffButtonText(count)}</span>
    </button>`;
  }

  public bindAllOffControl(): void {
    const allOff = this.root.querySelector<HTMLElement>("#btn-all-off");
    if (!allOff) return;
    let holdTimer: number | undefined;
    let fired = false;
    allOff.addEventListener("pointerdown", () => {
      fired = false;
      allOff.classList.add("is-holding");
      holdTimer = window.setTimeout(() => {
        fired = true;
        allOff.classList.remove("is-holding");
        void this.turnAllOff();
      }, 600);
    });
    const cancel = () => {
      window.clearTimeout(holdTimer);
      allOff.classList.remove("is-holding");
    };
    allOff.addEventListener("pointerup", () => {
      cancel();
      if (!fired) {
        this.replyBanner = { text: t("按住 0.6 秒关闭这 {count} 台（插座、扫地机默认不参与）", { count: this.allOffTargets.length }), source: t("提示") };
        this.render();
      }
    });
    allOff.addEventListener("pointerleave", cancel);
  }

  private async turnAllOff(): Promise<void> {
    const targets = this.allOffTargets;
    if (targets.length === 0) return;
    const intents: DeviceIntent[] = targets.map((d) => ({
      targetId: d.id,
      operation: { kind: "power", isOn: false },
    }));
    await this.executeIntents(
      intents,
      t("已关闭 {count} 台开启中的设备", { count: targets.length }),
      t("一键全关"),
      { recordHabits: true },
    );
  }

  public async handleNaturalCommand(rawInput: string, fromScheduled = false): Promise<void> {
    return handleNaturalCommand(this, rawInput, fromScheduled);
  }

  private learnShortcut(
    phrase: string,
    reply: string,
    intents: readonly DeviceIntent[],
  ): void {
    learnShortcut(this, phrase, reply, intents);
  }

  private buildInverseCommand(dev: SmartDevice, command: DeviceCommand): DeviceCommand[] {
    return buildInverseCommand(dev, command);
  }

  public async executeIntents(
    intents: readonly DeviceIntent[],
    replyText: string,
    sourceLabel: string,
    options: { recordHabits?: boolean } = {},
  ): Promise<boolean> {
    return executeIntents(this, intents, replyText, sourceLabel, options);
  }

  public async executeSingleCommand(
    device: SmartDevice,
    command: DeviceCommand,
    summary: string,
    intent?: DeviceIntent,
    readBackPower = false,
  ): Promise<void> {
    return executeSingleCommand(this, device, command, summary, intent, readBackPower);
  }

  private readBackMatches(deviceId: string, intent?: DeviceIntent): boolean {
    return readBackMatches(this, deviceId, intent);
  }

  private recordHabits(intents: readonly DeviceIntent[]): HabitRecordingReceipt | null {
    return recordHabits(this, intents);
  }

  public habitSequences(): HabitSequenceEntry[] {
    return habitSequences();
  }

  public lastHabitAction(): HabitLastAction | null {
    return lastHabitAction();
  }

  private saveHabitMemory(memory: UserHabitMemory): void {
    saveHabitMemory(this, memory);
  }

  private unrecordHabits(receipt: HabitRecordingReceipt): void {
    unrecordHabits(this, receipt);
  }

  /** Time bucket + per-room temperature (1 °C steps) and humidity (5 % steps): the ambient signature (#113). */
  private proactiveSignature(): string {
    const bucket = timeBucketLabel(new Date().getHours());
    const readings = this.computedEnvironmentReadings
      .map(
        (reading) =>
          `${reading.temperature !== null ? Math.round(reading.temperature) : "-"}|${
            reading.humidity !== null ? Math.round(reading.humidity / 5) * 5 : "-"
          }`,
      )
      .join(",");
    return `${bucket}|${readings}`;
  }

  private isIntentReversibleOnDevice(intent: DeviceIntent, device: SmartDevice): { reversible: boolean; nextDevice: SmartDevice } {
    if (!device.isOnline || (device.kind.kind === "plug" && device.kind.switchEntityId.startsWith("button."))) {
      return { reversible: false, nextDevice: device };
    }
    const normalized = IntentValidator.normalize(intent.operation, device);
    if (!normalized) return { reversible: false, nextDevice: device };
    if (
      this.settings.connectionMode === "homeAssistant" &&
      normalized.kind === "power" &&
      normalized.isOn &&
      device.kind.kind === "climate" &&
      !device.kind.availableModes.some((mode) => mode !== "off" && mode !== "unknown" && mode !== "unavailable")
    ) {
      return { reversible: false, nextDevice: device };
    }
    const normalizedIntent: DeviceIntent = { targetId: intent.targetId, operation: normalized };
    const commands = IntentValidator.commandsForIntent(normalizedIntent, device);
    if (commands.length === 0 || !commands.every((command) => this.buildInverseCommand(device, command).length > 0)) {
      return { reversible: false, nextDevice: device };
    }
    const k = device.kind;
    let nextKind = k;
    if (k.kind === "light") {
      if (normalized.kind === "power") nextKind = { ...k, isOn: normalized.isOn };
      else if (normalized.kind === "brightness") nextKind = { ...k, isOn: true, brightnessPercent: normalized.percent };
      else if (normalized.kind === "colorTemperature") nextKind = { ...k, isOn: true, colorTempKelvin: normalized.kelvin, currentEffect: null };
      else if (normalized.kind === "lightEffect") nextKind = { ...k, isOn: true, currentEffect: normalized.effect };
    } else if (k.kind === "climate") {
      if (normalized.kind === "power") {
        const resumeMode = k.hvacMode === "off" ? (k.availableModes.find((m) => m !== "off") ?? "cool") : k.hvacMode;
        nextKind = { ...k, isOn: normalized.isOn, hvacMode: normalized.isOn ? resumeMode : "off" };
      } else if (normalized.kind === "hvacMode") {
        nextKind = { ...k, isOn: normalized.mode !== "off", hvacMode: normalized.mode };
      } else if (normalized.kind === "targetTemperature") {
        nextKind = { ...k, targetTemperature: normalized.celsius };
      } else if (normalized.kind === "fanSpeed") {
        nextKind = { ...k, fanMode: normalized.speed };
      }
    }
    return { reversible: true, nextDevice: { ...device, kind: nextKind } };
  }

  /** The Top-4 zero-delay suggestions: the AI cache when fresh, otherwise ranked locally (#113). */
  public currentProactiveSuggestions(): AssistantSuggestion[] {
    if (this.pendingSuggestions.length > 0 && !this.isGrokBallStageExpanded) return [];
    const signature = this.proactiveSignature();
    const aliasedDevices = withAliases(this.layout, this.devices);
    const local = new UserHabitMemory(this.settings.habitEntries, this.habitSequences(), this.lastHabitAction()).topSuggestions({
      devices: aliasedDevices,
      scenes: this.isGrokBallStageExpanded ? [] : this.scenes,
      environmentReadings: this.computedEnvironmentReadings,
    });
    const cached = this.aiProactiveSignature === signature ? this.aiProactiveSuggestions ?? [] : [];
    const fallback = this.isGrokBallStageExpanded
      ? new UserHabitMemory([]).topSuggestions({ devices: aliasedDevices, scenes: [], limit: aliasedDevices.length + 4 })
      : [];
    const result: AssistantSuggestion[] = [];
    for (const item of [...cached, ...local, ...fallback]) {
      if (this.isGrokBallStageExpanded && item.intents.some((intent) => intent.operation.kind === "activateScene")) continue;
      const actionableIntents = item.intents.filter((intent) => habitActionable(intent, aliasedDevices, this.scenes));
      if (actionableIntents.length === 0) continue;
      if (this.isGrokBallStageExpanded) {
        if (!item.intents.every((intent) => aliasedDevices.some((entry) => entry.id === intent.targetId && entry.isOnline))) continue;
        const stateByTarget = new Map<string, SmartDevice>();
        let allReversible = true;
        for (const intent of actionableIntents) {
          const current = stateByTarget.get(intent.targetId) ?? aliasedDevices.find((entry) => entry.id === intent.targetId);
          if (!current) {
            allReversible = false;
            break;
          }
          const check = this.isIntentReversibleOnDevice(intent, current);
          if (!check.reversible) {
            allReversible = false;
            break;
          }
          stateByTarget.set(intent.targetId, check.nextDevice);
        }
        if (!allReversible) continue;
      }
      const candidate: AssistantSuggestion = { ...item, intents: actionableIntents };
      if (result.some((existing) => JSON.stringify(existing.intents) === JSON.stringify(candidate.intents))) continue;
      result.push(candidate);
      if (result.length === 4) break;
    }
    return result;
  }

  public syncGrokBallEmotion(): void {
    const now = Date.now();
    this.grokBall.setEmotion(resolveGrokBallEmotion({
      timeBucket: timeBucketLabel(new Date(now).getHours()),
      activeDeviceCount: this.activeDeviceCount,
      speechListening: this.isListeningVoice,
      assistantState: this.isResolvingIntent ? "thinking" : this.pendingSuggestions.length > 0 ? "awaitingChoice" : "idle",
      isRecommending: this.isRefreshingProactive,
      hasErrorToast: this.replyBanner?.isError === true || Boolean(this.haConnectionError),
      isStageExpanded: this.isGrokBallStageExpanded,
      isPointerTracking: now < this.grokBallPointerUntil,
      hasRecentCelebration: now < this.grokBallCelebrationUntil,
    }));
  }

  private renderGrokBallStage(): string {
    if (!this.isGrokBallStageExpanded) return "";
    return `<section class="cc-grok-stage" aria-label="${t("猜你想控")}">
      ${this.currentProactiveSuggestions().slice(0, 4).map((item) => `
        <button class="cc-grok-pill" data-proactive-id="${this.escapeHtml(item.id)}" title="${this.escapeHtml(item.title)}">
          ${this.escapeHtml(item.title)}</button>`).join("")}
    </section>`;
  }

  public renderGrokBallSidebar(): string {
    if (!this.settings.enableGrokBall) return "";
    return `<aside class="cc-grok-sidebar" aria-label="${t("猜你想控")}">
      <button class="cc-grok-toggle" id="btn-grok-ball" data-grok-toggle aria-label="${t("猜你想控")}" aria-expanded="${this.isGrokBallStageExpanded}"><span data-grok-slot></span></button>
      ${this.renderGrokBallStage()}
    </aside>`;
  }

  public setGrokBallStageExpanded(expanded: boolean): void {
    if (this.isGrokBallStageExpanded === expanded) return;
    this.isGrokBallStageExpanded = expanded;
    this.applyPanelHeight();
    if (window.__TAURI_INTERNALS__) {
      void this.panelGeometryUpdates.then(() => this.render());
    } else {
      this.render();
    }
  }

  /**
   * Silent background AI refresh for proactive suggestions (#113): fires only when the
   * time bucket or room climate changed, never blocks the panel, never asks for consent,
   * and keeps the previous cache when the request fails.
   */
  public maybeRefreshProactiveInBackground(): void {
    if (this.isRefreshingProactive || this.settings.connectionMode === "demo") return;
    if (this.proactiveRetryAfterMs !== null && Date.now() < this.proactiveRetryAfterMs) return;
    const signature = this.proactiveSignature();
    if (signature === this.aiProactiveSignature) return;
    const baseURL = this.settings.assistantBaseURL.trim() || "https://openrouter.ai/api/v1";
    if (!endpointAllowsSendingSecrets(baseURL)) return;
    const apiKey = this.apiKeyFor(baseURL);
    const isLoopback = isLocalAssistantEndpoint(baseURL);
    if (!apiKey && !isLoopback) return;
    if (!isLoopback) {
      const endpoint = assistantEndpointIdentity(baseURL);
      if (!endpoint || !this.settings.cloudConsentEndpoints.includes(endpoint)) return;
    }
    const sourceRevision = this.sourceRevision;
    const selectedHomeId = this.settings.selectedHomeId;
    this.isRefreshingProactive = true;
    const resolver = new ModelIntentResolver(
      { baseURL, model: this.settings.assistantModel, apiKey },
      this.transport,
    );
    resolver
      .recommendProactiveSuggestions(
        this.devices,
        this.scenes,
        buildAssistantContext({
          now: new Date(),
          readings: this.computedEnvironmentReadings,
          devices: this.devices,
          scenes: this.scenes,
          sharing: this.settings.habitShareEnabled ? "on" : "off",
          memory: new UserHabitMemory(this.settings.habitEntries, this.habitSequences(), this.lastHabitAction()),
          phrases: this.settings.learnedShortcuts.map((shortcut) => ({
            phrase: shortcut.phrase,
            intents: shortcut.intents,
          })),
          mention: { kind: "none" },
        }),
      )
      .then((suggestions) => {
        if (sourceRevision !== this.sourceRevision || this.settings.selectedHomeId !== selectedHomeId) return;
        this.isRefreshingProactive = false;
        if (this.proactiveSignature() === signature) {
          // The context counts as served only once a usable result landed (Codex #116 review).
          this.aiProactiveSignature = signature;
          if (suggestions.length > 0) {
            this.aiProactiveSuggestions = suggestions;
          } else {
            // An empty result is a valid "home is ideal" answer: drop any older cache so the
            // local ranking takes over instead of stale suggestions (Codex #116 re-review).
            this.aiProactiveSuggestions = null;
          }
          if (!this.hasBlockingPanelInteraction()) this.render();
        }
      })
      .catch(() => {
        if (sourceRevision !== this.sourceRevision || this.settings.selectedHomeId !== selectedHomeId) return;
        // Silent: the previous cache keeps showing; retry after a cooldown (Codex #116 review).
        this.isRefreshingProactive = false;
        this.proactiveRetryAfterMs = Date.now() + MenuMijiaWindowsApp.PROACTIVE_RETRY_COOLDOWN_MS;
      });
  }

  public invalidateSourceControl(): void {
    this.sourceRevision += 1;
    this.syncGeneration += 1;
    this.isSyncingCloud = false;
    this.isResolvingIntent = false;
    this.aiProactiveSuggestions = null;
    this.aiProactiveSignature = null;
    this.isRefreshingProactive = false;
    this.proactiveRetryAfterMs = null;
    this.isGrokBallStageExpanded = false;
    this.grokBallCelebrationUntil = 0;
    this.applyPanelHeight();
    this.haConnectionError = null;
    this.lastUndoAction = null;
    this.pendingCloudConsent = null;
    this.pendingSuggestions = [];
  }

  public async performUndo(): Promise<void> {
    if (!this.lastUndoAction || this.lastUndoAction.expiresAtMs <= Date.now()) {
      this.lastUndoAction = null;
      this.replyBanner = {
        text: t("没有可撤销的操作（仅支持 10 分钟内的操作撤销）"),
        source: t("撤销提示"),
      };
      this.render();
      return;
    }
    const action = this.lastUndoAction;
    this.lastUndoAction = null;
    const sourceRevision = this.sourceRevision;
    const failedSteps: UndoStep[] = [];
    const blockedDevices = new Set<string>();
    let failureMessage = "";
    for (const step of action.steps) {
      if (blockedDevices.has(step.deviceId)) {
        failedSteps.push(step);
        continue;
      }
      let failed = false;
      for (const command of step.commands) {
        if (sourceRevision !== this.sourceRevision) return;
        if (!(await this.applyCommand(command))) {
          failed = true;
          failureMessage = this.replyBanner?.text ?? "设备未响应";
        }
      }
      if (failed) {
        failedSteps.push(step);
        blockedDevices.add(step.deviceId);
      }
    }
    if (sourceRevision !== this.sourceRevision) return;
    let remainingReceipt = action.habitReceipt;
    if (action.habitReceipt) {
      if (failedSteps.length === 0) {
        this.unrecordHabits(action.habitReceipt);
        remainingReceipt = undefined;
      } else {
        const { succeeded, remaining } = partitionHabitReceipt(action.habitReceipt, blockedDevices);
        if (succeeded) {
          this.unrecordHabits(succeeded);
        }
        remainingReceipt = remaining ?? undefined;
      }
    }
    if (failedSteps.length > 0 && this.lastUndoAction === null) {
      this.lastUndoAction = { ...action, steps: failedSteps, habitReceipt: remainingReceipt };
    }
    this.replyBanner = failedSteps.length > 0
      ? { text: t("撤销未完成，{count} 项待恢复。{message}", { count: failedSteps.length, message: failureMessage }), source: t("控制失败"), isError: true }
      : { text: t("已撤销：{summary}", { summary: action.summary }), source: t("已恢复") };
    this.render();
  }

  public async applyCommand(command: DeviceCommand, readBackPower = false): Promise<boolean> {
    const sourceRevision = this.sourceRevision;
    try {
      if (this.settings.connectionMode === "homeAssistant") command = homeAssistantCommand(command, this.devices);
      const readPower = await this.dispatchCloudCommand(command, readBackPower);
      if (typeof readPower === "boolean") command = withReadPower(command, readPower);
    } catch (error) {
      if (sourceRevision !== this.sourceRevision) return false;
      this.replyBanner = {
        text: error instanceof Error ? error.message : String(error),
        source: t("控制失败"),
        isError: true,
      };
      this.render();
      return false;
    }
    if (sourceRevision !== this.sourceRevision) return false;
    this.localControlRevision += 1;
    for (const dev of this.devices) {
      const k = dev.kind;
      switch (command.kind) {
        case "setLightPower":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = command.isOn;
          }
          break;
        case "setLightBrightness":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = command.percent > 0;
            k.brightnessPercent = command.percent;
          }
          break;
        case "setLightColorTemp":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = true;
            k.colorTempKelvin = command.kelvin;
            k.currentEffect = null;
          }
          break;
        case "setLightEffect":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = true;
            k.currentEffect = command.effect;
          }
          break;
        case "setClimatePower":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            k.isOn = command.isOn;
            k.hvacMode = command.isOn ? command.resumeMode : "off";
          }
          break;
        case "setClimateMode":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            k.isOn = command.hvacMode !== "off";
            k.hvacMode = command.hvacMode;
          }
          break;
        case "setClimateTemperature":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            if (this.settings.connectionMode !== "homeAssistant" || k.hvacMode !== "off") {
              k.isOn = true;
            }
            k.targetTemperature = command.temperature;
          }
          break;
        case "setClimateFanMode":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            k.fanMode = command.fanMode;
          }
          break;
        case "setFanPower":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = command.isOn;
          }
          break;
        case "setFanPercentage":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = command.percent > 0;
            k.percentage = command.percent;
            const fav = k.availablePresetModes.find((m) => m.toLowerCase() === "favorite");
            if (fav) k.presetMode = fav;
          }
          break;
        case "setFanPresetMode":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = true;
            k.presetMode = command.presetMode;
          }
          break;
        case "setFanOscillating":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = true;
            k.isOscillating = command.oscillating;
          }
          break;
        case "setSwitch":
          if (k.kind === "plug" && k.switchEntityId === command.entityId && !command.entityId.startsWith("button.")) {
            k.isOn = command.isOn;
          } else if (k.kind === "camera") {
            if (k.entityId === command.entityId) {
              k.isOn = command.isOn;
              if (this.cameraLive.activeLiveCameraId === dev.id && !this.cameraLive.liveCameraHidden) {
                if (command.isOn) {
                  this.cameraLive.reconnectCameraLiveView();
                } else {
                  this.cameraLive.stopLiveTransport();
                  this.cameraLive.liveCameraLoading = false;
                }
              }
            } else if (k.motionDetectionEntityId === command.entityId) {
              k.isMotionDetectionOn = command.isOn;
            }
          }
          break;
        case "setSelectOption":
          if (k.kind === "camera" && k.entityId === command.entityId) {
            k.nightShot = command.option;
          } else if (k.kind === "fridge" && k.modeEntityId === command.entityId) {
            k.currentMode = command.option;
          }
          break;
        case "setNumberValue":
          if (k.kind === "fridge") {
            if (k.fridgeTargetEntityId === command.entityId) {
              k.fridgeTargetTemp = command.value;
            } else if (k.freezerTargetEntityId === command.entityId) {
              k.freezerTargetTemp = command.value;
            }
          }
          break;
        case "vacuumAction":
          if (k.kind === "vacuum" && k.entityId === command.entityId) {
            k.status =
              command.action === "start"
                ? "cleaning"
                : command.action === "pause"
                  ? "paused"
                  : "returning";
          }
          break;
        case "activateScene":
          break;
      }
    }

    return true;
  }

  private async dispatchCloudCommand(command: DeviceCommand, readBackPower = false): Promise<boolean | null> {
    const sourceRevision = this.sourceRevision;
    if (this.settings.connectionMode === "demo") return null;
    if (this.settings.connectionMode === "homeAssistant") {
      const client = new HomeAssistantClient(this.settings.haBaseURL, this.settings.haToken);
      await this.endpointSubmission;
      if (sourceRevision !== this.sourceRevision) throw new Error("Connection source changed");
      await client.execute(command);
      return null;
    }
    if (!this.settings.miSession) throw new Error(t("请先扫码登录米家"));
    const session = this.settings.miSession;
    const dev = this.devices.find((d) => {
      const k = d.kind;
      if (k.kind === "plug") return k.switchEntityId === command.entityId || k.childLockEntityId === command.entityId;
      if (k.kind === "camera") return k.entityId === command.entityId || k.motionDetectionEntityId === command.entityId;
      if (k.kind === "fridge") {
        return (
          k.modeEntityId === command.entityId ||
          k.fridgeTargetEntityId === command.entityId ||
          k.freezerTargetEntityId === command.entityId
        );
      }
      if (k.kind === "sensor") return false;
      return k.entityId === command.entityId;
    });
    if (!dev) throw new Error(t("无法找到指令对应的设备"));

    const spec = await this.specResolver.resolve({
      did: dev.id,
      name: dev.name,
      model: dev.model,
      isOnline: dev.isOnline,
      specType: null,
    });
    const mapped = MiotCommandMapper.map(command, spec);
    if (sourceRevision !== this.sourceRevision) throw new Error("Connection source changed");
    const client = new MiCloudClient(session, this.transport);
    if (mapped.kind === "setProps") {
      await client.setProps(mapped.writes);
      if (readBackPower) {
        const power = mapped.writes.find((write) => typeof write.value === "boolean");
        if (power) {
          let read: Map<string, unknown>;
          try {
            read = await client.getProps([power]);
          } catch (error) {
            if (sourceRevision === this.sourceRevision) this.markCloudValuesStale();
            throw error;
          }
          const value = read.get(propKeyString(power));
          const isOn = readMiotPower(value);
          if (isOn === null) {
            // The write may have landed; the old row is no longer a trusted reading.
            if (sourceRevision === this.sourceRevision) this.markCloudValuesStale();
            throw new Error(t("未能读回设备状态"));
          }
          return isOn;
        }
      }
    } else {
      await client.action(mapped.call);
    }
    return null;
  }

  private markCloudValuesStale(): void {
    if (this.settings.connectionMode === "xiaomiCloud" && this.devices.length > 0) {
      this.cloudValuesStale = true;
    }
  }

  private markCloudValuesFresh(): void {
    if (this.settings.connectionMode === "xiaomiCloud") this.cloudValuesStale = false;
  }

  private get valuesAreStale(): boolean {
    if (this.settings.connectionMode === "xiaomiCloud") {
      return this.cloudValuesStale && this.devices.length > 0;
    }
    if (this.settings.connectionMode === "homeAssistant") {
      return this.haConnectionError !== null && this.devices.length > 0;
    }
    return false;
  }

  public toggleVoiceInput(): void {
    if (this.isListeningVoice) {
      this.speechRecognition?.stop();
      this.isListeningVoice = false;
      this.render();
      return;
    }

    const SpeechCtor = window.SpeechRecognition ?? window.webkitSpeechRecognition;
    if (!SpeechCtor) {
      this.isShowingAssistantBar = true;
      this.replyBanner = {
        text: t("当前系统环境不支持离线语音识别，请直接输入文字指令。"),
        source: t("语音提示"),
      };
      this.render();
      this.root.querySelector<HTMLInputElement>("#command-input")?.focus();
      return;
    }

    this.isShowingAssistantBar = true;
    const recognition = new SpeechCtor();
    recognition.lang = speechLocale();
    recognition.interimResults = false;
    recognition.continuous = false;

    recognition.onresult = (event) => {
      const first = event.results[0]?.[0]?.transcript;
      if (first) {
        const inputEl = this.root.querySelector<HTMLInputElement>("#command-input");
        if (inputEl) inputEl.value = "";
        void this.handleNaturalCommand(first);
      }
    };
    recognition.onerror = () => {
      this.isListeningVoice = false;
      this.render();
    };
    recognition.onend = () => {
      this.isListeningVoice = false;
      this.render();
    };

    this.speechRecognition = recognition;
    this.isListeningVoice = true;
    this.render();
    recognition.start();
  }

  public async startXiaomiQRLogin(): Promise<void> {
    if (this.isPollingQR) return;
    this.isPollingQR = true;
    this.qrStatusText = t("正在获取小米安全登录二维码...");
    invokeTauriVoid("set_pin_popover", { pin: true });
    this.render();

    try {
      const login = new MiAccountLogin(this.transport, this.settings.miCloudRegion);
      const ticket = await login.start();
      this.qrTicket = ticket;
      this.qrStatusText = t("请打开手机「米家 App → 我的 → 右上角扫一扫」确认登录");
      this.render();

      const session = await login.waitForScan(ticket);
      this.invalidateSourceControl();
      // The account-level passToken is never persisted (#27).
      this.settings.miSession = sessionWithoutPassToken(session);
      this.settings.miCloudRegion = normalizeMiCloudRegion(session.region);
      this.settings.connectionMode = "xiaomiCloud";
      this.settings.hasCompletedOnboarding = true;
      // Clear fake demo devices immediately upon real Xiaomi login
      this.devices = [];
      this.scenes = [];
      this.groupOwnerByMemberDid = new Map();
      this.selectedRoom = "全部";
      this.activeSheet = "none";
      this.qrTicket = null;
      this.saveSettings();

      this.qrStatusText = t("已连接小米账号 {user}", { user: maskedMiUserId(session.userId) });
      this.replyBanner = {
        text: t("已登录小米账号 {user}，正在拉取真实设备...", { user: maskedMiUserId(session.userId) }),
        source: t("扫码成功"),
      };
      this.render();

      await this.refreshDevices(false);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.qrStatusText = t("扫码未完成：{message}", { message: msg });
    } finally {
      this.isPollingQR = false;
      invokeTauriVoid("set_pin_popover", { pin: false });
      this.render();
    }
  }

  public formatRemainingMs(ms: number): string {
    const secs = Math.max(0, Math.ceil(ms / 1000));
    if (secs >= 60) {
      const m = Math.floor(secs / 60);
      const s = secs % 60;
      return s > 0 ? `${m}分${s}秒` : `${m}分钟`;
    }
    return `${secs}秒`;
  }

  public get statusSummaryText(): string {
    if (this.valuesAreStale) return t("可能过期");
    if (this.settings.connectionMode === "homeAssistant") return this.isSyncingCloud ? "Home Assistant · Connecting" : `Home Assistant · ${this.onlineDeviceCount} online`;
    if (this.settings.connectionMode === "xiaomiCloud") {
      if (this.isSyncingCloud && this.devices.length === 0) {
        return t("正在从小米云端同步真实设备...");
      }
      if (this.activeDeviceCount > 0) {
        return t("{count} 台开启中 · 共 {online} 台在线", { count: this.activeDeviceCount, online: this.onlineDeviceCount });
      }
      return t("全屋待机 · {online} 台实时在线", { online: this.onlineDeviceCount });
    }
    return t("演示预览 · 点击下方「扫码直连」同步你的真机");
  }

  public get skin(): AppSkin {
    return this.settings.skin;
  }

  public get effectiveAppearance(): "light" | "dark" {
    const prefersLight =
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-color-scheme: light)").matches;
    return resolveAppearance(this.settings.appearance, prefersLight);
  }

  public get layout(): LayoutPrefs {
    return this.settings.layout;
  }

  /** Card sizes are per page: "all" or a room name. */
  public get pageKey(): string {
    return this.selectedRoom === "全部" ? "all" : this.selectedRoom;
  }

  public tileSize(dev: SmartDevice): Exclude<TileSize, "auto"> {
    return resolvedSize(chosenSize(this.layout, this.pageKey, dev.id), dev, this.settings.isCompactGridMode, this.settings.climatePanel);
  }

  public saveLayout(): void {
    this.saveSettings();
  }

  /**
   * Re-renders while keeping scroll offsets, and slides every card from its old position to its
   * new one (FLIP), so reorders, resizes and group moves animate instead of jumping.
   */
  public render(): void {
    const focused = document.activeElement as HTMLElement | null;
    const focusedInput =
      focused && (focused.tagName === "INPUT" || focused.tagName === "TEXTAREA")
        ? (focused as HTMLInputElement | HTMLTextAreaElement)
        : null;
    const keepsFocusedDraft = focusedInput ? inputKeepsDraft(focusedInput) : false;
    const focusAttributes = focused
      ? Array.from(focused.attributes)
          .filter((attr) => attr.name === "id" || attr.name.startsWith("data-"))
          .map((attr) => ({ name: attr.name, value: attr.value }))
      : [];
    const focusSnapshot =
      focused && focusAttributes.length > 0
        ? {
            tagName: focused.tagName,
            attributes: focusAttributes,
            value: keepsFocusedDraft ? focusedInput?.value ?? null : null,
            selectionStart: keepsFocusedDraft ? focusedInput?.selectionStart ?? null : null,
            selectionEnd: keepsFocusedDraft ? focusedInput?.selectionEnd ?? null : null,
          }
        : null;
    const hasMountedPopover = this.root.querySelector(":scope > .cc-popover") !== null;
    if (hasMountedPopover) {
      this.root.classList.remove("is-opening");
    }
    const tiles = Array.from(this.root.querySelectorAll<HTMLElement>("[data-tile-id]"));
    const before = new Map(tiles.map((el) => [el.dataset.tileId as string, el.getBoundingClientRect()]));
    const scrollTop = this.root.querySelector(".cc-scroll-area")?.scrollTop ?? 0;
    const roomLeft = this.root.querySelector(".cc-room-scroll")?.scrollLeft ?? 0;
    const sheetScrollTop = this.root.querySelector(".cc-sheet")?.scrollTop ?? 0;

    this.pendingCloudRender = false;
    this.grokBall.prepareMove();
    this.renderNow();
    const grokSlot = this.root.querySelector<HTMLElement>("[data-grok-slot]");
    if (grokSlot) this.grokBall.mount(grokSlot, this.grokBall.element.dataset.emotion ?? "02");
    this.syncGrokBallEmotion();

    const area = this.root.querySelector(".cc-scroll-area");
    if (area) area.scrollTop = scrollTop;
    const strip = this.root.querySelector<HTMLElement>(".cc-room-scroll");
    if (strip) strip.scrollLeft = roomLeft;
    const sheet = this.root.querySelector<HTMLElement>(".cc-sheet");
    if (sheet) sheet.scrollTop = sheetScrollTop;

    if (focusSnapshot) {
      const matches = Array.from(
        this.root.querySelectorAll<HTMLElement>(focusSnapshot.tagName.toLowerCase()),
      ).filter((element) =>
        focusSnapshot.attributes.every(
          (attribute) => element.getAttribute(attribute.name) === attribute.value,
        ),
      );
      const replacement = matches.length === 1 ? matches[0] : undefined;
      if (replacement) {
        if (focusSnapshot.value !== null && "value" in replacement) {
          (replacement as HTMLInputElement).value = focusSnapshot.value;
        }
        replacement.focus({ preventScroll: true });
        if (
          focusSnapshot.selectionStart !== null &&
          "setSelectionRange" in replacement
        ) {
          (replacement as HTMLInputElement).setSelectionRange(
            focusSnapshot.selectionStart,
            focusSnapshot.selectionEnd ?? focusSnapshot.selectionStart,
          );
        }
      }
    }

    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (!reduce && before.size > 0) {
      this.root.querySelectorAll<HTMLElement>("[data-tile-id]").forEach((el) => {
        const id = el.dataset.tileId as string;
        const old = before.get(id);
        if (!old || id === this.draggingId) return;
        const now = el.getBoundingClientRect();
        const dx = old.left - now.left;
        const dy = old.top - now.top;
        if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return;
        el.animate(
          [{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "translate(0, 0)" }],
          { duration: 340, easing: "cubic-bezier(0.2, 0.9, 0.3, 1.15)" },
        );
      });
    }
    this.applyDragOffset();
    this.animateEntrance = false;
    this.poppedDeviceId = null;
  }

  private renderNow(): void {
    renderPanel(this);
  }

  public renderEnvironmentStrip(): string {
    return renderEnvironmentStripView({
      readings: this.computedEnvironmentReadings,
      watts: this.totalPowerWatts,
      valuesAreStale: this.valuesAreStale,
      escapeHtml: (v) => this.escapeHtml(v),
    });
  }

  public renderDeviceGrid(): string {
    if (this.settings.connectionMode === "homeAssistant" && this.devices.length === 0) return `<div class="cc-empty-state"><div class="cc-empty-title">Home Assistant</div><div class="cc-empty-subtitle">${this.isSyncingCloud ? "Connecting…" : "No connected devices. Check the saved URL, token and endpoint permission."}</div><button class="cc-btn-secondary" id="btn-empty-settings">Settings</button></div>`;
    if (this.settings.connectionMode === "xiaomiCloud" && this.devices.length === 0) {
      if (this.isSyncingCloud) {
        return `
          <div class="cc-empty-state">
            <div class="cc-empty-icon is-pulsing">${SF_ICONS.sparkles}</div>
            <div class="cc-empty-title">${t("正在同步你的真实米家设备…")}</div>
            <div class="cc-empty-subtitle">${t("正在从小米云端拉取房间、MIoT 规格与实时状态")}</div>
          </div>
        `;
      }
      return `
        <div class="cc-empty-state">
          <div class="cc-empty-icon">${SF_ICONS.houseFill}</div>
          <div class="cc-empty-title">${t("尚未同步到米家设备")}</div>
          <div class="cc-empty-subtitle">当前地区（${this.escapeHtml(normalizeMiCloudRegion(this.settings.miSession?.region ?? this.settings.miCloudRegion))}）没有设备，可尝试切换地区</div>
          <div class="cc-empty-actions">
            <button class="cc-btn-primary" id="btn-empty-resync">${t("重新同步设备")}</button>
            <button class="cc-btn-secondary" id="btn-empty-settings">${t("切换账号 / 设置")}</button>
          </div>
        </div>
      `;
    }

    if (this.devices.length > 0 && this.presentationDevices.length === 0 && (this.settings.hideOfflineDevices || this.listCut.kind === "deviceKind")) {
      const title = this.listCut.kind === "deviceKind"
        ? (this.settings.hideOfflineDevices ? t("这一类暂无通电在线的设备") : t("这一类暂无设备"))
        : t("该房间暂无通电在线的设备");
      const offlineButton = this.settings.hideOfflineDevices
        ? `<div class="cc-empty-actions"><button class="cc-btn-secondary" id="btn-show-offline">${t("显示离线设备")}</button></div>`
        : "";
      return `
        <div class="cc-empty-state">
          <div class="cc-empty-title">${title}</div>
          ${offlineButton}
        </div>
      `;
    }

    const isAll = this.selectedRoom === "全部";
    const ordered = withAliases(this.layout, applyOrder(this.layout.order, this.presentationDevices));
    const sections = pageSections(this.layout, ordered, isAll);
    const bento = this.skin === "bento" && this.settings.isCompactGridMode;
    let index = 0;
    return sections
      .map((section) => {
        const collapsed = this.layout.collapsed.includes(scopedKey(this.pageKey, section.id));
        const spanMap = spans(section.devices, (d) => (this.expandedDeviceId === d.id ? "full" : this.tileSize(d)), bento);
        const header =
          section.title === null
            ? ""
            : `<button class="cc-group-header ${collapsed ? "is-collapsed" : ""}" data-collapse="${this.escapeHtml(section.id)}" ${section.groupId ? `data-group-id="${this.escapeHtml(section.groupId)}"` : ""}>
                <span class="cc-group-caret">${SF_ICONS.chevronDown}</span>
                <span class="cc-group-title">${this.escapeHtml(section.title)}</span>
                <span class="cc-group-count">${section.devices.length}</span>
                <span class="cc-group-rule"></span>
              </button>`;
        const body = collapsed
          ? ""
          : `<div class="cc-devices-grid is-flow ${bento ? "is-bento" : ""}">
              ${section.devices.map((dev) => this.renderDeviceTile(dev, spanMap.get(dev.id) ?? 6, index++)).join("")}
            </div>`;
        return `<section class="cc-group">${header}${body}</section>`;
      })
      .join("");
  }

  private renderDeviceTile(dev: SmartDevice, span: number, index: number): string {
    return renderDeviceTileView(dev, {
      span,
      index,
      size: this.tileSize(dev),
      skin: this.skin,
      animateEntrance: this.animateEntrance,
      poppedDeviceId: this.poppedDeviceId,
      draggingId: this.draggingId,
      isEditingLayout: this.isEditingLayout,
      selectedRoom: this.selectedRoom,
      valuesAreStale: this.valuesAreStale,
      expandedDeviceId: this.expandedDeviceId,
      waitingDeviceIds: this.waitingDeviceIds,
      compactGrid: this.settings.isCompactGridMode,
      dimPreview: this.dimPreview,
      escapeHtml: (v) => this.escapeHtml(v),
    });
  }

  public renderHomeMenu(): string {
    if (!this.isHomeMenuOpen || this.homes.length < 2) return "";
    const item = (id: string | null, label: string, count?: number) => `
      <button class="cc-menu-item ${this.settings.selectedHomeId === id ? "is-checked" : ""}" data-home="${id ?? ""}">
        <span>${this.escapeHtml(label)}</span>${count !== undefined ? `<small>${count}</small>` : ""}
      </button>`;
    return `
      <div class="cc-menu-scrim" data-close-menus></div>
      <div class="cc-menu cc-home-menu">
        ${item(null, t("全部家庭"))}
        <div class="cc-menu-sep"></div>
        ${this.homes.map((h) => item(h.id, h.name, h.deviceCount)).join("")}
      </div>`;
  }

  public renderContextMenu(): string {
    const m = this.ctxMenu;
    if (!m) return "";
    const pos = `left:${Math.min(m.x, window.innerWidth - 230)}px; top:${Math.min(m.y, window.innerHeight - 260)}px`;
    if (m.groupId) {
      const g = this.layout.groups.find((x) => x.id === m.groupId);
      if (!g) return "";
      const gid = this.escapeHtml(g.id);
      return `
        <div class="cc-menu-scrim" data-close-menus></div>
        <div class="cc-menu" style="${pos}">
          <div class="cc-menu-title">${this.escapeHtml(g.name)}</div>
          <button class="cc-menu-item" data-group-action="rename:${gid}">重命名</button>
          <button class="cc-menu-item" data-group-action="up:${gid}">上移分组</button>
          <button class="cc-menu-item" data-group-action="down:${gid}">下移分组</button>
          <div class="cc-menu-sep"></div>
          <button class="cc-menu-item is-danger" data-group-action="delete:${gid}">删除分组</button>
        </div>`;
    }
    const dev = this.devices.find((d) => d.id === m.deviceId);
    if (!dev) return "";
    const id = this.escapeHtml(dev.id);
    const size = chosenSize(this.layout, this.pageKey, dev.id);
    const current = this.layout.groupMap[dev.id];
    return `
      <div class="cc-menu-scrim" data-close-menus></div>
      <div class="cc-menu" style="${pos}">
        <div class="cc-menu-title">${this.escapeHtml(this.layout.aliases[dev.id] ?? dev.name)}</div>
        <div class="cc-menu-label">${t("卡片大小（本页）")}</div>
        <div class="cc-menu-chips">
          ${TILE_SIZES.map((t) => `<button class="cc-menu-chip ${size === t.id ? "is-active" : ""}" data-set-size="${id}:${t.id}">${t.title}</button>`).join("")}
        </div>
        <div class="cc-menu-label">${t("移到分组")}</div>
        <div class="cc-menu-chips">
          ${this.layout.groups.map((g) => `<button class="cc-menu-chip ${current === g.id ? "is-active" : ""}" data-set-group="${id}:${this.escapeHtml(g.id)}">${this.escapeHtml(g.name)}</button>`).join("")}
          ${current ? `<button class="cc-menu-chip" data-set-group="${id}:">不分组</button>` : ""}
          <button class="cc-menu-chip is-add" data-new-group="${id}">＋ 新建</button>
        </div>
        <div class="cc-menu-sep"></div>
        <button class="cc-menu-item" data-rename-device="${id}">重命名…</button>
        <button class="cc-menu-item" data-start-editing>${t("编辑布局")}</button>
      </div>`;
  }

  public renderPrompt(): string {
    const p = this.prompt;
    if (!p) return "";
    let title = t("新建分组");
    let value = "";
    let placeholder = t("例如：灯光、电器、环境");
    if (p.kind === "renameGroup") {
      title = t("重命名分组");
      value = this.layout.groups.find((g) => g.id === p.groupId)?.name ?? "";
    } else if (p.kind === "renameDevice") {
      title = t("重命名设备");
      const dev = this.devices.find((d) => d.id === p.deviceId);
      placeholder = dev?.name ?? "";
      value = this.layout.aliases[p.deviceId] ?? dev?.name ?? "";
    }
    const hasAlias = p.kind === "renameDevice" && Boolean(this.layout.aliases[p.deviceId]);
    return `
      <div class="cc-prompt-backdrop" data-prompt-cancel></div>
      <div class="cc-prompt">
        <strong>${title}</strong>
        <input id="prompt-input" class="cc-prompt-input" type="text" value="${this.escapeHtml(value)}" placeholder="${this.escapeHtml(placeholder)}" />
        ${p.kind === "renameDevice" ? `<small>${t("只在本 App 显示，不会修改米家里的名字")}</small>` : ""}
        <div class="cc-prompt-actions">
          ${hasAlias ? `<button class="cc-btn-secondary" id="btn-prompt-reset">${t("恢复原名")}</button>` : ""}
          <button class="cc-btn-secondary" data-prompt-cancel>${t("取消")}</button>
          <button class="cc-btn-primary" id="btn-prompt-save">${t("保存")}</button>
        </div>
      </div>`;
  }

  public renderOnboardingModal(): string {
    return `
      <div class="cc-sheet-backdrop">
        <div class="cc-sheet" role="dialog" aria-modal="true" aria-label="${t("首次设置")}">
          <div class="cc-sheet-header">
            <div class="cc-sheet-badge">${t("MenuBarMijia 控制中心")}</div>
            <button class="cc-circle-btn is-small" id="btn-close-onboarding" title="${t("关闭引导")}" aria-label="${t("关闭引导")}">
              ${SF_ICONS.xmark}
            </button>
          </div>

          <h2 class="cc-sheet-title">${t("扫码直连你的真实米家设备")}</h2>
          <p class="cc-sheet-desc">
            ${t("手机打开「米家 App → 扫一扫」即可直接同步全屋真实设备；常驻 Windows 右下角系统托盘，点击图标或按 Alt+M 随时弹出，点击外部自动收起。")}
          </p>

          <div class="cc-field">
            <label>${t("云端服务器地区")}</label>
            <select class="cc-input" data-mi-region>
              ${MI_CLOUD_REGIONS.map(
                (region) => `<option value="${region.code}" ${normalizeMiCloudRegion(this.settings.miCloudRegion) === region.code ? "selected" : ""}>${this.escapeHtml(region.label)}</option>`,
              ).join("")}
            </select>
            <p class="cc-field-hint">${t("欧洲、印度、俄罗斯、新加坡、美区的米家账号请先选择对应地区，再扫码登录。")}</p>
          </div>

          <div class="cc-qr-box">
            <button class="cc-btn-primary is-full" id="btn-start-qr" ${this.isPollingQR ? "disabled" : ""}>
              ${SF_ICONS.qrcode}
              <span>${this.isPollingQR ? t("正在等待手机米家扫码确认...") : t("获取米家登录二维码")}</span>
            </button>
            <div class="cc-qr-status">${this.escapeHtml(this.qrStatusText)}</div>
            ${
              this.qrTicket
                ? `<div class="cc-qr-frame">
                    <img src="${this.escapeHtml(this.qrTicket.qrImageURL)}" alt="Xiaomi QR" />
                  </div>`
                : ""
            }
          </div>

          <div class="cc-field">
            <label>${t("OpenRouter API Key（可选，用于 Jev SystemOne 模糊意图决策）")}</label>
            <input
              id="onboarding-api-key"
              class="cc-input"
              type="password"
              placeholder="sk-or-v1-..."
              value="${this.escapeHtml(this.apiKeyFor(this.settings.assistantBaseURL))}"
            />
          </div>

          <div class="cc-sheet-footer">
            <button class="cc-btn-secondary" id="btn-close-onboarding-alt">${t("先看演示预览")}</button>
            <button class="cc-btn-primary" id="btn-finish-onboarding">${t("进入控制中心")}</button>
          </div>
        </div>
      </div>
    `;
  }

  public renderSettingsModal(): string {
    return renderSettingsModal({
      settings: this.settings,
      devices: this.devices,
      availableUpdate: this.availableUpdate,
      apiKeyFor: (baseURL) => this.apiKeyFor(baseURL),
      habitSequences: () => this.habitSequences(),
      hotkeyNeedsHint: this.hotkeyNeedsHint,
      hotkeyRegistrationError: this.hotkeyRegistrationError,
      isPollingQR: this.isPollingQR,
      isRecordingHotkey: this.isRecordingHotkey,
      panelAnchor: this.panelAnchor,
      qrStatusText: this.qrStatusText,
      qrTicket: this.qrTicket,
      isCheckingUpdate: this.isCheckingUpdate,
      isInstallingUpdate: this.isInstallingUpdate,
      updateStatusMessage: this.updateStatusMessage,
      escapeHtml: (value) => this.escapeHtml(value),
    });
  }

  public bindEvents(): void {
    bindEventsImpl(this);
  }

  public startEditing(): void {
    this.isEditingLayout = true;
    this.expandedDeviceId = null;
    invokeTauriVoid("set_pin_popover", { pin: true });
    this.render();
  }

  public stopEditing(): void {
    this.isEditingLayout = false;
    this.draggingId = null;
    this.dragPointer = null;
    invokeTauriVoid("set_pin_popover", { pin: false });
    this.render();
  }

  public openPrompt(prompt: NonNullable<typeof this.prompt>): void {
    this.ctxMenu = null;
    this.prompt = prompt;
    invokeTauriVoid("set_pin_popover", { pin: true });
    this.render();
  }

  public closePrompt(): void {
    this.prompt = null;
    invokeTauriVoid("set_pin_popover", { pin: this.isEditingLayout });
    this.render();
  }

  public savePrompt(raw: string): void {
    const name = raw.trim();
    const p = this.prompt;
    if (!p) return;
    if (p.kind === "newGroup") {
      if (!name) return;
      const id = `g${Date.now().toString(36)}`;
      this.layout.groups.push({ id, name });
      this.layout.groupMap[p.deviceId] = id;
    } else if (p.kind === "renameGroup") {
      if (!name) return;
      this.layout.groups = this.layout.groups.map((g) => (g.id === p.groupId ? { id: g.id, name } : g));
    } else {
      const original = this.devices.find((d) => d.id === p.deviceId)?.name;
      if (!name || name === original) delete this.layout.aliases[p.deviceId];
      else this.layout.aliases[p.deviceId] = name;
    }
    this.saveLayout();
    this.closePrompt();
  }

  /** Keeps the picked-up card under the pointer; runs after every render. */
  public applyDragOffset(): void {
    if (!this.draggingId || !this.dragPointer) return;
    const el = this.root.querySelector<HTMLElement>(`[data-tile-id="${CSS.escape(this.draggingId)}"]`);
    if (!el) return;
    el.style.translate = "0px 0px";
    const r = el.getBoundingClientRect();
    const p = this.dragPointer;
    el.style.translate = `${p.x - p.grabX - r.left}px ${p.y - p.grabY - r.top}px`;
  }

  /** Section of a device on the current page: a user group id or "rest". */
  private sectionOf(id: string): string {
    const g = this.layout.groupMap[id];
    return g && this.layout.groups.some((x) => x.id === g) ? g : "rest";
  }

  /** Before/after the hovered card (top or left half = before); first when above every card. */
  public swapIfNeeded(x: number, y: number): void {
    const dragged = this.draggingId;
    if (!dragged) return;
    const now = performance.now();
    if (this.lastSwap && now - this.lastSwap.at < 250) return;
    const others = Array.from(this.root.querySelectorAll<HTMLElement>("[data-tile-id]"))
      .filter((el) => el.dataset.tileId !== dragged)
      .map((el) => ({ id: el.dataset.tileId as string, r: el.getBoundingClientRect() }));
    if (others.length === 0) return;
    let target: string | null = null;
    let after = false;
    const top = others.reduce((a, b) => (b.r.top < a.r.top ? b : a));
    if (y < top.r.top) {
      target = top.id;
    } else {
      const hit = others.find((o) => x >= o.r.left && x <= o.r.right && y >= o.r.top && y <= o.r.bottom);
      if (!hit) return;
      target = hit.id;
      const r = hit.r;
      after = y < r.top + r.height * 0.3 ? false : y > r.bottom - r.height * 0.3 ? true : x > r.left + r.width / 2;
    }
    const slot = `${target}|${after}`;
    if (this.lastSwap?.slot === slot) return;
    this.lastSwap = { slot, at: now };
    // Dropping beside a card in another group files the dragged card into that group.
    const to = this.sectionOf(target);
    if (to !== this.sectionOf(dragged)) {
      if (to === "rest") delete this.layout.groupMap[dragged]; else this.layout.groupMap[dragged] = to;
    }
    this.layout.order = moveInOrder(this.layout.order, this.devices.map((d) => d.id), dragged, target, after);
    this.saveLayout();
    this.render();
  }

  /**
   * One pointer stream drives tap, long-press-to-edit, drag-to-reorder and drag-to-dim. Listeners
   * live on the persistent root/window, so re-rendering mid-gesture never cancels the drag.
   */
  public bindSettingsEvents(): void {
    bindSettingsEvents(this);
  }

  private bindLayoutGestures(): void {
    bindLayoutGestures(this);
  }

  /**
   * The panel has no title bar, so empty header space doubles as the move handle: the press goes to
   * the OS move loop and the backend snaps the window to the nearest work-area corner (#204). Buttons
   * and fields keep their own clicks.
   */
  private bindPanelDrag(): void {
    this.root.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || !window.__TAURI_INTERNALS__?.invoke) return;
      const target = event.target;
      if (!(target instanceof window.HTMLElement)) return;
      if (!target.closest(".cc-header-top")) return;
      if (target.closest("button, input, textarea, select, a")) return;
      invokeTauriVoid("start_panel_drag");
    });
  }

  /** Drop-in animation each time the tray popover is shown. */
  private bindOpenAnimation(): void {
    const play = () => {
      this.applyPanelHeight();
      this.root.classList.remove("is-opening");
      void this.root.offsetWidth;
      this.root.classList.add("is-opening");
      const strip = this.root.querySelector<HTMLElement>(".cc-room-scroll");
      const active = strip?.querySelector<HTMLElement>(".cc-room-pill.is-active");
      if (strip && active) strip.scrollLeft = this.selectedRoom === "全部" ? 0 : active.offsetLeft - (strip.clientWidth - active.offsetWidth) / 2;
    };
    let hiddenAt = 0;
    if (window.__TAURI_INTERNALS__) {
      window.addEventListener("blur", () => { hiddenAt = performance.now(); });
      window.addEventListener("focus", () => { if (performance.now() - hiddenAt > 150) play(); });
    }
    this.root.addEventListener("animationend", (e) => {
      const target = e.target as HTMLElement | null;
      if (target === this.root || target?.classList?.contains("cc-popover")) {
        this.root.classList.remove("is-opening");
      }
    });
    if (typeof window.matchMedia === "function") {
      const mql = window.matchMedia("(prefers-color-scheme: light)");
      mql.addEventListener?.("change", () => {
        if (this.settings.appearance === "system") {
          this.render();
        }
      });
    }
    play();
  }

  /** Pulls the placement the backend persists so a drag shows up in the settings sheet (#204). */
  public syncPanelPlacement(): void {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    const requested = this.panelAnchor;
    void invoke<PanelPlacement>("panel_placement")
      .then((value) => {
        // A choice made while this request was in flight wins; the next open re-reads the backend.
        if (this.panelAnchor !== requested) return;
        const { anchor } = parsePanelPlacement(value);
        if (anchor === this.panelAnchor) return;
        this.panelAnchor = anchor;
        if (this.activeSheet === "settings") this.render();
      })
      .catch(() => undefined);
  }

  public applyPanelHeight(): void {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    this.panelGeometryUpdates = this.panelGeometryUpdates.then(async () => {
      const h = PANEL_HEIGHTS.find((item) => item.id === this.settings.panelHeight) ?? PANEL_HEIGHTS[1]!;
      const side = await invoke<boolean>("set_panel_height", {
        height: h.px,
        expanded: this.isGrokBallStageExpanded,
        sideLeft: this.grokBallOnLeft,
        grokEnabled: this.settings.enableGrokBall,
      });
      if (typeof side === "boolean") {
        this.grokBallOnLeft = side;
        this.root.dataset.grokSide = side ? "left" : "right";
      }
    }).catch((error: unknown) => console.error("Panel geometry update failed", error));
  }

  /** The saved API key, only when it was saved for this server (#19). */
  public apiKeyFor(baseURL: string): string {
    const key = this.settings.openRouterApiKey.trim();
    if (!key) return "";
    const identity = assistantEndpointIdentity(baseURL);
    return identity !== null && identity === this.settings.assistantKeyEndpoint ? key : "";
  }

  /** Pointing the address at another server clears the saved key from the form; switching back restores it. */
  public syncKeyFieldWithEndpoint(apiKeyEl: HTMLInputElement, baseURL: string): void {
    const savedKey = this.settings.openRouterApiKey.trim();
    if (!savedKey) return;
    const belongs = this.apiKeyFor(baseURL) !== "";
    if (!belongs && apiKeyEl.value.trim() === savedKey) {
      apiKeyEl.value = "";
    } else if (belongs && apiKeyEl.value.trim() === "") {
      apiKeyEl.value = savedKey;
    }
  }

  public escapeHtml(str: string): string {
    return str
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }
}

document.addEventListener("DOMContentLoaded", () => {
  const root = document.getElementById("app");
  if (root) {
    new MenuMijiaWindowsApp(root);
  }
});
