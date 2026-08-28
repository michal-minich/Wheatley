import { Er } from "../core/Er";
import { JsonObject, parseJson } from "../core/Json";
import {
    parseConversationEvent,
    parseConversationFailure,
    parseGeneratedImage,
    parseVoiceEvent,
    parseReasoningEvent,
    parseTextTurnResult,
    parseTokenMessage,
    parseToolMessage,
} from "../transport/WheatleyJson";
import { parseChatLanguage } from "../chat/Language";
import type { ChatLanguage } from "../chat/Language";
import type { BrowserAudioRuntime } from "./BrowserAudioRuntime";
import {
    BrowserLiveAudioCapture,
    type BrowserLiveAudioCaptureRelease,
} from "./BrowserLiveAudioCapture";
import { browserVoiceEvent } from "./BrowserVoiceDiagnostics";
import type {
    LiveAudioClient,
    LiveAudioCommit,
    LiveAudioControl,
    LiveAudioHandlers,
    LiveAudioStartRequest,
} from "./LiveAudio";
import type { TextTurnResult } from "../transport/ChatTransport";
import type { WheatleyEndpoint } from "../transport/WheatleyEndpoint";
import { uiText } from "../ui/UiText";

export class BrowserLiveAudio implements LiveAudioClient {
    readonly #endpoint: WheatleyEndpoint;
    readonly #audio: BrowserAudioRuntime;
    readonly #capture = new BrowserLiveAudioCapture();
    #speechCommitDelaySeconds: number;
    readonly #activeTurns = new Set<BrowserLiveAudioTurn>();

    constructor(
        endpoint: WheatleyEndpoint,
        audio: BrowserAudioRuntime,
        speechCommitDelaySeconds: number,
    ) {
        this.#endpoint = endpoint;
        this.#audio = audio;
        this.#speechCommitDelaySeconds = speechCommitDelaySeconds;
    }

    prepare(): void {
        this.#audio.prepare();
    }

    setSpeechCommitDelaySeconds(seconds: number): void {
        if (this.#speechCommitDelaySeconds === seconds)
            return;
        this.#speechCommitDelaySeconds = seconds;
        for (const turn of this.#activeTurns)
            turn.setSpeechCommitDelaySeconds(seconds);
    }

    start(request: LiveAudioStartRequest, handlers: LiveAudioHandlers): LiveAudioControl {
        const turn = new BrowserLiveAudioTurn(
            this.#endpoint,
            this.#audio,
            request,
            handlers,
            this.#speechCommitDelaySeconds,
            this.#capture,
        );
        this.#activeTurns.add(turn);
        void turn.result.then(
            () => this.#activeTurns.delete(turn),
            () => this.#activeTurns.delete(turn),
        );
        return turn;
    }

    releaseIdleMicrophone(): void {
        this.#closeCapture(this.#capture.stopIfIdle());
    }

    releaseMicrophone(): void {
        this.#closeCapture(this.#capture.stop());
    }

    #closeCapture(release: ReturnType<BrowserLiveAudioCapture["stop"]>): void {
        void release?.contextClosed?.catch((error: unknown) =>
            console.error("Live microphone context close failed", error));
    }

}

class BrowserLiveAudioTurn implements LiveAudioControl {
    readonly result: Promise<TextTurnResult | undefined>;
    readonly #endpoint: WheatleyEndpoint;
    readonly #audio: BrowserAudioRuntime;
    readonly #handlers: LiveAudioHandlers;
    readonly #language: ChatLanguage;
    readonly #profileId: string;
    readonly #sessionId: string;
    readonly #turnId: string;
    readonly #capture: BrowserLiveAudioCapture;
    readonly #socket: WebSocket;
    #resolve!: (result: TextTurnResult | undefined) => void;
    #reject!: (error: unknown) => void;
    #settled = false;
    #cancelled = false;
    #listening = false;
    #stopCuePlayed = false;
    #captureStoppedReported = false;
    #conversationTurnId = "";
    #lastConversationSequence = 0;
    #speechCommitDelaySeconds: number;
    #queue = Promise.resolve();
    #userImageFilename: string | undefined;
    #previewCandidateId = 0;
    #previewRevision = 0;
    #previewText = "";

    constructor(
        endpoint: WheatleyEndpoint,
        audio: BrowserAudioRuntime,
        request: LiveAudioStartRequest,
        handlers: LiveAudioHandlers,
        speechCommitDelaySeconds: number,
        capture: BrowserLiveAudioCapture,
    ) {
        this.#endpoint = endpoint;
        this.#audio = audio;
        this.#handlers = handlers;
        this.#language = request.language;
        this.#profileId = request.profileId;
        this.#sessionId = request.sessionId;
        this.#turnId = request.turnId;
        this.#speechCommitDelaySeconds = speechCommitDelaySeconds;
        this.#capture = capture;
        browserVoiceEvent(this.#turnId, "live_turn_created");
        this.result = new Promise<TextTurnResult | undefined>((resolve, reject) => {
            this.#resolve = resolve;
            this.#reject = reject;
        });
        this.#socket = new WebSocket(this.#endpoint.webSocket(
            `/profiles/${encodeURIComponent(request.profileId)}/turns/audio/live`,
        ));
        this.#socket.binaryType = "arraybuffer";
        this.#socket.addEventListener("open", () => {
            this.#socket.send(startMessage(request, this.#speechCommitDelaySeconds));
        });
        this.#socket.addEventListener("message", event => {
            this.#queue = this.#queue
                .then(async () => await this.#handleMessage(String(event.data)))
                .catch((error: unknown) => this.#fail(error));
        });
        this.#socket.addEventListener("error", () =>
            this.#fail(new Error(uiText(this.#language).liveAudioFailed)));
        this.#socket.addEventListener("close", () => this.#handleClose());
    }

    finish(): void {
        if (this.#settled || this.#cancelled || !this.#listening)
            return;
        this.#listening = false;
        const keepOpen = this.#handlers.shouldKeepMicrophoneOpen();
        this.#releaseCapture(true, keepOpen);
        if (!keepOpen) {
            this.#stopCuePlayed = true;
            void this.#playChime("stop");
        }
        if (this.#socket.readyState === WebSocket.OPEN)
            this.#socket.send(JSON.stringify({ type: "stop" }));
    }

    suspend(): void {
        if (this.#settled || this.#cancelled || !this.#listening)
            return;
        this.#listening = false;
        this.#releaseCapture(true);
        if (this.#socket.readyState === WebSocket.OPEN)
            this.#socket.send(JSON.stringify({ type: "suspend" }));
    }

    resume(): void {
        if (this.#settled || this.#cancelled || this.#socket.readyState !== WebSocket.OPEN)
            return;
        this.#socket.send(JSON.stringify({ type: "resume" }));
    }

    cancel(): void {
        if (this.#settled)
            return;
        this.#cancelled = true;
        const wasListening = this.#listening;
        this.#listening = false;
        this.#releaseCapture(true, false, true);
        if (wasListening)
            void this.#playChime("stop");
        if (this.#socket.readyState === WebSocket.OPEN)
            this.#socket.send(JSON.stringify({ type: "cancel" }));
        this.#closeSocket(1000, "Cancelled");
        this.#settle(undefined);
    }

    releaseMicrophone(): void {
        this.#closeCapture(this.#capture.stopIfOwnedOrIdle(this.#socket, this.#turnId));
    }

    readPeak(): number {
        return this.#capture.readPeak();
    }

    setSpeechCommitDelaySeconds(seconds: number): void {
        if (this.#speechCommitDelaySeconds === seconds)
            return;
        this.#speechCommitDelaySeconds = seconds;
        if (this.#socket.readyState === WebSocket.OPEN)
            this.#socket.send(speechCommitDelayMessage(seconds));
    }

    async #handleMessage(text: string): Promise<void> {
        if (this.#cancelled || this.#settled)
            return;
        const rawMessage = parseJson(text, "live audio message");
        const message = JsonObject.from(
            rawMessage,
            "live audio message",
        );
        switch (message.string("type")) {
            case "voice_event": {
                const event = parseVoiceEvent(rawMessage);
                switch (event.kind) {
                    case "ready":
                        return;
                    case "listening_started":
                    case "listening_retry":
                    case "listening_resumed":
                    case "candidate_rejected":
                        await this.#handleListening(event.kind);
                        return;
                    case "listening_suspended":
                        this.#handlers.onSuspended();
                        return;
                    case "transcript_draft_selected":
                    case "audio_receiving":
                    case "speech_detected":
                        return;
                    case "preview_changed":
                        this.#handlePreview(JsonObject.from(
                            event.payload,
                            "Voice preview",
                        ));
                        return;
                    case "endpoint_reached":
                        this.#handleEndpoint();
                        return;
                    case "transcript_accepted":
                        await this.#handleFinal(JsonObject.from(
                            event.payload,
                            "Voice transcript",
                        ));
                        return;
                    case "session_resume_choice":
                        return Er.contract("Browser turn received a session-resume choice.");
                    case "failed":
                        return Er.io(JsonObject.from(
                            event.payload,
                            "Voice failure",
                        ).string("message"));
                }
                return Er.contract("Unsupported Voice event kind.");
            }
            case "thinking_music": {
                const action = message.string("action");
                if (action !== "play" && action !== "stop")
                    return Er.contract("Thinking music action must be play or stop.");
                const delayMs = message.number("delay_ms");
                if (!Number.isSafeInteger(delayMs) || delayMs < 0 || delayMs > 60_000)
                    return Er.contract("Thinking music delay must be from 0 to 60000 ms.");
                this.#handlers.onThinkingMusic({ action, delayMs });
                return;
            }
            case "conversation_event": {
                const event = parseConversationEvent(message.value("event"));
                if (event.profileId !== this.#profileId)
                    return Er.contract("Conversation event profile changed.");
                if (event.sessionId !== this.#sessionId)
                    return Er.contract("Conversation event session changed.");
                if (this.#conversationTurnId !== "" && event.turnId !== this.#conversationTurnId)
                    return Er.contract("Conversation event turn changed.");
                if (event.sequence !== this.#lastConversationSequence + 1)
                    return Er.contract("Conversation event sequence gap.");
                this.#lastConversationSequence = event.sequence;
                this.#conversationTurnId = event.turnId;
                switch (event.kind) {
                    case "status": {
                        const status = JsonObject.from(
                            event.payload,
                            "live conversation status",
                        ).string("code");
                        if (status === "conversation_accepted")
                            this.#handlers.onAccepted(event.turnId);
                        else if (status === "api_text_pi_started")
                            this.#handlers.onStarted(event.turnId);
                        return;
                    }
                    case "assistant_delta":
                        this.#handlers.onToken(parseTokenMessage(event.payload), event.turnId);
                        return;
                    case "tool":
                        this.#handlers.onTool(
                            parseToolMessage(event.payload),
                            event.turnId,
                        );
                        return;
                    case "artifact":
                        this.#handlers.onArtifact(
                            parseGeneratedImage(
                                event.payload,
                                url => this.#endpoint.resource(url),
                            ),
                            event.turnId,
                        );
                        return;
                    case "reasoning":
                        this.#handlers.onReasoning(
                            parseReasoningEvent(event.payload),
                            event.turnId,
                        );
                        return;
                    case "completed":
                        this.#settle(audioResult(
                            parseTextTurnResult(event.payload),
                            this.#endpoint,
                            this.#profileId,
                            this.#sessionId,
                            this.#userImageFilename,
                        ));
                        return;
                    case "failed":
                        this.#handlers.onFailed(
                            parseConversationFailure(event.payload),
                            event.turnId,
                            event.timestamp,
                        );
                        return Er.io(JsonObject.from(
                            event.payload,
                            "conversation failure",
                        ).string("message"));
                }
                return Er.contract("Unsupported conversation event kind.");
            }
            default:
                return Er.contract(`Unsupported live audio event ${message.string("type")}.`);
        }
    }

    #handlePreview(payload: JsonObject): void {
        const candidateId = payload.number("candidate_id");
        const revision = payload.number("revision");
        if (!Number.isSafeInteger(candidateId) || candidateId <= 0)
            return Er.contract("Voice preview candidate ID must be a positive integer.");
        if (!Number.isSafeInteger(revision) || revision <= 0)
            return Er.contract("Voice preview revision must be a positive integer.");
        if (candidateId < this.#previewCandidateId)
            return;
        if (candidateId === this.#previewCandidateId && revision <= this.#previewRevision)
            return;
        if (candidateId > this.#previewCandidateId) {
            if (this.#previewCandidateId > 0)
                this.#handlers.onIgnored();
            this.#previewCandidateId = candidateId;
            this.#previewRevision = 0;
            this.#previewText = "";
        }
        this.#previewRevision = revision;
        this.#previewText = completePreviewText(
            this.#previewText,
            payload.string("text"),
        );
        this.#handlers.onPreview(this.#previewText);
    }

    async #handleListening(kind: string): Promise<void> {
        const ignored = kind === "candidate_rejected";
        const wantsCapture = kind === "listening_started"
            || kind === "listening_retry"
            || kind === "listening_resumed"
            || ignored;
        if (!wantsCapture)
            return;
        if (ignored)
            this.#handlers.onIgnored();
        if (this.#listening)
            return;
        this.#stopCuePlayed = false;
        if (this.#cancelled || this.#settled)
            return;
        browserVoiceEvent(this.#turnId, "capture_requested");
        const reused = await this.#capture.start(this.#socket, this.#turnId);
        if (!reused)
            void this.#playChime("start");
        browserVoiceEvent(this.#turnId, "capture_started");
        if (this.#turnEnded()) {
            this.#releaseCapture(true, false, true);
            return;
        }
        this.#captureStoppedReported = false;
        this.#listening = true;
        this.#handlers.onListening();
    }

    #turnEnded(): boolean {
        return this.#cancelled || this.#settled;
    }

    #handleEndpoint(): void {
        this.#listening = false;
        browserVoiceEvent(this.#turnId, "endpoint_received");
        const keepOpen = this.#handlers.shouldKeepMicrophoneOpen();
        this.#releaseCapture(true, keepOpen);
        this.#handlers.onEndpoint();
        if (!keepOpen && !this.#stopCuePlayed) {
            this.#stopCuePlayed = true;
            void this.#playChime("stop");
        }
    }

    async #handleFinal(message: JsonObject): Promise<void> {
        browserVoiceEvent(this.#turnId, "final_transcript_received");
        const userText = message.string("user_text").trim();
        const previewText = message.string("text").trim();
        const text = userText.length > 0 ? userText : previewText;
        if (text.length === 0)
            return Er.contract("Live audio final transcript is empty.");
        const userAudioArtifactId = message.nonEmpty("user_audio_artifact_id");
        if (userAudioArtifactId !== `runtime-user-audio:${this.#turnId}`)
            return Er.contract("Live audio accepted artifact changed.");
        const commit = await this.#handlers.onFinal({
            text,
            language: parseChatLanguage(message.string("language"), message.path("language")),
            userAudioArtifactId,
        });
        if (commit.image !== undefined) {
            await this.#stageUserImage(commit.image);
            this.#userImageFilename = commit.image.name;
        }
        if (this.#socket.readyState !== WebSocket.OPEN)
            return Er.io("Live audio connection closed before its accepted prompt could commit.");
        this.#socket.send(commitMessage(commit));
        this.#handlers.onCommitted();
    }

    async #stageUserImage(image: File): Promise<void> {
        const form = new FormData();
        form.append("image", image, image.name);
        form.append("image_media_type", image.type);
        const path = `/profiles/${encodeURIComponent(this.#profileId)}`
            + `/user-images/${encodeURIComponent(this.#turnId)}`;
        const response = await fetch(this.#endpoint.api(path), {
            method: "POST",
            body: form,
        });
        if (!response.ok)
            return Er.io(await response.text());
    }

    async #playChime(kind: "start" | "stop"): Promise<void> {
        browserVoiceEvent(this.#turnId, `${kind}_cue_started`);
        try {
            await this.#audio.playListeningCue(kind);
            browserVoiceEvent(this.#turnId, `${kind}_cue_ended`);
        } catch (error: unknown) {
            browserVoiceEvent(this.#turnId, `${kind}_cue_failed`);
            console.error(`Listening ${kind} chime failed`, error);
        }
    }

    #releaseCapture(
        reportCaptureStopped: boolean,
        keepOpen = false,
        forceIfIdle = false,
    ): void {
        const release = forceIfIdle
            ? this.#capture.stopIfOwnedOrIdle(this.#socket, this.#turnId)
            : this.#capture.release(this.#socket, this.#turnId, keepOpen);
        if (release === undefined)
            return;
        browserVoiceEvent(
            this.#turnId,
            release.contextClosed === undefined
                ? "capture_detached"
                : "capture_tracks_stopped",
        );
        if (reportCaptureStopped && !this.#captureStoppedReported) {
            this.#captureStoppedReported = true;
            this.#handlers.onCaptureStopped();
        }
        if (release.contextClosed === undefined)
            return;
        void release.contextClosed
            .then(() => browserVoiceEvent(this.#turnId, "capture_context_closed"))
            .catch((error: unknown) => {
                browserVoiceEvent(this.#turnId, "capture_context_close_failed");
                console.error("Live microphone context close failed", error);
            });
    }

    #closeCapture(release: BrowserLiveAudioCaptureRelease | undefined): void {
        if (release?.contextClosed === undefined)
            return;
        void release.contextClosed.catch((error: unknown) => {
            browserVoiceEvent(this.#turnId, "capture_context_close_failed");
            console.error("Live microphone context close failed", error);
        });
    }

    #settle(result: TextTurnResult | undefined): void {
        if (this.#settled)
            return;
        this.#settled = true;
        this.#releaseCapture(true);
        if (this.#socket.readyState === WebSocket.OPEN)
            this.#closeSocket(1000, "Done");
        this.#resolve(result);
    }

    #fail(error: unknown): void {
        if (this.#settled || this.#cancelled)
            return;
        this.#settled = true;
        this.#releaseCapture(true);
        this.#closeSocket();
        this.#reject(error);
    }

    #handleClose(): void {
        this.#queue = this.#queue.then(() => {
            if (!this.#settled && !this.#cancelled)
                this.#fail(new Error(uiText(this.#language).liveAudioFailed));
        });
    }

    #closeSocket(code?: number, reason?: string): void {
        try {
            if (code === undefined)
                this.#socket.close();
            else
                this.#socket.close(code, reason);
        } catch {
            // Closing a socket whose handshake is still failing is best effort.
        }
    }
}

function completePreviewText(previous: string, next: string): string {
    const previousWords = previous.trim().split(/\s+/u);
    const nextWords = next.trim().split(/\s+/u);
    if (previousWords.length < 24 || nextWords.length > 16)
        return next;
    const previousNormalized = previous.trim().toLowerCase();
    const nextNormalized = next.trim().toLowerCase();
    if (nextNormalized.length === 0
        || nextNormalized.length * 2 >= previousNormalized.length
        || !previousNormalized.endsWith(nextNormalized))
        return next;
    return previous;
}

function startMessage(request: LiveAudioStartRequest, silenceSeconds: number): string {
    return JSON.stringify({
        type: "start",
        session_id: request.sessionId,
        submission_id: request.turnId,
        device_id: request.deviceId,
        text: "",
        language: request.language,
        load_memory: true,
        reasoning_mode: request.reasoningMode,
        model: request.modelId,
        after_sequence: 0,
        purpose: "turn",
        prewarm_existing_session: true,
        silence_seconds: silenceSeconds,
        audio_input_selector: "",
        audio_input_label: "",
        audio: {
            format: "pcm_s16le",
            sample_rate: 16_000,
            channels: 1,
            frame_ms: 20,
            bitrate: 0,
            application: "",
            complexity: 0,
            container: "",
        },
    });
}

function commitMessage(commit: LiveAudioCommit): string {
    return JSON.stringify({
        type: "commit",
        reasoning_mode: commit.reasoningMode,
        model: commit.modelId,
    });
}

function speechCommitDelayMessage(seconds: number): string {
    return JSON.stringify({
        type: "configure",
        silence_seconds: seconds,
    });
}

function audioResult(
    result: TextTurnResult,
    endpoint: WheatleyEndpoint,
    profileId: string,
    sessionId: string,
    imageFilename?: string,
): TextTurnResult {
    return {
        ...result,
        userAudioUrl: endpoint.api(`/audio/${encodeURIComponent(result.turnId)}`),
        ...(imageFilename === undefined ? {} : {
            userImage: {
                url: endpoint.api(
                    `/profiles/${encodeURIComponent(profileId)}`
                    + `/turns/${encodeURIComponent(result.turnId)}`
                    + `/images/${encodeURIComponent(imageFilename)}`
                    + `?session_id=${encodeURIComponent(sessionId)}`,
                ),
                filename: imageFilename,
            },
        }),
    };
}
