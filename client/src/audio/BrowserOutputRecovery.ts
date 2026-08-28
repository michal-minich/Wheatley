import { browserVoiceEvent } from "./BrowserVoiceDiagnostics";
import { abortableDelay } from "./MediaHelpers";

interface RecoveryWindow {
    readonly turnId: string;
    readonly startedAt: number;
    readonly readyAt: number;
}

export class BrowserOutputRecovery {
    readonly #contexts = new Set<AudioContext>();
    readonly #recoveryMs: number;
    #window: RecoveryWindow | undefined;

    constructor(recoveryMs: number) {
        this.#recoveryMs = recoveryMs;
    }

    async unlock(context: AudioContext): Promise<void> {
        this.#contexts.add(context);
        await context.resume();
        await context.suspend();
    }

    prepare(context: AudioContext): void {
        this.#contexts.add(context);
        if (context.state === "running")
            return;
        void context.resume()
            .then(async () => await context.suspend())
            .catch((error: unknown) =>
                console.error("Preparing browser output failed", error));
    }

    suspendForCapture(turnId: string): void {
        this.#window = undefined;
        browserVoiceEvent(turnId, "output_contexts_suspending_for_capture");
        this.#suspendAll();
    }

    markMicrophoneReleased(turnId: string): void {
        const startedAt = performance.now();
        this.#window = {
            turnId,
            startedAt,
            readyAt: startedAt + this.#recoveryMs,
        };
        browserVoiceEvent(turnId, "output_recovery_started", {
            recovery_ms: this.#recoveryMs,
        });
        this.#suspendAll();
    }

    async wait(context: AudioContext, signal: AbortSignal): Promise<void> {
        this.#contexts.add(context);
        const recovery = this.#window;
        if (recovery !== undefined) {
            const remainingMs = Math.ceil(recovery.readyAt - performance.now());
            if (remainingMs > 0) {
                browserVoiceEvent(recovery.turnId, "output_recovery_wait_started", {
                    remaining_ms: remainingMs,
                });
                await abortableDelay(remainingMs, signal, "Output recovery wait aborted.");
                if (this.#window !== recovery) {
                    await this.wait(context, signal);
                    return;
                }
                browserVoiceEvent(recovery.turnId, "output_recovery_wait_ended", {
                    elapsed_ms: Math.round(performance.now() - recovery.startedAt),
                });
            }
        }
        signal.throwIfAborted();
        await context.resume();
        signal.throwIfAborted();
    }

    suspend(context: AudioContext): void {
        if (context.state === "running")
            void context.suspend().catch((error: unknown) =>
                console.error("Suspending browser output failed", error));
    }

    #suspendAll(): void {
        for (const context of this.#contexts)
            this.suspend(context);
    }
}
