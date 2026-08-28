import type { ChatBranchPoint } from "../transport/ChatTransport";

export interface ChatTranscriptHandlers {
    readonly onBranch: (point: ChatBranchPoint) => void;
    readonly onCancelQueued: (itemId: string, turnId: string) => void;
    readonly onSpeak: (turnId: string, itemId: string) => void;
    readonly onSpeakText: (turnId: string, itemId: string, text: string) => void;
    readonly onPlayUserAudio: (turnId: string, audioUrl: string) => void;
    readonly onStopPlayback: () => void;
    readonly onSpeakReasoning: (turnId: string, itemId: string) => void;
    readonly onLoadReasoning: (turnId: string, itemId: string) => Promise<string>;
    readonly onActivityPaneOpenChange: (open: boolean) => void;
    readonly onInspectTool: (
        turnId: string,
        callIndex: number,
        toolName: string | undefined,
    ) => void;
}
