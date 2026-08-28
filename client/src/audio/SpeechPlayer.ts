import type { SpeechPlayback } from "./AudioPlayback";

export interface SpeechPlayer {
    readonly unlock: () => Promise<void>;
    readonly suspendForCapture: (turnId: string) => void;
    readonly prepareAfterCapture: (turnId: string) => void;
    readonly begin: (playback: SpeechPlayback) => void;
    readonly beginLocal: (turnId: string) => void;
    readonly enqueue: (audioUrl: string) => void;
    readonly finish: () => Promise<void>;
    readonly stop: () => void;
}
