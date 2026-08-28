import { parseChatLanguage, type ChatLanguage } from "../chat/Language";
import { Er } from "../core/Er";
import { JsonObject, jsonArray } from "../core/Json";
import { isReasoningMode, reasoningModes, type ReasoningMode } from "./ChatTransport";
import type {
    ClientConfigData,
    CompactionEvent,
    CodexLiveEvent,
    PresentationSnapshot,
    PresentedConversationEvent,
    ModelCatalog,
    ModelInfo,
    InstructionSnapshot,
    InstructionDocument,
    GeneratedImage,
    ProfileClientConfigData,
    ProfileSummary,
    RecentSessionSummary,
    ReasoningDetail,
    ReasoningEvent,
    SessionStartResult,
    SessionBranchResult,
    SpeechSegment,
    StartupState,
    StoredTurn,
    StoredTurnItem,
    TextEvent,
    TextTurnMetrics,
    ToolDetail,
    ToolIndicator,
    TextTurnResult,
    ConversationEventEnvelope,
    ConversationAccepted,
    ConversationFailure,
    SessionQueueItem,
    SessionQueueMutation,
    SessionQueueSnapshot,
} from "./ChatTransport";

const instructionDocumentIds = [
    "system",
    "user",
    "workspace",
    "auto_memory",
    "memory_rules",
] as const;

export type VoiceEventKind =
    | "ready"
    | "listening_started"
    | "listening_retry"
    | "listening_suspended"
    | "listening_resumed"
    | "candidate_rejected"
    | "transcript_draft_selected"
    | "audio_receiving"
    | "speech_detected"
    | "preview_changed"
    | "endpoint_reached"
    | "transcript_accepted"
    | "session_resume_choice"
    | "failed";

export interface VoiceEventEnvelope {
    readonly kind: VoiceEventKind;
    readonly payload: unknown;
}

export function parseVoiceEvent(value: unknown): VoiceEventEnvelope {
    const event = JsonObject.from(value, "voice event");
    if (event.string("type") !== "voice_event")
        return Er.contract("Voice event type must be voice_event.");
    return {
        kind: event.choice("kind", [
            "ready",
            "listening_started",
            "listening_retry",
            "listening_suspended",
            "listening_resumed",
            "candidate_rejected",
            "transcript_draft_selected",
            "audio_receiving",
            "speech_detected",
            "preview_changed",
            "endpoint_reached",
            "transcript_accepted",
            "session_resume_choice",
            "failed",
        ] as const),
        payload: event.value("payload"),
    };
}

export function parseConversationEvent(value: unknown): ConversationEventEnvelope {
    const event = JsonObject.from(value, "conversation event");
    const sequence = event.number("sequence");
    const presentationSequence = event.opt.positiveInteger("presentation_sequence");
    if (!Number.isSafeInteger(sequence) || sequence <= 0)
        return Er.contract("Conversation event sequence must be a positive integer.");
    return {
        profileId: event.string("profile_id"),
        sessionId: event.string("session_id"),
        turnId: event.string("turn_id"),
        sequence,
        ...(presentationSequence === undefined ? {} : { presentationSequence }),
        timestamp: event.string("timestamp"),
        kind: event.choice("kind", [
            "status",
            "assistant_delta",
            "reasoning",
            "tool",
            "artifact",
            "completed",
            "failed",
        ] as const),
        payload: event.value("payload"),
    };
}

export function parseConversationFailure(value: unknown): ConversationFailure {
    const failure = JsonObject.from(value, "conversation failure");
    return {
        code: failure.string("code"),
        message: failure.string("message"),
    };
}

const sessionQueueStates = [
    "preparing",
    "ready",
    "running",
    "completed",
    "failed",
    "cancelled",
    "interrupted",
] as const;

export function parseConversationAccepted(
    value: unknown,
    turnId: string,
): ConversationAccepted {
    const status = JsonObject.from(value, "conversation accepted status");
    const details = status.object("details");
    return {
        turnId,
        submissionId: details.string("submission_id"),
        queueState: details.choice("queue_state", sessionQueueStates),
        queueSequence: details.integer("queue_sequence", 1),
        queueRevision: details.nonNegativeInteger("queue_revision"),
    };
}

function parseSessionQueueItem(value: unknown, path: string): SessionQueueItem {
    const item = JsonObject.from(value, path);
    return {
        id: item.string("id"),
        sessionId: item.string("session_id"),
        sequence: item.integer("sequence", 1),
        kind: item.choice("kind", ["user", "scheduled"] as const),
        source: item.string("source"),
        deviceId: item.string("device_id"),
        submittedAt: item.string("submitted_at"),
        state: item.choice("state", sessionQueueStates),
        text: item.string("text"),
        model: item.string("model"),
        reasoningMode: item.choice("reasoning_mode", reasoningModes),
        language: parseChatLanguage(item.string("language"), `${path}.language`),
        artifactReference: item.string("artifact_reference"),
        preparationSource: item.string("preparation_source"),
        executionId: item.string("execution_id"),
        failure: item.string("failure"),
        resultReference: item.string("result_reference"),
    };
}

export function parseSessionQueueSnapshot(value: unknown): SessionQueueSnapshot {
    const snapshot = JsonObject.from(value, "session queue");
    return {
        schemaVersion: snapshot.integer("schema_version", 1, 1),
        sessionId: snapshot.string("session_id"),
        revision: snapshot.nonNegativeInteger("revision"),
        nextSequence: snapshot.integer("next_sequence", 1),
        items: snapshot.array("items").map((item, index) =>
            parseSessionQueueItem(item, `session queue.items[${index}]`)),
    };
}

export function parseSessionQueueMutation(value: unknown): SessionQueueMutation {
    const mutation = JsonObject.from(value, "session queue mutation");
    return {
        sessionId: mutation.string("session_id"),
        revision: mutation.nonNegativeInteger("revision"),
        item: parseSessionQueueItem(mutation.value("item"), "session queue.item"),
    };
}

export function parseClientConfig(value: unknown): ClientConfigData {
    const config = JsonObject.from(value, "client config");
    const outputRecoveryMs = config.integer("output_recovery_ms", 0, 30_000);
    const thinkingMusicFadeInMs = config.integer("thinking_music_fade_in_ms", 0, 10_000);
    const thinkingMusicFadeOutMs = config.integer("thinking_music_fade_out_ms", 0, 10_000);
    const profiles = config.array("profiles").map((value, index) => {
        const profile = JsonObject.from(value, `client config.profiles[${index}]`);
        const language = profile.string("language");
        return {
            profileId: profile.string("profile_id"),
            accentId: profile.string("accent"),
            autoSpeak: profile.boolean("auto_speak"),
            playMusic: profile.boolean("play_music"),
            keepMicrophoneOn: profile.boolean("keep_microphone_on"),
            language: language === ""
                ? ""
                : parseChatLanguage(language, profile.path("language")),
            reasoningMode: profile.choice(
                "reasoning_mode",
                reasoningModes,
            ),
            activityPaneOpen: profile.boolean("activity_pane_open"),
            showThinking: profile.boolean("show_thinking"),
            showCompactedContext: profile.boolean("show_compacted_context"),
            modelId: profile.string("model"),
        } satisfies ProfileClientConfigData;
    });
    if (profiles.length === 0)
        return Er.contract("Client config must include at least one profile.");
    const delay = config.integer("speech_commit_delay_seconds", 1, 12);
    return {
        lastUsedProfileId: config.string("last_used_profile_id"),
        speechCommitDelaySeconds: delay,
        outputRecoveryMs,
        thinkingMusicFadeInMs,
        thinkingMusicFadeOutMs,
        profiles,
    };
}

export function parseCodexLiveEvent(value: unknown): CodexLiveEvent {
    const event = JsonObject.from(value, "Codex live event");
    return {
        sequence: event.nonNegativeInteger("sequence"),
        threadId: event.string("thread_id"),
        turnId: event.string("turn_id"),
        itemId: event.string("item_id"),
        summaryIndex: event.integer("summary_index", -1),
        kind: event.choice("kind", [
            "reasoning_summary",
            "tool",
            "steer",
            "final",
            "error",
        ] as const),
        operation: event.choice("operation", ["start", "delta", "finish"] as const),
        text: event.string("text"),
        name: event.string("name"),
        status: event.string("status"),
        timestamp: event.string("timestamp"),
        recovered: event.boolean("recovered"),
    };
}

export function parsePresentationSnapshot(value: unknown): PresentationSnapshot {
    const snapshot = JsonObject.from(value, "presentation snapshot");
    const entries = snapshot.array("entries").map((value, index) => {
        const entry = JsonObject.from(value, `presentation snapshot.entries[${index}]`);
        const sequence = entry.positiveInteger("sequence");
        const source = entry.choice("source", ["pi", "codex", "queue"] as const);
        return {
            sequence,
            source,
            kind: entry.string("kind"),
            turnId: entry.string("turn_id"),
            itemId: entry.string("item_id"),
            payload: entry.value("payload"),
        };
    });
    const conversationEvents: PresentedConversationEvent[] = [];
    for (const entry of entries) {
        if (entry.source !== "pi" || ![
            "status",
            "assistant_delta",
            "reasoning",
            "tool",
            "artifact",
            "completed",
            "failed",
        ].includes(entry.kind)) continue;
        // Pre-event branch records use the same marker names solely for
        // ordering and deliberately carry `{}`. They are not live events.
        try {
            conversationEvents.push({
                ...parseConversationEvent(entry.payload),
                presentationSequence: entry.sequence,
            });
        } catch {
            // A presentation marker without the ConversationEvent contract is
            // retained in `markers` above, but cannot be replayed as a token.
        }
    }
    return {
        watermark: snapshot.nonNegativeInteger("watermark"),
        markers: entries.map(entry => ({
            sequence: entry.sequence,
            source: entry.source,
            kind: entry.kind,
            turnId: entry.turnId,
            itemId: entry.itemId,
        })),
        queueMutations: entries.flatMap(entry => {
            if (entry.source !== "queue" || entry.kind !== "lifecycle") return [];
            return [parseSessionQueueMutation(entry.payload)];
        }),
        conversationEvents,
        failures: entries.flatMap(entry => {
            if (entry.source !== "pi" || entry.kind !== "failed") return [];
            try {
                const event = parseConversationEvent(entry.payload);
                const failure = parseConversationFailure(event.payload);
                // Builds before the steering-boundary fix wrote this synthetic
                // failure onto the completed parent and every adjacent steer.
                // It was never an agent failure and must not reappear on reload.
                if (failure.message === "Pi completed before queued steering was delivered")
                    return [];
                return [{
                    ...failure,
                    turnId: event.turnId,
                    timestamp: event.timestamp,
                    presentationSequence: entry.sequence,
                }];
            } catch {
                return [];
            }
        }),
        codexEvents: entries.flatMap(entry => entry.source === "codex"
            ? [{ ...parseCodexLiveEvent(entry.payload), sequence: entry.sequence }]
            : []),
        compactions: entries.flatMap(entry => entry.source === "pi" && entry.kind === "compaction"
            ? [{ ...parseCompactionEvent(entry.payload, "presentation compaction"),
                presentationSequence: entry.sequence }]
            : []),
    };
}

export function parseSessionBranchResult(value: unknown): SessionBranchResult {
    const result = JsonObject.from(value, "session branch");
    return {
        sessionId: result.string("session_id"),
        language: result.choice("language", ["en", "sk", "de"] as const),
    };
}

export function parseCompactionStatus(status: JsonObject): CompactionEvent {
    const code = status.string("code");
    const details = status.object("details");
    if (code === "pi_compaction_started") {
        return {
            id: details.string("id"),
            reason: details.choice("reason", ["manual", "threshold", "overflow"] as const),
            status: "compacting",
            startedAt: details.string("started_at"),
            completedAt: "",
            durationMs: 0,
            summary: "",
            errorMessage: "",
            tokensBefore: 0,
            estimatedTokensAfter: 0,
            willRetry: false,
        };
    }
    return parseCompactionEvent(status.value("details"), "conversation compaction");
}

export function parseCompactionEvent(value: unknown, label: string): CompactionEvent {
    const event = JsonObject.from(value, label);
    const presentationSequence = event.opt.positiveInteger("presentation_sequence");
    return {
        id: event.string("id"),
        reason: event.choice("reason", ["manual", "threshold", "overflow"] as const),
        status: event.choice(
            "status",
            ["compacting", "completed", "failed", "aborted", "skipped"] as const,
        ),
        startedAt: event.string("started_at"),
        completedAt: event.string("completed_at"),
        durationMs: event.nonNegativeInteger("duration_ms"),
        summary: event.string("summary"),
        errorMessage: event.string("error_message"),
        tokensBefore: event.nonNegativeInteger("tokens_before"),
        estimatedTokensAfter: event.nonNegativeInteger("estimated_tokens_after"),
        willRetry: event.boolean("will_retry"),
        ...(presentationSequence === undefined ? {} : { presentationSequence }),
    };
}

export function parseModelCatalog(value: unknown): ModelCatalog {
    const catalog = JsonObject.from(value, "model catalog");
    const models = catalog.array("models").map((row, index) => {
        const model = JsonObject.from(row, `model catalog.models[${index}]`);
        const reasoningModes = model.array("reasoning_modes").map((value, modeIndex) =>
            parseReasoningMode(value, `${model.path("reasoning_modes")}[${modeIndex}]`));
        return {
            id: model.string("id"),
            provider: model.string("provider"),
            model: model.string("model"),
            name: model.string("name"),
            reasoning: model.boolean("reasoning"),
            reasoningModes,
            vision: model.boolean("vision"),
            contextWindow: model.positiveInteger("context_window"),
        } satisfies ModelInfo;
    });
    if (models.length === 0)
        return Er.contract("Model catalog must contain at least one model.");
    const defaultModelId = catalog.string("default_model");
    if (!models.some(model => model.id === defaultModelId))
        return Er.contract(`Default model ${defaultModelId} is not in the catalog.`);
    return { defaultModelId, models };
}

function parseReasoningMode(value: unknown, path: string): ReasoningMode {
    if (typeof value === "string" && isReasoningMode(value)) return value;
    return Er.contract(path);
}

export function parseProfiles(value: unknown): readonly ProfileSummary[] {
    const profiles = jsonArray(value, "profiles").map((row, index) => {
        const profile = JsonObject.from(row, `profiles[${index}]`);
        return {
            id: profile.string("profile_id"),
        } satisfies ProfileSummary;
    });
    return profiles.length === 0
        ? Er.contract("Profiles response must contain at least one profile.")
        : profiles;
}

export function parseInstructionSnapshot(value: unknown): InstructionSnapshot {
    const snapshot = JsonObject.from(value, "instruction snapshot");
    const documents = snapshot.array("documents").map((value, index) => {
        const document = JsonObject.from(value, `instruction snapshot.documents[${index}]`);
        return {
            id: document.choice("id", instructionDocumentIds),
            label: document.string("label"),
            scope: document.choice("scope", ["profile", "app"] as const),
            content: document.string("content"),
        } satisfies InstructionDocument;
    });
    if (documents.length !== instructionDocumentIds.length
        || instructionDocumentIds.some(id => documents.filter(item => item.id === id).length !== 1))
        return Er.contract("Instruction snapshot must contain each document exactly once.");
    return {
        profileId: snapshot.string("profile_id"),
        workspacePath: snapshot.string("workspace_path"),
        documents,
    };
}

export function parseRecentSessions(value: unknown): readonly RecentSessionSummary[] {
    return jsonArray(value, "recent sessions").map((row, index) => {
        const session = JsonObject.from(row, `recent sessions[${index}]`);
        return {
            sessionId: session.string("session_id"),
            startedAt: session.string("started_at"),
            language: parseChatLanguage(session.string("language"), session.path("language")),
            initialUserText: session.string("initial_user_text"),
            processing: session.boolean("processing"),
            hasScheduledTurn: session.opt.boolean("has_scheduled_turn") ?? false,
            hasToolUse: session.boolean("has_tool_use"),
            hasGeneratedImage: session.boolean("has_generated_image"),
            hasWebSearch: session.boolean("has_web_search"),
            hasCompaction: session.boolean("has_compaction"),
            hasScreenCapture: session.boolean("has_screen_capture"),
            automaticSessionUnseen: session.opt.boolean("automatic_session_unseen") ?? false,
            unseenScheduledTurnCount:
                session.opt.nonNegativeInteger("unseen_scheduled_turn_count") ?? 0,
        } satisfies RecentSessionSummary;
    });
}

export function parseStartupState(value: unknown): StartupState {
    const state = JsonObject.from(value, "profile startup state");
    const supportedLanguages = parseLanguages(state.array("languages"), state.path("languages"));
    const language = parseChatLanguage(state.string("language"), state.path("language"));
    if (!supportedLanguages.includes(language))
        return Er.contract(`Active language ${language} is not a supported option.`);
    const lastSessionId = state.string("last_session_id");
    const lastSessionLanguage = state.string("last_session_language");
    return {
        canResumeLastSession: state.boolean("can_resume_last_session"),
        lastSessionId,
        language,
        lastSessionLanguage: lastSessionLanguage === ""
            ? ""
            : parseChatLanguage(lastSessionLanguage, state.path("last_session_language")),
        supportedLanguages,
    };
}

export function parseSessionStartResult(value: unknown): SessionStartResult {
    const result = JsonObject.from(value, "profile startup result");
    if (!result.boolean("ok"))
        return Er.io("Profile startup did not complete.");
    return readSessionStartResult(result);
}

export function parseSessionOpened(value: unknown): SessionStartResult {
    return readSessionStartResult(JsonObject.from(value, "opened profile session"));
}

export function parseStoredTurns(
    value: unknown,
    userAudioUrl: (turnId: string) => string,
    userImageUrl: (turnId: string, filename: string) => string,
): readonly StoredTurn[] {
    return jsonArray(value, "current session turns").map((row, index) => {
        const turn = JsonObject.from(row, `current session turns[${index}]`);
        const turnId = turn.string("turn_id");
        const userImageValue = turn.opt.object("user_image");
        const userImageFilename = userImageValue?.string("filename");
        return {
            turnId,
            submissionId: turn.string("submission_id"),
            startedAt: turn.string("started_at"),
            completedAt: turn.string("completed_at"),
            modelName: turn.string("model_name"),
            activityDurationMs: turn.number("activity_duration_ms"),
            metrics: parseTextTurnMetrics(turn.object("metrics")),
            userText: turn.string("user_text"),
            scheduledTask: turn.boolean("scheduled_task"),
            reasoningMode: turn.choice(
                "reasoning_mode",
                reasoningModes,
            ),
            processing: turn.boolean("processing"),
            assistantStreaming: turn.boolean("assistant_streaming"),
            assistantStreamingItemId: turn.string("assistant_streaming_item_id"),
            items: turn.array("items").map((item, itemIndex) => parseStoredTurnItem(
                item,
                `current session turns[${index}].items[${itemIndex}]`,
                image => userImageUrl(turnId, image.filename),
            )),
            ...(turn.boolean("has_user_audio")
                ? { userAudioUrl: userAudioUrl(turnId) }
                : {}),
            ...(userImageFilename === undefined
                ? {}
                : { userImage: {
                    url: userImageUrl(turnId, userImageFilename),
                    filename: userImageFilename,
                } }),
        } satisfies StoredTurn;
    });
}

export function parseSpeechSegment(
    value: unknown,
    resolveUrl: (url: string) => string,
): SpeechSegment {
    const segment = JsonObject.from(value, "speech segment");
    return {
        audioUrl: resolveUrl(segment.string("audio_url")),
        mediaType: segment.string("media_type"),
    };
}

export function parseTokenMessage(value: unknown): TextEvent {
    const event = JsonObject.from(value, "token event");
    return {
        itemId: event.string("item_id"),
        text: event.string("text"),
    };
}

export function parseReasoningEvent(value: unknown): ReasoningEvent {
    const event = JsonObject.from(value, "reasoning event");
    return {
        phase: event.choice("phase", ["start", "delta", "end"] as const),
        itemId: event.string("item_id"),
        durationMs: event.number("duration_ms"),
        text: event.string("text"),
    };
}

export function parseReasoningDetail(value: unknown): ReasoningDetail {
    return { text: JsonObject.from(value, "reasoning detail").string("text") };
}

export function parseToolMessage(value: unknown): ToolIndicator {
    return parseToolIndicator(value, "tool event");
}

export function parseGeneratedImage(
    value: unknown,
    resolveUrl: (url: string) => string,
): GeneratedImage {
    const image = JsonObject.from(value, "generated image");
    const kind = image.choice("kind", ["generated_image", "screen_capture"] as const);
    const modelWidth = image.opt.positiveInteger("model_width");
    const modelHeight = image.opt.positiveInteger("model_height");
    if ((modelWidth === undefined) !== (modelHeight === undefined))
        return Er.contract("Generated image model dimensions must be paired.");
    return {
        kind,
        ...(kind === "generated_image"
            ? { generatedImageId: image.positiveInteger("generated_image_id") }
            : {}),
        itemId: image.string("item_id"),
        filename: image.string("filename"),
        mediaType: image.choice("media_type", ["image/png"] as const),
        url: resolveUrl(image.string("url")),
        path: image.string("path"),
        sha256: image.string("sha256"),
        byteCount: image.positiveInteger("byte_count"),
        width: image.positiveInteger("width"),
        height: image.positiveInteger("height"),
        seed: image.nonNegativeInteger("seed"),
        quality: image.choice("quality", ["low", "medium", "high"] as const),
        aspect: image.choice("aspect", ["square", "portrait", "landscape"] as const),
        prompt: image.string("prompt"),
        ...(modelWidth === undefined ? {} : { modelWidth, modelHeight: modelHeight! }),
    };
}

export function parseToolDetail(value: unknown): ToolDetail {
    const detail = JsonObject.from(value, "tool detail");
    const tool = detail.object("tool");
    const argumentsValue = detail.value("arguments");
    JsonObject.from(argumentsValue, "tool detail.arguments");
    return {
        tool: {
            callIndex: tool.number("call_index"),
            callId: tool.string("call_id"),
            name: tool.string("name"),
            source: tool.choice(
                "source",
                ["pi", "client", "codex", "scheduler", "wheatley"] as const,
            ),
            status: tool.choice("status", ["running", "succeeded", "failed"] as const),
            startedAt: tool.string("started_at"),
            completedAt: tool.string("completed_at"),
            durationMs: tool.number("duration_ms"),
            workingDirectory: tool.string("working_directory"),
        },
        arguments: argumentsValue,
        content: detail.array("content"),
        details: detail.value("details"),
        extensionData: detail.value("extension_data"),
    };
}

export function parseSystemMessage(value: unknown): string {
    return JsonObject.from(value, "startup system event").string("message");
}

export function parseTextTurnResult(value: unknown): TextTurnResult {
    const result = JsonObject.from(value, "text turn result");
    const turn = result.object("turn");
    return {
        turnId: turn.string("turn_id"),
        startedAt: turn.string("started_at"),
        completedAt: turn.string("completed_at"),
        modelName: turn.string("model_name"),
        assistantText: turn.string("assistant_text"),
        language: parseChatLanguage(turn.string("language"), turn.path("language")),
        metrics: parseTextTurnMetrics(turn.object("metrics")),
    };
}

function parseTextTurnMetrics(metrics: JsonObject): TextTurnMetrics {
    return {
        ...optionalNumber("durationMs", metrics.opt.nonNegativeInteger("duration_ms")),
        ...optionalNumber(
            "timeToFirstTokenMs",
            metrics.opt.nonNegativeInteger("time_to_first_token_ms"),
        ),
        ...optionalNumber("generationMs", metrics.opt.nonNegativeInteger("generation_ms")),
        ...optionalNumber("inputTokens", metrics.opt.nonNegativeInteger("input_tokens")),
        ...optionalNumber("outputTokens", metrics.opt.nonNegativeInteger("output_tokens")),
        ...optionalNumber(
            "cacheReadTokens",
            metrics.opt.nonNegativeInteger("cache_read_tokens"),
        ),
        ...optionalNumber(
            "cacheWriteTokens",
            metrics.opt.nonNegativeInteger("cache_write_tokens"),
        ),
        ...optionalNumber(
            "reasoningTokens",
            metrics.opt.nonNegativeInteger("reasoning_tokens"),
        ),
        ...optionalNumber("totalTokens", metrics.opt.nonNegativeInteger("total_tokens")),
        ...optionalNumber("contextTokens", metrics.opt.nonNegativeInteger("context_tokens")),
        ...optionalNumber(
            "contextWindowTokens",
            metrics.opt.nonNegativeInteger("context_window_tokens"),
        ),
    };
}

function optionalNumber<K extends string>(
    name: K,
    value: number | undefined,
): Partial<Record<K, number>> {
    return value === undefined ? {} : { [name]: value } as Partial<Record<K, number>>;
}

export function parseErrorMessage(value: unknown): string {
    return JsonObject.from(value, "error response").object("error").string("message");
}

function parseLanguages(values: readonly unknown[], label: string): readonly ChatLanguage[] {
    const languages = values.map((value, index) =>
        parseChatLanguage(value, `${label}[${index}]`));
    const uniqueCodes = new Set(languages);
    return uniqueCodes.size === languages.length && languages.length > 0
        ? languages
        : Er.contract("Profile languages must be non-empty and unique.");
}

function readSessionStartResult(result: JsonObject): SessionStartResult {
    return {
        sessionId: result.string("session_id"),
        language: parseChatLanguage(result.string("language"), result.path("language")),
        resumedLastSession: result.boolean("resumed_last_session"),
        reasoningMode: result.choice(
            "reasoning_mode",
            reasoningModes,
        ),
    };
}

function parseToolIndicator(value: unknown, label: string): ToolIndicator {
    const indicator = JsonObject.from(value, label);
    const presentation = indicator.opt.object("presentation");
    const generatedImagePreview = presentation?.opt.string("kind") === "generated_image_pending"
        ? {
            callIndex: indicator.number("call_index"),
            prompt: presentation.string("prompt"),
            width: presentation.positiveInteger("width"),
            height: presentation.positiveInteger("height"),
            quality: presentation.choice("quality", ["low", "medium", "high"] as const),
            aspect: presentation.choice(
                "aspect",
                ["square", "portrait", "landscape"] as const,
            ),
        } as const
        : undefined;
    const scheduledTaskId = presentation?.opt.string("scheduled_task_id");
    return {
        message: indicator.string("message"),
        spokenMessage: indicator.string("spoken_message"),
        itemId: indicator.string("item_id"),
        callIndex: indicator.number("call_index"),
        name: indicator.string("name"),
        stage: indicator.choice("stage", ["start", "end"] as const),
        status: indicator.choice("status", ["running", "succeeded", "failed"] as const),
        durationMs: indicator.opt.nonNegativeInteger("duration_ms") ?? 0,
        ...(generatedImagePreview === undefined ? {} : { generatedImagePreview }),
        ...(scheduledTaskId === undefined ? {} : { scheduledTaskId }),
    };
}

function parseStoredTurnItem(
    value: unknown,
    label: string,
    generatedImageUrl: (image: GeneratedImage) => string,
): StoredTurnItem {
    const item = JsonObject.from(value, label);
    const kind = item.string("kind");
    const itemId = item.string("item_id");
    if (kind === "reasoning") {
        return {
            kind,
            itemId,
            text: item.string("text_tail"),
            truncated: item.boolean("truncated"),
            durationMs: item.number("duration_ms"),
        };
    }
    if (kind === "assistant") {
        return {
            kind,
            itemId,
            text: item.string("text"),
            completedAt: item.string("completed_at"),
        };
    }
    if (kind === "tool") {
        return {
            kind,
            itemId,
            indicator: parseToolIndicator(value, label),
        };
    }
    if (kind === "generated_image" || kind === "screen_capture") {
        const image = parseGeneratedImage(value, url => url);
        return {
            ...image,
            url: generatedImageUrl(image),
        };
    }
    return Er.contract(`Unsupported stored turn item kind ${kind}.`);
}
