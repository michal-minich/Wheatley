import { Er } from "../core/Er";

export interface SseEvent {
    readonly name: string;
    readonly data: string;
}

export async function readSseStream(
    body: ReadableStream<Uint8Array>,
    onEvent: (event: SseEvent) => boolean | Promise<boolean>,
): Promise<void> {
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let eventName = "";
    let eventData = "";

    const dispatch = async (): Promise<boolean> => {
        if (!eventName.length && !eventData.length)
            return true;
        if (!eventName.length)
            return Er.contract("SSE event name is required.");
        if (!eventData.length)
            return Er.contract("SSE event data is required.");
        const keepReading = await onEvent({ name: eventName, data: eventData });
        eventName = "";
        eventData = "";
        return keepReading;
    };

    try {
        let chunk = await reader.read();
        while (!chunk.done) {
            buffer += decoder.decode(chunk.value, { stream: true });

            let lineBreak = buffer.indexOf("\n");
            while (lineBreak >= 0) {
                let line = buffer.slice(0, lineBreak);
                buffer = buffer.slice(lineBreak + 1);
                if (line.endsWith("\r"))
                    line = line.slice(0, -1);

                if (!line.length) {
                    if (!await dispatch()) {
                        await reader.cancel();
                        return;
                    }
                } else if (line.startsWith("event:")) {
                    eventName = line.slice("event:".length).trim();
                } else if (line.startsWith("data:")) {
                    const piece = line.slice("data:".length).trim();
                    eventData = eventData.length ? `${eventData}\n${piece}` : piece;
                }

                lineBreak = buffer.indexOf("\n");
            }
            chunk = await reader.read();
        }

        if (eventName.length || eventData.length)
            await dispatch();
    } finally {
        reader.releaseLock();
    }
}
