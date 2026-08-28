import { Er } from "../core/Er";

export function abortableDelay(
    milliseconds: number,
    signal: AbortSignal,
    abortMessage: string,
): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        const timeout = window.setTimeout(() => {
            signal.removeEventListener("abort", onAbort);
            resolve();
        }, milliseconds);
        const onAbort = (): void => {
            window.clearTimeout(timeout);
            signal.removeEventListener("abort", onAbort);
            reject(new DOMException(abortMessage, "AbortError"));
        };
        signal.addEventListener("abort", onAbort, { once: true });
    });
}

export function stopMediaTracks(stream: MediaStream): void {
    for (const track of stream.getTracks())
        track.stop();
}

export function requireSecureMicrophoneContext(): void {
    if (!window.isSecureContext)
        return Er.io("Microphone access requires HTTPS or localhost.");
}
