import { HomeAssistantClient, homeAssistantIdentity, homeAssistantCommand, parseCachedHAHome } from "../core/homeAssistant.js";
import type { SynthesizedHome } from "../core/models.js";
import { GrokBallView } from "./grokBall.js";
import {
  ASSISTANT_PROVIDER_PRESETS,
  DelayPhrase,
  IntentReply,
  IntentValidator,
  LocalIntentParser,
  ModelIntentResolver,
  UndoPhrase,
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
  INSECURE_ENDPOINT_MESSAGE,
  ModelActionPolicy,
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
  UPDATE_RELEASES_PAGE,
  UPDATE_RELEASES_URL,
  UPDATE_STORAGE_KEY,
  checkForUpdate,
  isNewerVersion,
  parseUpdateState,
  serializeUpdateState,
  type GitHubRelease,
  type UpdateState,
} from "../core/updateChecker.js";
import {
  CredentialVault,
  credentialsFromSettings,
  hasCredentials,
  parseMiSession,
  sanitizeSettingsForStorage,
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
  cloudRefreshDue,
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
  partitionDueTimers,
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
  normalizeGlobalShortcut,
  pageSections,
  parsePanelPlacement,
  recordShortcutFromKeyEvent,
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
  resolveLanguage,
  setLanguage,
  speechLocale,
  t,
} from "../core/i18n.js";
import {
  type TemperatureUnitPreference,
  applyTemperatureUnit,
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
import { APP_VERSION, CAMERA_QUALITY_TITLES, CACHED_DEVICES_VERSION, LEGACY_STORAGE_KEY, SF_ICONS, STORAGE_KEY } from "./appConstants.js";
import { demoDevices, demoScenes, quickActions } from "./demo.js";
import { createTransport, invokeTauriVoid } from "./transport.js";
import { loadSettings, stripCredentialFieldsFromStoredCopies, upgradeCachedDevices, writeSettingsForStorage } from "./settings.js";
import { CameraLiveController } from "./cameraLive.js";
import { renderDeviceTile as renderDeviceTileView, renderEnvironmentStrip as renderEnvironmentStripView } from "./deviceViews.js";
import { renderSettingsModal } from "./settingsViews.js";
import { bindEvents as bindEventsImpl } from "./bindEvents.js";
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
  private readonly loadedSettings: LoadedSettings = loadSettings();
  public settings: PersistedSettings = this.loadedSettings.settings;
  private readonly credentialVault = new CredentialVault();
  private lastSubmittedEndpoints: string | null = null;
  // Assigned in the constructor, after the interface language is resolved: the demo home is
  // generated per language (#52), so a field initializer would freeze the module default.
  public devices: SmartDevice[];
  public scenes: HomeScene[];
  public environmentReadings: EnvironmentReading[] = [];
  private listCut: DeviceListCut = { kind: "all" };

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
  private haConnectionError: string | null = null;
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
  private grokBallCelebrationUntil = 0;
  private grokBallPointerUntil = 0;
  private grokBallOnLeft = false;
  private panelGeometryUpdates: Promise<void> = Promise.resolve();
  /** Panel anchor the backend persists (#204); the window position itself is owned by Rust. */
  public panelAnchor: PanelAnchor = "auto";
  /** Earliest timestamp a failed background refresh may retry (Codex #116 review). */
  private proactiveRetryAfterMs: number | null = null;
  /** Cooldown before a failed background refresh retries (Codex #116 review). */
  private static readonly PROACTIVE_RETRY_COOLDOWN_MS = 5 * 60_000;
  private isResolvingIntent = false;
  private isSyncingCloud = false;
  private syncGeneration = 0;
  private lastCloudRefreshAt: number | null = null;
  public localControlRevision = 0;
  private sourceRevision = 0;
  /** A silent cloud result that is waiting for the user to finish interacting. */
  private pendingCloudRender = false;
  public endpointSubmission: Promise<unknown> = Promise.resolve();
  public pointerIsDown = false;
  private isListeningVoice = false;
  public scheduledCommands: ScheduledCommand[] = [];
  /** Timers that came due while the PC slept; they only run when the user taps 立即执行 (#22). */
  public missedScheduledCommands: ScheduledCommand[] = [];
  private lastUndoAction: UndoAction | null = null;
  public qrTicket: QRLoginTicket | null = null;
  public qrStatusText = t("点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。");
  public isPollingQR = false;
  /** Latest GitHub release found by the daily check (#39); shown in settings and the tray menu. */
  public availableUpdate: GitHubRelease | null = null;
  private updateState: UpdateState = { lastCheckedAtMs: null, release: null };
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

  /**
   * First run after this version: move the plaintext copy into the Windows Credential
   * Manager, then rewrite localStorage without secrets (#28). Later runs read only the
   * credential store, so an upgrade needs no QR login again.
   */
  private initializeCredentials(): void {
    if (this.loadedSettings.hasLegacyCredentials) {
      // Rewrite the plaintext copy first so a credential-manager failure can never
      // leave tokens in localStorage. The in-memory settings keep the login alive.
      writeSettingsForStorage(this.settings);
      stripCredentialFieldsFromStoredCopies();
      void this.persistCredentials();
      return;
    }
    // A stale pre-1.0 copy can still hold secrets even when the v2 copy is clean (#28).
    stripCredentialFieldsFromStoredCopies();
    void this.hydrateCredentials();
  }

  private async hydrateCredentials(): Promise<void> {
    try {
      const credentials = await this.credentialVault.load();
      if (!hasCredentials(credentials)) return;
      const current = credentialsFromSettings(this.settings);
      if (!current.miSession && credentials.miSession) this.settings.miSession = credentials.miSession;
      if (current.haToken === "" && credentials.haToken !== "") this.settings.haToken = credentials.haToken;
      if (current.assistantApiKey === "" && credentials.assistantApiKey !== "") {
        this.settings.openRouterApiKey = credentials.assistantApiKey;
        this.settings.assistantKeyEndpoint ??= assistantEndpointIdentity(this.settings.assistantBaseURL);
      }
      if (this.settings.miSession) {
        this.settings.hasCompletedOnboarding = true;
        this.settings.miCloudRegion = normalizeMiCloudRegion(this.settings.miSession.region);
        if (this.activeSheet === "onboarding") this.activeSheet = "none";
      }
      this.submitServiceEndpoints();
      writeSettingsForStorage(this.settings);
      if (this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession) {
        void this.refreshDevices(true);
      }
      if (this.settings.connectionMode === "homeAssistant") {
        const cache = this.settings.cachedHAHome;
        if (cache?.identity === homeAssistantIdentity(this.settings.haBaseURL, this.settings.haToken)) {
          this.devices = structuredClone(cache.home.devices);
          this.scenes = structuredClone(cache.home.scenes);
          this.environmentReadings = structuredClone(cache.home.environmentReadings);
        }
      }
      this.render();
      if (this.settings.connectionMode === "homeAssistant") void this.refreshHADevices();
    } catch {
      if (this.settings.connectionMode === "homeAssistant") {
        this.haConnectionError = "Home Assistant credentials could not be loaded. Check Windows Credential Manager.";
        this.render();
      }
    }
  }

  private async persistCredentials(): Promise<void> {
    try {
      await this.credentialVault.persist(credentialsFromSettings(this.settings));
    } catch {
      // The credential manager refused the write; never fall back to plaintext storage.
    }
  }

  public saveSettings(forceSubmitEndpoints = false): void {
    writeSettingsForStorage(this.settings);
    this.submitServiceEndpoints(forceSubmitEndpoints);
    void this.persistCredentials();
  }

  /** OS-preferred languages, read from the WebView's `window.navigator` (#52). */
  private static osLanguages(): string[] {
    const languages = window.navigator.languages;
    if (Array.isArray(languages) && languages.length > 0) return [...languages];
    return window.navigator.language ? [window.navigator.language] : [];
  }

  /** Picks the UI language from the saved preference plus the OS languages (#52). */
  public applyInterfaceLanguage(): void {
    setLanguage(resolveLanguage(this.settings.interfaceLanguage, MenuMijiaWindowsApp.osLanguages()));
  }

  /** Resolves °C/°F from the saved preference plus the OS region; core values stay Celsius (#52). */
  public applyTemperatureSetting(): void {
    const locale = MenuMijiaWindowsApp.osLanguages()[0] ?? "en";
    applyTemperatureUnit(locale, this.settings.temperatureUnit);
  }

  private submitServiceEndpoints(force = false): void {
    const assistantUrl = this.settings.assistantBaseURL.trim();
    const haUrl = this.settings.haBaseURL.trim();
    const serialized = `${assistantUrl}\n${haUrl}`;
    if (!force && serialized === this.lastSubmittedEndpoints) return;
    this.lastSubmittedEndpoints = serialized;
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    this.endpointSubmission = invoke("set_service_endpoints", { assistantUrl, haUrl }).catch(() => undefined);
  }

  /** Restores the last known release so an update found yesterday still shows after a restart. */
  private restoreUpdateState(): void {
    try {
      this.updateState = parseUpdateState(localStorage.getItem(UPDATE_STORAGE_KEY));
    } catch {
      this.updateState = { lastCheckedAtMs: null, release: null };
    }
    const release = this.updateState.release;
    if (release && isNewerVersion(release.version, APP_VERSION)) {
      this.availableUpdate = release;
      invokeTauriVoid("set_update_available", { version: release.version });
    }
  }

  private saveUpdateState(): void {
    try {
      localStorage.setItem(UPDATE_STORAGE_KEY, serializeUpdateState(this.updateState));
    } catch {
      // Quota errors only cost the "once per day" memory, never the check itself.
    }
  }

  /**
   * Automatic check is skipped outside Tauri (browser preview/tests) because the CSP only
   * allows `native_http`. `manual` is an explicit user action, so it bypasses the daily
   * limit and the auto-check switch (#39).
   */
  public async checkForAppUpdate(manual: boolean): Promise<void> {
    if (!manual && !window.__TAURI_INTERNALS__?.invoke) return;
    if (this.isCheckingUpdate || this.isInstallingUpdate) return;
    if (manual) {
      this.isCheckingUpdate = true;
      this.updateStatusMessage = null;
      this.render();
    }
    const result = await checkForUpdate({
      currentVersion: APP_VERSION,
      enabled: manual || this.settings.autoCheckUpdates,
      lastCheckedAtMs: this.updateState.lastCheckedAtMs,
      nowMs: Date.now(),
      force: manual,
      requestLatest: () =>
        this.transport({
          url: UPDATE_RELEASES_URL,
          method: "GET",
          headers: {
            Accept: "application/vnd.github+json",
            "User-Agent": "MenuBarMijia-Windows",
          },
          timeoutMs: 8000,
        }),
    });
    this.isCheckingUpdate = false;
    if (!result.requested) return;

    this.updateState = { lastCheckedAtMs: result.checkedAtMs, release: result.release };
    this.saveUpdateState();
    if (result.updateAvailable && result.release) {
      this.availableUpdate = result.release;
      this.updateStatusMessage = null;
      invokeTauriVoid("set_update_available", { version: result.release.version });
      this.render();
    } else if (!result.failed && this.availableUpdate) {
      // A successful check with no newer release retires yesterday's notice.
      this.availableUpdate = null;
      this.updateStatusMessage = manual
        ? { text: t("已是最新版本 v{version}", { version: APP_VERSION }), isError: false }
        : null;
      invokeTauriVoid("set_update_available", { version: null });
      this.render();
    } else if (manual) {
      const text = result.failed ? t("检查更新失败，请稍后再试") : t("已是最新版本 v{version}", { version: APP_VERSION });
      this.updateStatusMessage = { text, isError: result.failed };
      this.replyBanner = {
        text,
        source: t("检查更新"),
        isError: result.failed,
      };
      this.render();
    }
  }

  public openSettingsSheet(): void {
    this.activeSheet = "settings";
    invokeTauriVoid("set_pin_popover", { pin: true });
    this.syncPanelPlacement();
    this.render();
    void this.checkForAppUpdate(false);
  }

  public openUpdatePage(): void {
    invokeTauriVoid("open_release_page", { url: this.availableUpdate?.htmlURL ?? UPDATE_RELEASES_PAGE });
  }

  public async startUpdateInstall(): Promise<void> {
    if (this.isInstallingUpdate || !this.availableUpdate) return;
    const asset = this.availableUpdate.installerAsset;
    if (!asset) {
      this.openUpdatePage();
      return;
    }
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) {
      this.openUpdatePage();
      return;
    }
    this.isInstallingUpdate = true;
    this.updateStatusMessage = {
      text: t("正在下载并校验 v{version} 安装包，完成后将自动启动安装…", { version: this.availableUpdate.version }),
      isError: false,
    };
    this.render();
    try {
      await invoke("install_update", { asset });
      this.isInstallingUpdate = false;
      this.render();
    } catch (error) {
      this.isInstallingUpdate = false;
      const message =
        typeof error === "string" && error.trim().length > 0
          ? error
          : error instanceof Error && error.message.trim().length > 0
            ? error.message
            : t("下载或校验更新包失败，请重试或手动下载");
      this.updateStatusMessage = { text: message, isError: true };
      this.render();
    }
  }

  /**
   * Synchronizes the Windows global shortcut registration with the current preference (#43),
   * unregistering immediately when disabled (Coding Standard #3) and surfacing conflicts.
   */
  public async applyGlobalHotkey(): Promise<void> {
    const enabled = this.settings.enableGlobalHotkey;
    const shortcut = normalizeGlobalShortcut(this.settings.globalHotkey);
    this.settings.globalHotkey = shortcut;
    if (!enabled) {
      this.hotkeyRegistrationError = null;
    }
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) {
      this.hotkeyRegistrationError = null;
      return;
    }
    try {
      await invoke("set_global_shortcut", { enabled, shortcut });
      this.hotkeyRegistrationError = null;
    } catch {
      this.hotkeyRegistrationError = enabled ? t("这个组合已被其他应用占用，换一个再试。") : null;
    }
    if (this.activeSheet === "settings") {
      this.render();
    }
  }

  private bindGlobalKeys(): void {
    window.addEventListener("keydown", (e) => {
      if (this.isRecordingHotkey) {
        e.preventDefault();
        e.stopPropagation();
        const outcome = recordShortcutFromKeyEvent(e);
        if (outcome.kind === "cancel") {
          this.isRecordingHotkey = false;
          this.hotkeyNeedsHint = false;
          this.render();
        } else if (outcome.kind === "invalid") {
          this.hotkeyNeedsHint = true;
          this.render();
        } else if (outcome.kind === "recorded") {
          this.isRecordingHotkey = false;
          this.hotkeyNeedsHint = false;
          this.settings.globalHotkey = outcome.shortcut;
          this.saveSettings();
          void this.applyGlobalHotkey();
          this.render();
        }
        return;
      }

      if (e.key === "Escape") {
        if (this.isGrokBallStageExpanded) {
          this.setGrokBallStageExpanded(false);
          return;
        }
        if (this.cameraLive.activeLiveCameraId !== null) {
          this.cameraLive.hideCameraLiveView();
          return;
        }
        if (this.activeSheet !== "none") {
          this.activeSheet = "none";
          this.isRecordingHotkey = false;
          this.hotkeyNeedsHint = false;
          invokeTauriVoid("set_pin_popover", { pin: false });
          this.render();
        } else {
          invokeTauriVoid("hide_panel");
        }
      } else if (e.key === "/" && document.activeElement?.tagName !== "INPUT") {
        e.preventDefault();
        this.isShowingAssistantBar = true;
        this.render();
        this.root.querySelector<HTMLInputElement>("#command-input")?.focus();
      }
    });
  }

  private startTimerLoop(): void {
    window.setInterval(() => {
      if (this.pendingCloudRender && !this.hasBlockingPanelInteraction()) {
        this.render();
      }

      this.maybeRefreshProactiveInBackground();

      const now = Date.now();
      this.syncGrokBallEmotion();
      let changed = false;

      if (this.lastUndoAction && this.lastUndoAction.expiresAtMs <= now) {
        this.lastUndoAction = null;
        changed = true;
      }

      // After sleep the interval resumes late; a timer more than a minute overdue is not run silently (#22).
      const { run, missed, remaining } = partitionDueTimers(this.scheduledCommands, now);
      if (run.length > 0 || missed.length > 0) {
        this.scheduledCommands = remaining;
        this.missedScheduledCommands.push(...missed);
        changed = true;
        for (const item of run) {
          void this.handleNaturalCommand(item.command, true);
        }
      } else if (this.scheduledCommands.length > 0) {
        changed = true;
      }

      if (changed) {
        this.render();
      }

      if (
        (this.settings.connectionMode === "homeAssistant" || this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession) &&
        this.activeSheet === "none" &&
        !this.isSyncingCloud &&
        !this.isPollingQR &&
        cloudRefreshDue(now, this.lastCloudRefreshAt, this.isPanelVisible())
      ) {
        void this.refreshDevices(true);
      }
    }, 1000);
  }

  /** The tray popover hides when it loses focus, so focus means it is on screen. */
  private isPanelVisible(): boolean {
    return document.visibilityState !== "hidden" && document.hasFocus();
  }

  /** Background refreshes must not rebuild the panel while the user is mid-action. */
  private hasBlockingPanelInteraction(): boolean {
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

  private get rooms(): string[] {
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

  private get computedEnvironmentReadings(): EnvironmentReading[] {
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

  private get homeTitle(): string {
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

  private renderAllOffControl(): string {
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
    const trimmed = rawInput.trim();
    if (!trimmed) return;
    const sourceRevision = this.sourceRevision;
    // A new command replaces any question still waiting for cloud consent, and old suggestions.
    this.pendingCloudConsent = null;
    this.pendingSuggestions = [];

    if (UndoPhrase.isUndo(trimmed)) {
      await this.performUndo();
      return;
    }

    if (DelayPhrase.isCancel(trimmed)) {
      const count = this.scheduledCommands.length + this.missedScheduledCommands.length;
      this.scheduledCommands = [];
      this.missedScheduledCommands = [];
      this.replyBanner = {
        text: count > 0 ? t("已取消 {count} 项定时指令", { count: count }) : t("当前没有待执行的定时指令"),
        source: t("0ms 本地直达"),
      };
      this.render();
      return;
    }

    if (!fromScheduled) {
      const delaySpec = DelayPhrase.extract(trimmed);
      if (delaySpec) {
        const scheduled: ScheduledCommand = {
          id: `${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
          command: delaySpec.remainder,
          delaySeconds: delaySpec.seconds,
          fireTimestampMs: Date.now() + delaySpec.seconds * 1000,
          reply: t("{delay}后：{command}", { delay: DelayPhrase.formatDelay(delaySpec.seconds), command: delaySpec.remainder }),
        };
        this.scheduledCommands.push(scheduled);
        this.replyBanner = {
          text: t("已设定 {delay}后执行「{command}」", { delay: DelayPhrase.formatDelay(delaySpec.seconds), command: delaySpec.remainder }),
          source: t("定时任务"),
        };
        this.render();
        return;
      }
    }

    const learnedMatch = this.settings.learnedShortcuts.find(
      (s) => s.phrase.replace(/\s+/g, "") === trimmed.replace(/\s+/g, ""),
    );
    if (learnedMatch) {
      // A timer firing a learned phrase is not a user action, so it never trains habits (#34/#113).
      await this.executeIntents(learnedMatch.intents, learnedMatch.reply, t("习惯记忆 0ms"), { recordHabits: !fromScheduled });
      return;
    }

    this.isResolvingIntent = true;
    this.render();

    try {
      const aliasedDevices = withAliases(this.layout, this.devices);
      const localPlan = LocalIntentParser.parse(trimmed, aliasedDevices, this.scenes);
      let plan: IntentPlan | null = localPlan;
      let sourceLabel = t("0ms 本地直达");

      if (!plan) {
        const baseURL = this.settings.assistantBaseURL.trim() || "https://openrouter.ai/api/v1";
        const apiKey = this.apiKeyFor(baseURL);
        const isLoopback = isLocalAssistantEndpoint(baseURL);
        if (!endpointAllowsSendingSecrets(baseURL)) {
          this.replyBanner = { text: INSECURE_ENDPOINT_MESSAGE, source: t("地址不安全"), isError: true };
          this.isResolvingIntent = false;
          this.render();
          return;
        }
        if (!apiKey && !isLoopback) {
          this.replyBanner = {
            text: t("未命中本地规则。请在设置中填写 AI 服务的 API Key（支持 OpenRouter Jev、原生 Jev、DeepSeek 等）。"),
            source: t("需要 API Key"),
            isError: true,
          };
          this.isResolvingIntent = false;
          this.render();
          return;
        }
        const endpoint = assistantEndpointIdentity(baseURL);
        if (!isLoopback && endpoint && !this.settings.cloudConsentEndpoints.includes(endpoint)) {
          this.pendingCloudConsent = { utterance: trimmed, endpoint };
          this.replyBanner = {
            text: t("这句话本机没听懂，要交给云端 AI（{endpoint}）处理吗？会发送：这句话、设备名称/房间/状态。只问这一次，可在设置里撤销。", { endpoint: endpoint }),
            source: t("需要确认"),
          };
          this.isResolvingIntent = false;
          this.render();
          return;
        }
        const resolver = new ModelIntentResolver(
          {
            baseURL,
            model: this.settings.assistantModel,
            apiKey,
          },
          this.transport,
        );
        // Same ambient context macOS sends with Jev requests (#38); the getter falls
        // back to sensor devices when no refreshed EnvironmentReading list exists.
        const readings = this.computedEnvironmentReadings;
        const context = buildAssistantContext({
          now: new Date(),
          readings,
          devices: aliasedDevices,
          scenes: this.scenes,
          sharing: this.settings.habitShareEnabled ? "on" : "off",
          memory: new UserHabitMemory(this.settings.habitEntries, this.habitSequences(), this.lastHabitAction()),
          phrases: this.settings.learnedShortcuts.map((shortcut) => ({
            phrase: shortcut.phrase,
            intents: shortcut.intents,
          })),
          mention: { kind: "utterance", text: trimmed },
        });
        plan = await resolver.resolve(trimmed, aliasedDevices, this.scenes, context);
        if (sourceRevision !== this.sourceRevision) return;
        sourceLabel = resolver.usesSystemOne ? "Jev SystemOne" : this.settings.assistantModel;
      }

      const sanitized = IntentValidator.sanitize(plan.intents, aliasedDevices, this.scenes);
      this.pendingSuggestions = [...plan.suggestions];
      if (sanitized.length === 0 && plan.suggestions.length > 0) {
        this.replyBanner = { text: plan.reply || ModelActionPolicy.confirmationReply(null), source: t("需要确认") };
        return;
      }
      if (sanitized.length === 0) {
        this.replyBanner =
          plan.intents.length > 0
            ? { text: t("无法找到指令对应的设备"), source: t("控制失败"), isError: true }
            : { text: plan.reply || t("无法找到指令对应的设备"), source: sourceLabel, isError: !plan.reply };
        return;
      }
      const replyText =
        plan.reply || IntentReply.describe(sanitized, aliasedDevices, this.scenes);
      const succeeded = await this.executeIntents(sanitized, replyText, sourceLabel, {
        recordHabits: plan.source === "local" && !fromScheduled,
      });
      if (sourceRevision !== this.sourceRevision) return;

      if (
        succeeded &&
        this.settings.habitLearningEnabled &&
        plan.source === "model" &&
        sanitized.length > 0
      ) {
        this.learnShortcut(trimmed, replyText, sanitized);
      }
    } catch (err) {
      if (sourceRevision !== this.sourceRevision) return;
      const msg = err instanceof Error ? err.message : String(err);
      this.replyBanner = {
        text: msg,
        source: t("出错提示"),
        isError: true,
      };
    } finally {
      if (sourceRevision === this.sourceRevision) {
        this.isResolvingIntent = false;
        this.render();
      }
    }
  }

  private learnShortcut(
    phrase: string,
    reply: string,
    intents: readonly DeviceIntent[],
  ): void {
    const clean = phrase.trim();
    if (clean.length < 2 || clean.length > 18) return;
    if (this.settings.learnedShortcuts.some((s) => s.phrase === clean)) return;
    this.settings.learnedShortcuts.unshift({
      phrase: clean,
      reply,
      intents,
      learnedAt: new Date().toISOString(),
    });
    if (this.settings.learnedShortcuts.length > 25) {
      this.settings.learnedShortcuts.length = 25;
    }
    this.saveSettings();
  }

  private buildInverseCommand(dev: SmartDevice, command: DeviceCommand): DeviceCommand[] {
    const k = dev.kind;
    switch (command.kind) {
      case "setLightPower":
        return k.kind === "light" ? [{ kind: "setLightPower", entityId: k.entityId, isOn: k.isOn }] : [];
      case "setLightBrightness":
        return k.kind === "light" && k.brightnessPercent !== null ? [
          { kind: "setLightBrightness", entityId: k.entityId, percent: k.brightnessPercent },
          { kind: "setLightPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setLightColorTemp":
        return k.kind === "light" && k.colorTempKelvin !== null ? [
          { kind: "setLightColorTemp", entityId: k.entityId, kelvin: k.colorTempKelvin },
          ...(k.currentEffect !== null ? [{ kind: "setLightEffect" as const, entityId: k.entityId, effect: k.currentEffect }] : []),
          { kind: "setLightPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setLightEffect":
        if (k.kind !== "light") return [];
        if (k.currentEffect !== null) return [
          { kind: "setLightEffect", entityId: k.entityId, effect: k.currentEffect },
          { kind: "setLightPower", entityId: k.entityId, isOn: k.isOn },
        ];
        return k.colorTempKelvin !== null ? [
          { kind: "setLightColorTemp", entityId: k.entityId, kelvin: k.colorTempKelvin },
          { kind: "setLightPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setClimatePower":
      case "setClimateMode":
        return k.kind === "climate" ? [{ kind: "setClimateMode", entityId: k.entityId, hvacMode: k.isOn ? k.hvacMode : "off" }] : [];
      case "setClimateTemperature":
        return k.kind === "climate" ? [
          { kind: "setClimateTemperature", entityId: k.entityId, temperature: k.targetTemperature },
          { kind: "setClimatePower", entityId: k.entityId, isOn: k.isOn, resumeMode: k.hvacMode },
        ] : [];
      case "setClimateFanMode":
        return k.kind === "climate" && k.fanMode !== null ? [{ kind: "setClimateFanMode", entityId: k.entityId, fanMode: k.fanMode }] : [];
      case "setFanPower":
        return k.kind === "fan" ? [{ kind: "setFanPower", entityId: k.entityId, isOn: k.isOn }] : [];
      case "setFanPercentage":
        return k.kind === "fan" && k.percentage !== null ? [
          { kind: "setFanPercentage", entityId: k.entityId, percent: k.percentage },
          ...(k.presetMode !== null ? [{ kind: "setFanPresetMode" as const, entityId: k.entityId, presetMode: k.presetMode }] : []),
          { kind: "setFanPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setFanPresetMode":
        return k.kind === "fan" && k.presetMode !== null ? [
          { kind: "setFanPresetMode", entityId: k.entityId, presetMode: k.presetMode },
          { kind: "setFanPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setFanOscillating":
        return k.kind === "fan" && k.isOscillating !== null ? [
          { kind: "setFanOscillating", entityId: k.entityId, oscillating: k.isOscillating },
          { kind: "setFanPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setSwitch":
        if (k.kind === "plug") {
          if (command.entityId.startsWith("button.")) return [];
          return [{ kind: "setSwitch", entityId: command.entityId, isOn: command.entityId === k.childLockEntityId ? k.isChildLocked : k.isOn }];
        }
        if (k.kind === "camera") {
          const prevOn = command.entityId === k.motionDetectionEntityId ? Boolean(k.isMotionDetectionOn) : k.isOn;
          return [{ kind: "setSwitch", entityId: command.entityId, isOn: prevOn }];
        }
        return [];
      case "setSelectOption":
        if (k.kind === "camera" && k.nightShot !== null) {
          return [{ kind: "setSelectOption", entityId: command.entityId, option: k.nightShot }];
        }
        if (k.kind === "fridge") {
          return [{ kind: "setSelectOption", entityId: command.entityId, option: k.currentMode }];
        }
        return [];
      case "setNumberValue":
        if (k.kind === "fridge") {
          if (command.entityId === k.fridgeTargetEntityId) {
            return [{ kind: "setNumberValue", entityId: command.entityId, value: k.fridgeTargetTemp }];
          }
          if (command.entityId === k.freezerTargetEntityId) {
            return [{ kind: "setNumberValue", entityId: command.entityId, value: k.freezerTargetTemp }];
          }
        }
        return [];
      case "vacuumAction":
      case "activateScene":
        return [];
      default: {
        const exhaustive: never = command;
        return exhaustive;
      }
    }
  }

  public async executeIntents(
    intents: readonly DeviceIntent[],
    replyText: string,
    sourceLabel: string,
    options: { recordHabits?: boolean } = {},
  ): Promise<boolean> {
    const sourceRevision = this.sourceRevision;
    const commands: Array<{ deviceId: string; command: DeviceCommand; intentIndex: number }> = [];
    const candidateIntents: Array<{ intent: DeviceIntent; commandCount: number; succeededCount: number }> = [];
    let failed = 0;
    let failureMessage = "";
    for (const intent of intents) {
      if (intent.operation.kind === "activateScene") {
        const scene = this.scenes.find((s) => s.id === intent.targetId);
        if (scene) {
          const intentIndex = candidateIntents.length;
          candidateIntents.push({ intent, commandCount: 1, succeededCount: 0 });
          commands.push({ deviceId: scene.id, command: { kind: "activateScene", entityId: scene.entityId }, intentIndex });
        }
        continue;
      }
      const dev = this.devices.find((d) => d.id === intent.targetId);
      if (!dev) continue;
      if (!dev.isOnline) {
        failed += 1;
        failureMessage = `${dev.name} (${t("离线")})`;
        continue;
      }
      const intentCommands = IntentValidator.commandsForIntent(intent, dev);
      if (intentCommands.length === 0) {
        failed += 1;
        failureMessage = t("无法找到指令对应的设备");
        continue;
      }
      const intentIndex = candidateIntents.length;
      candidateIntents.push({ intent, commandCount: intentCommands.length, succeededCount: 0 });
      for (const command of intentCommands) {
        commands.push({ deviceId: dev.id, command, intentIndex });
      }
    }

    const steps: UndoStep[] = [];
    let succeeded = 0;
    let canUndo = true;
    for (const { deviceId, command, intentIndex } of commands) {
      if (sourceRevision !== this.sourceRevision) return false;
      // Scenes have no device row and no inverse; they simply run and count as applied (#113).
      if (command.kind === "activateScene") {
        if (await this.applyCommand(command)) {
          succeeded += 1;
          const entry = candidateIntents[intentIndex];
          if (entry) entry.succeededCount += 1;
        } else {
          failed += 1;
          failureMessage = this.replyBanner?.text ?? "设备未响应";
        }
        continue;
      }
      const device = this.devices.find((d) => d.id === deviceId);
      if (!device) {
        failed += 1;
        failureMessage = t("设备列表已更新，请重新执行");
        continue;
      }
      const isMomentaryButton = command.kind === "setSwitch" && command.entityId.startsWith("button.");
      const inverseCommands = isMomentaryButton ? [] : this.buildInverseCommand(device, command);
      if (await this.applyCommand(command)) {
        succeeded += 1;
        const entry = candidateIntents[intentIndex];
        if (entry) entry.succeededCount += 1;
        if (!isMomentaryButton) {
          canUndo = canUndo && inverseCommands.length > 0;
          if (inverseCommands.length > 0) {
            steps.unshift({ deviceId, commands: inverseCommands });
          }
        }
      } else {
        failed += 1;
        failureMessage = this.replyBanner?.text ?? "设备未响应";
      }
    }
    if (sourceRevision !== this.sourceRevision) return false;
    if (succeeded > 0) {
      if (failed === 0) this.grokBallCelebrationUntil = Date.now() + 2400;
      const succeededIntents = candidateIntents
        .filter((entry) => entry.succeededCount === entry.commandCount && entry.commandCount > 0)
        .map((entry) => entry.intent);
      // Only explicit user asks train habits, and only for intents that actually succeeded (#34/#113/#116).
      const habitReceipt = options.recordHabits && succeededIntents.length > 0 ? this.recordHabits(succeededIntents) : null;
      // Scene activations have no inverse: an undo action must exist only when at least one
      // device step is restorable, otherwise Undo would report success without doing anything
      // (Codex #116 re-review).
      this.lastUndoAction = canUndo && steps.length > 0 ? {
        summary: replyText,
        steps,
        expiresAtMs: Date.now() + 10 * 60 * 1000,
        habitReceipt: habitReceipt ?? undefined,
      } : null;
    }
    if (succeeded === 0 && failed === 0) {
      this.replyBanner = { text: t("无法找到指令对应的设备"), source: t("控制失败"), isError: true };
      this.render();
      return false;
    }
    this.replyBanner = failed > 0
      ? { text: t("已执行 {ok} 项，{failed} 项失败。{message}", { ok: succeeded, failed: failed, message: failureMessage }), source: t("控制失败"), isError: true }
      : { text: replyText, source: sourceLabel };
    this.render();
    return failed === 0;
  }

  public async executeSingleCommand(
    device: SmartDevice,
    command: DeviceCommand,
    summary: string,
    intent?: DeviceIntent,
    readBackPower = false,
  ): Promise<void> {
    const sourceRevision = this.sourceRevision;
    const inverseCommands = this.buildInverseCommand(device, command);
    if (!(await this.applyCommand(command, readBackPower))) return;
    if (sourceRevision !== this.sourceRevision) return;
    // Momentary buttons (Wake-on-LAN) complete without reporting an on/off state to compare.
    const isMomentaryButton = command.kind === "setSwitch" && command.entityId.startsWith("button.");
    if (readBackPower && !isMomentaryButton && !this.readBackMatches(device.id, intent)) {
      this.replyBanner = { text: t("未能读回设备状态"), source: t("控制失败"), isError: true };
      this.render();
      return;
    }
    this.grokBallCelebrationUntil = Date.now() + 2400;
    const habitReceipt = intent ? this.recordHabits([intent]) : null;
    this.lastUndoAction = inverseCommands.length > 0 ? {
      summary,
      steps: [{ deviceId: device.id, commands: inverseCommands }],
      expiresAtMs: Date.now() + 10 * 60 * 1000,
      habitReceipt: habitReceipt ?? undefined,
    } : null;
    this.replyBanner = { text: summary, source: t("实时控制") };
    this.render();
  }

  private readBackMatches(deviceId: string, intent?: DeviceIntent): boolean {
    if (!intent || intent.operation.kind !== "power") return true;
    const current = this.devices.find((item) => item.id === deviceId);
    return current !== undefined && isDeviceActiveOn(current) === intent.operation.isOn;
  }

  /** Records manual card actions into the habit memory for the current time bucket (#113). */
  private recordHabits(intents: readonly DeviceIntent[]): HabitRecordingReceipt | null {
    if (!this.settings.habitLearningEnabled || intents.length === 0) return null;
    const memory = new UserHabitMemory(this.settings.habitEntries, this.habitSequences(), this.lastHabitAction());
    const receipt = memory.record(intents, this.devices, this.scenes, new Date());
    if (receipt) this.saveHabitMemory(memory);
    return receipt;
  }

  /** Sequence entries and lastAction persist alongside the entries (ADR-0009). */
  public habitSequences(): HabitSequenceEntry[] {
    const raw = localStorage.getItem("menumijia.windows.habit.sequences.v1");
    if (!raw) return [];
    try {
      const parsed = JSON.parse(raw) as { sequences?: HabitSequenceEntry[]; lastAction?: HabitLastAction | null };
      return Array.isArray(parsed.sequences) ? parsed.sequences : [];
    } catch {
      return [];
    }
  }

  public lastHabitAction(): HabitLastAction | null {
    const raw = localStorage.getItem("menumijia.windows.habit.sequences.v1");
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw) as { lastAction?: HabitLastAction | null };
      return parsed.lastAction ?? null;
    } catch {
      return null;
    }
  }

  private saveHabitMemory(memory: UserHabitMemory): void {
    this.settings.habitEntries = [...memory.entries];
    this.saveSettings();
    try {
      localStorage.setItem("menumijia.windows.habit.sequences.v1", JSON.stringify({
        sequences: memory.sequences,
        lastAction: memory.lastAction,
      }));
    } catch {
      // Quota errors only cost the sequence context, never the entries.
    }
  }

  private unrecordHabits(receipt: HabitRecordingReceipt): void {
    const memory = new UserHabitMemory(this.settings.habitEntries, this.habitSequences(), this.lastHabitAction());
    memory.unrecord(receipt);
    this.saveHabitMemory(memory);
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

  private syncGrokBallEmotion(): void {
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

  private renderGrokBallSidebar(): string {
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
  private maybeRefreshProactiveInBackground(): void {
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

  private async applyCommand(command: DeviceCommand, readBackPower = false): Promise<boolean> {
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

  private formatRemainingMs(ms: number): string {
    const secs = Math.max(0, Math.ceil(ms / 1000));
    if (secs >= 60) {
      const m = Math.floor(secs / 60);
      const s = secs % 60;
      return s > 0 ? `${m}分${s}秒` : `${m}分钟`;
    }
    return `${secs}秒`;
  }

  private get statusSummaryText(): string {
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
    const isDemo = this.settings.connectionMode === "demo";
    const activeUndo =
      this.lastUndoAction && this.lastUndoAction.expiresAtMs > Date.now()
        ? this.lastUndoAction
        : null;
    const scheme = this.effectiveAppearance;
    this.root.dataset.scheme = scheme;
    this.root.classList.toggle("is-grok-enabled", this.settings.enableGrokBall);
    this.root.classList.toggle("is-grok-expanded", this.settings.enableGrokBall && this.isGrokBallStageExpanded);
    this.root.classList.toggle("is-native-host", Boolean(window.__TAURI_INTERNALS__));
    this.root.dataset.grokSide = this.grokBallOnLeft ? "left" : "right";
    const popoverClass = `cc-popover skin-${this.skin} scheme-${scheme} ${this.skin === "classic" ? "" : "is-skinned"} ${this.isEditingLayout ? "is-editing" : ""}`.trim();
    const innerContent = `
        <header class="cc-header">
          <div class="cc-header-top">
            <div class="cc-title-group">
              <div class="cc-home-emblem" aria-hidden="true">${SF_ICONS.houseFill}</div>
              <div class="cc-title-stack">
                <div class="cc-title-row">
                  ${
                    this.homes.length > 1
                      ? `<button class="cc-home-switch" id="btn-home-menu" aria-expanded="${this.isHomeMenuOpen}" aria-label="${t("切换家庭")}">
                          <span class="cc-home-title">${this.escapeHtml(this.homeTitle)}</span>
                          <span class="cc-home-caret ${this.isHomeMenuOpen ? "is-open" : ""}">${SF_ICONS.chevronDown}</span>
                        </button>`
                      : `<span class="cc-home-title">${this.escapeHtml(this.homeTitle)}</span>`
                  }
                  <span class="cc-mode-pill ${isDemo ? "is-demo" : "is-cloud"}">
                    ${isDemo ? t("演示预览") : this.settings.connectionMode === "homeAssistant" ? "Home Assistant" : t("Miot 直连")}
                  </span>
                </div>
                <div class="cc-subtitle">${this.escapeHtml(this.isEditingLayout ? t("拖动卡片排序 · 点右下角圆弧手柄改大小") : this.statusSummaryText)}</div>
              </div>
            </div>

            <div class="cc-header-controls">
              <button
                class="cc-circle-btn ${this.isListeningVoice ? "is-recording" : ""}"
                id="btn-mic"
                title="${t("语音控制")}"
                aria-label="${t("语音控制")}"
                aria-pressed="${this.isListeningVoice}"
              >
                ${SF_ICONS.micFill}
              </button>
              <button
                class="cc-circle-btn ${this.isShowingAssistantBar ? "is-selected" : ""}"
                id="btn-toggle-assistant"
                title="${t("AI 自然语言指令栏 (/)")}"
                aria-label="${t("AI 自然语言指令栏")}"
                aria-pressed="${this.isShowingAssistantBar}"
              >
                ${SF_ICONS.sparkles}
              </button>
              ${this.renderAllOffControl()}
              <button
                class="cc-circle-btn"
                id="btn-hide-panel"
                title="${t("收起面板到右下角托盘 (Esc)")}"
                aria-label="${t("收起面板")}"
              >
                ${SF_ICONS.chevronDown}
              </button>
            </div>
          </div>

          ${this.renderEnvironmentStrip()}
        </header>

        ${
          this.isShowingAssistantBar
            ? `
          <section class="cc-assistant-section">
            <div class="cc-spotlight-bar">
              <span class="cc-spotlight-icon">${SF_ICONS.sparkles}</span>
              <input
                id="command-input"
                class="cc-spotlight-input"
                type="text"
                placeholder="${t("说一句：我困了 / 调低两度 / 10分钟后关灯 / 撤销...")}"
                aria-label="${t("自然语言指令")}"
                ${this.isResolvingIntent ? "disabled" : ""}
              />
              <button
                id="btn-send"
                class="cc-spotlight-send"
                title="${t("执行指令 (Enter)")}"
                aria-label="${t("执行指令")}"
                ${this.isResolvingIntent ? "disabled" : ""}
              >
                ${SF_ICONS.arrowUpCircle}
              </button>
            </div>

            ${
              this.replyBanner ||
              this.scheduledCommands.length > 0 ||
              this.missedScheduledCommands.length > 0 ||
              activeUndo ||
              this.pendingSuggestions.length > 0
                ? `
              <div class="cc-feedback-card ${this.replyBanner?.isError ? "is-error" : ""}">
                ${
                  this.replyBanner
                    ? `
                  <div class="cc-feedback-row">
                    <span class="cc-feedback-badge">${this.escapeHtml(this.replyBanner.source)}</span>
                    <span class="cc-feedback-text">${this.escapeHtml(this.replyBanner.text)}</span>
                    ${
                      this.pendingCloudConsent
                        ? `<button class="cc-inline-pill" id="btn-cloud-allow">${t("允许并发送")}</button>
                           <button class="cc-inline-pill" id="btn-cloud-decline">${t("不用了")}</button>`
                        : ""
                    }
                    ${
                      activeUndo
                        ? `<button class="cc-inline-pill" id="btn-undo">${t("撤销")}</button>`
                        : ""
                    }
                  </div>
                `
                    : ""
                }
                ${
                  this.pendingSuggestions.length > 0
                    ? `
                  <div class="cc-suggestion-row">
                    ${this.pendingSuggestions
                      .map(
                        (item) => `<button class="cc-inline-pill" data-suggestion-id="${this.escapeHtml(item.id)}">${this.escapeHtml(item.title)}${
                          item.confidencePercent !== null ? ` · ${item.confidencePercent}%` : ""
                        }</button>`,
                      )
                      .join("")}
                  </div>
                `
                    : ""
                }
                ${
                  this.missedScheduledCommands.length > 0
                    ? `
                  <div class="cc-timers-stack">
                    ${this.missedScheduledCommands
                      .map(
                        (item) => `
                      <div class="cc-timer-row">
                        <span>${t("已错过定时：{command}（电脑睡眠时到点，没有自动执行）", { command: this.escapeHtml(item.command) })}</span>
                        <button class="cc-inline-pill" data-run-missed="${item.id}">立即执行</button>
                        <button class="cc-inline-pill" data-dismiss-missed="${item.id}">忽略</button>
                      </div>
                    `,
                      )
                      .join("")}
                  </div>
                `
                    : ""
                }
                ${
                  this.scheduledCommands.length > 0
                    ? `
                  <div class="cc-timers-stack">
                    ${this.scheduledCommands
                      .map(
                        (item) => `
                      <div class="cc-timer-row">
                        <span>${this.escapeHtml(item.command)} ${t("· 剩余 {remaining}", { remaining: this.formatRemainingMs(item.fireTimestampMs - Date.now()) })}</span>
                        <button class="cc-inline-pill" data-cancel-timer="${item.id}">取消</button>
                      </div>
                    `,
                      )
                      .join("")}
                  </div>
                `
                    : ""
                }
              </div>
            `
                : ""
            }
          </section>
        `
            : ""
        }

        ${this.haConnectionError ? `<div class="cc-feedback-card is-error" role="alert" data-ha-error><span class="cc-feedback-badge">Home Assistant</span><span class="cc-feedback-text">${this.escapeHtml(this.haConnectionError)}</span></div>` : ""}

        ${
          this.settings.showQuickActionsBar
            ? `<section class="cc-quick-strip">
          ${quickActions().map(
            (act) => `
            <button class="cc-quick-pill tint-${act.tint}" data-scene-cmd="${this.escapeHtml(act.command)}">
              <span class="cc-quick-icon">${act.icon}</span>
              <span>${this.escapeHtml(act.title)}</span>
            </button>
          `,
          ).join("")}
          ${this.settings.connectionMode === "homeAssistant" ? this.scenes.map((scene) => `<button class="cc-quick-pill tint-blue" data-ha-scene="${this.escapeHtml(scene.id)}"><span class="cc-quick-icon">${SF_ICONS.sparkles}</span><span>${this.escapeHtml(scene.name)}</span></button>`).join("") : ""}
        </section>`
            : ""
        }


        <div class="cc-room-bar">
          <div class="cc-room-track">
          <div class="cc-room-scroll">
            ${this.rooms
              .map(
                (room) => {
                  const pressed = room === "全部" ? this.listCut.kind === "all" : this.selectedRoom === room;
                  return `
              <button
                class="cc-room-pill ${pressed ? "is-active" : ""}"
                data-room="${this.escapeHtml(room)}"
                aria-pressed="${pressed}"
              >
                ${this.escapeHtml(room === "全部" ? t("全部") : room)}
              </button>
            `;
                },
              )
              .join("")}
          </div>
          </div>
          <div class="cc-room-tools">
          <button
            class="cc-circle-btn is-small"
            id="btn-toggle-grid"
            title="${this.settings.isCompactGridMode ? t("切换为单列详情视图") : t("切换为双列控制中心磁贴")}"
            aria-label="${this.settings.isCompactGridMode ? t("切换为单列详情视图") : t("切换为双列控制中心磁贴")}"
            aria-pressed="${this.settings.isCompactGridMode}"
          >
            ${this.settings.isCompactGridMode ? SF_ICONS.grid2x2 : SF_ICONS.grid1x2}
          </button>
          <button
            class="cc-circle-btn is-small ${this.settings.hideOfflineDevices ? "is-selected" : ""}"
            id="btn-toggle-hide-offline"
            title="${this.settings.hideOfflineDevices ? t("当前只显示在线设备（点击显示全部）") : t("点击隐藏未通电/离线设备")}"
            aria-label="${t("只显示在线设备")}"
            aria-pressed="${this.settings.hideOfflineDevices}"
          >
            ${this.settings.hideOfflineDevices ? SF_ICONS.wifi : SF_ICONS.wifiSlash}
          </button>
          </div>
        </div>
        ${this.renderKindBar()}

        <div class="cc-divider"></div>

        <main class="cc-scroll-area">
          ${this.renderDeviceGrid()}
        </main>

        <div class="cc-divider"></div>

        <footer class="cc-footer">
          <div class="cc-footer-status">
            <span class="cc-status-dot ${this.isSyncingCloud ? "is-syncing" : this.settings.connectionMode === "homeAssistant" ? (this.haConnectionError || !this.settings.haBaseURL || !this.settings.haToken ? "is-demo" : "is-online") : isDemo ? "is-demo" : "is-online"}"></span>
            <span class="cc-footer-label">
              ${
                this.settings.connectionMode === "xiaomiCloud" && this.settings.miSession
                  ? t("米家账号 {user} · {count} 台设备", { user: maskedMiUserId(this.settings.miSession.userId), count: this.devices.length })
                  : this.settings.connectionMode === "homeAssistant" ? `Home Assistant · ${this.devices.length}` : t("演示模式 · 未连接米家云")
              }
            </span>
          </div>

          <div class="cc-footer-actions">
            ${
              this.availableUpdate
                ? `<button class="cc-footer-pill is-accent" id="btn-footer-update" title="${t("发现新版本 v{version}", { version: this.availableUpdate.version })}">
                    <span>${t("更新 v{version}", { version: this.availableUpdate.version })}</span>
                  </button>`
                : ""
            }
            ${
              this.settings.connectionMode !== "homeAssistant" && (!this.settings.miSession || isDemo)
                ? `<button class="cc-footer-pill is-accent" id="btn-footer-qr" title="${t("用手机米家 App 扫码直连真实设备")}">
                    ${SF_ICONS.qrcode}
                    <span>${t("扫码直连")}</span>
                  </button>`
                : ""
            }
            <button
              class="cc-footer-icon-btn"
              id="btn-toggle-appearance"
              title="${scheme === "light" ? t("切换深色模式") : t("切换浅色模式")}"
              aria-label="${scheme === "light" ? t("切换深色模式") : t("切换浅色模式")}"
            >
              ${scheme === "light" ? SF_ICONS.moonStarsFill : SF_ICONS.sunMaxFill}
            </button>
            <button
              class="cc-footer-icon-btn ${this.isSyncingCloud ? "is-spinning" : ""}"
              id="btn-refresh"
              title="${t("立即同步最新设备状态")}"
              aria-label="${t("立即同步最新设备状态")}"
            >
              ${SF_ICONS.arrowClockwise}
            </button>
            <button
              class="cc-footer-icon-btn"
              id="btn-settings"
              title="${t("连接设置与 AI 决策配置")}"
              aria-label="${t("打开设置")}"
            >
              ${SF_ICONS.sliderHorizontal}
            </button>
            <button
              class="cc-footer-pill is-danger"
              id="btn-quit-app"
              title="${t("完全退出 MenuBarMijia")}"
            >
              ${SF_ICONS.power}
              <span>${t("退出")}</span>
            </button>
          </div>
        </footer>

        ${this.activeSheet === "onboarding" ? this.renderOnboardingModal() : ""}
        ${this.activeSheet === "settings" ? this.renderSettingsModal() : ""}
        ${this.cameraLive.activeLiveCameraId !== null ? this.cameraLive.renderCameraLiveModal() : ""}
        ${this.renderHomeMenu()}
        ${this.renderContextMenu()}
        ${this.renderPrompt()}
    `;
    const existingPopover = this.root.querySelector<HTMLElement>(":scope > .cc-popover");
    if (existingPopover) {
      if (existingPopover.className !== popoverClass) {
        existingPopover.className = popoverClass;
      }
      existingPopover.innerHTML = innerContent;
    } else {
      this.root.innerHTML = `<div class="${popoverClass}">${innerContent}</div>`;
    }
    this.root.querySelector(":scope > .cc-grok-sidebar")?.remove();
    this.root.insertAdjacentHTML("beforeend", this.renderGrokBallSidebar());

    this.bindEvents();
  }

  private renderEnvironmentStrip(): string {
    return renderEnvironmentStripView({
      readings: this.computedEnvironmentReadings,
      watts: this.totalPowerWatts,
      valuesAreStale: this.valuesAreStale,
      escapeHtml: (v) => this.escapeHtml(v),
    });
  }

  private renderDeviceGrid(): string {
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

  private renderHomeMenu(): string {
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

  private renderContextMenu(): string {
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

  private renderPrompt(): string {
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

  private renderOnboardingModal(): string {
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

  private renderSettingsModal(): string {
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

  private bindEvents(): void {
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
  private syncPanelPlacement(): void {
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
