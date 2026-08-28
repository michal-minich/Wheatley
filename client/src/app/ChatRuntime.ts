import { BrowserAudioRuntime } from "../audio/BrowserAudioRuntime";
import { BrowserLiveAudio } from "../audio/BrowserLiveAudio";
import { BrowserScreenCapture } from "../capture/BrowserScreenCapture";
import { ChatSession } from "../chat/ChatSession";
import { ChatSpeech } from "../chat/ChatSpeech";
import type { AccentId } from "../theme/Accents";
import type {
    ChatBranchPoint,
    ChatTransport,
    ModelCatalog,
    ModelInfo,
    ProfileSummary,
    RecentSessionSummary,
    StartupState,
} from "../transport/ChatTransport";
import type { WheatleyEndpoint } from "../transport/WheatleyEndpoint";
import { ChatAppView } from "../ui/ChatAppView";
import { ClientConfig } from "./ClientConfig";
import { chatPath, parseChatPath } from "./ChatRoute";

export class ChatRuntime {
    readonly #clientConfig: ClientConfig;
    readonly #session: ChatSession;
    readonly #view: ChatAppView;
    readonly #models: ModelCatalog;
    readonly #screenCapture: BrowserScreenCapture;
    #renderScheduled = false;

    constructor(
        root: HTMLElement,
        api: ChatTransport,
        endpoint: WheatleyEndpoint,
        clientConfig: ClientConfig,
        profiles: readonly ProfileSummary[],
        models: ModelCatalog,
        startup: StartupState,
    ) {
        this.#clientConfig = clientConfig;
        this.#models = models;
        const audio = new BrowserAudioRuntime(
            endpoint,
            clientConfig.outputRecoveryMs,
            clientConfig.thinkingMusicFadeInMs,
            clientConfig.thinkingMusicFadeOutMs,
        );
        const speech = new ChatSpeech(
            api,
            audio,
            clientConfig.autoSpeak,
            (enabled) => clientConfig.setAutoSpeak(enabled),
        );
        const liveAudio = new BrowserLiveAudio(
            endpoint,
            audio,
            clientConfig.speechCommitDelaySeconds,
        );
        this.#screenCapture = new BrowserScreenCapture(
            endpoint,
            audio,
            () => this.#clientConfig.profileId,
            (active) => this.#view.setScreenShareActive(active),
        );
        this.#session = new ChatSession(
            api,
            liveAudio,
            audio,
            speech,
            "web",
            clientConfig.profileId,
            startup,
            (language) => clientConfig.setLanguage(language),
            clientConfig.playMusic,
            (enabled) => clientConfig.setPlayMusic(enabled),
            clientConfig.keepMicrophoneOn,
            (enabled) => clientConfig.setKeepMicrophoneOn(enabled),
            clientConfig.reasoningMode,
            (reasoningMode) => clientConfig.setReasoningMode(reasoningMode),
            models,
            clientConfig.modelId,
            (modelId) => clientConfig.setModel(modelId),
            taskId => void this.#view.openScheduledTaskEditor(taskId).catch((error: unknown) => {
                console.error("Opening created scheduled task failed", error);
            }),
        );
        this.#view = new ChatAppView(
            {
                onSend: async (text) => await this.#session.send(text),
                onStop: () => void this.#session.stop(),
                onStartLiveListening: () => this.#session.startLiveListening(),
                onCancelLiveListening: () => this.#session.cancelLiveListening(),
                onSubmitLiveListening: () => this.#session.submitLiveListening(),
                onNewChat: () => void this.#newChat(),
                onLanguageChange: (language) => this.#session.selectLanguage(language),
                onHome: () => this.#showHome(true),
                onOpenRecent: (session) => void this.#openRecent(session, true),
                onDelete: () => void this.#session.deleteCurrentSession(),
                onBranch: (point) => void this.#branch(point),
                onCancelQueued: (itemId, turnId) =>
                    void this.#session.cancelQueuedTurn(itemId, turnId),
                onProfileChange: (profileId) => {
                    history.pushState(null, "", "/");
                    void this.#changeProfile(profileId);
                },
                onAccentChange: (accentId) => this.#selectAccent(accentId),
                onToggleAutoSpeak: () => this.#session.toggleAutoSpeak(),
                onTogglePlayMusic: () => this.#session.togglePlayMusic(),
                onToggleKeepMicrophoneOn: () => this.#session.toggleKeepMicrophoneOn(),
                onToggleReasoning: () => this.#session.toggleReasoning(),
                onModelChange: (modelId) => {
                    if (this.#screenCapture.active && !this.#model(modelId).vision)
                        void this.#screenCapture.stop();
                    this.#session.selectModel(modelId);
                },
                onImageSelected: (file) => this.#session.selectImage(file),
                onActivityPaneOpenChange: (open) =>
                    this.#clientConfig.setActivityPaneOpen(open),
                onSpeak: (turnId, itemId) => this.#session.speak(turnId, itemId),
                onSpeakText: (turnId, itemId, text) =>
                    this.#session.speakText(turnId, itemId, text),
                onSpeakReasoning: (turnId, itemId) =>
                    this.#session.speakReasoning(turnId, itemId),
                onLoadReasoning: async (turnId, itemId) =>
                    await this.#session.loadReasoning(turnId, itemId),
                onPlayUserAudio: (turnId, audioUrl) =>
                    this.#session.playUserAudio(turnId, audioUrl),
                onStopPlayback: () => this.#session.stopPlayback(),
                onSpeechCommitDelayChange: (seconds) => {
                    liveAudio.setSpeechCommitDelaySeconds(seconds);
                    this.#clientConfig.setSpeechCommitDelaySeconds(seconds);
                },
                onShowThinkingChange: (show) => {
                    this.#clientConfig.setShowThinking(show);
                    this.#view.setShowThinking(show);
                },
                onCompactNow: () => void this.#session.compactNow(),
                onShowCompactedContextChange: (show) => {
                    this.#clientConfig.setShowCompactedContext(show);
                    this.#view.setShowCompactedContext(show);
                },
                onOpenInstructions: () =>
                    void this.#view.openInstructions(
                        this.#clientConfig.profileId,
                        this.#session.snapshot().language,
                    ),
                onOpenScheduledTasks: () => void this.#view.openScheduledTasks(),
                onToggleScreenShare: () =>
                    void this.#toggleScreenShare().catch((error: unknown) => {
                        console.error("Screen sharing failed", error);
                        globalThis.alert(
                            error instanceof Error ? error.message : String(error),
                        );
                    }),
                onDirectInteraction: () => this.#session.noteDirectInteraction(),
                onLoadToolDetail: async (turnId, callIndex) =>
                    await this.#session.loadToolDetail(turnId, callIndex),
            },
            api,
            this.#session,
            profiles,
            models.models,
            clientConfig.profileId,
            clientConfig.accent.id,
            startup.language,
            clientConfig.activityPaneOpen,
            clientConfig.showThinking,
            clientConfig.showCompactedContext,
            clientConfig.speechCommitDelaySeconds,
        );

        this.#view.applyAccent(clientConfig.accent);
        this.#session.observe(() => this.#scheduleRender());
        root.replaceChildren(this.#view.element);
        this.#view.render(this.#session.snapshot());
        void this.#initializeRoute(profiles);
        globalThis.addEventListener(
            "popstate",
            () => void this.#applyRoute(profiles),
        );
        globalThis.addEventListener(
            "pagehide",
            () => void this.#screenCapture.stop(),
        );
    }

    async #initializeRoute(profiles: readonly ProfileSummary[]): Promise<void> {
        if (globalThis.location.pathname === "/new") {
            await this.#newChat(true);
            return;
        }
        await this.#session.openHome();
        await this.#applyRoute(profiles);
    }

    async #applyRoute(profiles: readonly ProfileSummary[]): Promise<void> {
        const route = parseChatPath(globalThis.location.pathname);
        if (route === undefined) {
            if (globalThis.location.pathname.startsWith("/chat/"))
                history.replaceState(null, "", "/");
            this.#session.showHome();
            return;
        }
        if (!profiles.some((profile) => profile.id === route.profileId)) {
            history.replaceState(null, "", "/");
            this.#session.showHome();
            return;
        }
        if (route.profileId !== this.#clientConfig.profileId)
            await this.#selectProfile(route.profileId);
        const recent = this.#session
            .snapshot()
            .recentSessions.find((session) => session.sessionId === route.sessionId);
        if (recent === undefined) {
            history.replaceState(null, "", "/");
            this.#session.showHome();
            return;
        }
        await this.#session.openRecent(recent);
    }

    async #openRecent(
        session: RecentSessionSummary,
        push: boolean,
    ): Promise<void> {
        if (push)
            history.pushState(
                null,
                "",
                chatPath(this.#clientConfig.profileId, session.sessionId),
            );
        await this.#session.openRecent(session);
    }

    #showHome(push: boolean): void {
        if (push && globalThis.location.pathname !== "/")
            history.pushState(null, "", "/");
        this.#session.showHome();
    }

    async #newChat(replace = false): Promise<void> {
        await this.#session.newChat();
        const sessionId = this.#session.snapshot().currentSessionId;
        if (sessionId !== undefined) {
            const path = chatPath(this.#clientConfig.profileId, sessionId);
            if (replace) history.replaceState(null, "", path);
            else history.pushState(null, "", path);
        }
    }

    async #branch(point: ChatBranchPoint): Promise<void> {
        const result = await this.#session.branch(point);
        if (result !== undefined)
            history.pushState(
                null,
                "",
                chatPath(this.#clientConfig.profileId, result.sessionId),
            );
    }

    async #selectProfile(profileId: string): Promise<void> {
        this.#clientConfig.selectProfile(profileId);
        this.#clientConfig.selectAvailableModel(this.#models);
        this.#view.selectProfile(profileId);
        this.#view.applyAccent(this.#clientConfig.accent);
        this.#view.setActivityPaneOpen(this.#clientConfig.activityPaneOpen);
        this.#view.setShowThinking(this.#clientConfig.showThinking);
        this.#view.setShowCompactedContext(this.#clientConfig.showCompactedContext);
        await this.#session.selectProfile(
            profileId,
            this.#clientConfig.autoSpeak,
            this.#clientConfig.playMusic,
            this.#clientConfig.keepMicrophoneOn,
            this.#clientConfig.language,
            this.#clientConfig.reasoningMode,
            this.#clientConfig.modelId,
        );
    }

    async #changeProfile(profileId: string): Promise<void> {
        if (this.#screenCapture.active) await this.#screenCapture.stop();
        await this.#selectProfile(profileId);
    }

    async #toggleScreenShare(): Promise<void> {
        if (!this.#screenCapture.active) {
            const current = this.#model(this.#clientConfig.modelId);
            if (!current.vision) {
                const vision = this.#models.models.find((model) => model.vision);
                if (vision === undefined)
                    throw new Error("Screen sharing requires an available vision model.");
                this.#session.selectModel(vision.id);
            }
        }
        await this.#screenCapture.toggle();
    }

    #model(modelId: string): ModelInfo {
        const model = this.#models.models.find(
            (candidate) => candidate.id === modelId,
        );
        if (model === undefined) throw new Error(`Unknown model ${modelId}.`);
        return model;
    }

    #selectAccent(accentId: AccentId): void {
        this.#clientConfig.setAccent(accentId);
        this.#view.applyAccent(this.#clientConfig.accent);
    }

    #scheduleRender(): void {
        if (this.#renderScheduled) return;
        this.#renderScheduled = true;
        requestAnimationFrame(() => {
            this.#renderScheduled = false;
            this.#view.render(this.#session.snapshot());
        });
    }
}
