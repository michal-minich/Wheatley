import type { ChatLanguage } from "../chat/Language";
import type {
    GeneratedImage,
    ConversationFailure,
    ReasoningEvent,
    ReasoningMode,
    TextEvent,
    TextTurnResult,
    ToolIndicator,
} from "../transport/ChatTransport";

export interface LiveAudioStartRequest {
    readonly profileId: string;
    readonly sessionId: string;
    readonly turnId: string;
    readonly deviceId: string;
    readonly language: ChatLanguage;
    readonly reasoningMode: ReasoningMode;
    readonly modelId: string;
}

export interface LiveAudioCommit {
    readonly reasoningMode: ReasoningMode;
    readonly modelId: string;
    readonly image?: File;
}

export interface LiveAudioFinalTranscript {
    readonly text: string;
    readonly language: ChatLanguage;
    readonly userAudioArtifactId: string;
}

export interface LiveAudioThinkingMusic {
    readonly action: "play" | "stop";
    readonly delayMs: number;
}

export interface LiveAudioHandlers {
    readonly onListening: () => void;
    readonly onSuspended: () => void;
    readonly onPreview: (text: string) => void;
    readonly onIgnored: () => void;
    readonly onCaptureStopped: () => void;
    readonly shouldKeepMicrophoneOpen: () => boolean;
    readonly onEndpoint: () => void;
    readonly onFinal: (transcript: LiveAudioFinalTranscript) =>
        LiveAudioCommit | Promise<LiveAudioCommit>;
    readonly onAccepted: (turnId: string) => void;
    readonly onStarted: (turnId: string) => void;
    readonly onCommitted: () => void;
    readonly onThinkingMusic: (command: LiveAudioThinkingMusic) => void;
    readonly onToken: (event: TextEvent, turnId: string) => void;
    readonly onTool: (indicator: ToolIndicator, turnId: string) => void;
    readonly onArtifact: (artifact: GeneratedImage, turnId: string) => void;
    readonly onReasoning: (event: ReasoningEvent, turnId: string) => void;
    readonly onFailed: (
        failure: ConversationFailure,
        turnId: string,
        timestamp: string,
    ) => void;
}

export interface LiveAudioControl {
    readonly result: Promise<TextTurnResult | undefined>;
    finish(): void;
    suspend(): void;
    resume(): void;
    cancel(): void;
    releaseMicrophone(): void;
    readPeak(): number;
}

export interface LiveAudioClient {
    prepare(): void;
    start(request: LiveAudioStartRequest, handlers: LiveAudioHandlers): LiveAudioControl;
    releaseIdleMicrophone(): void;
    releaseMicrophone(): void;
}
