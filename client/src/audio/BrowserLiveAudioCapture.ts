import { requireSecureMicrophoneContext, stopMediaTracks } from "./MediaHelpers";
import { browserVoiceEvent } from "./BrowserVoiceDiagnostics";

interface CaptureFrameMessage {
    readonly frame: ArrayBuffer;
    readonly peak: number;
}

interface ActiveCapture {
    readonly stream: MediaStream;
    readonly context: AudioContext;
    readonly source: MediaStreamAudioSourceNode;
    readonly worklet: AudioWorkletNode;
    readonly silentOutput: GainNode;
    readonly visibilityChanged: () => void;
    readonly contextStateChanged: () => void;
}

export interface BrowserLiveAudioCaptureRelease {
    readonly contextClosed?: Promise<void>;
}

const maximumSocketBacklogBytes = 256 * 1_024;

export class BrowserLiveAudioCapture {
    #active: ActiveCapture | undefined;
    #socket: WebSocket | undefined;
    #turnId = "";
    readonly #pendingFrames: ArrayBuffer[] = [];
    #workletFrames = 0;
    #socketFrames = 0;
    #droppedFrames = 0;
    #peak = 0;

    async start(socket: WebSocket, turnId = "unknown-live-turn"): Promise<boolean> {
        if (this.#active !== undefined) {
            const bufferedFrames = this.#attach(socket, turnId);
            browserVoiceEvent(turnId, "capture_graph_reused", {
                buffered_frames: bufferedFrames,
            });
            return true;
        }
        requireSecureMicrophoneContext();

        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        let context: AudioContext | undefined;
        try {
            this.#workletFrames = 0;
            this.#socketFrames = 0;
            this.#droppedFrames = 0;
            context = new AudioContext();
            await context.audioWorklet.addModule("/audio/pcm-capture-worklet.js");
            await context.resume();
            const source = context.createMediaStreamSource(stream);
            const worklet = new AudioWorkletNode(context, "wheatley-pcm-capture");
            const silentOutput = context.createGain();
            silentOutput.gain.value = 0;
            this.#attach(socket, turnId);
            worklet.port.addEventListener("message", event => {
                const message = event.data as CaptureFrameMessage;
                this.#peak = message.peak;
                this.#workletFrames++;
                const activeSocket = this.#socket;
                const activeTurnId = this.#turnId;
                if (activeSocket === undefined) {
                    this.#pendingFrames.push(message.frame);
                } else if (activeSocket.readyState === WebSocket.OPEN
                    && activeSocket.bufferedAmount < maximumSocketBacklogBytes) {
                    activeSocket.send(message.frame);
                    this.#socketFrames++;
                } else {
                    this.#droppedFrames++;
                }
                if (this.#workletFrames % 100 === 0)
                    browserVoiceEvent(activeTurnId || turnId, "capture_frame_checkpoint", {
                        visibility: document.visibilityState,
                        audio_context_state: context!.state,
                        worklet_frames: this.#workletFrames,
                        socket_frames: this.#socketFrames,
                        buffered_frames: this.#pendingFrames.length,
                        dropped_frames: this.#droppedFrames,
                        socket_buffered_bytes: activeSocket?.bufferedAmount ?? 0,
                    });
            });
            const visibilityChanged = (): void => browserVoiceEvent(
                turnId,
                "capture_visibility_changed",
                {
                    visibility: document.visibilityState,
                    audio_context_state: context!.state,
                    worklet_frames: this.#workletFrames,
                    socket_frames: this.#socketFrames,
                    buffered_frames: this.#pendingFrames.length,
                },
            );
            const contextStateChanged = (): void => browserVoiceEvent(
                turnId,
                "capture_context_state_changed",
                {
                    visibility: document.visibilityState,
                    audio_context_state: context!.state,
                    worklet_frames: this.#workletFrames,
                    socket_frames: this.#socketFrames,
                    buffered_frames: this.#pendingFrames.length,
                },
            );
            document.addEventListener("visibilitychange", visibilityChanged);
            context.addEventListener("statechange", contextStateChanged);
            worklet.port.start();
            source.connect(worklet);
            worklet.connect(silentOutput);
            silentOutput.connect(context.destination);
            this.#active = {
                stream,
                context,
                source,
                worklet,
                silentOutput,
                visibilityChanged,
                contextStateChanged,
            };
            browserVoiceEvent(turnId, "capture_graph_started", {
                visibility: document.visibilityState,
                audio_context_state: context.state,
            });
            return false;
        } catch (error: unknown) {
            this.#socket = undefined;
            this.#turnId = "";
            if (context !== undefined)
                void context.close();
            stopMediaTracks(stream);
            throw error;
        }
    }

    release(
        socket: WebSocket,
        turnId: string,
        keepOpen: boolean,
    ): BrowserLiveAudioCaptureRelease | undefined {
        if (this.#socket !== socket || this.#turnId !== turnId)
            return undefined;
        this.#socket = undefined;
        this.#turnId = "";
        return keepOpen ? {} : this.stop();
    }

    stopIfOwnedOrIdle(
        socket: WebSocket,
        turnId: string,
    ): BrowserLiveAudioCaptureRelease | undefined {
        if (this.#socket !== undefined
            && (this.#socket !== socket || this.#turnId !== turnId))
            return undefined;
        return this.stop();
    }

    stopIfIdle(): BrowserLiveAudioCaptureRelease | undefined {
        return this.#socket === undefined ? this.stop() : undefined;
    }

    stop(): BrowserLiveAudioCaptureRelease | undefined {
        const active = this.#active;
        this.#active = undefined;
        this.#socket = undefined;
        this.#turnId = "";
        this.#pendingFrames.length = 0;
        this.#peak = 0;
        if (active === undefined)
            return undefined;
        active.source.disconnect();
        document.removeEventListener("visibilitychange", active.visibilityChanged);
        active.context.removeEventListener("statechange", active.contextStateChanged);
        active.worklet.disconnect();
        active.silentOutput.disconnect();
        active.worklet.port.close();
        stopMediaTracks(active.stream);
        return { contextClosed: active.context.close() };
    }

    readPeak(): number {
        return this.#peak;
    }

    #attach(socket: WebSocket, turnId: string): number {
        this.#socket = socket;
        this.#turnId = turnId;
        const bufferedFrames = this.#pendingFrames.length;
        for (const frame of this.#pendingFrames) {
            socket.send(frame);
            this.#socketFrames++;
        }
        this.#pendingFrames.length = 0;
        return bufferedFrames;
    }
}
