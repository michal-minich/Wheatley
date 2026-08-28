import { Er } from "../core/Er";
import type { BrowserOutputRecovery } from "./BrowserOutputRecovery";
import { browserVoiceEvent } from "./BrowserVoiceDiagnostics";
import type { SpeechPlayer } from "./SpeechPlayer";
import type {
    AudioPlaybackListener,
    SpeechPlayback,
} from "./AudioPlayback";

interface PlaybackRun {
    readonly turnId: string;
    readonly playback: SpeechPlayback | undefined;
    readonly controller: AbortController;
    readonly buffers: AudioBuffer[];
    readonly done: Promise<void>;
    readonly resolveDone: () => void;
    loading: Promise<void>;
    source: AudioBufferSourceNode | undefined;
    inputComplete: boolean;
    firstSourceStarted: boolean;
}

export class BrowserSpeechPlayer implements SpeechPlayer {
    readonly #outputRecovery: BrowserOutputRecovery;
    readonly #onPlaybackEvent: AudioPlaybackListener;
    readonly #onFirstPlaybackStarted: () => void;
    #context: AudioContext | undefined;
    #run: PlaybackRun | undefined;

    constructor(
        outputRecovery: BrowserOutputRecovery,
        onPlaybackEvent: AudioPlaybackListener,
        onFirstPlaybackStarted: () => void,
    ) {
        this.#outputRecovery = outputRecovery;
        this.#onPlaybackEvent = onPlaybackEvent;
        this.#onFirstPlaybackStarted = onFirstPlaybackStarted;
    }

    async unlock(): Promise<void> {
        await this.#outputRecovery.unlock(this.#audioContext());
    }

    suspendForCapture(turnId: string): void {
        this.#outputRecovery.suspendForCapture(turnId);
    }

    prepareAfterCapture(turnId: string): void {
        this.#outputRecovery.markMicrophoneReleased(turnId);
    }

    begin(playback: SpeechPlayback): void {
        this.#stopPlayback();
        this.#run = playbackRun(playback.turnId, playback);
        this.#onPlaybackEvent(playback, "queued", "");
    }

    beginLocal(turnId: string): void {
        this.#stopPlayback();
        this.#run = playbackRun(turnId, undefined);
    }

    enqueue(audioUrl: string): void {
        const run = this.#run ?? Er.internal("Speech playback has not started.");
        run.loading = this.#loadAfter(run, audioUrl, run.loading);
        void run.loading.catch(() => undefined);
    }

    async finish(): Promise<void> {
        const run = this.#run ?? Er.internal("Speech playback has not started.");
        try {
            await run.loading;
        } catch (error: unknown) {
            this.#failPlayback(run, error);
            throw error;
        }
        if (this.#run !== run)
            return;
        run.inputComplete = true;
        this.#finishIfIdle(run);
        await run.done;
    }

    stop(): void {
        this.#stopPlayback();
    }

    #stopPlayback(): void {
        const run = this.#run;
        if (run === undefined)
            return;
        this.#run = undefined;
        run.controller.abort();
        if (run.source !== undefined)
            stopSource(run.source);
        run.buffers.length = 0;
        if (this.#context !== undefined)
            this.#outputRecovery.suspend(this.#context);
        if (run.playback !== undefined)
            this.#onPlaybackEvent(run.playback, "cancelled", "");
        run.resolveDone();
    }

    async #loadAfter(
        run: PlaybackRun,
        audioUrl: string,
        previous: Promise<void>,
    ): Promise<void> {
        await previous;
        const startedAt = performance.now();
        browserVoiceEvent(run.turnId, "speech_audio_requested");
        const response = await fetch(audioUrl, { signal: run.controller.signal });
        if (!response.ok)
            return Er.io(`Speech audio request failed with HTTP ${response.status}.`);
        const buffer = await this.#audioContext().decodeAudioData(await response.arrayBuffer());
        if (this.#run !== run)
            return;
        browserVoiceEvent(run.turnId, "speech_audio_decoded", {
            request_to_decode_ms: Math.round(performance.now() - startedAt),
        });
        await this.#outputRecovery.wait(this.#audioContext(), run.controller.signal);
        if (this.#run !== run)
            return;
        run.buffers.push(buffer);
        this.#startNext(run);
    }

    #startNext(run: PlaybackRun): void {
        if (this.#run !== run || run.source !== undefined || run.buffers.length === 0) {
            this.#finishIfIdle(run);
            return;
        }

        const source = this.#audioContext().createBufferSource();
        source.buffer = run.buffers.shift()!;
        source.connect(this.#audioContext().destination);
        source.addEventListener("ended", () => {
            if (this.#run !== run || run.source !== source)
                return;
            browserVoiceEvent(run.turnId, "speech_segment_ended");
            run.source = undefined;
            this.#startNext(run);
        }, { once: true });
        run.source = source;
        source.start();
        if (!run.firstSourceStarted) {
            run.firstSourceStarted = true;
            this.#onFirstPlaybackStarted();
            browserVoiceEvent(run.turnId, "first_speech_playback_started");
            if (run.playback !== undefined)
                this.#onPlaybackEvent(run.playback, "started", "");
        } else {
            browserVoiceEvent(run.turnId, "speech_segment_started");
        }
    }

    #finishIfIdle(run: PlaybackRun): void {
        if (
            this.#run !== run
            || !run.inputComplete
            || run.source !== undefined
            || run.buffers.length > 0
        ) {
            return;
        }
        this.#run = undefined;
        this.#outputRecovery.suspend(this.#audioContext());
        if (run.playback !== undefined)
            this.#onPlaybackEvent(run.playback, "finished", "");
        run.resolveDone();
    }

    #failPlayback(run: PlaybackRun, error: unknown): void {
        if (this.#run !== run)
            return;
        this.#run = undefined;
        run.controller.abort();
        if (run.source !== undefined)
            stopSource(run.source);
        run.buffers.length = 0;
        if (this.#context !== undefined)
            this.#outputRecovery.suspend(this.#context);
        if (run.playback !== undefined) {
            this.#onPlaybackEvent(
                run.playback,
                "failed",
                error instanceof Error ? error.message : "Speech playback failed",
            );
        }
        run.resolveDone();
    }

    #audioContext(): AudioContext {
        this.#context ??= new AudioContext();
        return this.#context;
    }

}

function playbackRun(
    turnId: string,
    playback: SpeechPlayback | undefined,
): PlaybackRun {
    let resolveDone = (): void => undefined;
    const done = new Promise<void>(resolve => {
        resolveDone = resolve;
    });
    return {
        turnId,
        playback,
        controller: new AbortController(),
        buffers: [],
        done,
        resolveDone,
        loading: Promise.resolve(),
        source: undefined,
        inputComplete: false,
        firstSourceStarted: false,
    };
}

function stopSource(source: AudioBufferSourceNode): void {
    try {
        source.stop();
    } catch (error: unknown) {
        if (!(error instanceof DOMException && error.name === "InvalidStateError"))
            throw error;
    }
}
