import type { ChatSessionSnapshot } from "../chat/ChatSession";
import type { ChatLanguage } from "../chat/Language";
import { keepMicrophoneOpenBetweenTurns } from "../audio/MicrophonePolicy";
import { cssColor, type Accent, type AccentId } from "../theme/Accents";
import type {
    ChatBranchPoint,
    ModelInfo,
    ProfileSummary,
    RecentSessionSummary,
    ToolDetail,
} from "../transport/ChatTransport";
import { ChatComposer } from "./ChatComposer";
import { ChatToolbar } from "./ChatToolbar";
import { ChatTranscriptView } from "./ChatTranscriptView";
import { HomeView } from "./HomeView";
import { H } from "./h";
import { ToolDetailDialog } from "./ToolDetailDialog";
import { InstructionEditor } from "./InstructionEditor";
import type { AudioLevelSource } from "./RecordingWaveform";
import type { ChatTransport } from "../transport/ChatTransport";
import { ScheduledTaskManager } from "./ScheduledTaskManager";

export interface ChatAppViewHandlers {
  readonly onSend: (text: string) => Promise<boolean>;
  readonly onStop: () => void;
  readonly onStartLiveListening: () => void;
  readonly onCancelLiveListening: () => void;
  readonly onSubmitLiveListening: () => void;
  readonly onNewChat: () => void;
  readonly onLanguageChange: (language: ChatLanguage) => void;
  readonly onHome: () => void;
  readonly onOpenRecent: (session: RecentSessionSummary) => void;
  readonly onDelete: () => void;
  readonly onBranch: (point: ChatBranchPoint) => void;
  readonly onCancelQueued: (itemId: string, turnId: string) => void;
  readonly onProfileChange: (profileId: string) => void;
  readonly onAccentChange: (accentId: AccentId) => void;
  readonly onToggleAutoSpeak: () => void;
  readonly onTogglePlayMusic: () => void;
  readonly onToggleKeepMicrophoneOn: () => void;
  readonly onToggleReasoning: () => void;
  readonly onModelChange: (modelId: string) => void;
  readonly onImageSelected: (file: File | undefined) => void;
  readonly onActivityPaneOpenChange: (open: boolean) => void;
  readonly onSpeak: (turnId: string, itemId: string) => void;
  readonly onSpeakText: (turnId: string, itemId: string, text: string) => void;
  readonly onSpeakReasoning: (turnId: string, itemId: string) => void;
  readonly onLoadReasoning: (turnId: string, itemId: string) => Promise<string>;
  readonly onPlayUserAudio: (turnId: string, audioUrl: string) => void;
  readonly onStopPlayback: () => void;
  readonly onSpeechCommitDelayChange: (seconds: number) => void;
  readonly onShowThinkingChange: (show: boolean) => void;
  readonly onCompactNow: () => void;
  readonly onShowCompactedContextChange: (show: boolean) => void;
  readonly onLoadToolDetail: (
    turnId: string,
    callIndex: number,
  ) => Promise<ToolDetail>;
  readonly onOpenInstructions: () => void;
    readonly onOpenScheduledTasks: () => void;
    readonly onToggleScreenShare: () => void;
    readonly onDirectInteraction: () => void;
}

export class ChatAppView {
    readonly element: HTMLElement;
    readonly #toolbar: ChatToolbar;
    readonly #home: HomeView;
    readonly #main: HTMLElement;
    readonly #transcript: ChatTranscriptView;
    readonly #composer: ChatComposer;
    readonly #toolDetail: ToolDetailDialog;
    readonly #instructions: InstructionEditor;
    readonly #scheduledTasks: ScheduledTaskManager;
    #lastSnapshot: ChatSessionSnapshot | undefined;
    #language: ChatLanguage;

    constructor(
        handlers: ChatAppViewHandlers,
        api: ChatTransport,
        recordingLevels: AudioLevelSource,
        profiles: readonly ProfileSummary[],
        models: readonly ModelInfo[],
        profileId: string,
        accentId: AccentId,
        language: ChatLanguage,
        activityPaneOpen: boolean,
        showThinking: boolean,
        showCompactedContext: boolean,
        speechCommitDelaySeconds: number,
    ) {
        this.#language = language;
        this.#toolDetail = new ToolDetailDialog(handlers.onLoadToolDetail);
        this.#instructions = new InstructionEditor(api, {
            onClose: () => this.#applyVisibility(),
        });
        this.#scheduledTasks = new ScheduledTaskManager(api);
        this.#home = new HomeView({ onOpenRecent: handlers.onOpenRecent });
        this.#toolbar = new ChatToolbar(
            {
                onHome: handlers.onHome,
                onNewChat: handlers.onNewChat,
                onOpenRecent: handlers.onOpenRecent,
                onLanguageChange: handlers.onLanguageChange,
                onDelete: handlers.onDelete,
                onProfileChange: handlers.onProfileChange,
                onSearchChats: (query) => this.#home.setSearch(query),
                onFilterChats: (filter) => this.#home.setFilter(filter),
                onAccentChange: handlers.onAccentChange,
                onToggleAutoSpeak: handlers.onToggleAutoSpeak,
                onTogglePlayMusic: handlers.onTogglePlayMusic,
                onToggleKeepMicrophoneOn: handlers.onToggleKeepMicrophoneOn,
                onStopPlayback: handlers.onStopPlayback,
                onSpeechCommitDelayChange: handlers.onSpeechCommitDelayChange,
                onShowThinkingChange: handlers.onShowThinkingChange,
                onCompactNow: handlers.onCompactNow,
                onShowCompactedContextChange: handlers.onShowCompactedContextChange,
                onOpenInstructions: handlers.onOpenInstructions,
                onOpenScheduledTasks: handlers.onOpenScheduledTasks,
                onToggleScreenShare: handlers.onToggleScreenShare,
            },
            profiles,
            profileId,
            accentId,
            language,
            showThinking,
            showCompactedContext,
            speechCommitDelaySeconds,
        );
        this.#transcript = new ChatTranscriptView(
            {
                onBranch: handlers.onBranch,
                onCancelQueued: handlers.onCancelQueued,
                onSpeak: handlers.onSpeak,
                onSpeakText: handlers.onSpeakText,
                onSpeakReasoning: handlers.onSpeakReasoning,
                onLoadReasoning: handlers.onLoadReasoning,
                onPlayUserAudio: handlers.onPlayUserAudio,
                onStopPlayback: handlers.onStopPlayback,
                onInspectTool: (turnId, callIndex, toolName) =>
                    void this.#toolDetail.open(
                        turnId,
                        callIndex,
                        toolName,
                        this.#language,
                    ),
                onActivityPaneOpenChange: handlers.onActivityPaneOpenChange,
            },
            activityPaneOpen,
            showThinking,
            showCompactedContext,
        );
        this.#composer = new ChatComposer(
            {
                onSend: handlers.onSend,
                onStop: handlers.onStop,
                onStartLiveListening: handlers.onStartLiveListening,
                onCancelLiveListening: handlers.onCancelLiveListening,
                onSubmitLiveListening: handlers.onSubmitLiveListening,
                onToggleReasoning: handlers.onToggleReasoning,
                onModelChange: handlers.onModelChange,
                onImageSelected: handlers.onImageSelected,
                onInteraction: handlers.onDirectInteraction,
            },
            recordingLevels,
            models,
        );
        const conversation = H.div()
            .class("chat-conversation")
            .append(this.#transcript.element, this.#composer.element)
            .el();
        this.#main = H.main()
            .class("chat-main")
            .append(conversation, this.#transcript.activityPane)
            .el();
        this.element = H.div()
            .class("chat-shell")
            .append(
                this.#toolbar.element,
                this.#home.element,
                this.#main,
                this.#instructions.element,
                this.#scheduledTasks.element,
                this.#scheduledTasks.editor,
                this.#toolDetail.element,
            )
            .el();
    }

    selectProfile(profileId: string): void {
        this.#toolbar.selectProfile(profileId);
        this.#toolbar.clearSearch();
        this.#toolbar.resetRecentFilter();
        this.#home.clearSearch();
        this.#home.resetFilter();
    }

    applyAccent(value: Accent): void {
        this.element.style.setProperty("--accent", cssColor(value.color));
        this.element.style.setProperty("--accent-bg", cssColor(value.background));
        this.#toolbar.setAccent(value.id);
    }

    setActivityPaneOpen(open: boolean): void {
        this.#transcript.setActivityPaneOpen(open);
    }

    setShowThinking(show: boolean): void {
        this.#toolbar.setShowThinking(show);
        this.#transcript.setShowThinking(show);
    }

    setShowCompactedContext(show: boolean): void {
        this.#toolbar.setShowCompactedContext(show);
        this.#transcript.setShowCompactedContext(show);
    }

    setScreenShareActive(active: boolean): void {
        this.#toolbar.setScreenShareActive(active);
        if (this.#lastSnapshot !== undefined) this.render(this.#lastSnapshot);
    }

    render(snapshot: ChatSessionSnapshot): void {
        this.#lastSnapshot = snapshot;
        this.#language = snapshot.language;
        document.documentElement.lang = snapshot.language;
        this.#toolbar.render(snapshot);
        this.#scheduledTasks.setContext(
            snapshot.profileId,
            snapshot.currentSessionId ?? "",
            snapshot.modelId,
            snapshot.models,
            snapshot.language,
        );
        this.#instructions.setLanguage(snapshot.language);
        this.#applyVisibility();
        if (snapshot.panel === "home") this.#home.render(snapshot);
        this.#transcript.render(snapshot);
        this.#composer.render(
            snapshot.phase,
            keepMicrophoneOpenBetweenTurns(
                snapshot.keepMicrophoneOn,
                snapshot.playMusic,
                snapshot.speech.autoEnabled,
            ),
            snapshot.language,
            this.#toolbar.profileName,
            snapshot.modelId,
            snapshot.reasoningMode,
            snapshot.pendingImage,
            snapshot.visionRequired,
        );
    }

    async openInstructions(
        profileId: string,
        language: ChatLanguage,
    ): Promise<void> {
        const loading = this.#instructions.open(profileId, language);
        this.#applyVisibility();
        await loading;
    }

    async openScheduledTasks(): Promise<void> {
        await this.#scheduledTasks.open();
    }

    async openScheduledTaskEditor(taskId: string): Promise<void> {
        await this.#scheduledTasks.openEditor(taskId);
    }

    #applyVisibility(): void {
        const snapshot = this.#lastSnapshot;
        if (snapshot === undefined) return;
        const editing = this.#instructions.isOpen;
        this.#toolbar.element.hidden = editing;
        this.#home.element.hidden = editing || snapshot.panel !== "home";
        this.#main.hidden = editing || snapshot.panel !== "chat";
    }
}
