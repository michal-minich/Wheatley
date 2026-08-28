import { Er } from "../core/Er";
import type { WheatleyEndpoint } from "../transport/WheatleyEndpoint";
import type { BrowserOutputRecovery } from "./BrowserOutputRecovery";
import { abortableDelay } from "./MediaHelpers";
import { BrowserThinkingMusicCache, parseThinkingMusicSelection } from "./ThinkingMusicMedia";

interface ThinkingMusicRun {
    readonly controller: AbortController;
    source?: AudioBufferSourceNode;
    gain?: GainNode;
}

type Listener = () => void;

export class BrowserThinkingMusic {
    readonly #endpoint: WheatleyEndpoint;
    readonly #outputRecovery: BrowserOutputRecovery;
    readonly #fadeInSeconds: number;
    readonly #fadeOutSeconds: number;
    readonly #cache: BrowserThinkingMusicCache;
    readonly #listeners = new Set<Listener>();
    #context: AudioContext | undefined;
    #run: ThinkingMusicRun | undefined;
    #title: string | undefined;

    constructor(
        endpoint: WheatleyEndpoint,
        outputRecovery: BrowserOutputRecovery,
        fadeInMs: number,
        fadeOutMs: number,
    ) {
        this.#endpoint = endpoint;
        this.#outputRecovery = outputRecovery;
        this.#fadeInSeconds = fadeInMs / 1_000;
        this.#fadeOutSeconds = fadeOutMs / 1_000;
        this.#cache = new BrowserThinkingMusicCache(endpoint);
    }

    prepare(): void {
        this.#outputRecovery.prepare(this.#audioContext());
    }

    get title(): string | undefined {
        return this.#title;
    }

    observe(listener: Listener): void {
        this.#listeners.add(listener);
    }

    play(profileId: string): void {
        this.#play(profileId, 0);
    }

    playAfter(profileId: string, delayMs: number): void {
        this.#play(profileId, delayMs);
    }

    #play(profileId: string, delayMs: number): void {
        this.stop();
        const run: ThinkingMusicRun = { controller: new AbortController() };
        this.#run = run;
        const readyAt = performance.now() + Math.max(0, delayMs);
        void this.#start(run, profileId, readyAt).catch((error: unknown) => {
            if (this.#run === run && !run.controller.signal.aborted)
                console.error("Thinking music playback failed", error);
            if (this.#run === run) {
                this.#run = undefined;
                this.#setTitle(undefined);
            }
        });
    }

    stop(): void {
        this.#setTitle(undefined);
        const run = this.#run;
        if (run === undefined)
            return;
        this.#run = undefined;
        run.controller.abort();
        if (run.source === undefined || run.gain === undefined)
            return;
        const context = this.#audioContext();
        const now = context.currentTime;
        run.gain.gain.cancelScheduledValues(now);
        run.gain.gain.setValueAtTime(run.gain.gain.value, now);
        run.gain.gain.linearRampToValueAtTime(0, now + this.#fadeOutSeconds);
        stopSource(run.source, now + this.#fadeOutSeconds + 0.02);
        window.setTimeout(() => {
            if (this.#run === undefined)
                this.#outputRecovery.suspend(context);
        }, (this.#fadeOutSeconds + 0.03) * 1_000);
    }

    async #start(run: ThinkingMusicRun, profileId: string, readyAt: number): Promise<void> {
        const context = this.#audioContext();
        const selectionResponse = await fetch(
            this.#endpoint.api(`/profiles/${encodeURIComponent(profileId)}/thinking-music`),
            {
                cache: "no-store",
                signal: run.controller.signal,
            },
        );
        if (this.#run !== run)
            return;
        if (!selectionResponse.ok)
            return Er.io(`Thinking music selection failed with HTTP ${selectionResponse.status}.`);
        const selection = parseThinkingMusicSelection(await selectionResponse.json());
        const audio = await context.decodeAudioData(
            await this.#cache.load(selection.asset, run.controller.signal),
        );
        if (this.#run !== run)
            return;
        const remainingMs = Math.ceil(readyAt - performance.now());
        if (remainingMs > 0)
            await abortableDelay(
                remainingMs,
                run.controller.signal,
                "Thinking music delay aborted.",
            );
        if (this.#run !== run)
            return;
        await this.#outputRecovery.wait(context, run.controller.signal);
        if (this.#run !== run)
            return;

        const source = context.createBufferSource();
        const gain = context.createGain();
        source.buffer = audio;
        source.loop = true;
        const targetGain = decibelsToLinear(selection.gainDb);
        gain.gain.setValueAtTime(0, context.currentTime);
        gain.gain.linearRampToValueAtTime(targetGain, context.currentTime + this.#fadeInSeconds);
        source.connect(gain);
        gain.connect(context.destination);
        source.addEventListener("ended", () => {
            if (this.#run === run) {
                this.#run = undefined;
                this.#setTitle(undefined);
            }
        }, { once: true });
        run.source = source;
        run.gain = gain;
        source.start();
        this.#setTitle(selection.title);
    }

    #audioContext(): AudioContext {
        this.#context ??= new AudioContext();
        return this.#context;
    }

    #setTitle(title: string | undefined): void {
        if (this.#title === title)
            return;
        this.#title = title;
        for (const listener of this.#listeners)
            listener();
    }
}

function decibelsToLinear(decibels: number): number {
    return 10 ** (decibels / 20);
}

function stopSource(source: AudioBufferSourceNode, when: number): void {
    try {
        source.stop(when);
    } catch (error: unknown) {
        if (!(error instanceof DOMException && error.name === "InvalidStateError"))
            throw error;
    }
}
