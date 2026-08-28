import { Er } from "../core/Er";
import { JsonObject, parseJson } from "../core/Json";
import type { ChatLanguage } from "../chat/Language";
import { readSseStream, type SseEvent } from "./SseReader";
import type {
    ChatTransport,
    ClientConfigData,
    CompactionEvent,
    CodexEventHandlers,
    SessionTurnEventHandlers,
    PresentationSnapshot,
    ModelCatalog,
    InstructionDocument,
    InstructionSnapshot,
    ProfileSummary,
    RecentSessionSummary,
    ReasoningDetail,
    SessionChoice,
    ChatBranchPoint,
    SessionBranchResult,
    SessionStartHandlers,
    SessionStartResult,
    SpeechSegment,
    SpeechStreamHandlers,
    SpeechStreamRequest,
    StartupState,
    StoredTurn,
    SessionQueueSnapshot,
    SessionQueueMutation,
    TextTurnHandlers,
    TextTurnRequest,
    TextTurnResult,
    ScheduledTaskPresenceResult,
    ToolDetail,
} from "./ChatTransport";
import {
    parseClientConfig,
    parseCompactionEvent,
    parseCompactionStatus,
    parseConversationEvent,
    parseConversationAccepted,
    parseConversationFailure,
    parseCodexLiveEvent,
    parsePresentationSnapshot,
    parseErrorMessage,
    parseProfiles,
    parseModelCatalog,
    parseInstructionSnapshot,
    parseGeneratedImage,
    parseRecentSessions,
    parseReasoningDetail,
    parseReasoningEvent,
    parseSessionOpened,
    parseSessionBranchResult,
    parseSessionStartResult,
    parseSpeechSegment,
    parseStartupState,
    parseStoredTurns,
    parseSessionQueueSnapshot,
    parseSessionQueueMutation,
    parseSystemMessage,
    parseTextTurnResult,
    parseTokenMessage,
    parseToolMessage,
    parseToolDetail,
} from "./WheatleyJson";
import type { WheatleyEndpoint } from "./WheatleyEndpoint";

type SseHandler = (event: SseEvent) => boolean;

interface SpeechStreamState {
  completed: boolean;
}

interface ConversationCursor {
  turnId: string;
  sequence: number;
}

function requireNextConversationEvent(
    event: ReturnType<typeof parseConversationEvent>,
    profileId: string,
    sessionId: string,
    cursor: ConversationCursor,
): void {
    if (event.profileId !== profileId)
        return Er.contract("Conversation event profile changed.");
    if (event.sessionId !== sessionId)
        return Er.contract("Conversation event session changed.");
    if (cursor.turnId !== "" && event.turnId !== cursor.turnId)
        return Er.contract("Conversation event turn changed.");
    if (event.sequence !== cursor.sequence + 1)
        return Er.contract("Conversation event sequence gap.");
    cursor.turnId = event.turnId;
    cursor.sequence = event.sequence;
}

export class WheatleyApi implements ChatTransport {
    readonly #endpoint: WheatleyEndpoint;

    constructor(endpoint: WheatleyEndpoint) {
        this.#endpoint = endpoint;
    }

    resourceUrl(url: string): string {
        return this.#endpoint.resource(url);
    }

    async loadTranslation(language: ChatLanguage): Promise<unknown> {
        return await this.#get(`/translations/${language}`);
    }

    async loadClientConfig(): Promise<ClientConfigData> {
        return parseClientConfig(await this.#get("/config/clients/web"));
    }

    async saveClientConfig(config: ClientConfigData): Promise<void> {
        const response = await fetch(this.#url("/config/clients/web"), {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                last_used_profile_id: config.lastUsedProfileId,
                speech_commit_delay_seconds: config.speechCommitDelaySeconds,
                output_recovery_ms: config.outputRecoveryMs,
                thinking_music_fade_in_ms: config.thinkingMusicFadeInMs,
                thinking_music_fade_out_ms: config.thinkingMusicFadeOutMs,
                profiles: config.profiles.map((profile) => ({
                    profile_id: profile.profileId,
                    accent: profile.accentId,
                    auto_speak: profile.autoSpeak,
                    play_music: profile.playMusic,
                    keep_microphone_on: profile.keepMicrophoneOn,
                    language: profile.language,
                    reasoning_mode: profile.reasoningMode,
                    activity_pane_open: profile.activityPaneOpen,
                    show_thinking: profile.showThinking,
                    show_compacted_context: profile.showCompactedContext,
                    model: profile.modelId,
                })),
            }),
        });
        if (!response.ok) return Er.io(await this.#error(response));
    }

    async loadProfiles(): Promise<readonly ProfileSummary[]> {
        return parseProfiles(await this.#get("/profiles"));
    }

    async loadModels(): Promise<ModelCatalog> {
        return parseModelCatalog(await this.#get("/models"));
    }

    async reportScheduledTaskPresence(
        profileId: string,
        sessionId: string,
        clientId: string,
        deviceId: string,
        phase: string,
        visible: boolean,
        lastInteractionAt: string,
        expiresAt: string,
    ): Promise<ScheduledTaskPresenceResult> {
        const path = this.#profilePath(profileId, "/scheduled-tasks/presence");
        const response = await fetch(this.#url(path), {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                client_id: clientId,
                device_id: deviceId,
                session_id: sessionId,
                phase,
                visible,
                last_interaction_at: lastInteractionAt,
                expires_at: expiresAt,
            }),
        });
        if (!response.ok) return Er.io(await this.#error(response));
        const value = await response.json() as { yield_requested?: unknown };
        return { yieldRequested: value.yield_requested === true };
    }

    async listScheduledTasks(profileId: string): Promise<unknown> {
        return await this.#get(this.#profilePath(profileId, "/scheduled-tasks"));
    }

    async getScheduledTask(profileId: string, taskId: string): Promise<unknown> {
        return await this.#get(
            this.#profilePath(
                profileId,
                `/scheduled-tasks/${encodeURIComponent(taskId)}`,
            ),
        );
    }

    async updateScheduledTask(
        profileId: string,
        taskId: string,
        sessionId: string,
        modelId: string,
        patch: unknown,
    ): Promise<unknown> {
        return await this.#scheduledTaskMutation(profileId, taskId, "PUT", {
            session_id: sessionId,
            model: modelId,
            patch,
        });
    }

    async setScheduledTaskEnabled(
        profileId: string,
        taskId: string,
        enabled: boolean,
    ): Promise<unknown> {
        return await this.#scheduledTaskMutation(
            profileId,
            `${taskId}/enabled`,
            "PUT",
            { enabled },
        );
    }

    async runScheduledTaskNow(
        profileId: string,
        taskId: string,
    ): Promise<unknown> {
        return await this.#scheduledTaskMutation(
            profileId,
            `${taskId}/run-now`,
            "POST",
            {},
        );
    }

    async deleteScheduledTask(profileId: string, taskId: string): Promise<void> {
        await this.#scheduledTaskMutation(profileId, taskId, "DELETE", undefined);
    }

    async loadInstructions(profileId: string): Promise<InstructionSnapshot> {
        return parseInstructionSnapshot(
            await this.#get(this.#profilePath(profileId, "/instructions")),
        );
    }

    async saveInstructions(
        profileId: string,
        documents: readonly InstructionDocument[],
        workspacePath: string,
    ): Promise<InstructionSnapshot> {
        const response = await fetch(
            this.#url(this.#profilePath(profileId, "/instructions")),
            {
                method: "PUT",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    workspace_path: workspacePath,
                    documents: documents.map((document) => ({
                        id: document.id,
                        content: document.content,
                    })),
                }),
            },
        );
        if (!response.ok) return Er.io(await this.#error(response));
        return parseInstructionSnapshot(
            parseJson(await response.text(), "HTTP response"),
        );
    }

    async loadStartupState(
        profileId: string,
        language?: ChatLanguage | "",
    ): Promise<StartupState> {
        const query =
      language === undefined || language === ""
          ? ""
          : `?language=${encodeURIComponent(language)}`;
        return parseStartupState(
            await this.#get(this.#profilePath(profileId, `/startup${query}`)),
        );
    }

    async startSession(
        profileId: string,
        choice: SessionChoice,
        modelId: string,
        handlers: SessionStartHandlers,
    ): Promise<SessionStartResult> {
        const response = await fetch(
            this.#url(this.#profilePath(profileId, "/startup/stream")),
            {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    mode: "chat",
                    model: modelId,
                    language: choice.kind === "new" ? choice.language : "",
                    resume_session_id: choice.kind === "resume" ? choice.sessionId : "",
                }),
            },
        );

        let result: SessionStartResult | undefined;
        await this.#readSse(response, (event) => {
            switch (event.name) {
                case "system":
                    parseSystemMessage(this.#eventData(event));
                    return true;
                case "opened":
                    handlers.onOpened(parseSessionOpened(this.#eventData(event)));
                    return true;
                case "done":
                    result = parseSessionStartResult(this.#eventData(event));
                    return false;
                case "error":
                    return Er.io(parseErrorMessage(this.#eventData(event)));
                default:
                    return Er.contract(`Unsupported startup event ${event.name}.`);
            }
        });
        return (
            result ?? Er.contract("Startup stream ended without a final response.")
        );
    }

    async loadRecentSessions(
        profileId: string,
    ): Promise<readonly RecentSessionSummary[]> {
        const path = this.#profilePath(profileId, "/recent-sessions");
        return parseRecentSessions(await this.#get(path));
    }

    async loadSession(
        profileId: string,
        sessionId: string,
    ): Promise<readonly StoredTurn[]> {
        return parseStoredTurns(
            await this.#get(
                this.#profilePath(
                    profileId,
                    `/session-turns?session_id=${encodeURIComponent(sessionId)}`,
                ),
            ),
            (turnId) => this.#url(`/audio/${encodeURIComponent(turnId)}`),
            (turnId, filename) =>
                this.#userImageUrl(profileId, sessionId, turnId, filename),
        );
    }

    async loadSessionQueue(
        profileId: string,
        sessionId: string,
    ): Promise<SessionQueueSnapshot> {
        return parseSessionQueueSnapshot(
            await this.#get(
                this.#profilePath(
                    profileId,
                    `/queue?session_id=${encodeURIComponent(sessionId)}`,
                ),
            ),
        );
    }

    async cancelSessionQueueItem(
        profileId: string,
        sessionId: string,
        itemId: string,
    ): Promise<SessionQueueMutation | undefined> {
        const response = await fetch(
            this.#url(this.#profilePath(
                profileId,
                `/queue/${encodeURIComponent(itemId)}/cancel`,
            )),
            {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ session_id: sessionId }),
            },
        );
        // The item can leave the cancellable queue while the user's click is
        // in flight. That conflict is normal synchronization, not a turn
        // failure; the queue/event stream will provide the authoritative state.
        if (response.status === 409) return undefined;
        if (!response.ok) return Er.io(await this.#error(response));
        return parseSessionQueueMutation(parseJson(await response.text(), "queue cancellation"));
    }

    async loadPresentation(
        profileId: string,
        sessionId: string,
    ): Promise<PresentationSnapshot> {
        return parsePresentationSnapshot(
            await this.#get(
                this.#profilePath(
                    profileId,
                    `/presentation?session_id=${encodeURIComponent(sessionId)}`,
                ),
            ),
        );
    }

    async branchSession(
        profileId: string,
        sessionId: string,
        point: ChatBranchPoint,
    ): Promise<SessionBranchResult> {
        const response = await fetch(
            this.#url(this.#profilePath(profileId, "/branches")),
            {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    session_id: sessionId,
                    turn_id: point.turnId,
                    kind: point.kind,
                    item_id: point.itemId,
                }),
            },
        );
        if (!response.ok) return Er.io(await this.#error(response));
        return parseSessionBranchResult(
            parseJson(await response.text(), "HTTP response"),
        );
    }

    async compactSession(
        profileId: string,
        sessionId: string,
    ): Promise<CompactionEvent> {
        const response = await fetch(
            this.#url(this.#profilePath(profileId, "/compaction")),
            {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ session_id: sessionId }),
            },
        );
        if (!response.ok) return Er.io(await this.#error(response));
        return parseCompactionEvent(await response.json(), "compaction response");
    }

    async deleteSession(profileId: string, sessionId: string): Promise<void> {
        const suffix = `/session?session_id=${encodeURIComponent(sessionId)}`;
        const response = await fetch(
            this.#url(this.#profilePath(profileId, suffix)),
            {
                method: "DELETE",
            },
        );
        if (response.status === 404) return;
        if (!response.ok) return Er.io(await this.#error(response));
    }

    async loadToolDetail(
        profileId: string,
        sessionId: string,
        turnId: string,
        callIndex: number,
    ): Promise<ToolDetail> {
        const suffix =
      `/turns/${encodeURIComponent(turnId)}/tools/${callIndex}` +
      `?session_id=${encodeURIComponent(sessionId)}`;
        return parseToolDetail(
            await this.#get(this.#profilePath(profileId, suffix)),
        );
    }

    async loadReasoning(
        profileId: string,
        sessionId: string,
        turnId: string,
        itemId: string,
    ): Promise<ReasoningDetail> {
        const suffix =
      `/turns/${encodeURIComponent(turnId)}/reasoning` +
      `?session_id=${encodeURIComponent(sessionId)}` +
      `&item_id=${encodeURIComponent(itemId)}`;
        return parseReasoningDetail(
            await this.#get(this.#profilePath(profileId, suffix)),
        );
    }

    async streamTextTurn(
        profileId: string,
        request: TextTurnRequest,
        handlers: TextTurnHandlers,
    ): Promise<TextTurnResult> {
        const response =
      request.image === undefined
          ? await this.#openTextTurn(profileId, request)
          : await this.#openImageTurn(profileId, request);

        let result: TextTurnResult | undefined;
        const cursor: ConversationCursor = { turnId: "", sequence: 0 };
        await this.#readSse(response, (event) => {
            const data = this.#eventData(event);
            switch (event.name) {
                case "conversation": {
                    const conversation = parseConversationEvent(data);
                    requireNextConversationEvent(
                        conversation,
                        profileId,
                        request.sessionId,
                        cursor,
                    );
                    handlers.onEvent(conversation);
                    switch (conversation.kind) {
                        case "assistant_delta":
                            handlers.onToken(
                                parseTokenMessage(conversation.payload),
                                conversation.turnId,
                            );
                            return true;
                        case "tool":
                            handlers.onTool(
                                parseToolMessage(conversation.payload),
                                conversation.turnId,
                            );
                            return true;
                        case "artifact":
                            handlers.onArtifact(
                                parseGeneratedImage(conversation.payload, (url) =>
                                    this.#endpoint.resource(url),
                                ),
                                conversation.turnId,
                            );
                            return true;
                        case "reasoning":
                            handlers.onReasoning(
                                parseReasoningEvent(conversation.payload),
                                conversation.turnId,
                            );
                            return true;
                        case "status": {
                            const payload = JsonObject.from(
                                conversation.payload,
                                "conversation status",
                            );
                            const status = payload.string("code");
                            if (status === "conversation_accepted")
                                handlers.onAccepted(parseConversationAccepted(
                                    conversation.payload,
                                    conversation.turnId,
                                ));
                            else if (status === "api_text_pi_started")
                                handlers.onStarted(conversation.turnId);
                            else if (status.startsWith("pi_compaction_"))
                                handlers.onCompaction(parseCompactionStatus(payload));
                            return true;
                        }
                        case "completed":
                            result = parseTextTurnResult(conversation.payload);
                            return false;
                        case "failed": {
                            const failure = parseConversationFailure(conversation.payload);
                            handlers.onFailed(
                                failure,
                                conversation.turnId,
                                conversation.timestamp,
                            );
                            return Er.io(failure.message);
                        }
                    }
                    return Er.contract("Unsupported conversation event kind.");
                }
                case "error":
                    return Er.io(parseErrorMessage(data));
                default:
                    return Er.contract(`Unsupported text turn event ${event.name}.`);
            }
        });
        const completed =
      result ?? Er.contract("Text turn stream ended without a final response.");
        return request.image === undefined
            ? completed
            : {
                ...completed,
                userImage: {
                    url: this.#userImageUrl(
                        profileId,
                        request.sessionId,
                        completed.turnId,
                        request.image.name,
                    ),
                    filename: request.image.name,
                },
            };
    }

    async stopTextTurn(
        profileId: string,
        sessionId: string,
        turnId: string,
    ): Promise<void> {
        const path = this.#profilePath(
            profileId,
            `/turns/text/${encodeURIComponent(turnId)}/stop`,
        );
        const response = await fetch(this.#url(path), {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ session_id: sessionId }),
        });
        if (!response.ok) return Er.io(await this.#error(response));
    }

    async synthesizeSpeech(
        profileId: string,
        text: string,
        language: ChatLanguage,
        signal: AbortSignal,
    ): Promise<SpeechSegment> {
        const response = await fetch(
            this.#url(this.#profilePath(profileId, "/tts")),
            {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ text, language }),
                signal,
            },
        );
        if (!response.ok) return Er.io(await this.#error(response));
        return parseSpeechSegment(await response.json(), (url) =>
            this.#endpoint.resource(url),
        );
    }

    async streamTurnSpeech(
        profileId: string,
        request: SpeechStreamRequest,
        handlers: SpeechStreamHandlers,
        signal: AbortSignal,
    ): Promise<void> {
        const suffix = `/turns/${encodeURIComponent(request.turnId)}/speech/stream`;
        const response = await fetch(
            this.#url(this.#profilePath(profileId, suffix)),
            {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    session_id: request.sessionId,
                    speech_id: request.speechId,
                    source: request.source,
                    item_id: request.itemId ?? "",
                    include_reasoning_status: request.includeReasoningStatus,
                    start_after_existing: request.startAfterExisting,
                }),
                signal,
            },
        );

        const state: SpeechStreamState = { completed: false };
        await this.#readSse(response, (event) => {
            const data = this.#eventData(event);
            switch (event.name) {
                case "segment":
                    handlers.onSegment(
                        parseSpeechSegment(data, (url) => this.#endpoint.resource(url)),
                    );
                    return true;
                case "done":
                    state.completed = true;
                    return false;
                case "error":
                    return Er.io(parseErrorMessage(data));
                default:
                    return Er.contract(`Unsupported speech event ${event.name}.`);
            }
        });
        if (!state.completed)
            return Er.contract("Speech stream ended without a final response.");
    }

    async stopTurnSpeech(
        profileId: string,
        sessionId: string,
        speechId: string,
    ): Promise<void> {
        const suffix = `/speech/${encodeURIComponent(speechId)}/stop`;
        const response = await fetch(
            this.#url(this.#profilePath(profileId, suffix)),
            {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ session_id: sessionId }),
            },
        );
        if (!response.ok) return Er.io(await this.#error(response));
    }

    async streamCodexEvents(
        profileId: string,
        sessionId: string,
        afterSequence: number,
        handlers: CodexEventHandlers,
        signal: AbortSignal,
    ): Promise<void> {
        const suffix =
      `/codex/events?session_id=${encodeURIComponent(sessionId)}` +
      `&after_sequence=${encodeURIComponent(afterSequence)}`;
        const response = await fetch(
            this.#url(this.#profilePath(profileId, suffix)),
            { signal },
        );
        await this.#readSse(response, (event) => {
            if (event.name === "heartbeat") return true;
            if (event.name !== "codex")
                return Er.contract(`Unsupported Codex event ${event.name}.`);
            handlers.onEvent(parseCodexLiveEvent(this.#eventData(event)));
            return true;
        });
    }

    async streamSessionTurns(
        profileId: string,
        sessionId: string,
        afterSequence: number,
        handlers: SessionTurnEventHandlers,
        signal: AbortSignal,
    ): Promise<void> {
        const suffix =
      `/session-turns/stream?session_id=${encodeURIComponent(sessionId)}` +
      `&after_sequence=${encodeURIComponent(afterSequence)}`;
        const response = await fetch(
            this.#url(this.#profilePath(profileId, suffix)),
            { signal },
        );
        await this.#readSse(response, (event) => {
            if (event.name === "heartbeat") return true;
            if (event.name === "changed") {
                const value = this.#eventData(event);
                const changed = JsonObject.from(value, "session turn change");
                const presentationSequence = changed.opt.positiveInteger(
                    "presentation_sequence",
                ) ?? changed.opt.positiveInteger("watermark");
                if (presentationSequence === undefined)
                    return Er.contract("A session turn change has no presentation sequence.");
                handlers.onCursor(presentationSequence);
                const mutation = typeof value === "object"
                    && value !== null
                    && "item" in value
                    && "revision" in value
                    ? parseSessionQueueMutation(value)
                    : undefined;
                handlers.onChanged(mutation);
                return true;
            }
            if (event.name === "conversation") {
                const conversation = parseConversationEvent(this.#eventData(event));
                if (conversation.presentationSequence === undefined)
                    return Er.contract(
                        "A session conversation event has no presentation sequence.",
                    );
                handlers.onCursor(conversation.presentationSequence);
                handlers.onConversation(conversation);
                return true;
            }
            return Er.contract(`Unsupported session-turn event ${event.name}.`);
        });
    }

    async #get(path: string): Promise<unknown> {
        const response = await fetch(this.#url(path));
        if (!response.ok) return Er.io(await this.#error(response));
        return parseJson(await response.text(), "HTTP response");
    }

    async #scheduledTaskMutation(
        profileId: string,
        suffix: string,
        method: string,
        body: unknown,
    ): Promise<unknown> {
        const response = await fetch(
            this.#url(this.#profilePath(profileId, `/scheduled-tasks/${suffix}`)),
            {
                method,
                ...(body === undefined
                    ? {}
                    : { headers: { "Content-Type": "application/json" } }),
                ...(body === undefined ? {} : { body: JSON.stringify(body) }),
            },
        );
        if (!response.ok) return Er.io(await this.#error(response));
        return parseJson(await response.text(), "scheduled task response");
    }

    async #openTextTurn(
        profileId: string,
        request: TextTurnRequest,
    ): Promise<Response> {
        const path = this.#profilePath(profileId, "/turns/text/stream");
        return await fetch(this.#url(path), {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                session_id: request.sessionId,
                text: request.text,
                submission_id: request.turnId,
                device_id: request.deviceId,
                language: request.language,
                source: "browser_text",
                load_memory: true,
                reasoning_mode: request.reasoningMode,
                model: request.modelId,
                after_sequence: 0,
            }),
        });
    }

    async #openImageTurn(
        profileId: string,
        request: TextTurnRequest,
    ): Promise<Response> {
        const image = request.image!;
        const form = new FormData();
        form.append("image", image, image.name);
        form.append("image_media_type", image.type);
        form.append("session_id", request.sessionId);
        form.append("text", request.text);
        form.append("submission_id", request.turnId);
        form.append("device_id", request.deviceId);
        form.append("language", request.language);
        form.append("load_memory", "true");
        form.append("reasoning_mode", request.reasoningMode);
        form.append("model", request.modelId);
        form.append("after_sequence", "0");
        const path = this.#profilePath(profileId, "/turns/image/stream");
        return await fetch(this.#url(path), { method: "POST", body: form });
    }

    #userImageUrl(
        profileId: string,
        sessionId: string,
        turnId: string,
        filename: string,
    ): string {
        const suffix =
      `/turns/${encodeURIComponent(turnId)}` +
      `/images/${encodeURIComponent(filename)}` +
      `?session_id=${encodeURIComponent(sessionId)}`;
        return this.#url(this.#profilePath(profileId, suffix));
    }

    async #readSse(response: Response, handler: SseHandler): Promise<void> {
        if (!response.ok) return Er.io(await this.#error(response));
        if (response.body === null) return Er.contract("SSE response has no body.");
        await readSseStream(response.body, handler);
    }

    #eventData(event: SseEvent): unknown {
        return parseJson(event.data, `${event.name} SSE event`);
    }

    async #error(response: Response): Promise<string> {
        const text = await response.text();
        if (text.length === 0) return `HTTP ${response.status}`;
        try {
            return parseErrorMessage(parseJson(text, "HTTP error response"));
        } catch {
            return text;
        }
    }

    #url(path: string): string {
        return this.#endpoint.api(path);
    }

    #profilePath(profileId: string, suffix: string): string {
        return `/profiles/${encodeURIComponent(profileId)}${suffix}`;
    }
}
