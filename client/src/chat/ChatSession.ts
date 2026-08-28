import type { BrowserAudioRuntime } from "../audio/BrowserAudioRuntime";
import type { LiveAudioClient, LiveAudioControl } from "../audio/LiveAudio";
import { keepMicrophoneOpenBetweenTurns } from "../audio/MicrophonePolicy";
import { Er } from "../core/Er";
import { JsonObject } from "../core/Json";
import type {
    ChatTransport,
    ChatBranchPoint,
    ModelCatalog,
    ModelInfo,
    RecentSessionSummary,
    ReasoningMode,
    SessionChoice,
    SessionStartResult,
    StoredTurn,
    SessionBranchResult,
    StartupState,
    TextTurnHandlers,
    TextTurnResult,
    ToolDetail,
    ToolIndicator,
    UserImage,
    WebImageReference,
    ConversationEventEnvelope,
    ConversationAccepted,
    PresentationSnapshot,
} from "../transport/ChatTransport";
import { reasoningModes } from "../transport/ChatTransport";
import {
    parseGeneratedImage,
    parseConversationAccepted,
    parseConversationFailure,
    parseReasoningEvent,
    parseTextTurnResult,
    parseTokenMessage,
    parseToolMessage,
} from "../transport/WheatleyJson";
import { uiText } from "../ui/UiText";
import type { ChatMessage } from "./ChatMessage";
import type { ChatSpeech, ChatSpeechState } from "./ChatSpeech";
import type { ChatLanguage } from "./Language";
import { ChatTranscript } from "./ChatTranscript";
import type { ActiveChatActivity } from "./ChatTranscript";

export type SessionPhase =
    | "launcher"
    | "loading"
    | "starting"
    | "preparing"
    | "ready"
    | "requesting-live-microphone"
    | "live-listening"
    | "live-transcribing"
    | "scheduled-yield"
    | "streaming"
    | "stopping";

export type ChatPanel = "home" | "chat";

export interface ChatSessionSnapshot {
    readonly profileId: string;
    readonly phase: SessionPhase;
    readonly panel: ChatPanel;
    readonly hasOpenChat: boolean;
    readonly canSwitchChats: boolean;
    readonly hasDeletableChat: boolean;
    readonly canDeleteChat: boolean;
    readonly canCompactNow: boolean;
    readonly compacting: boolean;
    readonly currentSessionId?: string;
    readonly language: ChatLanguage;
    readonly supportedLanguages: readonly ChatLanguage[];
    readonly recentSessions: readonly RecentSessionSummary[];
    readonly recentSessionsLoading: boolean;
    readonly messages: readonly ChatMessage[];
    readonly activeActivity?: ActiveChatActivity;
    readonly speech: ChatSpeechState;
    readonly playMusic: boolean;
    readonly keepMicrophoneOn: boolean;
    readonly musicTitle?: string;
    readonly reasoningMode: ReasoningMode;
    readonly modelId: string;
    readonly models: readonly ModelInfo[];
    readonly pendingImage?: UserImage;
    readonly visionRequired: boolean;
    readonly error?: string;
    /** Changes for every displayed error so views can restart its dismissal animation. */
    readonly errorVersion?: number;
}

type Listener = () => void;
type SaveLanguagePreference = (language: ChatLanguage) => void;
type SaveMusicPreference = (enabled: boolean) => void;
type SaveKeepMicrophonePreference = (enabled: boolean) => void;
type SaveReasoningPreference = (reasoningMode: ReasoningMode) => void;
type SaveModelPreference = (modelId: string) => void;
type ScheduledTaskCreated = (taskId: string) => void;

const errorVisibleDurationMs = 6_000;
const errorFadeDurationMs = 200;
const observerReconnectDelayMs = 500;

export class ChatSession {
    readonly #transport: ChatTransport;
    readonly #liveAudio: LiveAudioClient;
    readonly #audio: BrowserAudioRuntime;
    readonly #speech: ChatSpeech;
    readonly #deviceId: string;
    readonly #saveLanguagePreference: SaveLanguagePreference;
    readonly #saveMusicPreference: SaveMusicPreference;
    readonly #saveKeepMicrophonePreference: SaveKeepMicrophonePreference;
    readonly #saveReasoningPreference: SaveReasoningPreference;
    readonly #saveModelPreference: SaveModelPreference;
    readonly #onScheduledTaskCreated: ScheduledTaskCreated;
    readonly #models: readonly ModelInfo[];
    readonly #transcript = new ChatTranscript();
    readonly #listeners = new Set<Listener>();
    #profileId: string;
    #language: ChatLanguage;
    #supportedLanguages: readonly ChatLanguage[];
    #recentSessions: readonly RecentSessionSummary[] = [];
    #recentSessionsLoading = false;
    #recentRequestId = 0;
    #startupGeneration = 0;
    #startupTask: Promise<void> | undefined;
    #phase: SessionPhase = "launcher";
    #panel: ChatPanel = "home";
    #activeTurnId: string | undefined;
    #sessionId: string | undefined;
    #preparationComplete = false;
    #error: string | undefined;
    #errorVersion = 0;
    #errorTimeout: ReturnType<typeof setTimeout> | undefined;
    #playMusic: boolean;
    #keepMicrophoneOn: boolean;
    #chatMusicPlaying = false;
    #reasoningMode: ReasoningMode = "off";
    #modelId: string;
    #liveMode = false;
    #liveControl: LiveAudioControl | undefined;
    readonly #liveControls = new Set<LiveAudioControl>();
    readonly #localLiveTurnIds = new Map<string, string>();
    #resumeLiveAfterScheduledYield = false;
    #codexEventsAbort: AbortController | undefined;
    #sessionTurnsAbort: AbortController | undefined;
    #restoringPresentation = false;
    #pendingImageFile: File | undefined;
    #pendingImage: UserImage | undefined;
    #visionRequired = false;
    #compacting = false;
    #branching = false;
    #scheduledYieldTurnId: string | undefined;
    #scheduledYieldCompletion: (() => void) | undefined;
    readonly #externalScheduledModels = new Map<string, string>();
    readonly #externalScheduledTranscriptTurns = new Set<string>();
    readonly #externalScheduledSpeechTurns = new Set<string>();
    readonly #externalConversationSequences = new Map<string, number>();
    readonly #nonScheduledConversationTurns = new Set<string>();
    readonly #locallyRunningConversationTurns = new Set<string>();
    readonly #observerFollowedLocalTurns = new Set<string>();
    readonly #pendingExternalConversationEvents = new Map<
        string,
        ConversationEventEnvelope[]
    >();
    readonly #localImageUrls = new Set<string>();
    #lastInteractionAt = new Date().toISOString();

    constructor(
        transport: ChatTransport,
        liveAudio: LiveAudioClient,
        audio: BrowserAudioRuntime,
        speech: ChatSpeech,
        deviceId: string,
        profileId: string,
        startup: StartupState,
        saveLanguagePreference: SaveLanguagePreference,
        playMusic: boolean,
        saveMusicPreference: SaveMusicPreference,
        keepMicrophoneOn: boolean,
        saveKeepMicrophonePreference: SaveKeepMicrophonePreference,
        reasoningMode: ReasoningMode,
        saveReasoningPreference: SaveReasoningPreference,
        catalog: ModelCatalog,
        modelId: string,
        saveModelPreference: SaveModelPreference,
        onScheduledTaskCreated: ScheduledTaskCreated,
    ) {
        this.#transport = transport;
        this.#liveAudio = liveAudio;
        this.#audio = audio;
        this.#speech = speech;
        this.#deviceId = deviceId;
        this.#saveLanguagePreference = saveLanguagePreference;
        this.#playMusic = playMusic;
        this.#saveMusicPreference = saveMusicPreference;
        this.#keepMicrophoneOn = keepMicrophoneOn;
        this.#saveKeepMicrophonePreference = saveKeepMicrophonePreference;
        this.#saveReasoningPreference = saveReasoningPreference;
        this.#profileId = profileId;
        this.#language = startup.language;
        this.#supportedLanguages = startup.supportedLanguages;
        this.#reasoningMode = reasoningMode;
        this.#models = catalog.models;
        this.#modelId = modelId;
        this.#saveModelPreference = saveModelPreference;
        this.#onScheduledTaskCreated = onScheduledTaskCreated;
        this.#normalizeReasoningPreference();
        this.#speech.observe(() => {
            if (this.#speech.state.active === undefined)
                this.#playChatMusic();
            else {
                this.#chatMusicPlaying = false;
                this.#audio.stopThinkingMusic();
            }
            this.#emit();
        });
        this.#audio.observeThinkingMusic(() => this.#emit());
        globalThis.setInterval(() => {
            this.#reportPresence();
        }, 5_000);
        globalThis.setInterval(() => {
            if (this.#panel === "home" && document.visibilityState === "visible")
                void this.#refreshRecentSessions(true);
        }, 2_000);
    }

    observe(listener: Listener): void {
        this.#listeners.add(listener);
    }

    noteDirectInteraction(): void {
        this.#lastInteractionAt = new Date().toISOString();
        this.#reportPresence();
    }

    snapshot(): ChatSessionSnapshot {
        return {
            profileId: this.#profileId,
            phase: this.#phase,
            panel: this.#panel,
            hasOpenChat: this.#hasOpenChat(),
            canSwitchChats: this.#canSwitchChats(),
            hasDeletableChat: this.#hasDeletableChat(),
            canDeleteChat: this.#canDeleteChat(),
            canCompactNow: !this.#compacting
                && this.#sessionId !== undefined
                && this.#transcript.messages.length > 0
                && (this.#phase === "ready" || this.#phase === "preparing"),
            compacting: this.#compacting,
            ...(this.#sessionId === undefined ? {} : { currentSessionId: this.#sessionId }),
            language: this.#language,
            supportedLanguages: this.#supportedLanguages,
            recentSessions: this.#recentSessions,
            recentSessionsLoading: this.#recentSessionsLoading,
            messages: this.#transcript.messages,
            ...(this.#transcript.activeActivity === undefined
                ? {}
                : { activeActivity: this.#transcript.activeActivity }),
            speech: this.#speech.state,
            playMusic: this.#playMusic,
            keepMicrophoneOn: this.#keepMicrophoneOn,
            ...(this.#audio.thinkingMusicTitle === undefined
                ? {}
                : { musicTitle: this.#audio.thinkingMusicTitle }),
            reasoningMode: this.#reasoningMode,
            modelId: this.#modelId,
            models: this.#models,
            ...(this.#pendingImage === undefined ? {} : { pendingImage: this.#pendingImage }),
            visionRequired: this.#visionRequired,
            ...(this.#error === undefined
                ? {}
                : { error: this.#error, errorVersion: this.#errorVersion }),
        };
    }

    #reportPresence(): void {
        if (this.#sessionId === undefined)
            return;
        const now = new Date();
        const phase = this.#presencePhase();
        void this.#transport.reportScheduledTaskPresence(
            this.#profileId,
            this.#sessionId,
            this.#deviceId,
            this.#deviceId,
            phase,
            document.visibilityState === "visible",
            this.#lastInteractionAt,
            new Date(now.getTime() + 15_000).toISOString(),
        ).then(result => {
            if (result.yieldRequested)
                this.#yieldLiveForScheduledTask();
        }).catch(() => undefined);
    }

    /** Applies another producer's durable Conversation stream to this open
        chat. Locally submitted turns have their own request stream and are
        ignored here; scheduled and other-tab turns need no polling fallback. */
    #onExternalConversationEvent(event: ConversationEventEnvelope): void {
        if (event.profileId !== this.#profileId || event.sessionId !== this.#sessionId)
            return;
        if (this.#nonScheduledConversationTurns.has(event.turnId))
            return;
        if (event.kind === "status") {
            const status = JsonObject.from(event.payload, "conversation status");
            if (status.string("code") === "conversation_accepted") {
                const accepted = parseConversationAccepted(event.payload, event.turnId);
                const details = status.object("details");
                const modelName = details.string("model");
                const reasoningMode = details.choice("reasoning_mode", reasoningModes);
                const source = details.opt.string("source");
                this.#transcript.setTurnReasoningMode(event.turnId, reasoningMode);
                if (source === "audio_live"
                    && this.#acceptLocalLiveTurn(accepted.submissionId, event.turnId)) {
                    this.#transcript.updateQueueState(
                        event.turnId,
                        accepted.queueState,
                        accepted.submissionId,
                        accepted.queueSequence,
                        accepted.queueRevision,
                    );
                    return;
                }
                this.#externalScheduledModels.set(event.turnId, modelName);
                if (this.#phase === "scheduled-yield"
                    && source === "scheduled_task")
                    this.#scheduledYieldTurnId = event.turnId;
                if (source !== "scheduled_task" && !this.#transcript.hasTurn(event.turnId))
                    this.#transcript.acceptTurn(
                        details.string("user_text"),
                        event.turnId,
                        modelName,
                        undefined,
                        accepted.submissionId,
                        accepted.queueState,
                        accepted.queueSequence,
                        accepted.queueRevision,
                    );
                this.#emit();
                this.#applyExternalConversationEvent(event);
                this.#applyPendingExternalConversationEvents(event.turnId);
                return;
            }
        }
        if (!this.#externalScheduledModels.has(event.turnId)) {
            const pending = this.#pendingExternalConversationEvents.get(event.turnId) ?? [];
            pending.push(event);
            this.#pendingExternalConversationEvents.set(event.turnId, pending);
            return;
        }
        this.#applyExternalConversationEvent(event);
    }

    #applyPendingExternalConversationEvents(turnId: string): void {
        const pending = this.#pendingExternalConversationEvents.get(turnId);
        if (pending === undefined)
            return;
        this.#pendingExternalConversationEvents.delete(turnId);
        for (const event of pending)
            this.#applyExternalConversationEvent(event);
    }

    #beginExternalScheduledResponse(turnId: string): void {
        if (this.#externalScheduledTranscriptTurns.has(turnId))
            return;
        const modelName = this.#externalScheduledModels.get(turnId);
        if (modelName === undefined)
            return;
        this.#externalScheduledTranscriptTurns.add(turnId);
        this.#transcript.beginAcceptedResponse(turnId, modelName);
    }

    #applyExternalConversationEvent(event: ConversationEventEnvelope): void {
        const previous = this.#externalConversationSequences.get(event.turnId) ?? 0;
        if (event.sequence <= previous)
            return;
        this.#externalConversationSequences.set(event.turnId, event.sequence);
        switch (event.kind) {
            case "status": {
                const status = JsonObject.from(event.payload, "scheduled conversation status");
                if (status.string("code") === "api_text_pi_started") {
                    this.#transcript.updateQueueState(event.turnId, "running");
                    this.#beginExternalScheduledResponse(event.turnId);
                }
                return;
            }
            case "assistant_delta": {
                this.#beginExternalScheduledResponse(event.turnId);
                this.#transcript.appendAssistant(
                    parseTokenMessage(event.payload),
                    event.turnId,
                );
                this.#emit();
                const itemId = this.#transcript.activeAssistantItemId;
                if (itemId !== undefined)
                    this.#playExternalScheduledSpeechAfterRender(event.turnId, itemId);
                return;
            }
            case "reasoning":
                this.#beginExternalScheduledResponse(event.turnId);
                this.#transcript.appendReasoning(
                    parseReasoningEvent(event.payload),
                    event.turnId,
                );
                this.#emit();
                return;
            case "tool": {
                this.#beginExternalScheduledResponse(event.turnId);
                const indicator = parseToolMessage(event.payload);
                this.#transcript.addTool(indicator, event.turnId);
                this.#emit();
                if (indicator.scheduledTaskId !== undefined)
                    this.#onScheduledTaskCreated(indicator.scheduledTaskId);
                if (this.#sessionId !== undefined)
                    void this.#loadWebImages(
                        event.turnId,
                        indicator,
                        this.#startupGeneration,
                        this.#sessionId,
                    );
                return;
            }
            case "artifact": {
                this.#beginExternalScheduledResponse(event.turnId);
                const artifact = parseGeneratedImage(
                    event.payload,
                    url => this.#transport.resourceUrl(url),
                );
                const pendingItemId = this.#transcript.addGeneratedImage(
                    artifact,
                    event.turnId,
                );
                if (pendingItemId !== undefined)
                    this.#speech.replaceItemId(event.turnId, pendingItemId, artifact.itemId);
                this.#emit();
                return;
            }
            case "completed":
                this.#transcript.updateQueueState(event.turnId, "completed");
                this.#beginExternalScheduledResponse(event.turnId);
                this.#finishTurn(parseTextTurnResult(event.payload), event.turnId);
                this.#finishObserverFollowedLocalTurn(event.turnId);
                this.#externalScheduledModels.delete(event.turnId);
                this.#externalScheduledTranscriptTurns.delete(event.turnId);
                if (this.#scheduledYieldTurnId === event.turnId)
                    this.#scheduledYieldCompletion?.();
                this.#emit();
                return;
            case "failed":
                {
                    this.#transcript.updateQueueState(event.turnId, "failed");
                    const failure = parseConversationFailure(event.payload);
                    const copy = uiText(this.#language);
                    this.#transcript.addFailure(
                        event.turnId,
                        copy.turnFailed,
                        failure.code,
                        failure.message,
                        copy.technicalDetails,
                        event.timestamp,
                    );
                }
                this.#transcript.failTurn(event.turnId);
                this.#finishObserverFollowedLocalTurn(event.turnId);
                this.#externalScheduledModels.delete(event.turnId);
                this.#externalScheduledTranscriptTurns.delete(event.turnId);
                this.#externalScheduledSpeechTurns.delete(event.turnId);
                if (this.#scheduledYieldTurnId === event.turnId)
                    this.#scheduledYieldCompletion?.();
                this.#showError(uiText(this.#language).turnFailed);
                this.#emit();
                return;
        }
    }

    /** Let the DOM commit the first streamed token before automatic speech can
        start. The speech source itself remains live and receives later tokens. */
    #playExternalScheduledSpeechAfterRender(turnId: string, itemId: string): void {
        if (this.#externalScheduledSpeechTurns.has(turnId) || this.#sessionId === undefined)
            return;
        this.#externalScheduledSpeechTurns.add(turnId);
        globalThis.requestAnimationFrame(() => {
            if (
                this.#sessionId === undefined
                || !this.#externalScheduledSpeechTurns.has(turnId)
            ) return;
            this.#playResponseAutomatically(
                this.#profileId,
                this.#sessionId,
                turnId,
                itemId,
            );
        });
    }

    #presencePhase(): string {
        if (this.#phase === "live-listening") return "listening";
        if (this.#phase === "live-transcribing") return "transcribing";
        if (this.#phase === "streaming") return "model_turn";
        if (this.#phase === "stopping") return "stopping";
        if (this.#phase === "scheduled-yield") return "suspended";
        return "idle";
    }

    /** A scheduled active-session task asked this in-memory client to yield.
        The Voice transport retains its candidate; only capture is suspended. */
    #yieldLiveForScheduledTask(): void {
        if (this.#phase !== "live-listening") return;
        this.#resumeLiveAfterScheduledYield = true;
        this.#liveControl?.suspend();
    }

    #onLiveSuspendedForScheduledTask(): void {
        const sessionId = this.#sessionId;
        if (sessionId === undefined || !this.#resumeLiveAfterScheduledYield) return;
        this.#phase = "scheduled-yield";
        this.#emit();
        this.#reportPresence();
        void this.#awaitYieldedScheduledTask(sessionId, this.#startupGeneration);
    }

    async #awaitYieldedScheduledTask(
        sessionId: string,
        startupGeneration: number,
    ): Promise<void> {
        try {
            await new Promise<void>(resolve => {
                const timeout = globalThis.setTimeout(resolve, 45_000);
                this.#scheduledYieldCompletion = () => {
                    globalThis.clearTimeout(timeout);
                    resolve();
                };
            });
            await this.#speech.whenIdle();
        } catch (error: unknown) {
            console.error("Scheduled Voice yield failed", error);
        } finally {
            if (startupGeneration === this.#startupGeneration && sessionId === this.#sessionId) {
                this.#scheduledYieldTurnId = undefined;
                this.#scheduledYieldCompletion = undefined;
                const resume = this.#resumeLiveAfterScheduledYield;
                this.#resumeLiveAfterScheduledYield = false;
                if (resume && this.#liveControl !== undefined) {
                    this.#liveControl.resume();
                } else {
                    if (this.#phase === "scheduled-yield") this.#phase = this.#idlePhase();
                    this.#emit();
                }
            }
        }
    }

    async selectProfile(
        profileId: string,
        autoSpeak: boolean,
        playMusic: boolean,
        keepMicrophoneOn: boolean,
        language: ChatLanguage | "",
        reasoningMode: ReasoningMode,
        modelId: string,
    ): Promise<void> {
        this.#cancelLiveListening();
        this.#phase = "loading";
        this.#stopChatMusic();
        this.#speech.stop();
        this.#speech.setAutoEnabled(autoSpeak);
        this.#playMusic = playMusic;
        this.#keepMicrophoneOn = keepMicrophoneOn;
        this.#profileId = profileId;
        this.#reasoningMode = reasoningMode;
        this.#modelId = modelId;
        this.#normalizeReasoningPreference();
        if (language !== "")
            this.#setLanguage(language);
        await this.#loadLauncher(language);
    }

    async openHome(): Promise<void> {
        await this.#refreshRecentSessions();
    }

    async newChat(): Promise<void> {
        if (!this.#canStartNewChat())
            return;
        if (this.#playMusic)
            this.#audio.prepareThinkingMusic();
        await this.#start({ kind: "new", language: this.#language });
    }

    selectLanguage(language: ChatLanguage): void {
        if (this.#panel !== "home"
            || !this.#canSwitchChats()
            || !this.#supportedLanguages.includes(language))
            return;
        this.#setLanguage(language);
        this.#emit();
    }

    showHome(): void {
        if (!this.#hasOpenChat())
            return;
        this.#leaveLiveCapture();
        this.#panel = "home";
        this.#stopChatMusic();
        this.#emit();
        void this.#refreshRecentSessions();
    }

    showChat(): void {
        if (!this.#hasOpenChat())
            return;
        if (this.#playMusic)
            this.#audio.prepareThinkingMusic();
        this.#panel = "chat";
        this.#playChatMusic();
        this.#emit();
    }

    async start(choice: SessionChoice): Promise<void> {
        if (this.#phase !== "launcher")
            return;
        if (this.#playMusic)
            this.#audio.prepareThinkingMusic();
        await this.#start(choice);
    }

    async openRecent(session: RecentSessionSummary): Promise<void> {
        if (this.#playMusic)
            this.#audio.prepareThinkingMusic();
        if (session.sessionId === this.#sessionId) {
            this.showChat();
            return;
        }
        if (!this.#canSwitchChats())
            return;
        await this.#start({
            kind: "resume",
            sessionId: session.sessionId,
            language: session.language,
        });
    }

    async deleteCurrentSession(): Promise<void> {
        const sessionId = this.#sessionId;
        if (sessionId === undefined || !this.#canDeleteChat())
            return;
        const startupTask = this.#startupTask;
        this.#startupGeneration++;

        this.#recentSessions = this.#recentSessions.filter(session =>
            session.sessionId !== sessionId);
        this.#panel = "home";
        this.#reset("launcher");

        try {
            if (startupTask !== undefined)
                await startupTask;
            await this.#transport.deleteSession(this.#profileId, sessionId);
        } catch (error: unknown) {
            console.error("Chat deletion failed", error);
            this.#showError(uiText(this.#language).deleteFailed);
        }
        await this.#refreshRecentSessions();
    }

    async branch(point: ChatBranchPoint): Promise<SessionBranchResult | undefined> {
        const sourceSessionId = this.#sessionId;
        if (sourceSessionId === undefined || !this.#canBranchChat() || this.#branching)
            return undefined;
        this.#branching = true;
        try {
            const result = await this.#transport.branchSession(
                this.#profileId,
                sourceSessionId,
                point,
            );
            await this.#start({
                kind: "resume",
                sessionId: result.sessionId,
                language: result.language,
            });
            void this.#refreshRecentSessions();
            return result;
        } catch (error: unknown) {
            console.error("Chat branching failed", error);
            this.#showError(uiText(this.#language).branchFailed);
            this.#emit();
            return undefined;
        } finally {
            this.#branching = false;
        }
    }

    async #start(choice: SessionChoice): Promise<void> {
        const task = this.#runStart(choice);
        this.#startupTask = task;
        try {
            await task;
        } finally {
            if (this.#startupTask === task)
                this.#startupTask = undefined;
        }
    }

    async #runStart(choice: SessionChoice): Promise<void> {
        const startupGeneration = ++this.#startupGeneration;
        this.#setLanguage(choice.language);
        this.#panel = "chat";
        this.#reset("starting");
        if (choice.kind === "resume") {
            this.#sessionId = choice.sessionId;
            this.#emit();
        }
        this.#preparationComplete = false;

        try {
            let opening = Promise.resolve();
            const result = await this.#transport.startSession(
                this.#profileId,
                choice,
                this.#modelId,
                {
                    onOpened: opened => {
                        if (startupGeneration !== this.#startupGeneration)
                            return;
                        opening = this.#open(opened, startupGeneration);
                        void opening.catch(() => undefined);
                    },
                },
            );
            await opening;
            if (startupGeneration !== this.#startupGeneration)
                return;
            this.#setLanguage(result.language);
            this.#preparationComplete = true;
            if (this.#phase === "preparing")
                this.#phase = "ready";
        } catch (error: unknown) {
            if (startupGeneration !== this.#startupGeneration)
                return;
            console.error("Session startup failed", error);
            this.#panel = "home";
            this.#reset("launcher");
            this.#showError(uiText(this.#language).startupFailed);
            await this.#refreshRecentSessions();
        }
        this.#emit();
    }

    async #open(result: SessionStartResult, startupGeneration: number): Promise<void> {
        const [restored, queue, presentation] = await Promise.all([
            result.resumedLastSession
                ? this.#transport.loadSession(this.#profileId, result.sessionId)
                : Promise.resolve([]),
            this.#transport.loadSessionQueue(this.#profileId, result.sessionId),
            this.#transport.loadPresentation(this.#profileId, result.sessionId),
        ]);
        if (startupGeneration !== this.#startupGeneration)
            return;
        this.#setLanguage(result.language);
        this.#sessionId = result.sessionId;
        const processingTurnIds = new Set(
            restored.filter(turn => turn.processing).map(turn => turn.turnId),
        );
        // A processing turn's materialized view contains only finished Pi
        // items. Rebuild the whole turn from its durable event stream so the
        // current reasoning/assistant item includes every delta before reload
        // without duplicating those already-finished items.
        this.#transcript.append(restored.map(turn => turn.processing
            ? { ...turn, items: turn.items.filter(item =>
                item.kind === "tool"
                && item.indicator.name === "scheduled_task_trigger") }
            : turn));
        for (const turn of restored)
            if (!turn.processing)
                this.#nonScheduledConversationTurns.add(turn.turnId);
        this.#replayPresentationEvents(
            presentation,
            event => processingTurnIds.has(event.turnId),
        );
        for (const mutation of presentation.queueMutations)
            this.#transcript.applyQueueMutation(mutation, restored, this.#language);
        this.#transcript.restorePresentation(presentation, this.#language);
        this.#transcript.applyQueueSnapshot(queue, restored, this.#language);
        this.#loadStoredWebImages(restored, startupGeneration, result.sessionId);
        this.#visionRequired = restored.some(turn => turn.userImage !== undefined);
        if (this.#visionRequired && !this.#model().vision)
            this.#selectFirstVisionModel();
        this.#phase = "preparing";
        this.#playChatMusic();
        this.#watchCodexEvents(result.sessionId, startupGeneration, presentation.watermark);
        this.#watchSessionTurns(result.sessionId, startupGeneration, presentation.watermark);
        for (const active of restored.filter(turn => turn.processing)) {
            if (active.assistantStreaming
                && this.#externalScheduledModels.has(active.turnId))
                this.#playExternalScheduledSpeechAfterRender(
                    active.turnId,
                    active.assistantStreamingItemId,
                );
        }
        this.#emit();
    }

    #replayPresentationEvents(
        presentation: PresentationSnapshot,
        include: (event: PresentationSnapshot["conversationEvents"][number]) => boolean,
    ): void {
        this.#restoringPresentation = true;
        try {
            for (const event of presentation.conversationEvents)
                if (include(event))
                    this.#onExternalConversationEvent(event);
        } finally {
            this.#restoringPresentation = false;
        }
    }

    #observerIsCurrent(
        controller: AbortController,
        sessionId: string,
        startupGeneration: number,
    ): boolean {
        return !controller.signal.aborted
            && startupGeneration === this.#startupGeneration
            && sessionId === this.#sessionId;
    }

    async #waitForObserverReconnect(signal: AbortSignal): Promise<void> {
        await new Promise<void>(resolve => {
            const onAbort = (): void => {
                globalThis.clearTimeout(timeout);
                resolve();
            };
            const timeout = globalThis.setTimeout(() => {
                signal.removeEventListener("abort", onAbort);
                resolve();
            }, observerReconnectDelayMs);
            signal.addEventListener("abort", onAbort, { once: true });
        });
    }

    #watchCodexEvents(
        sessionId: string,
        startupGeneration: number,
        afterSequence: number,
    ): void {
        this.#codexEventsAbort?.abort();
        const controller = new AbortController();
        this.#codexEventsAbort = controller;
        void this.#followCodexEvents(
            sessionId,
            startupGeneration,
            afterSequence,
            controller,
        ).finally(() => {
            if (this.#codexEventsAbort === controller)
                this.#codexEventsAbort = undefined;
        });
    }

    async #followCodexEvents(
        sessionId: string,
        startupGeneration: number,
        afterSequence: number,
        controller: AbortController,
    ): Promise<void> {
        let cursor = afterSequence;
        while (this.#observerIsCurrent(controller, sessionId, startupGeneration)) {
            try {
                await this.#transport.streamCodexEvents(
                    this.#profileId,
                    sessionId,
                    cursor,
                    { onEvent: event => {
                        if (!this.#observerIsCurrent(
                            controller,
                            sessionId,
                            startupGeneration,
                        )) return;
                        cursor = Math.max(cursor, event.sequence);
                        this.#transcript.applyCodex(event, this.#language);
                        this.#emit();
                    } },
                    controller.signal,
                );
            } catch {
                if (!this.#observerIsCurrent(controller, sessionId, startupGeneration))
                    return;
            }
            await this.#waitForObserverReconnect(controller.signal);
        }
    }

    #watchSessionTurns(
        sessionId: string,
        startupGeneration: number,
        afterSequence: number,
    ): void {
        this.#sessionTurnsAbort?.abort();
        const controller = new AbortController();
        this.#sessionTurnsAbort = controller;
        void this.#followSessionTurns(
            sessionId,
            startupGeneration,
            afterSequence,
            controller,
        ).finally(() => {
            if (this.#sessionTurnsAbort === controller)
                this.#sessionTurnsAbort = undefined;
        });
    }

    async #followSessionTurns(
        sessionId: string,
        startupGeneration: number,
        afterSequence: number,
        controller: AbortController,
    ): Promise<void> {
        let cursor = afterSequence;
        while (this.#observerIsCurrent(controller, sessionId, startupGeneration)) {
            try {
                await this.#transport.streamSessionTurns(
                    this.#profileId,
                    sessionId,
                    cursor,
                    { onCursor: sequence => {
                        cursor = Math.max(cursor, sequence);
                    }, onChanged: mutation => {
                        if (mutation !== undefined)
                            this.#transcript.applyQueueMutation(
                                mutation,
                                [],
                                this.#language,
                            );
                        void this.#refreshSessionQueue(sessionId, startupGeneration);
                    }, onConversation: event => {
                        if (!this.#observerIsCurrent(
                            controller,
                            sessionId,
                            startupGeneration,
                        )) return;
                        this.#onExternalConversationEvent(event);
                    } },
                    controller.signal,
                );
            } catch {
                if (!this.#observerIsCurrent(controller, sessionId, startupGeneration))
                    return;
            }
            await this.#waitForObserverReconnect(controller.signal);
        }
    }

    async #refreshSessionQueue(sessionId: string, startupGeneration: number): Promise<void> {
        try {
            const queue = await this.#transport.loadSessionQueue(this.#profileId, sessionId);
            if (startupGeneration !== this.#startupGeneration || this.#sessionId !== sessionId)
                return;
            this.#transcript.applyQueueSnapshot(queue, [], this.#language);
            this.#emit();
        } catch {
            // Reconnect or a later durable change will provide another
            // snapshot opportunity; do not change the projection on failure.
        }
    }

    async send(text: string): Promise<boolean> {
        this.#lastInteractionAt = new Date().toISOString();
        const prompt = text.trim();
        if ((prompt.length === 0 && this.#pendingImageFile === undefined)
            || (this.#phase !== "ready" && this.#phase !== "preparing"
                && this.#phase !== "streaming"))
            return false;
        if (this.#playMusic)
            this.#audio.prepareThinkingMusic();

        const selectionGeneration = this.#startupGeneration;
        const turnId = `web-text-${crypto.randomUUID()}`;
        const sessionId = this.#sessionId!;
        const reasoningMode = this.#turnReasoningMode(prompt);
        const modelId = this.#modelId;
        const modelName = this.#model().name;
        const image = this.#takePendingImage();
        this.#clearError();
        let accepted = false;
        let acceptedId: string | undefined;
        let presentationCursor = 0;
        let settleAcceptance!: (value: boolean) => void;
        const acceptance = new Promise<boolean>(resolve => {
            settleAcceptance = resolve;
        });

        void this.#transport.streamTextTurn(
            this.#profileId,
            {
                sessionId,
                text: prompt,
                turnId,
                deviceId: this.#deviceId,
                language: this.#language,
                reasoningMode,
                modelId,
                ...(image === undefined ? {} : { image: image.file }),
            },
            this.#turnStreamHandlers(selectionGeneration, {
                onEvent: event => {
                    if (event.presentationSequence !== undefined)
                        presentationCursor = event.presentationSequence;
                    this.#externalConversationSequences.set(event.turnId, event.sequence);
                },
                onAccepted: acceptedTurn => {
                    if (accepted || selectionGeneration !== this.#startupGeneration)
                        return;
                    accepted = true;
                    acceptedId = acceptedTurn.turnId;
                    this.#nonScheduledConversationTurns.add(acceptedTurn.turnId);
                    this.#transcript.setTurnReasoningMode(
                        acceptedTurn.turnId,
                        reasoningMode,
                    );
                    this.#transcript.acceptTurn(
                        prompt,
                        acceptedTurn.turnId,
                        modelName,
                        image?.preview,
                        acceptedTurn.submissionId,
                        acceptedTurn.queueState,
                        acceptedTurn.queueSequence,
                        acceptedTurn.queueRevision,
                    );
                    this.#playChatMusic();
                    void this.#refreshRecentSessions();
                    this.#emit();
                    settleAcceptance(true);
                },
                onStarted: startedTurnId => {
                    if (selectionGeneration !== this.#startupGeneration)
                        return;
                    this.#activeTurnId = startedTurnId;
                    this.#locallyRunningConversationTurns.add(startedTurnId);
                    this.#transcript.updateQueueState(startedTurnId, "running");
                    this.#phase = "streaming";
                    this.#transcript.beginAcceptedResponse(startedTurnId, modelName);
                    this.#playResponseAutomatically(
                        this.#profileId,
                        sessionId,
                        startedTurnId,
                    );
                    this.#emit();
                },
            }),
        ).then(result => {
            if (selectionGeneration !== this.#startupGeneration)
                return;
            this.#finishTurn(result, turnId);
            this.#locallyRunningConversationTurns.delete(result.turnId);
            if (this.#activeTurnId === result.turnId)
                this.#activeTurnId = [...this.#locallyRunningConversationTurns].at(-1);
            if (this.#locallyRunningConversationTurns.size === 0)
                this.#phase = this.#idlePhase();
            this.#emit();
            void this.#refreshRecentSessions();
        }).catch((error: unknown) => {
            if (selectionGeneration !== this.#startupGeneration)
                return;
            if (!accepted && image !== undefined) {
                this.#pendingImageFile = image.file;
                this.#pendingImage = image.preview;
                this.#visionRequired = false;
            }
            if (accepted) {
                const acceptedTurnId = acceptedId ?? turnId;
                if (this.#transcript.queueState(acceptedTurnId) !== "cancelled"
                    && presentationCursor > 0) {
                    console.warn(
                        "Text turn observer was lost; following its durable session stream.",
                        error,
                    );
                    this.#followLocalTurnDurably(
                        acceptedTurnId,
                        modelName,
                        sessionId,
                        selectionGeneration,
                        presentationCursor,
                    );
                    this.#emit();
                    settleAcceptance(true);
                    return;
                }
                if (this.#transcript.queueState(acceptedTurnId) !== "cancelled")
                    this.#failTurn(turnId, error, "Text turn failed");
            }
            else {
                console.error("Text turn submission failed", error);
                this.#showError(uiText(this.#language).turnFailed);
            }
            if (acceptedId !== undefined)
                this.#locallyRunningConversationTurns.delete(acceptedId);
            if (this.#activeTurnId === acceptedId)
                this.#activeTurnId = [...this.#locallyRunningConversationTurns].at(-1);
            if (this.#locallyRunningConversationTurns.size === 0)
                this.#phase = this.#idlePhase();
            this.#emit();
            settleAcceptance(false);
            void this.#refreshRecentSessions();
        }).finally(() => {
            if (!accepted)
                settleAcceptance(false);
        });

        return await acceptance;
    }

    async cancelQueuedTurn(itemId: string, turnId: string): Promise<void> {
        if (this.#sessionId === undefined) return;
        try {
            const mutation = await this.#transport.cancelSessionQueueItem(
                this.#profileId,
                this.#sessionId,
                itemId,
            );
            if (mutation === undefined) return;
            this.#transcript.updateQueueState(
                turnId,
                mutation.item.state,
                itemId,
                mutation.item.sequence,
                mutation.revision,
            );
            this.#emit();
        } catch (error: unknown) {
            console.error("Cancelling queued turn failed", error);
            this.#showError(uiText(this.#language).turnFailed);
            this.#emit();
        }
    }

    startLiveListening(): void {
        if (this.#phase !== "ready" && this.#phase !== "preparing")
            return;
        this.#liveMode = true;
        this.#stopChatMusic();
        this.#speech.stop();
        this.#speech.prepare();
        this.#liveAudio.prepare();
        this.#audio.prepare();
        this.#clearError();
        void this.#runLiveListening(this.#startupGeneration);
    }

    submitLiveListening(): void {
        if (this.#phase !== "live-listening")
            return;
        this.#phase = "live-transcribing";
        this.#liveControl?.finish();
        this.#emit();
    }

    cancelLiveListening(): void {
        if (this.#phase !== "requesting-live-microphone"
            && this.#phase !== "live-listening"
            && this.#phase !== "live-transcribing")
            return;
        this.#cancelLiveListening();
        this.#speech.stop();
        this.#phase = this.#idlePhase();
        this.#playChatMusic();
        this.#emit();
    }

    async #runLiveListening(selectionGeneration: number): Promise<void> {
        try {
            while (this.#liveMode && selectionGeneration === this.#startupGeneration) {
                const submissionId = `web-audio-live-${crypto.randomUUID()}`;
                const profileId = this.#profileId;
                const sessionId = this.#sessionId!;
                const requestedModel = this.#model();
                const requestedReasoningMode = this.#turnReasoningMode();
                const streamHandlers = this.#turnStreamHandlers(selectionGeneration);
                let effectiveReasoningMode = requestedReasoningMode;
                let committed = false;
                let advanceSettled = false;
                let settleAdvance!: (committed: boolean) => void;
                const advance = new Promise<boolean>(resolve => {
                    settleAdvance = value => {
                        if (advanceSettled)
                            return;
                        advanceSettled = true;
                        resolve(value);
                    };
                });
                this.#localLiveTurnIds.set(submissionId, submissionId);
                this.#phase = "requesting-live-microphone";
                this.#emit();
                const control = this.#liveAudio.start({
                    profileId,
                    sessionId,
                    turnId: submissionId,
                    deviceId: this.#deviceId,
                    language: this.#language,
                    reasoningMode: requestedReasoningMode,
                    modelId: this.#modelId,
                }, {
                    onListening: () => {
                        if (control !== this.#liveControl)
                            return;
                        this.#speech.suspendForCapture(submissionId);
                        this.#phase = "live-listening";
                        this.#emit();
                    },
                    onSuspended: () => {
                        if (control !== this.#liveControl)
                            return;
                        this.#onLiveSuspendedForScheduledTask();
                    },
                    onPreview: text => {
                        if (control !== this.#liveControl)
                            return;
                        this.#transcript.updateDraft(
                            text,
                            submissionId,
                            this.#model().name,
                        );
                        this.#emit();
                    },
                    onIgnored: () => {
                        if (control !== this.#liveControl)
                            return;
                        this.#transcript.cancelDraft();
                        this.#emit();
                    },
                    onCaptureStopped: () => {
                        if (control !== this.#liveControl)
                            return;
                        this.#speech.prepareAfterCapture(submissionId);
                    },
                    shouldKeepMicrophoneOpen: () => this.#continuousMicrophoneEnabled(),
                    onEndpoint: () => {
                        if (control !== this.#liveControl)
                            return;
                        this.#phase = "live-transcribing";
                        this.#emit();
                    },
                    onFinal: transcript => {
                        const image = this.#takePendingImage();
                        this.#setLanguage(transcript.language);
                        this.#transcript.acceptDraft(
                            transcript.text,
                            submissionId,
                            requestedModel.name,
                            image?.preview,
                        );
                        effectiveReasoningMode = this.#turnReasoningMode(transcript.text);
                        this.#transcript.setTurnReasoningMode(
                            submissionId,
                            effectiveReasoningMode,
                        );
                        this.#emit();
                        return {
                            reasoningMode: effectiveReasoningMode,
                            modelId: requestedModel.id,
                            ...(image === undefined ? {} : { image: image.file }),
                        };
                    },
                    onAccepted: turnId => {
                        this.#acceptLocalLiveTurn(submissionId, turnId);
                    },
                    onStarted: turnId => {
                        if (selectionGeneration !== this.#startupGeneration)
                            return;
                        this.#acceptLocalLiveTurn(submissionId, turnId);
                        this.#activeTurnId = turnId;
                        this.#locallyRunningConversationTurns.add(turnId);
                        this.#transcript.beginAcceptedResponse(
                            turnId,
                            requestedModel.name,
                        );
                        if (this.#speech.state.autoEnabled)
                            this.#playResponseAutomatically(profileId, sessionId, turnId);
                        this.#emit();
                    },
                    onCommitted: () => {
                        committed = true;
                        if (this.#continuousMicrophoneEnabled())
                            settleAdvance(true);
                        else
                            control.releaseMicrophone();
                    },
                    onThinkingMusic: command => {
                        if (command.action === "stop")
                            this.#audio.stopThinkingMusic();
                        else if (this.#playMusic && !this.#continuousMicrophoneEnabled())
                            this.#audio.applyThinkingMusic(profileId, command);
                        else
                            this.#audio.stopThinkingMusic();
                    },
                    onToken: streamHandlers.onToken,
                    onTool: streamHandlers.onTool,
                    onArtifact: streamHandlers.onArtifact,
                    onReasoning: streamHandlers.onReasoning,
                    onFailed: streamHandlers.onFailed,
                });
                this.#liveControl = control;
                this.#liveControls.add(control);
                void control.result.then(async result => {
                    this.#liveControls.delete(control);
                    if (control === this.#liveControl)
                        this.#liveControl = undefined;
                    if (result === undefined) {
                        settleAdvance(false);
                        return;
                    }
                    if (selectionGeneration !== this.#startupGeneration) {
                        settleAdvance(false);
                        return;
                    }
                    this.#audio.stopThinkingMusic();
                    this.#finishTurn(result, submissionId);
                    this.#localLiveTurnIds.delete(submissionId);
                    this.#locallyRunningConversationTurns.delete(result.turnId);
                    if (this.#activeTurnId === result.turnId)
                        this.#activeTurnId = [...this.#locallyRunningConversationTurns].at(-1);
                    this.#emit();
                    await this.#speech.whenIdle();
                    if (committed && this.#liveMode)
                        settleAdvance(true);
                }).catch((error: unknown) => {
                    this.#liveControls.delete(control);
                    if (control === this.#liveControl)
                        this.#liveControl = undefined;
                    settleAdvance(false);
                    this.#localLiveTurnIds.delete(submissionId);
                    if (selectionGeneration !== this.#startupGeneration)
                        return;
                    console.error("Live audio turn failed", error);
                    this.#audio.stopThinkingMusic();
                    if (!committed) {
                        this.#liveMode = false;
                        this.#transcript.cancelDraft();
                    }
                    this.#showError(uiText(this.#language).liveAudioFailed);
                    this.#emit();
                });
                const continueListening = await advance;
                if (control === this.#liveControl)
                    this.#liveControl = undefined;
                if (!continueListening)
                    break;
            }
            if (selectionGeneration === this.#startupGeneration)
                this.#liveMode = false;
        } catch (error: unknown) {
            if (selectionGeneration === this.#startupGeneration && this.#liveMode) {
                console.error("Live audio turn failed", error);
                this.#audio.stopThinkingMusic();
                this.#speech.stop();
                this.#transcript.cancelDraft();
                if (this.#activeTurnId !== undefined)
                    this.#transcript.failTurn();
                this.#showError(this.#phase === "requesting-live-microphone"
                    ? uiText(this.#language).microphoneUnavailable
                    : uiText(this.#language).liveAudioFailed);
            }
            this.#liveMode = false;
        } finally {
            if (selectionGeneration === this.#startupGeneration && !this.#liveMode) {
                this.#liveAudio.releaseMicrophone();
                this.#liveControl = undefined;
                this.#activeTurnId = [...this.#locallyRunningConversationTurns].at(-1);
                if (this.#phase !== "scheduled-yield")
                    this.#phase = this.#locallyRunningConversationTurns.size > 0
                        ? "streaming"
                        : this.#idlePhase();
                this.#playChatMusic();
                this.#emit();
            }
        }
    }

    async stop(): Promise<void> {
        if (this.#phase === "requesting-live-microphone"
            || this.#phase === "live-listening"
            || this.#phase === "live-transcribing") {
            this.cancelLiveListening();
            return;
        }
        const turnId = this.#activeTurnId;
        if (this.#phase !== "streaming")
            return;
        this.#stopChatMusic();
        this.#speech.stop();
        if (turnId === undefined) {
            this.#emit();
            return;
        }
        this.#phase = "stopping";
        this.#emit();
        try {
            await this.#transport.stopTextTurn(this.#profileId, this.#sessionId!, turnId);
        } catch (error: unknown) {
            console.error("Stopping text turn failed", error);
            if (this.#activeTurnId === turnId) {
                this.#phase = "streaming";
                this.#showError(uiText(this.#language).turnFailed);
                this.#emit();
            }
        }
    }

    async compactNow(): Promise<void> {
        if (!this.snapshot().canCompactNow || this.#sessionId === undefined)
            return;
        const startedAt = new Date().toISOString();
        const provisionalId = `manual:${crypto.randomUUID()}`;
        this.#compacting = true;
        this.#clearError();
        this.#transcript.upsertCompaction({
            id: provisionalId,
            reason: "manual",
            status: "compacting",
            startedAt,
            completedAt: "",
            durationMs: 0,
            summary: "",
            errorMessage: "",
            tokensBefore: 0,
            estimatedTokensAfter: 0,
            willRetry: false,
        });
        this.#emit();
        try {
            const result = await this.#transport.compactSession(this.#profileId, this.#sessionId);
            this.#transcript.upsertCompaction({
                id: provisionalId,
                reason: "manual",
                status: "skipped",
                startedAt,
                completedAt: "",
                durationMs: 0,
                summary: "",
                errorMessage: "",
                tokensBefore: 0,
                estimatedTokensAfter: 0,
                willRetry: false,
            });
            this.#transcript.upsertCompaction(result);
            if (result.status !== "completed" && result.errorMessage.length > 0)
                this.#showError(result.errorMessage);
        } catch (error: unknown) {
            this.#transcript.upsertCompaction({
                id: provisionalId,
                reason: "manual",
                status: "skipped",
                startedAt,
                completedAt: "",
                durationMs: 0,
                summary: "",
                errorMessage: "",
                tokensBefore: 0,
                estimatedTokensAfter: 0,
                willRetry: false,
            });
            this.#showError(error instanceof Error ? error.message : String(error));
        } finally {
            this.#compacting = false;
            this.#emit();
        }
    }

    toggleAutoSpeak(): void {
        const enabled = this.#speech.toggleAuto();
        if (enabled)
            this.#liveAudio.releaseIdleMicrophone();
        if (
            enabled
            && this.#phase === "streaming"
            && this.#activeTurnId !== undefined
            && this.#sessionId !== undefined
            && !this.#liveMode
        ) {
            const itemId = this.#transcript.activeAssistantItemId;
            this.#playResponseAutomatically(
                this.#profileId,
                this.#sessionId,
                this.#activeTurnId,
                itemId,
                itemId === undefined,
            );
        }
    }

    togglePlayMusic(): void {
        this.#playMusic = !this.#playMusic;
        this.#saveMusicPreference(this.#playMusic);
        if (!this.#playMusic) {
            this.#stopChatMusic();
        } else {
            this.#liveAudio.releaseIdleMicrophone();
            this.#audio.prepareThinkingMusic();
            this.#playChatMusic();
        }
        this.#emit();
    }

    toggleKeepMicrophoneOn(): void {
        this.#keepMicrophoneOn = !this.#keepMicrophoneOn;
        this.#saveKeepMicrophonePreference(this.#keepMicrophoneOn);
        if (!this.#keepMicrophoneOn)
            this.#liveAudio.releaseIdleMicrophone();
        this.#emit();
    }

    toggleReasoning(): void {
        const model = this.#model();
        if (!model.reasoning || model.reasoningModes.length < 2)
            return;
        const current = this.#turnReasoningMode();
        const index = model.reasoningModes.indexOf(current);
        this.#reasoningMode = model.reasoningModes[(index + 1) % model.reasoningModes.length]!;
        this.#saveReasoningPreference(this.#reasoningMode);
        this.#emit();
    }

    selectModel(modelId: string): void {
        const model = this.#models.find(candidate => candidate.id === modelId)
            ?? Er.internal(`Unknown selected model ${modelId}.`);
        if ((this.#visionRequired || this.#pendingImageFile !== undefined) && !model.vision)
            return;
        this.#modelId = model.id;
        this.#saveModelPreference(model.id);
        this.#normalizeReasoningPreference();
        this.#emit();
    }

    selectImage(file: File | undefined): void {
        if (file !== undefined && (!this.#model().vision || !file.type.startsWith("image/")))
            return;
        this.#clearPendingImage();
        if (file !== undefined) {
            const url = URL.createObjectURL(file);
            this.#localImageUrls.add(url);
            this.#pendingImageFile = file;
            this.#pendingImage = { url, filename: file.name };
        }
        this.#emit();
    }

    speak(turnId: string, itemId: string): void {
        this.#speech.playSpeech(this.#profileId, this.#sessionId!, turnId, itemId);
    }

    speakText(turnId: string, itemId: string, text: string): void {
        this.#speech.playText(this.#profileId, turnId, itemId, text, this.#language);
    }

    speakReasoning(turnId: string, itemId: string): void {
        this.#speech.playReasoning(this.#profileId, this.#sessionId!, turnId, itemId);
    }

    async loadReasoning(turnId: string, itemId: string): Promise<string> {
        if (this.#transcript.reasoningIsTruncated(turnId, itemId)) {
            const detail = await this.#transport.loadReasoning(
                this.#profileId,
                this.#sessionId!,
                turnId,
                itemId,
            );
            this.#transcript.setReasoning(turnId, itemId, detail.text);
            this.#emit();
        }
        return this.#transcript.reasoningText(turnId, itemId)
            ?? (await this.#transport.loadReasoning(
                this.#profileId,
                this.#sessionId!,
                turnId,
                itemId,
            )).text;
    }

    playUserAudio(turnId: string, audioUrl: string): void {
        this.#speech.playUserAudio(turnId, audioUrl);
    }

    stopPlayback(): void {
        this.#speech.stop();
    }

    async loadToolDetail(turnId: string, callIndex: number): Promise<ToolDetail> {
        return await this.#transport.loadToolDetail(
            this.#profileId,
            this.#sessionId!,
            turnId,
            callIndex,
        );
    }

    async #loadLauncher(language: ChatLanguage | ""): Promise<void> {
        this.#startupGeneration++;
        this.#recentRequestId++;
        this.#recentSessionsLoading = false;
        this.#panel = "home";
        this.#reset("loading");
        this.#recentSessions = [];
        try {
            const [startup, recentSessions] = await Promise.all([
                this.#transport.loadStartupState(this.#profileId, language),
                this.#transport.loadRecentSessions(this.#profileId),
            ]);
            this.#apply(startup);
            this.#recentSessions = recentSessions;
            this.#phase = "launcher";
        } catch (error: unknown) {
            console.error("Profile startup state failed", error);
            this.#phase = "launcher";
            this.#showError(uiText(this.#language).connectionUnavailable);
        }
        this.#emit();
    }

    #apply(startup: StartupState): void {
        this.#language = startup.language;
        this.#saveLanguagePreference(startup.language);
        this.#supportedLanguages = startup.supportedLanguages;
    }

    #setLanguage(language: ChatLanguage): void {
        if (this.#language === language)
            return;
        this.#language = language;
        this.#saveLanguagePreference(language);
    }

    #model(): ModelInfo {
        return this.#models.find(model => model.id === this.#modelId)
            ?? Er.internal(`Selected model ${this.#modelId} is unavailable.`);
    }

    readPeak(): number {
        if (this.#phase === "live-listening"
            || (this.#continuousMicrophoneEnabled()
                && (this.#phase === "requesting-live-microphone"
                    || this.#phase === "live-transcribing")))
            return this.#liveControl?.readPeak() ?? 0;
        return 0;
    }

    #turnReasoningMode(prompt = ""): ReasoningMode {
        const modes = this.#model().reasoningModes;
        if (promptStartsWithThink(prompt)) return modes.at(-1)!;
        return modes.includes(this.#reasoningMode) ? this.#reasoningMode : modes[0]!;
    }

    #normalizeReasoningPreference(): void {
        const modes = this.#model().reasoningModes;
        const normalized = modes.includes(this.#reasoningMode)
            ? this.#reasoningMode
            : this.#reasoningMode === "off" && modes.includes("off")
                ? "off"
                : modes.at(-1)!;
        if (normalized === this.#reasoningMode) return;
        this.#reasoningMode = normalized;
        this.#saveReasoningPreference(normalized);
    }

    #turnStreamHandlers(
        selectionGeneration: number,
        lifecycle: {
            readonly onEvent?: (event: ConversationEventEnvelope) => void;
            readonly onAccepted?: (accepted: ConversationAccepted) => void;
            readonly onStarted?: (turnId: string) => void;
        } = {},
    ): TextTurnHandlers {
        return {
            onEvent: event => lifecycle.onEvent?.(event),
            onAccepted: accepted => lifecycle.onAccepted?.(accepted),
            onStarted: turnId => lifecycle.onStarted?.(turnId),
            onToken: (event, turnId) => {
                if (selectionGeneration !== this.#startupGeneration)
                    return;
                this.#transcript.appendAssistant(event, turnId);
                this.#emit();
            },
            onTool: (indicator, turnId) => {
                if (selectionGeneration !== this.#startupGeneration)
                    return;
                this.#transcript.addTool(indicator, turnId);
                this.#emit();
                if (indicator.scheduledTaskId !== undefined)
                    this.#onScheduledTaskCreated(indicator.scheduledTaskId);
                if (this.#sessionId !== undefined)
                    void this.#loadWebImages(
                        turnId,
                        indicator,
                        selectionGeneration,
                        this.#sessionId,
                    );
            },
            onReasoning: (event, turnId) => {
                if (selectionGeneration !== this.#startupGeneration)
                    return;
                this.#transcript.appendReasoning(event, turnId);
                this.#emit();
            },
            onArtifact: (artifact, turnId) => {
                if (selectionGeneration !== this.#startupGeneration)
                    return;
                const pendingItemId = this.#transcript.addGeneratedImage(artifact, turnId);
                if (pendingItemId !== undefined) {
                    this.#speech.replaceItemId(
                        turnId,
                        pendingItemId,
                        artifact.itemId,
                    );
                }
                this.#emit();
            },
            onCompaction: event => {
                if (selectionGeneration !== this.#startupGeneration)
                    return;
                this.#compacting = event.status === "compacting";
                this.#transcript.upsertCompaction(event);
                this.#emit();
            },
            onFailed: (failure, turnId, timestamp) => {
                if (selectionGeneration !== this.#startupGeneration)
                    return;
                if (failure.code === "cancelled") {
                    this.#transcript.updateQueueState(turnId, "cancelled");
                    this.#emit();
                    return;
                }
                const copy = uiText(this.#language);
                this.#transcript.addFailure(
                    turnId,
                    copy.turnFailed,
                    failure.code,
                    failure.message,
                    copy.technicalDetails,
                    timestamp,
                );
                this.#transcript.failTurn(turnId);
                this.#emit();
            },
        };
    }

    #loadStoredWebImages(
        turns: readonly StoredTurn[],
        selectionGeneration: number,
        sessionId: string,
    ): void {
        for (const turn of turns) {
            for (const item of turn.items) {
                if (item.kind === "tool")
                    void this.#loadWebImages(
                        turn.turnId,
                        item.indicator,
                        selectionGeneration,
                        sessionId,
                    );
            }
        }
    }

    async #loadWebImages(
        turnId: string,
        indicator: ToolIndicator,
        selectionGeneration: number,
        sessionId: string,
    ): Promise<void> {
        if (indicator.name !== "image_search" || indicator.status !== "succeeded")
            return;
        try {
            const detail = await this.#transport.loadToolDetail(
                this.#profileId,
                sessionId,
                turnId,
                indicator.callIndex,
            );
            const images = webImageReferences(
                detail.details,
                url => this.#transport.resourceUrl(url),
            );
            if (
                images.length === 0
                || selectionGeneration !== this.#startupGeneration
                || sessionId !== this.#sessionId
            ) return;
            this.#transcript.setToolWebImages(turnId, indicator.callIndex, images);
            this.#emit();
        } catch (error: unknown) {
            console.error("Loading searched images for chat failed", error);
        }
    }

    #finishTurn(result: TextTurnResult, turnId: string): void {
        this.#setLanguage(result.language);
        this.#transcript.replaceTurnId(turnId, result.turnId);
        this.#transcript.finishTurn(result);
        if (result.userImage !== undefined)
            this.#visionRequired = true;
        this.#speech.replaceTurnId(turnId, result.turnId);
        for (const indicator of this.#transcript.toolsForTurn(result.turnId, "image_search"))
            void this.#loadWebImages(
                result.turnId,
                indicator,
                this.#startupGeneration,
                this.#sessionId!,
            );
        this.#refreshRecentSessionsAfterFirstTurn();
    }

    #failTurn(turnId: string, error: unknown, logMessage: string): void {
        console.error(logMessage, error);
        if (this.#speech.state.active?.turnId === turnId)
            this.#speech.stop();
        this.#transcript.failTurn(turnId);
        this.#showError(uiText(this.#language).turnFailed);
        this.#playChatMusic();
    }

    #reset(phase: SessionPhase): void {
        this.#codexEventsAbort?.abort();
        this.#codexEventsAbort = undefined;
        this.#sessionTurnsAbort?.abort();
        this.#sessionTurnsAbort = undefined;
        this.#cancelLiveListening();
        for (const control of this.#liveControls)
            control.cancel();
        this.#liveControls.clear();
        this.#localLiveTurnIds.clear();
        this.#phase = phase;
        this.#stopChatMusic();
        this.#speech.stop();
        this.#transcript.clear();
        this.#clearPendingImage();
        for (const url of this.#localImageUrls)
            URL.revokeObjectURL(url);
        this.#localImageUrls.clear();
        this.#visionRequired = false;
        this.#compacting = false;
        this.#externalScheduledModels.clear();
        this.#externalScheduledTranscriptTurns.clear();
        this.#externalScheduledSpeechTurns.clear();
        this.#externalConversationSequences.clear();
        this.#scheduledYieldTurnId = undefined;
        this.#scheduledYieldCompletion = undefined;
        this.#nonScheduledConversationTurns.clear();
        this.#locallyRunningConversationTurns.clear();
        this.#observerFollowedLocalTurns.clear();
        this.#pendingExternalConversationEvents.clear();
        this.#activeTurnId = undefined;
        this.#sessionId = undefined;
        this.#clearError();
        this.#emit();
    }

    #cancelLiveListening(): void {
        this.#liveMode = false;
        this.#audio.stopThinkingMusic();
        this.#liveControl?.cancel();
        this.#liveControl = undefined;
        this.#liveAudio.releaseMicrophone();
        this.#transcript.cancelDraft();
    }

    #leaveLiveCapture(): void {
        if (!this.#liveMode)
            return;
        this.#cancelLiveListening();
        if (this.#phase !== "scheduled-yield")
            this.#phase = this.#locallyRunningConversationTurns.size > 0
                ? "streaming"
                : this.#idlePhase();
    }

    #continuousMicrophoneEnabled(): boolean {
        return keepMicrophoneOpenBetweenTurns(
            this.#keepMicrophoneOn,
            this.#playMusic,
            this.#speech.state.autoEnabled,
        );
    }

    #acceptLocalLiveTurn(submissionId: string, turnId: string): boolean {
        if (!this.#localLiveTurnIds.has(submissionId))
            return false;
        const currentTurnId = this.#localLiveTurnIds.get(submissionId)!;
        if (currentTurnId !== turnId) {
            this.#transcript.replaceTurnId(currentTurnId, turnId);
            this.#speech.replaceTurnId(currentTurnId, turnId);
            if (this.#activeTurnId === currentTurnId)
                this.#activeTurnId = turnId;
            this.#localLiveTurnIds.set(submissionId, turnId);
        }
        this.#nonScheduledConversationTurns.add(turnId);
        return true;
    }

    #followLocalTurnDurably(
        turnId: string,
        modelName: string,
        sessionId: string,
        startupGeneration: number,
        afterPresentationSequence: number,
    ): void {
        this.#nonScheduledConversationTurns.delete(turnId);
        this.#externalScheduledModels.set(turnId, modelName);
        this.#externalScheduledTranscriptTurns.add(turnId);
        this.#externalScheduledSpeechTurns.add(turnId);
        this.#observerFollowedLocalTurns.add(turnId);
        this.#watchSessionTurns(
            sessionId,
            startupGeneration,
            afterPresentationSequence,
        );
    }

    #finishObserverFollowedLocalTurn(turnId: string): void {
        if (!this.#observerFollowedLocalTurns.delete(turnId))
            return;
        this.#nonScheduledConversationTurns.add(turnId);
        this.#locallyRunningConversationTurns.delete(turnId);
        if (this.#activeTurnId === turnId)
            this.#activeTurnId = [...this.#locallyRunningConversationTurns].at(-1);
        if (this.#locallyRunningConversationTurns.size === 0)
            this.#phase = this.#idlePhase();
    }

    #playChatMusic(): void {
        if (
            !this.#playMusic
            || this.#liveMode
            || this.#panel !== "chat"
            || this.#sessionId === undefined
            || this.#phase === "launcher"
            || this.#phase === "loading"
            || this.#phase === "starting"
            || this.#phase === "requesting-live-microphone"
            || this.#phase === "live-listening"
            || this.#phase === "live-transcribing"
            || this.#speech.state.active !== undefined
            || this.#chatMusicPlaying
        ) {
            return;
        }
        this.#chatMusicPlaying = true;
        this.#audio.applyThinkingMusic(this.#profileId, { action: "play", delayMs: 0 });
    }

    #stopChatMusic(): void {
        this.#chatMusicPlaying = false;
        this.#audio.stopThinkingMusic();
    }

    #playResponseAutomatically(
        profileId: string,
        sessionId: string,
        turnId: string,
        itemId?: string,
        startAfterExisting = false,
    ): void {
        if (!this.#speech.state.autoEnabled)
            return;
        this.#speech.playAutomatically(
            profileId,
            sessionId,
            turnId,
            itemId,
            startAfterExisting,
        );
    }

    #idlePhase(): SessionPhase {
        return this.#preparationComplete ? "ready" : "preparing";
    }

    #hasOpenChat(): boolean {
        return this.#phase !== "launcher" && this.#phase !== "loading";
    }

    #canSwitchChats(): boolean {
        return this.#phase !== "loading" && this.#phase !== "starting";
    }

    #canBranchChat(): boolean {
        return this.#panel === "chat" && (this.#phase === "launcher"
            || this.#phase === "ready"
            || this.#phase === "starting"
            || this.#phase === "preparing");
    }

    #canStartNewChat(): boolean {
        return this.#panel === "home"
            ? this.#phase !== "loading" && this.#phase !== "starting"
            : this.#canSwitchChats();
    }

    #canDeleteChat(): boolean {
        return (this.#phase === "starting"
                || this.#phase === "preparing"
                || this.#phase === "ready")
            && this.#hasDeletableChat()
            && !this.#recentSessions.some(session =>
                session.sessionId === this.#sessionId && session.processing);
    }

    #hasDeletableChat(): boolean {
        return this.#sessionId !== undefined
            && this.#recentSessions.some(session => session.sessionId === this.#sessionId);
    }

    #refreshRecentSessionsAfterFirstTurn(): void {
        if (this.#sessionId !== undefined
            && !this.#recentSessions.some(session => session.sessionId === this.#sessionId))
            void this.#refreshRecentSessions();
    }

    async #refreshRecentSessions(background = false): Promise<void> {
        if (background && this.#recentSessionsLoading)
            return;
        const requestId = ++this.#recentRequestId;
        if (!background) {
            this.#recentSessionsLoading = true;
            this.#emit();
        }
        try {
            const sessions = await this.#transport.loadRecentSessions(this.#profileId);
            if (requestId === this.#recentRequestId) {
                const changed = JSON.stringify(sessions) !== JSON.stringify(this.#recentSessions);
                this.#recentSessions = sessions;
                if (background && changed) this.#emit();
            }
        } catch (error: unknown) {
            console.error("Recent chats failed", error);
            if (!background && requestId === this.#recentRequestId)
                this.#showError(uiText(this.#language).recentChatsFailed);
        } finally {
            if (!background && requestId === this.#recentRequestId) {
                this.#recentSessionsLoading = false;
                this.#emit();
            }
        }
    }

    #showError(error: string): void {
        this.#error = error;
        this.#errorVersion++;
        if (this.#errorTimeout !== undefined)
            clearTimeout(this.#errorTimeout);
        this.#errorTimeout = setTimeout(() => {
            this.#errorTimeout = undefined;
            this.#error = undefined;
            this.#emit();
        }, errorVisibleDurationMs + errorFadeDurationMs);
    }

    #clearError(): void {
        if (this.#errorTimeout !== undefined)
            clearTimeout(this.#errorTimeout);
        this.#errorTimeout = undefined;
        this.#error = undefined;
    }

    #emit(): void {
        if (this.#restoringPresentation)
            return;
        for (const listener of this.#listeners)
            listener();
    }

    #takePendingImage(): { readonly file: File; readonly preview: UserImage } | undefined {
        const file = this.#pendingImageFile;
        const preview = this.#pendingImage;
        if (file === undefined || preview === undefined)
            return undefined;
        this.#pendingImageFile = undefined;
        this.#pendingImage = undefined;
        this.#visionRequired = true;
        return { file, preview };
    }

    #clearPendingImage(): void {
        const url = this.#pendingImage?.url;
        this.#pendingImageFile = undefined;
        this.#pendingImage = undefined;
        if (url !== undefined) {
            URL.revokeObjectURL(url);
            this.#localImageUrls.delete(url);
        }
    }

    #selectFirstVisionModel(): void {
        const model = this.#models.find(candidate => candidate.vision)
            ?? Er.internal("This image chat has no available vision-capable model.");
        this.#modelId = model.id;
        this.#saveModelPreference(model.id);
        this.#normalizeReasoningPreference();
    }
}

function webImageReferences(
    value: unknown,
    resolveResource: (url: string) => string,
): readonly WebImageReference[] {
    if (!isRecord(value) || !Array.isArray(value["images"]))
        return [];
    return value["images"].flatMap(candidate => {
        if (!isRecord(candidate)) return [];
        const title = candidate["title"];
        const imageUrl = candidate["image_url"];
        const sourceUrl = candidate["source_url"];
        const mediaType = candidate["media_type"];
        const width = candidate["width"];
        const height = candidate["height"];
        if (
            typeof title !== "string"
            || typeof imageUrl !== "string"
            || typeof sourceUrl !== "string"
            || (mediaType !== "image/jpeg" && mediaType !== "image/png")
        ) return [];
        return [{
            title,
            imageUrl: resolveResource(imageUrl),
            sourceUrl,
            mediaType,
            ...(typeof width === "number" && Number.isSafeInteger(width) && width > 0
                ? { width }
                : {}),
            ...(typeof height === "number" && Number.isSafeInteger(height) && height > 0
                ? { height }
                : {}),
        }];
    });
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function promptStartsWithThink(text: string): boolean {
    return /^\s*think(?![\p{L}\p{N}_])/iu.test(text);
}
