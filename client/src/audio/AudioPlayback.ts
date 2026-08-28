export type AudioPlaybackEventKind =
    | "queued"
    | "started"
    | "finished"
    | "cancelled"
    | "failed";

export type SpeechPlaybackSource = "answer" | "reasoning";

export interface SpeechPlayback {
    readonly profileId: string;
    readonly sessionId: string;
    readonly turnId: string;
    readonly outputId: string;
    readonly source: SpeechPlaybackSource;
}

export type AudioPlaybackListener = (
    playback: SpeechPlayback,
    kind: AudioPlaybackEventKind,
    errorMessage: string,
) => void;
