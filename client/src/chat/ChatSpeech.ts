import type { SpeechPlayer } from "../audio/SpeechPlayer";
import type { ChatTransport } from "../transport/ChatTransport";
import type { ChatLanguage } from "./Language";

export interface ChatSpeechState {
    readonly autoEnabled: boolean;
    readonly active?: ActiveChatPlayback;
}

export type ChatPlaybackKind = "assistant" | "reasoning" | "user";

export interface ActiveChatPlayback {
    readonly kind: ChatPlaybackKind;
    readonly turnId: string;
    readonly itemId?: string;
}

type Listener = () => void;
type SaveAutoPreference = (enabled: boolean) => void;

interface AutomaticSpeechRequest {
    readonly profileId: string;
    readonly sessionId: string;
    readonly turnId: string;
    readonly itemId: string | undefined;
    readonly startAfterExisting: boolean;
}

class ActiveSpeech {
    readonly kind: "assistant" | "reasoning";
    readonly profileId: string;
    readonly sessionId: string;
    turnId: string;
    readonly speechId: string;
    readonly controller = new AbortController();
    readonly includeReasoningStatus: boolean;
    readonly startAfterExisting: boolean;
    readonly automatic: boolean;
    readonly itemId: string | undefined;
    streamStarted = false;

    constructor(
        profileId: string,
        sessionId: string,
        turnId: string,
        kind: "assistant" | "reasoning",
        itemId: string | undefined,
        includeReasoningStatus: boolean,
        startAfterExisting: boolean,
        automatic: boolean,
    ) {
        this.profileId = profileId;
        this.sessionId = sessionId;
        this.turnId = turnId;
        this.kind = kind;
        this.itemId = itemId;
        this.includeReasoningStatus = includeReasoningStatus;
        this.startAfterExisting = startAfterExisting;
        this.automatic = automatic;
        this.speechId = `web-speech-${crypto.randomUUID()}`;
    }
}

class ActiveUserAudio {
    readonly kind = "user";
    readonly turnId: string;
    readonly audioUrl: string;

    constructor(turnId: string, audioUrl: string) {
        this.turnId = turnId;
        this.audioUrl = audioUrl;
    }
}

class ActiveTextSpeech {
    readonly kind = "assistant";
    readonly profileId: string;
    turnId: string;
    itemId: string;
    readonly text: string;
    readonly language: ChatLanguage;
    readonly controller = new AbortController();

    constructor(
        profileId: string,
        turnId: string,
        itemId: string,
        text: string,
        language: ChatLanguage,
    ) {
        this.profileId = profileId;
        this.turnId = turnId;
        this.itemId = itemId;
        this.text = text;
        this.language = language;
    }
}

type ActivePlayback = ActiveSpeech | ActiveTextSpeech | ActiveUserAudio;

export class ChatSpeech {
    readonly #transport: ChatTransport;
    readonly #player: SpeechPlayer;
    readonly #saveAutoPreference: SaveAutoPreference;
    readonly #listeners = new Set<Listener>();
    readonly #idleWaiters = new Set<() => void>();
    #autoEnabled: boolean;
    #active: ActivePlayback | undefined;
    #automaticQueue: AutomaticSpeechRequest[] = [];

    constructor(
        transport: ChatTransport,
        player: SpeechPlayer,
        autoEnabled: boolean,
        saveAutoPreference: SaveAutoPreference,
    ) {
        this.#transport = transport;
        this.#player = player;
        this.#autoEnabled = autoEnabled;
        this.#saveAutoPreference = saveAutoPreference;
    }

    get state(): ChatSpeechState {
        return {
            autoEnabled: this.#autoEnabled,
            ...(this.#active === undefined
                ? {}
                : {
                    active: {
                        kind: this.#active.kind,
                        turnId: this.#active.turnId,
                        ...((this.#active instanceof ActiveSpeech
                            || this.#active instanceof ActiveTextSpeech)
                            && this.#active.itemId !== undefined
                            ? { itemId: this.#active.itemId }
                            : {}),
                    },
                }),
        };
    }

    observe(listener: Listener): void {
        this.#listeners.add(listener);
    }

    toggleAuto(): boolean {
        this.#autoEnabled = !this.#autoEnabled;
        this.#saveAutoPreference(this.#autoEnabled);
        if (this.#autoEnabled) {
            void this.#player.unlock().catch((error: unknown) =>
                console.error("Speech audio unlock failed", error));
        } else if (
            this.#active instanceof ActiveSpeech
            && this.#active.automatic
        ) {
            this.stop();
        } else {
            this.#automaticQueue = [];
        }
        this.#emit();
        return this.#autoEnabled;
    }

    setAutoEnabled(enabled: boolean): void {
        if (this.#autoEnabled === enabled)
            return;
        this.#autoEnabled = enabled;
        if (!enabled) {
            if (this.#active instanceof ActiveSpeech && this.#active.automatic)
                this.stop();
            else
                this.#automaticQueue = [];
        }
        this.#emit();
    }

    prepare(): void {
        if (this.#autoEnabled) {
            void this.#player.unlock().catch((error: unknown) =>
                console.error("Speech audio unlock failed", error));
        }
    }

    whenIdle(): Promise<void> {
        if (this.#active === undefined)
            return Promise.resolve();
        return new Promise<void>(resolve => this.#idleWaiters.add(resolve));
    }

    playAutomatically(
        profileId: string,
        sessionId: string,
        turnId: string,
        itemId?: string,
        startAfterExisting = false,
    ): void {
        if (!this.#autoEnabled || this.#hasAutomaticSpeech(turnId))
            return;
        if (this.#active !== undefined) {
            this.#automaticQueue.push({
                profileId,
                sessionId,
                turnId,
                itemId,
                startAfterExisting,
            });
            return;
        }
        this.#playSpeech(
            profileId,
            sessionId,
            turnId,
            "assistant",
            itemId,
            false,
            startAfterExisting,
            true,
        );
    }

    suspendForCapture(turnId: string): void {
        this.#player.suspendForCapture(turnId);
    }

    prepareAfterCapture(turnId: string): void {
        this.#player.prepareAfterCapture(turnId);
    }

    playSpeech(profileId: string, sessionId: string, turnId: string, itemId: string): void {
        this.#playSpeech(profileId, sessionId, turnId, "assistant", itemId, false, false, false);
    }

    playReasoning(profileId: string, sessionId: string, turnId: string, itemId: string): void {
        this.#playSpeech(profileId, sessionId, turnId, "reasoning", itemId, false, false, false);
    }

    playText(
        profileId: string,
        turnId: string,
        itemId: string,
        text: string,
        language: ChatLanguage,
    ): void {
        if (
            this.#active instanceof ActiveTextSpeech
            && this.#active.turnId === turnId
            && this.#active.itemId === itemId
        ) {
            this.stop();
            return;
        }
        if (this.#active !== undefined)
            this.stop();
        const active = new ActiveTextSpeech(profileId, turnId, itemId, text, language);
        this.#active = active;
        this.#player.beginLocal(turnId);
        this.#emit();
        void this.#runTextSpeech(active);
    }

    #playSpeech(
        profileId: string,
        sessionId: string,
        turnId: string,
        kind: "assistant" | "reasoning",
        itemId: string | undefined,
        includeReasoningStatus: boolean,
        startAfterExisting: boolean,
        automatic: boolean,
    ): void {
        if (this.#active?.kind === kind
            && this.#active.turnId === turnId
            && (this.#active instanceof ActiveSpeech
                ? this.#active.itemId
                : undefined) === itemId) {
            this.stop();
            return;
        }
        if (this.#active !== undefined)
            this.stop();
        const active = new ActiveSpeech(
            profileId,
            sessionId,
            turnId,
            kind,
            itemId,
            includeReasoningStatus,
            startAfterExisting,
            automatic,
        );
        this.#active = active;
        this.#player.begin({
            profileId,
            sessionId,
            turnId,
            outputId: active.speechId,
            source: kind === "reasoning" ? "reasoning" : "answer",
        });
        this.#emit();
        void this.#runSpeech(active);
    }

    playUserAudio(turnId: string, audioUrl: string): void {
        if (this.#active?.kind === "user" && this.#active.turnId === turnId) {
            this.stop();
            return;
        }
        this.stop();
        const active = new ActiveUserAudio(turnId, audioUrl);
        this.#active = active;
        this.#player.beginLocal(turnId);
        this.#emit();
        void this.#runUserAudio(active);
    }

    replaceTurnId(currentTurnId: string, storedTurnId: string): void {
        if (
            !(this.#active instanceof ActiveSpeech)
            && !(this.#active instanceof ActiveTextSpeech)
        ) return;
        if (this.#active.turnId !== currentTurnId)
            return;
        this.#active.turnId = storedTurnId;
        this.#emit();
    }

    replaceItemId(turnId: string, currentItemId: string, storedItemId: string): void {
        if (
            !(this.#active instanceof ActiveTextSpeech)
            || this.#active.turnId !== turnId
            || this.#active.itemId !== currentItemId
        ) return;
        this.#active.itemId = storedItemId;
        this.#emit();
    }

    stop(): void {
        const active = this.#active;
        this.#automaticQueue = [];
        if (active === undefined)
            return;
        this.#active = undefined;
        if (active instanceof ActiveSpeech || active instanceof ActiveTextSpeech)
            active.controller.abort();
        this.#player.stop();
        if (active instanceof ActiveSpeech && active.streamStarted) {
            void this.#transport.stopTurnSpeech(active.profileId, active.sessionId, active.speechId)
                .catch((error: unknown) =>
                    console.error("Stopping speech stream failed", error));
        }
        this.#emit();
    }

    async #runSpeech(active: ActiveSpeech): Promise<void> {
        try {
            await this.#player.unlock();
            if (this.#active !== active)
                return;
            active.streamStarted = true;
            await this.#transport.streamTurnSpeech(
                active.profileId,
                {
                    sessionId: active.sessionId,
                    turnId: active.turnId,
                    speechId: active.speechId,
                    source: active.kind === "reasoning" ? "reasoning" : "answer",
                    ...(active.itemId === undefined ? {} : { itemId: active.itemId }),
                    includeReasoningStatus: active.includeReasoningStatus,
                    startAfterExisting: active.startAfterExisting,
                },
                { onSegment: segment => this.#player.enqueue(segment.audioUrl) },
                active.controller.signal,
            );
            if (this.#active !== active)
                return;
            await this.#player.finish();
        } catch (error: unknown) {
            if (this.#active === active && !active.controller.signal.aborted)
                console.error("Speech playback failed", error);
        } finally {
            this.#finish(active);
        }
    }

    async #runUserAudio(active: ActiveUserAudio): Promise<void> {
        try {
            await this.#player.unlock();
            if (this.#active !== active)
                return;
            this.#player.enqueue(active.audioUrl);
            await this.#player.finish();
        } catch (error: unknown) {
            if (this.#active === active)
                console.error("User audio playback failed", error);
        } finally {
            this.#finish(active);
        }
    }

    async #runTextSpeech(active: ActiveTextSpeech): Promise<void> {
        try {
            await this.#player.unlock();
            if (this.#active !== active)
                return;
            const segment = await this.#transport.synthesizeSpeech(
                active.profileId,
                active.text,
                active.language,
                active.controller.signal,
            );
            if (this.#active !== active)
                return;
            this.#player.enqueue(segment.audioUrl);
            await this.#player.finish();
        } catch (error: unknown) {
            if (this.#active === active && !active.controller.signal.aborted)
                console.error("Text speech playback failed", error);
        } finally {
            this.#finish(active);
        }
    }

    #hasAutomaticSpeech(turnId: string): boolean {
        return (this.#active instanceof ActiveSpeech
            && this.#active.automatic
            && this.#active.kind === "assistant"
            && this.#active.turnId === turnId)
            || this.#automaticQueue.some(request => request.turnId === turnId);
    }

    #finish(active: ActivePlayback): void {
        if (this.#active !== active)
            return;
        this.#active = undefined;
        this.#player.stop();
        const next = this.#autoEnabled ? this.#automaticQueue.shift() : undefined;
        if (next !== undefined) {
            this.#playSpeech(
                next.profileId,
                next.sessionId,
                next.turnId,
                "assistant",
                next.itemId,
                false,
                next.startAfterExisting,
                true,
            );
        }
        this.#emit();
    }

    #emit(): void {
        if (this.#active === undefined) {
            for (const resolve of this.#idleWaiters)
                resolve();
            this.#idleWaiters.clear();
        }
        for (const listener of this.#listeners)
            listener();
    }
}
