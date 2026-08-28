import type { WheatleyEndpoint } from "../transport/WheatleyEndpoint";
import type {
    AudioPlaybackEventKind,
    SpeechPlayback,
} from "./AudioPlayback";

/** Ordered best-effort delivery of device playback facts to Voice Runtime. */
export class BrowserPlaybackAcknowledgements {
    readonly #endpoint: WheatleyEndpoint;
    readonly #deliveries = new Map<string, PlaybackDelivery>();

    constructor(endpoint: WheatleyEndpoint) {
        this.#endpoint = endpoint;
    }

    report(
        playback: SpeechPlayback,
        kind: AudioPlaybackEventKind,
        errorMessage: string,
    ): void {
        const key = playbackKey(playback);
        const delivery = this.#deliveries.get(key) ?? this.#startDelivery(key);
        if (delivery.failed)
            return;
        delivery.pending = delivery.pending
            .then(async () => await this.#send(playback, kind, errorMessage))
            .catch((error: unknown) => {
                delivery.failed = true;
                console.error("Playback acknowledgement failed", error);
            });
        if (terminal(kind)) {
            void delivery.pending.finally(() => {
                if (this.#deliveries.get(key) === delivery)
                    this.#deliveries.delete(key);
            });
        }
    }

    #startDelivery(key: string): PlaybackDelivery {
        const delivery = { pending: Promise.resolve(), failed: false };
        this.#deliveries.set(key, delivery);
        return delivery;
    }

    async #send(
        playback: SpeechPlayback,
        kind: AudioPlaybackEventKind,
        errorMessage: string,
    ): Promise<void> {
        let lastError: unknown;
        for (const delayMs of [0, 250, 1_000]) {
            if (delayMs > 0)
                await delay(delayMs);
            try {
                const response = await fetch(this.#endpoint.api(
                    `/profiles/${encodeURIComponent(playback.profileId)}/audio/playback-events`,
                ), {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        session_id: playback.sessionId,
                        turn_id: playback.turnId,
                        output_id: playback.outputId,
                        source: playback.source,
                        kind,
                        adapter: "web_audio",
                        error_message: errorMessage,
                    }),
                    keepalive: true,
                });
                if (response.ok)
                    return;
                lastError = new Error(
                    `Playback acknowledgement failed with HTTP ${response.status}.`,
                );
            } catch (error: unknown) {
                lastError = error;
            }
        }
        throw lastError;
    }
}

interface PlaybackDelivery {
    pending: Promise<void>;
    failed: boolean;
}

function playbackKey(playback: SpeechPlayback): string {
    return `${playback.profileId}:${playback.sessionId}:${playback.outputId}`;
}

function terminal(kind: AudioPlaybackEventKind): boolean {
    return kind === "finished" || kind === "cancelled" || kind === "failed";
}

async function delay(milliseconds: number): Promise<void> {
    await new Promise(resolve => setTimeout(resolve, milliseconds));
}
