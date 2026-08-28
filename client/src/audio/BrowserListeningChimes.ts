import type { WheatleyEndpoint } from "../transport/WheatleyEndpoint";

type ChimeKind = "start" | "stop" | "capture";

export class BrowserListeningChimes {
    readonly #endpoint: WheatleyEndpoint;
    readonly #buffers = new Map<ChimeKind, Promise<AudioBuffer>>();
    #activePlaybacks = 0;
    #context: AudioContext | undefined;
    #outputPrepared: Promise<void> | undefined;

    constructor(endpoint: WheatleyEndpoint) {
        this.#endpoint = endpoint;
    }

    prepare(): void {
        const context = this.#audioContext();
        this.#outputPrepared ??= context.resume()
            .then(async () => await context.suspend())
            .catch((error: unknown) => {
                console.error("Listening chime output preparation failed", error);
                throw error;
            });
        void this.#outputPrepared.catch(() => undefined);
        void this.#buffer("start").catch((error: unknown) =>
            console.error("Listening start chime preload failed", error));
        void this.#buffer("stop").catch((error: unknown) =>
            console.error("Listening stop chime preload failed", error));
        void this.#buffer("capture").catch((error: unknown) =>
            console.error("Capture chime preload failed", error));
    }

    async play(kind: ChimeKind): Promise<void> {
        this.prepare();
        await this.#outputPrepared;
        const context = this.#audioContext();
        await context.resume();
        this.#activePlaybacks++;
        const source = context.createBufferSource();
        source.buffer = await this.#buffer(kind);
        source.connect(context.destination);
        try {
            await new Promise<void>(resolve => {
                source.addEventListener("ended", () => resolve(), { once: true });
                source.start();
            });
        } finally {
            this.#activePlaybacks--;
            if (this.#activePlaybacks === 0)
                await context.suspend();
        }
    }

    #buffer(kind: ChimeKind): Promise<AudioBuffer> {
        const existing = this.#buffers.get(kind);
        if (existing !== undefined)
            return existing;
        const loading = fetch(this.#endpoint.api(`/listening-chimes/${kind}`))
            .then(async response => {
                if (!response.ok)
                    throw new Error(`Listening ${kind} chime is unavailable.`);
                return await response.arrayBuffer();
            })
            .then(async data => await this.#audioContext().decodeAudioData(data));
        this.#buffers.set(kind, loading);
        return loading;
    }

    #audioContext(): AudioContext {
        this.#context ??= new AudioContext();
        return this.#context;
    }
}
