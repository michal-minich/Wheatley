import type {
    CompactionEvent,
    GeneratedImage,
    PendingGeneratedImage,
    SessionQueueItemState,
    ReasoningMode,
    TextTurnMetrics,
    ToolIndicator,
    UserImage,
} from "../transport/ChatTransport";

export type ChatMessageRole = "user" | "assistant" | "reasoning" | "tool" | "compaction";

export interface ChatFailure {
    readonly code: string;
    readonly detail: string;
    readonly detailsLabel: string;
}

export interface ChatMessage {
    readonly id: string;
    readonly role: ChatMessageRole;
    readonly text: string;
    readonly pending: boolean;
    readonly turnId?: string;
    readonly queueItemId?: string;
    readonly queueState?: SessionQueueItemState;
    readonly queueSequence?: number;
    readonly itemId?: string;
    readonly timestamp?: string;
    readonly modelName?: string;
    readonly reasoningMode?: ReasoningMode;
    readonly activityDurationMs?: number;
    readonly turnMetrics?: TextTurnMetrics;
    /** A server-originated scheduled-task prompt, presented as an inline task. */
    readonly scheduledTask?: boolean;
    readonly userAudioUrl?: string;
    readonly userImage?: UserImage;
    readonly generatedImage?: GeneratedImage;
    readonly pendingGeneratedImage?: PendingGeneratedImage;
    readonly tool?: ToolIndicator;
    readonly reasoningTruncated?: boolean;
    readonly reasoningDurationMs?: number;
    readonly compaction?: CompactionEvent;
    readonly failure?: ChatFailure;
}

export function isActivityMessage(message: ChatMessage): boolean {
    return message.role === "reasoning" || message.role === "tool";
}
