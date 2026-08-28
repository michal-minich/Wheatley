import type { ChatLanguage } from "../chat/Language";

export const reasoningModes = [
    "off", "minimal", "low", "medium", "high", "xhigh", "max",
] as const;
export type ReasoningMode = (typeof reasoningModes)[number];

export function isReasoningMode(value: string): value is ReasoningMode {
    return reasoningModes.includes(value as ReasoningMode);
}

export type ConversationEventKind =
  | "status"
  | "assistant_delta"
  | "reasoning"
  | "tool"
  | "artifact"
  | "completed"
  | "failed";

/** An ordered, durable event from a conversation turn. */
export interface ConversationEventEnvelope {
  readonly profileId: string;
  readonly sessionId: string;
  readonly turnId: string;
  readonly sequence: number;
  /** Shared session-journal position, present on live server events. */
  readonly presentationSequence?: number;
  readonly timestamp: string;
  readonly kind: ConversationEventKind;
  readonly payload: unknown;
}

/** A durable conversation event at its position in the shared session journal. */
export interface PresentedConversationEvent extends ConversationEventEnvelope {
  readonly presentationSequence: number;
}

export interface ConversationFailure {
  readonly code: string;
  readonly message: string;
}

export interface ConversationAccepted {
  readonly turnId: string;
  readonly submissionId: string;
  readonly queueState: SessionQueueItemState;
  readonly queueSequence: number;
  readonly queueRevision: number;
}

export interface PresentedConversationFailure extends ConversationFailure {
  readonly turnId: string;
  readonly timestamp: string;
  readonly presentationSequence: number;
}

export interface ProfileSummary {
  readonly id: string;
}

export interface ModelInfo {
  readonly id: string;
  readonly provider: string;
  readonly model: string;
  readonly name: string;
  readonly reasoning: boolean;
  readonly reasoningModes: readonly ReasoningMode[];
  readonly vision: boolean;
  readonly contextWindow: number;
}

export interface ModelCatalog {
  readonly defaultModelId: string;
  readonly models: readonly ModelInfo[];
}

export interface ProfileClientConfigData {
  readonly profileId: string;
  readonly accentId: string;
  readonly autoSpeak: boolean;
  readonly playMusic: boolean;
  readonly keepMicrophoneOn: boolean;
  readonly language: ChatLanguage | "";
  readonly reasoningMode: ReasoningMode;
  readonly activityPaneOpen: boolean;
  readonly showThinking: boolean;
  readonly showCompactedContext: boolean;
  readonly modelId: string;
}

export interface ClientConfigData {
  readonly lastUsedProfileId: string;
  readonly speechCommitDelaySeconds: number;
  readonly outputRecoveryMs: number;
  readonly thinkingMusicFadeInMs: number;
  readonly thinkingMusicFadeOutMs: number;
  readonly profiles: readonly ProfileClientConfigData[];
}

export interface StartupState {
  readonly canResumeLastSession: boolean;
  readonly lastSessionId: string;
  readonly language: ChatLanguage;
  readonly lastSessionLanguage: ChatLanguage | "";
  readonly supportedLanguages: readonly ChatLanguage[];
}

export type SessionChoice =
  | { readonly kind: "new"; readonly language: ChatLanguage }
  | {
      readonly kind: "resume";
      readonly sessionId: string;
      readonly language: ChatLanguage;
    };

export interface RecentSessionSummary {
  readonly sessionId: string;
  readonly startedAt: string;
  readonly language: ChatLanguage;
  readonly initialUserText: string;
  readonly processing: boolean;
  readonly hasScheduledTurn: boolean;
  readonly hasToolUse: boolean;
  readonly hasGeneratedImage: boolean;
  readonly hasWebSearch: boolean;
  readonly hasCompaction: boolean;
  readonly hasScreenCapture: boolean;
  readonly automaticSessionUnseen: boolean;
  readonly unseenScheduledTurnCount: number;
}

export interface ScheduledTaskPresenceResult {
  readonly yieldRequested: boolean;
}

export type InstructionDocumentId =
  | "system"
  | "user"
  | "workspace"
  | "auto_memory"
  | "memory_rules";

export interface InstructionDocument {
  readonly id: InstructionDocumentId;
  readonly label: string;
  readonly scope: "profile" | "app";
  readonly content: string;
}

export interface InstructionSnapshot {
  readonly profileId: string;
  readonly workspacePath: string;
  readonly documents: readonly InstructionDocument[];
}

export interface SessionStartResult {
  readonly sessionId: string;
  readonly language: ChatLanguage;
  readonly resumedLastSession: boolean;
  readonly reasoningMode: ReasoningMode;
}

export interface SessionStartHandlers {
  readonly onOpened: (result: SessionStartResult) => void;
}

export type ChatBranchKind = "user" | "reasoning" | "assistant" | "artifact";

export interface ChatBranchPoint {
  readonly turnId: string;
  readonly kind: ChatBranchKind;
  readonly itemId: string;
}

export interface SessionBranchResult {
  readonly sessionId: string;
  readonly language: ChatLanguage;
}

export interface StoredTurn {
  readonly turnId: string;
  readonly submissionId: string;
  readonly startedAt: string;
  readonly completedAt: string;
  readonly modelName: string;
  readonly activityDurationMs: number;
  readonly metrics: TextTurnMetrics;
  readonly userText: string;
  readonly scheduledTask: boolean;
  readonly reasoningMode: ReasoningMode;
  readonly processing: boolean;
  readonly assistantStreaming: boolean;
  readonly assistantStreamingItemId: string;
  readonly items: readonly StoredTurnItem[];
  readonly userAudioUrl?: string;
  readonly userImage?: UserImage;
}

export type SessionQueueItemState =
  | "preparing"
  | "ready"
  | "running"
  | "completed"
  | "failed"
  | "cancelled"
  | "interrupted";

export interface SessionQueueItem {
  readonly id: string;
  readonly sessionId: string;
  readonly sequence: number;
  readonly kind: "user" | "scheduled";
  readonly source: string;
  readonly deviceId: string;
  readonly submittedAt: string;
  readonly state: SessionQueueItemState;
  readonly text: string;
  readonly model: string;
  readonly reasoningMode: ReasoningMode;
  readonly language: ChatLanguage;
  readonly artifactReference: string;
  readonly preparationSource: string;
  readonly executionId: string;
  readonly failure: string;
  readonly resultReference: string;
}

export interface SessionQueueSnapshot {
  readonly schemaVersion: number;
  readonly sessionId: string;
  readonly revision: number;
  readonly nextSequence: number;
  readonly items: readonly SessionQueueItem[];
}

export interface SessionQueueMutation {
  readonly sessionId: string;
  readonly revision: number;
  readonly item: SessionQueueItem;
}

export interface TextTurnMetrics {
  readonly durationMs?: number;
  readonly timeToFirstTokenMs?: number;
  readonly generationMs?: number;
  readonly inputTokens?: number;
  readonly outputTokens?: number;
  readonly cacheReadTokens?: number;
  readonly cacheWriteTokens?: number;
  readonly reasoningTokens?: number;
  readonly totalTokens?: number;
  readonly contextTokens?: number;
  readonly contextWindowTokens?: number;
}

export interface UserImage {
  readonly url: string;
  readonly filename: string;
}

export interface GeneratedImage {
  readonly kind: "generated_image" | "screen_capture";
  readonly generatedImageId?: number;
  readonly itemId: string;
  readonly filename: string;
  readonly mediaType: "image/png";
  readonly url: string;
  readonly path: string;
  readonly sha256: string;
  readonly byteCount: number;
  readonly width: number;
  readonly height: number;
  readonly seed: number;
  readonly quality: "low" | "medium" | "high";
  readonly aspect: "square" | "portrait" | "landscape";
  readonly prompt: string;
  readonly modelWidth?: number;
  readonly modelHeight?: number;
}

export interface PendingGeneratedImage {
  readonly callIndex: number;
  readonly prompt: string;
  readonly width: number;
  readonly height: number;
  readonly quality: "low" | "medium" | "high";
  readonly aspect: "square" | "portrait" | "landscape";
}

export type StoredTurnItem =
  | StoredReasoningItem
  | StoredAssistantItem
  | StoredToolItem
  | StoredGeneratedImageItem;

export interface StoredGeneratedImageItem extends GeneratedImage {
  readonly kind: "generated_image" | "screen_capture";
}

export interface StoredReasoningItem {
  readonly kind: "reasoning";
  readonly itemId: string;
  readonly text: string;
  readonly truncated: boolean;
  readonly durationMs: number;
}

export interface StoredAssistantItem {
  readonly kind: "assistant";
  readonly itemId: string;
  readonly text: string;
  readonly completedAt: string;
}

export interface StoredToolItem {
  readonly kind: "tool";
  readonly itemId: string;
  readonly indicator: ToolIndicator;
}

export interface ReasoningDetail {
  readonly text: string;
}

export interface ReasoningEvent {
  readonly phase: "start" | "delta" | "end";
  readonly itemId: string;
  readonly durationMs: number;
  readonly text: string;
}

export interface TextEvent {
  readonly itemId: string;
  readonly text: string;
}

export interface CodexLiveEvent {
  readonly sequence: number;
  readonly threadId: string;
  readonly turnId: string;
  readonly itemId: string;
  readonly summaryIndex: number;
  readonly kind: "reasoning_summary" | "tool" | "steer" | "final" | "error";
  readonly operation: "start" | "delta" | "finish";
  readonly text: string;
  readonly name: string;
  readonly status: string;
  readonly timestamp: string;
  readonly recovered: boolean;
}

export interface PresentationMarker {
  readonly sequence: number;
  readonly source: "pi" | "codex" | "queue";
  readonly kind: string;
  readonly turnId: string;
  readonly itemId: string;
}

export interface CompactionEvent {
  readonly id: string;
  readonly reason: "manual" | "threshold" | "overflow";
  readonly status:
    "compacting" | "completed" | "failed" | "aborted" | "skipped";
  readonly startedAt: string;
  readonly completedAt: string;
  readonly durationMs: number;
  readonly summary: string;
  readonly errorMessage: string;
  readonly tokensBefore: number;
  readonly estimatedTokensAfter: number;
  readonly willRetry: boolean;
  readonly presentationSequence?: number;
}

export interface PresentationSnapshot {
  readonly watermark: number;
  readonly markers: readonly PresentationMarker[];
  readonly queueMutations: readonly SessionQueueMutation[];
  /** Durable Pi events used to rebuild in-progress turns and resume observers. */
  readonly conversationEvents: readonly PresentedConversationEvent[];
  readonly failures: readonly PresentedConversationFailure[];
  readonly codexEvents: readonly CodexLiveEvent[];
  readonly compactions: readonly CompactionEvent[];
}

export interface CodexEventHandlers {
  readonly onEvent: (event: CodexLiveEvent) => void;
}

export interface SessionTurnEventHandlers {
  readonly onCursor: (presentationSequence: number) => void;
  readonly onChanged: (queueMutation?: SessionQueueMutation) => void;
  readonly onConversation: (event: ConversationEventEnvelope) => void;
}

export interface ToolIndicator {
  readonly message: string;
  readonly spokenMessage: string;
  readonly itemId: string;
  readonly callIndex: number;
  readonly name: string;
  readonly stage: "start" | "end";
  readonly status: "running" | "succeeded" | "failed";
  readonly durationMs?: number;
  readonly generatedImagePreview?: PendingGeneratedImage;
  /** Present only on the successful creation event for a task the user can
      immediately review. This is presentation metadata, never model input. */
  readonly scheduledTaskId?: string;
  readonly webImages?: readonly WebImageReference[];
}

export interface WebImageReference {
  readonly title: string;
  readonly imageUrl: string;
  readonly sourceUrl: string;
  readonly mediaType: "image/jpeg" | "image/png";
  readonly width?: number;
  readonly height?: number;
}

export type ToolDetailStatus = "running" | "succeeded" | "failed";
export type ToolDetailSource = "pi" | "client" | "codex" | "scheduler" | "wheatley";

export interface ToolDetailSummary {
  readonly callIndex: number;
  readonly callId: string;
  readonly name: string;
  readonly source: ToolDetailSource;
  readonly status: ToolDetailStatus;
  readonly startedAt: string;
  readonly completedAt: string;
  readonly durationMs: number;
  readonly workingDirectory: string;
}

export interface ToolDetail {
  readonly tool: ToolDetailSummary;
  readonly arguments: unknown;
  readonly content: readonly unknown[];
  readonly details: unknown;
  readonly extensionData: unknown;
}

export interface SpeechSegment {
  readonly audioUrl: string;
  readonly mediaType: string;
}

export interface SpeechStreamRequest {
  readonly sessionId: string;
  readonly turnId: string;
  readonly speechId: string;
  readonly source: "answer" | "reasoning";
  readonly itemId?: string;
  readonly includeReasoningStatus: boolean;
  readonly startAfterExisting: boolean;
}

export interface SpeechStreamHandlers {
  readonly onSegment: (segment: SpeechSegment) => void;
}

export interface TextTurnRequest {
  readonly sessionId: string;
  readonly text: string;
  readonly turnId: string;
  readonly deviceId: string;
  readonly language: ChatLanguage;
  readonly reasoningMode: ReasoningMode;
  readonly modelId: string;
  readonly image?: File;
}

export interface TextTurnResult {
  readonly turnId: string;
  readonly startedAt: string;
  readonly completedAt: string;
  readonly modelName: string;
  readonly assistantText: string;
  readonly language: ChatLanguage;
  readonly metrics: TextTurnMetrics;
  readonly userAudioUrl?: string;
  readonly userImage?: UserImage;
}

export interface TextTurnHandlers {
  readonly onEvent: (event: ConversationEventEnvelope) => void;
  readonly onAccepted: (accepted: ConversationAccepted) => void;
  readonly onStarted: (turnId: string) => void;
  readonly onToken: (event: TextEvent, turnId: string) => void;
  readonly onTool: (indicator: ToolIndicator, turnId: string) => void;
  readonly onReasoning: (event: ReasoningEvent, turnId: string) => void;
  readonly onArtifact: (artifact: GeneratedImage, turnId: string) => void;
  readonly onCompaction: (event: CompactionEvent) => void;
  readonly onFailed: (
    failure: ConversationFailure,
    turnId: string,
    timestamp: string,
  ) => void;
}

export interface ChatTransport {
  resourceUrl(url: string): string;
  loadClientConfig(): Promise<ClientConfigData>;
  saveClientConfig(config: ClientConfigData): Promise<void>;
  loadProfiles(): Promise<readonly ProfileSummary[]>;
  loadModels(): Promise<ModelCatalog>;
  loadInstructions(profileId: string): Promise<InstructionSnapshot>;
  saveInstructions(
    profileId: string,
    documents: readonly InstructionDocument[],
    workspacePath: string,
  ): Promise<InstructionSnapshot>;
  loadStartupState(
    profileId: string,
    language?: ChatLanguage | "",
  ): Promise<StartupState>;
  startSession(
    profileId: string,
    choice: SessionChoice,
    modelId: string,
    handlers: SessionStartHandlers,
  ): Promise<SessionStartResult>;
  loadRecentSessions(
    profileId: string,
  ): Promise<readonly RecentSessionSummary[]>;
  loadSession(
    profileId: string,
    sessionId: string,
  ): Promise<readonly StoredTurn[]>;
  loadSessionQueue(
    profileId: string,
    sessionId: string,
  ): Promise<SessionQueueSnapshot>;
  cancelSessionQueueItem(
    profileId: string,
    sessionId: string,
    itemId: string,
  ): Promise<SessionQueueMutation | undefined>;
  loadPresentation(
    profileId: string,
    sessionId: string,
  ): Promise<PresentationSnapshot>;
  reportScheduledTaskPresence(
    profileId: string,
    sessionId: string,
    clientId: string,
    deviceId: string,
    phase: string,
    visible: boolean,
    lastInteractionAt: string,
    expiresAt: string,
  ): Promise<ScheduledTaskPresenceResult>;
  listScheduledTasks(profileId: string): Promise<unknown>;
  getScheduledTask(profileId: string, taskId: string): Promise<unknown>;
  updateScheduledTask(
    profileId: string,
    taskId: string,
    sessionId: string,
    modelId: string,
    patch: unknown,
  ): Promise<unknown>;
  setScheduledTaskEnabled(
    profileId: string,
    taskId: string,
    enabled: boolean,
  ): Promise<unknown>;
  runScheduledTaskNow(profileId: string, taskId: string): Promise<unknown>;
  deleteScheduledTask(profileId: string, taskId: string): Promise<void>;
  branchSession(
    profileId: string,
    sessionId: string,
    point: ChatBranchPoint,
  ): Promise<SessionBranchResult>;
  compactSession(
    profileId: string,
    sessionId: string,
  ): Promise<CompactionEvent>;
  deleteSession(profileId: string, sessionId: string): Promise<void>;
  loadToolDetail(
    profileId: string,
    sessionId: string,
    turnId: string,
    callIndex: number,
  ): Promise<ToolDetail>;
  loadReasoning(
    profileId: string,
    sessionId: string,
    turnId: string,
    itemId: string,
  ): Promise<ReasoningDetail>;
  streamTextTurn(
    profileId: string,
    request: TextTurnRequest,
    handlers: TextTurnHandlers,
  ): Promise<TextTurnResult>;
  stopTextTurn(
    profileId: string,
    sessionId: string,
    turnId: string,
  ): Promise<void>;
  synthesizeSpeech(
    profileId: string,
    text: string,
    language: ChatLanguage,
    signal: AbortSignal,
  ): Promise<SpeechSegment>;
  streamTurnSpeech(
    profileId: string,
    request: SpeechStreamRequest,
    handlers: SpeechStreamHandlers,
    signal: AbortSignal,
  ): Promise<void>;
  stopTurnSpeech(
    profileId: string,
    sessionId: string,
    speechId: string,
  ): Promise<void>;
  streamCodexEvents(
    profileId: string,
    sessionId: string,
    afterSequence: number,
    handlers: CodexEventHandlers,
    signal: AbortSignal,
  ): Promise<void>;
  streamSessionTurns(
    profileId: string,
    sessionId: string,
    afterSequence: number,
    handlers: SessionTurnEventHandlers,
    signal: AbortSignal,
  ): Promise<void>;
}
