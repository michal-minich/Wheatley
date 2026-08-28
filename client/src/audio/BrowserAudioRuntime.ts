import { Er } from "../core/Er";
import type { WheatleyEndpoint } from "../transport/WheatleyEndpoint";
import { BrowserListeningChimes } from "./BrowserListeningChimes";
import { BrowserOutputRecovery } from "./BrowserOutputRecovery";
import { BrowserSpeechPlayer } from "./BrowserSpeechPlayer";
import { BrowserThinkingMusic } from "./BrowserThinkingMusic";
import type { LiveAudioThinkingMusic } from "./LiveAudio";
import type { SpeechPlayer } from "./SpeechPlayer";
import type { SpeechPlayback } from "./AudioPlayback";
import { BrowserPlaybackAcknowledgements } from "./BrowserPlaybackAcknowledgements";

type ListeningCue = "start" | "stop";

/**
 * Device-local owner of browser/Tauri audible output and microphone recovery.
 * The concrete players remain small adapters; product orchestration addresses
 * this role instead of coordinating those adapters independently.
 */
export class BrowserAudioRuntime implements SpeechPlayer {
    readonly #recovery: BrowserOutputRecovery;
    readonly #speech: BrowserSpeechPlayer;
    readonly #thinkingMusic: BrowserThinkingMusic;
    readonly #chimes: BrowserListeningChimes;
    readonly #playbackAcknowledgements: BrowserPlaybackAcknowledgements;
    #capturingTurnId: string | undefined;

    constructor(
        endpoint: WheatleyEndpoint,
        outputRecoveryMs: number,
        thinkingMusicFadeInMs: number,
        thinkingMusicFadeOutMs: number,
    ) {
        this.#recovery = new BrowserOutputRecovery(outputRecoveryMs);
        this.#playbackAcknowledgements = new BrowserPlaybackAcknowledgements(endpoint);
        this.#speech = new BrowserSpeechPlayer(
            this.#recovery,
            (playback, kind, errorMessage) =>
                this.#playbackAcknowledgements.report(playback, kind, errorMessage),
            () => this.#thinkingMusic.stop(),
        );
        this.#thinkingMusic = new BrowserThinkingMusic(
            endpoint,
            this.#recovery,
            thinkingMusicFadeInMs,
            thinkingMusicFadeOutMs,
        );
        this.#chimes = new BrowserListeningChimes(endpoint);
    }

    prepare(): void {
        this.#chimes.prepare();
        this.#thinkingMusic.prepare();
    }

    prepareThinkingMusic(): void {
        this.#thinkingMusic.prepare();
    }

    get thinkingMusicTitle(): string | undefined {
        return this.#thinkingMusic.title;
    }

    observeThinkingMusic(listener: () => void): void {
        this.#thinkingMusic.observe(listener);
    }

    async playListeningCue(kind: ListeningCue): Promise<void> {
        await this.#chimes.play(kind);
    }

    async playCaptureCue(): Promise<void> {
        await this.#chimes.play("capture");
    }

    applyThinkingMusic(profileId: string, command: LiveAudioThinkingMusic): void {
        if (command.action === "stop") {
            this.#thinkingMusic.stop();
            return;
        }
        if (this.#capturingTurnId !== undefined)
            return Er.contract("Thinking music cannot start while capturing.");
        if (command.delayMs > 0)
            this.#thinkingMusic.playAfter(profileId, command.delayMs);
        else
            this.#thinkingMusic.play(profileId);
    }

    stopThinkingMusic(): void {
        this.#thinkingMusic.stop();
    }

    stopAllLocalOutput(): void {
        this.#thinkingMusic.stop();
        this.#speech.stop();
    }

    async unlock(): Promise<void> {
        await this.#speech.unlock();
    }

    suspendForCapture(turnId: string): void {
        this.#capturingTurnId = turnId;
        this.#thinkingMusic.stop();
        this.#speech.stop();
        this.#speech.suspendForCapture(turnId);
    }

    prepareAfterCapture(turnId: string): void {
        if (this.#capturingTurnId !== turnId)
            return;
        this.#capturingTurnId = undefined;
        this.#speech.prepareAfterCapture(turnId);
    }

    begin(playback: SpeechPlayback): void {
        if (this.#capturingTurnId !== undefined)
            return Er.contract("Speech cannot start while capturing.");
        this.#speech.begin(playback);
    }

    beginLocal(turnId: string): void {
        if (this.#capturingTurnId !== undefined)
            return Er.contract("Speech cannot start while capturing.");
        this.#speech.beginLocal(turnId);
    }

    enqueue(audioUrl: string): void {
        this.#speech.enqueue(audioUrl);
    }

    async finish(): Promise<void> {
        await this.#speech.finish();
    }

    stop(): void {
        this.#speech.stop();
    }
}
