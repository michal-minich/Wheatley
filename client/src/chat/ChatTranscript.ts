import { Er } from "../core/Er";
import type { ChatLanguage } from "./Language";
import type {
    CodexLiveEvent,
    CompactionEvent,
    StoredTurn,
    StoredTurnItem,
    ReasoningEvent,
    TextEvent,
    TextTurnResult,
    TextTurnMetrics,
    ToolIndicator,
    UserImage,
    GeneratedImage,
    PendingGeneratedImage,
    PresentationSnapshot,
    SessionQueueItemState,
    SessionQueueMutation,
    SessionQueueSnapshot,
    ReasoningMode,
} from "../transport/ChatTransport";
import { codexText, uiText } from "../ui/UiText";
import type { ChatFailure, ChatMessage, ChatMessageRole } from "./ChatMessage";

export interface ActiveChatActivity {
    readonly turnId: string;
    readonly startedMono: number;
}

interface MutableChatMessage {
    readonly id: string;
    readonly role: ChatMessageRole;
    text: string;
    pending: boolean;
    turnId?: string;
    queueItemId?: string;
    queueState?: SessionQueueItemState;
    queueSequence?: number;
    itemId?: string;
    timestamp?: string;
    modelName?: string;
    reasoningMode?: ReasoningMode;
    activityDurationMs?: number;
    turnMetrics?: TextTurnMetrics;
    scheduledTask?: boolean;
    userAudioUrl?: string;
    userImage?: UserImage;
    generatedImage?: GeneratedImage;
    pendingGeneratedImage?: PendingGeneratedImage;
    tool?: ToolIndicator;
    reasoningTruncated?: boolean;
    reasoningDurationMs?: number;
    presentationSequence?: number;
    compaction?: CompactionEvent;
    failure?: ChatFailure;
}

export class ChatTranscript {
    #messages: MutableChatMessage[] = [];
    #assistant: MutableChatMessage | undefined;
    #reasoning: MutableChatMessage | undefined;
    #draftUser: MutableChatMessage | undefined;
    #streamedAssistantText = "";
    #activeTurnId: string | undefined;
    #activeModelName: string | undefined;
    #activeStartedMono: number | undefined;
    readonly #reasoningModes = new Map<string, ReasoningMode>();
    #activitySinceAssistant = false;
    #nextMessageId = 0;
    #codexActivity = new Map<string, MutableChatMessage>();
    #queueRevision = 0;

    get messages(): readonly ChatMessage[] {
        return this.#messages.map(message => ({ ...message }));
    }

    get activeActivity(): ActiveChatActivity | undefined {
        if (
            !this.#activitySinceAssistant
            || this.#activeTurnId === undefined
            || this.#activeStartedMono === undefined
        ) {
            return undefined;
        }
        return {
            turnId: this.#activeTurnId,
            startedMono: this.#activeStartedMono,
        };
    }

    get activeAssistantItemId(): string | undefined {
        if (this.#assistant === undefined || this.#assistant.text.length === 0)
            return undefined;
        return this.#assistant.itemId
            ?? Er.internal("A streaming assistant message has no item ID.");
    }

    clear(): void {
        this.#messages = [];
        this.#assistant = undefined;
        this.#reasoning = undefined;
        this.#draftUser = undefined;
        this.#streamedAssistantText = "";
        this.#activeTurnId = undefined;
        this.#activeModelName = undefined;
        this.#activeStartedMono = undefined;
        this.#reasoningModes.clear();
        this.#activitySinceAssistant = false;
        this.#nextMessageId = 0;
        this.#codexActivity.clear();
        this.#queueRevision = 0;
    }

    append(turns: readonly StoredTurn[]): void {
        for (const turn of turns) {
            this.#reasoningModes.set(turn.turnId, turn.reasoningMode);
            const modelContext = turn.items.find(isModelContextItem);
            const finalAssistant = [...turn.items].reverse()
                .find(item => item.kind === "assistant");
            if (modelContext !== undefined)
                this.#appendStoredItem(turn, modelContext, true);
            // A scheduled request is provenance, rather than a message the
            // user wrote. Its durable scheduler tool entry is rendered as the
            // compact, inspectable task link instead of a user bubble.
            if (!turn.scheduledTask) {
                const text = turn.userText.trim();
                if (text.length > 0 || turn.userImage !== undefined) this.#add(
                    "user",
                    text,
                    turn.processing,
                    turn.turnId,
                    undefined,
                    turn.startedAt,
                    turn.modelName,
                    turn.userAudioUrl,
                    undefined,
                    undefined,
                    undefined,
                    undefined,
                    turn.userImage,
                );
            }
            for (const item of turn.items) {
                if (item === modelContext)
                    continue;
                this.#appendStoredItem(turn, item, item === finalAssistant);
            }
        }
    }

    #appendStoredItem(
        turn: StoredTurn,
        item: StoredTurnItem,
        includeTurnMetrics = false,
    ): void {
        if (item.kind === "reasoning") {
            this.#add(
                "reasoning",
                item.text,
                false,
                turn.turnId,
                item.itemId,
                undefined,
                turn.modelName,
                undefined,
                undefined,
                item.truncated,
                item.durationMs,
                turn.activityDurationMs,
            );
        } else if (item.kind === "assistant") {
            const message = this.#addText(
                "assistant",
                item.text,
                turn.turnId,
                item.completedAt,
                undefined,
                undefined,
                item.itemId,
                turn.modelName,
            );
            if (message !== undefined && includeTurnMetrics) message.turnMetrics = turn.metrics;
        } else if (item.kind === "tool") {
            const message = this.#addTool(
                item.indicator,
                turn.turnId,
                item.itemId,
                turn.modelName,
                turn.activityDurationMs,
            );
            if (includeTurnMetrics) message.turnMetrics = turn.metrics;
        } else {
            this.#addGeneratedImage(item, turn.turnId, turn.modelName);
        }
    }

    restorePresentation(snapshot: PresentationSnapshot, language: ChatLanguage): void {
        const first = new Map<string, number>();
        const firstInTurn = new Map<string, number>();
        for (const marker of snapshot.markers) {
            if (marker.source !== "pi")
                continue;
            const key = marker.itemId.length > 0
                ? `${marker.turnId}\u0000${marker.itemId}`
                : `${marker.turnId}\u0000${marker.kind}`;
            if (!first.has(key))
                first.set(key, marker.sequence);
            const existing = firstInTurn.get(marker.turnId);
            if (existing === undefined || marker.sequence < existing)
                firstInTurn.set(marker.turnId, marker.sequence);
        }
        for (const message of this.#messages) {
            const key = message.itemId !== undefined
                ? `${message.turnId ?? ""}\u0000${message.itemId}`
                : `${message.turnId ?? ""}\u0000${message.role === "user" ? "user" : "completed"}`;
            const sequence = first.get(key);
            if (sequence !== undefined) {
                message.presentationSequence = sequence;
                if (message.role === "user") message.pending = false;
            }
            // Old scheduled turns deliberately had no user presentation
            // record. Keep them immediately before their first durable item
            // during migration instead of sorting every prompt below every
            // response on reload.
            else if (message.role === "user" && message.turnId !== undefined) {
                const firstForTurn = firstInTurn.get(message.turnId);
                if (firstForTurn !== undefined)
                    message.presentationSequence = firstForTurn - 0.5;
            }
        }
        for (const event of snapshot.codexEvents)
            this.applyCodex(event, language);
        for (const event of snapshot.compactions)
            this.upsertCompaction(event);
        const copy = uiText(language);
        for (const failure of snapshot.failures)
            this.addFailure(
                failure.turnId,
                copy.turnFailed,
                failure.code,
                failure.message,
                copy.technicalDetails,
                failure.timestamp,
                failure.presentationSequence,
            );
        this.#messages.sort((left, right) => {
            // Entries that predate presentation journaling retain their
            // durable turn order. Only compare recorded presentation order
            // when both sides actually have it.
            if (left.presentationSequence === undefined || right.presentationSequence === undefined)
                return 0;
            return left.presentationSequence - right.presentationSequence;
        });
        for (const message of [...this.#messages]) {
            if (message.tool?.name === "model_context")
                this.#moveToTurnStart(message);
        }
        this.#sortQueuedUsers();
    }

    upsertCompaction(event: CompactionEvent): void {
        const id = `compaction:${event.id}`;
        const existing = this.#messages.find(message => message.id === id);
        if (event.status === "skipped") {
            if (existing !== undefined)
                this.#messages.splice(this.#messages.indexOf(existing), 1);
            return;
        }
        if (existing !== undefined) {
            existing.text = event.summary;
            existing.pending = event.status === "compacting";
            existing.timestamp = event.completedAt || event.startedAt;
            existing.compaction = event;
            if (event.presentationSequence === undefined)
                delete existing.presentationSequence;
            else
                existing.presentationSequence = event.presentationSequence;
            return;
        }
        this.#messages.push({
            id,
            role: "compaction",
            text: event.summary,
            pending: event.status === "compacting",
            timestamp: event.completedAt || event.startedAt,
            compaction: event,
            ...(event.presentationSequence === undefined
                ? {}
                : { presentationSequence: event.presentationSequence }),
        });
    }

    replace(turns: readonly StoredTurn[]): void {
        this.clear();
        this.append(turns);
    }

    /** Reload durable turns without dropping an unsubmitted live STT draft. */
    replacePreservingDraft(turns: readonly StoredTurn[]): void {
        const draft = this.#draftUser === undefined
            ? undefined
            : {
                text: this.#draftUser.text,
                turnId: this.#draftUser.turnId,
                modelName: this.#draftUser.modelName,
            };
        this.replace(turns);
        if (draft?.turnId !== undefined && draft.modelName !== undefined)
            this.updateDraft(draft.text, draft.turnId, draft.modelName);
    }

    beginTurn(
        prompt: string,
        turnId: string,
        modelName: string,
        userImage?: UserImage,
    ): void {
        this.#add("user", prompt, false, turnId, undefined, undefined, modelName,
            undefined, undefined, undefined, undefined, undefined, userImage);
        this.#beginResponse(turnId, modelName);
    }

    acceptTurn(
        prompt: string,
        turnId: string,
        modelName: string,
        userImage?: UserImage,
        queueItemId?: string,
        queueState?: SessionQueueItemState,
        queueSequence?: number,
        queueRevision?: number,
    ): void {
        const queuedMessage = queueItemId === undefined
            ? undefined
            : this.#messages.find(message =>
                message.role === "user" && message.queueItemId === queueItemId);
        if (this.hasTurn(turnId) && queuedMessage === undefined) return;
        if (queueRevision !== undefined)
            this.#queueRevision = Math.max(this.#queueRevision, queueRevision);
        const message = queuedMessage ?? this.#add(
            "user", prompt, true, turnId, undefined, undefined, modelName,
            undefined, undefined, undefined, undefined, undefined, userImage,
        );
        message.text = prompt;
        message.pending = true;
        message.turnId = turnId;
        message.modelName = modelName;
        if (userImage !== undefined) message.userImage = userImage;
        this.#setQueueFields(message, queueItemId, queueState, queueSequence);
        this.#sortQueuedUsers();
    }

    setTurnReasoningMode(turnId: string, mode: ReasoningMode): void {
        this.#reasoningModes.set(turnId, mode);
        for (const message of this.#messages) {
            if (message.turnId === turnId)
                message.reasoningMode = mode;
        }
    }

    updateQueueState(
        turnId: string,
        state: SessionQueueItemState,
        queueItemId?: string,
        queueSequence?: number,
        queueRevision?: number,
    ): void {
        if (queueRevision !== undefined) {
            if (queueRevision < this.#queueRevision) return;
            this.#queueRevision = queueRevision;
        }
        for (const message of this.#messages) {
            if (message.role !== "user"
                || (message.turnId !== turnId && message.queueItemId !== queueItemId))
                continue;
            if (queueItemId !== undefined) message.queueItemId = queueItemId;
            if (message.turnId === queueItemId && turnId !== queueItemId)
                message.turnId = turnId;
            message.queueState = state;
            if (queueSequence !== undefined) message.queueSequence = queueSequence;
            if (state === "cancelled" || state === "completed" || state === "failed"
                || state === "interrupted")
                message.pending = false;
        }
        if (state === "cancelled" || state === "completed" || state === "failed"
            || state === "interrupted")
            this.#deliverTurn(turnId);
        else
            this.#sortQueuedUsers();
    }

    applyQueueSnapshot(
        queue: SessionQueueSnapshot,
        turns: readonly StoredTurn[] = [],
        language: ChatLanguage = "en",
    ): void {
        if (queue.revision < this.#queueRevision) return;
        this.#queueRevision = queue.revision;
        for (const item of queue.items) {
            const turn = turns.find(candidate => candidate.submissionId === item.id);
            let message = this.#messages.find(candidate => candidate.queueItemId === item.id);
            if (message === undefined && turn !== undefined)
                message = this.#messages.find(candidate => candidate.turnId === turn.turnId);
            if (message === undefined && item.kind === "user" && item.state !== "completed") {
                this.#reasoningModes.set(turn?.turnId ?? item.id, item.reasoningMode);
                message = this.#add(
                    "user",
                    item.text.trim().length > 0 ? item.text : queueVoicePlaceholder(item.language),
                    item.state === "preparing"
                        || item.state === "ready"
                        || item.state === "running",
                    turn?.turnId ?? item.id,
                    undefined,
                    item.submittedAt,
                    item.model,
                );
            }
            const turnId = turn?.turnId ?? message?.turnId;
            if (turnId !== undefined) {
                this.updateQueueState(
                    turnId,
                    item.state,
                    item.id,
                    item.sequence,
                    queue.revision,
                );
                if (item.state === "failed" || item.state === "interrupted") {
                    this.failTurn(turnId, item.state);
                    const copy = uiText(language);
                    this.addFailure(
                        turnId,
                        copy.turnFailed,
                        item.state,
                        item.failure || `Conversation turn ${item.state}.`,
                        copy.technicalDetails,
                    );
                }
            }
        }
        this.#sortQueuedUsers();
    }

    applyQueueMutation(
        mutation: SessionQueueMutation,
        turns: readonly StoredTurn[] = [],
        language: ChatLanguage = "en",
    ): void {
        this.applyQueueSnapshot({
            schemaVersion: 1,
            sessionId: mutation.item.sessionId,
            revision: mutation.revision,
            nextSequence: mutation.item.sequence + 1,
            items: [mutation.item],
        }, turns, language);
    }

    hasTurn(turnId: string): boolean {
        return this.#messages.some(message => message.turnId === turnId);
    }

    queueState(turnId: string): SessionQueueItemState | undefined {
        return this.#messages.find(message =>
            message.turnId === turnId || message.queueItemId === turnId)?.queueState;
    }

    beginAcceptedResponse(turnId: string, modelName: string): void {
        this.#beginResponse(turnId, modelName);
    }

    updateDraft(text: string, turnId: string, modelName: string): void {
        const clean = text.trim();
        if (clean.length === 0)
            return;
        if (this.#draftUser === undefined) {
            this.#draftUser = this.#add(
                "user",
                clean,
                true,
                turnId,
                undefined,
                undefined,
                modelName,
            );
            return;
        }
        this.#draftUser.text = clean;
        this.#draftUser.turnId = turnId;
        this.#draftUser.modelName = modelName;
    }

    cancelDraft(): void {
        if (this.#draftUser === undefined)
            return;
        this.#messages.splice(this.#messages.indexOf(this.#draftUser), 1);
        this.#draftUser = undefined;
    }

    acceptDraft(
        prompt: string,
        turnId: string,
        modelName: string,
        userImage?: UserImage,
    ): void {
        const clean = prompt.trim();
        if (this.#draftUser === undefined)
            this.#draftUser = this.#add("user", clean, true, turnId);
        this.#draftUser.text = clean;
        this.#draftUser.pending = true;
        this.#draftUser.turnId = turnId;
        this.#draftUser.modelName = modelName;
        if (userImage === undefined)
            delete this.#draftUser.userImage;
        else
            this.#draftUser.userImage = userImage;
        this.#draftUser = undefined;
    }

    replaceTurnId(currentTurnId: string, storedTurnId: string): void {
        if (currentTurnId === storedTurnId)
            return;
        for (const message of this.#messages) {
            if (message.turnId === currentTurnId)
                message.turnId = storedTurnId;
        }
        if (this.#activeTurnId === currentTurnId)
            this.#activeTurnId = storedTurnId;
        const reasoningMode = this.#reasoningModes.get(currentTurnId);
        if (reasoningMode !== undefined) {
            this.#reasoningModes.delete(currentTurnId);
            this.#reasoningModes.set(storedTurnId, reasoningMode);
        }
    }

    #beginResponse(turnId: string, modelName: string): void {
        this.#deliverTurn(turnId);
        this.#finishAssistantSegment();
        this.#finishReasoningSegment();
        if (this.#activitySinceAssistant)
            this.#updateActivityDuration();
        this.#activeTurnId = turnId;
        this.#activeModelName = modelName;
        this.#activeStartedMono = performance.now();
        this.#activitySinceAssistant = false;
        this.#streamedAssistantText = "";
        this.#assistant = this.#add(
            "assistant",
            "",
            true,
            turnId,
            undefined,
            undefined,
            modelName,
        );
        this.#reasoning = undefined;
    }

    #deliverTurn(turnId: string): void {
        const turnMessages = this.#messages.filter(message => message.turnId === turnId);
        if (!turnMessages.length)
            return;
        for (const message of turnMessages) {
            if (message.role === "user") message.pending = false;
        }
        const otherMessages = this.#messages.filter(message => message.turnId !== turnId);
        const queued = otherMessages.findIndex(isQueuedUser);
        otherMessages.splice(queued < 0 ? otherMessages.length : queued, 0, ...turnMessages);
        this.#messages.splice(0, this.#messages.length, ...otherMessages);
    }

    #sortQueuedUsers(): void {
        const canonical = this.#messages.filter(message => !isQueuedUser(message));
        const queued = this.#messages.filter(isQueuedUser);
        queued.sort((left, right) =>
            (left.queueSequence ?? Number.MAX_SAFE_INTEGER)
            - (right.queueSequence ?? Number.MAX_SAFE_INTEGER));
        this.#messages.splice(0, this.#messages.length, ...canonical, ...queued);
    }

    #modelNameForTurn(turnId: string | undefined): string | undefined {
        if (turnId === undefined)
            return undefined;
        return this.#messages.findLast(message =>
            message.turnId === turnId && message.modelName !== undefined)?.modelName;
    }

    appendAssistant(event: TextEvent, turnId = this.#activeTurnId): void {
        if (turnId !== undefined && turnId !== this.#activeTurnId) {
            let assistant = this.#messages.findLast(message =>
                message.role === "assistant"
                && message.turnId === turnId
                && message.failure === undefined
                && message.generatedImage === undefined
                && message.pendingGeneratedImage === undefined
                && (message.itemId === event.itemId || message.itemId === undefined));
            assistant ??= this.#add(
                "assistant",
                "",
                true,
                turnId,
                event.itemId,
                undefined,
                this.#modelNameForTurn(turnId),
            );
            assistant.itemId = event.itemId;
            assistant.pending = true;
            assistant.text += event.text;
            return;
        }
        this.#markResponseStart();
        this.#finishReasoningSegment();
        this.#activeAssistant(event.itemId).text += event.text;
        this.#streamedAssistantText += event.text;
    }

    appendReasoning(event: ReasoningEvent, turnId = this.#activeTurnId): void {
        if (turnId !== undefined && turnId !== this.#activeTurnId) {
            let reasoning = this.#messages.find(message =>
                message.role === "reasoning"
                && message.turnId === turnId
                && message.itemId === event.itemId);
            if (event.phase !== "end" && reasoning === undefined)
                reasoning = this.#add(
                    "reasoning",
                    "",
                    true,
                    turnId,
                    event.itemId,
                    undefined,
                    this.#modelNameForTurn(turnId),
                );
            if (reasoning !== undefined) {
                if (event.text.length > 0)
                    reasoning.text += event.text;
                reasoning.reasoningDurationMs = event.durationMs;
                if (event.phase === "end")
                    reasoning.pending = false;
            }
            return;
        }
        if (event.phase === "start") {
            this.#beginReasoningSegment(event.itemId, event.durationMs);
        } else if (event.phase === "end") {
            this.#finishReasoningSegment(event.itemId, event.durationMs);
        } else if (event.text.length > 0) {
            const reasoning = this.#beginReasoningSegment(event.itemId, event.durationMs);
            reasoning.text += event.text;
        }
        this.#markActivity();
    }

    setReasoning(turnId: string, itemId: string, text: string): void {
        const reasoning = this.#messages.find(message =>
            message.role === "reasoning"
            && message.turnId === turnId
            && message.itemId === itemId);
        if (reasoning === undefined)
            return Er.internal("Cannot load reasoning for a turn without a reasoning message.");
        reasoning.text = text;
        reasoning.reasoningTruncated = false;
    }

    reasoningText(turnId: string, itemId: string): string | undefined {
        return this.#messages.find(message =>
            message.role === "reasoning"
            && message.turnId === turnId
            && message.itemId === itemId)?.text;
    }

    reasoningIsTruncated(turnId: string, itemId: string): boolean {
        return this.#messages.find(message =>
            message.role === "reasoning"
            && message.turnId === turnId
            && message.itemId === itemId)?.reasoningTruncated === true;
    }

    addTool(indicator: ToolIndicator, turnId = this.#activeTurnId): void {
        const clean = indicator.message.trim();
        if (indicator.stage === "end") {
            const tool = this.#messages.findLast(message =>
                message.role === "tool"
                && message.turnId === turnId
                && message.tool?.itemId === indicator.itemId
                && message.tool.callIndex === indicator.callIndex)
                ?? Er.internal("Cannot finish a tool that is not in the transcript.");
            if (clean.length)
                tool.text = clean;
            tool.tool = { ...tool.tool, ...indicator };
            if (indicator.status === "failed")
                this.#removePendingGeneratedImage(indicator.callIndex, turnId);
            if (turnId === this.#activeTurnId)
                this.#markActivity();
            return;
        }
        if (clean.length === 0)
            return;
        const existing = this.#messages.findLast(message =>
            message.role === "tool"
            && message.turnId === turnId
            && message.tool?.itemId === indicator.itemId
            && message.tool.callIndex === indicator.callIndex);
        if (existing !== undefined) {
            existing.text = clean;
            existing.tool = { ...existing.tool, ...indicator };
            return;
        }
        if (turnId === this.#activeTurnId) {
            this.#finishAssistantSegment();
            this.#finishReasoningSegment();
        }
        const message = this.#addTool(
            { ...indicator, message: clean },
            turnId,
            indicator.itemId,
            turnId === this.#activeTurnId
                ? this.#activeModelName
                : this.#modelNameForTurn(turnId),
        );
        if (indicator.name === "model_context")
            this.#moveToTurnStart(message);
        if (indicator.generatedImagePreview !== undefined)
            this.#addPendingGeneratedImage(indicator.generatedImagePreview, turnId);
        if (turnId === this.#activeTurnId)
            this.#markActivity();
    }

    setToolWebImages(
        turnId: string,
        callIndex: number,
        images: NonNullable<ToolIndicator["webImages"]>,
    ): void {
        const message = this.#messages.find(candidate =>
            candidate.role === "tool"
            && candidate.turnId === turnId
            && candidate.tool?.callIndex === callIndex);
        if (message?.tool === undefined)
            return;
        message.tool = { ...message.tool, webImages: images };
    }

    toolsForTurn(turnId: string, name: string): readonly ToolIndicator[] {
        return this.#messages.flatMap(message =>
            message.role === "tool"
            && message.turnId === turnId
            && message.tool?.name === name
                ? [message.tool]
                : []);
    }

    addGeneratedImage(
        image: GeneratedImage,
        turnId = this.#activeTurnId,
    ): string | undefined {
        if (turnId === this.#activeTurnId) {
            this.#finishAssistantSegment();
            this.#finishReasoningSegment();
        }
        const pending = this.#messages.findLast(message =>
            message.turnId === turnId
            && message.pendingGeneratedImage !== undefined);
        if (pending !== undefined) {
            const pendingItemId = pending.itemId
                ?? Er.internal("A pending generated image has no item ID.");
            pending.pending = false;
            pending.itemId = image.itemId;
            pending.generatedImage = image;
            delete pending.pendingGeneratedImage;
            return pendingItemId;
        }
        this.#addGeneratedImage(
            image,
            turnId,
            turnId === this.#activeTurnId
                ? this.#activeModelName
                : this.#modelNameForTurn(turnId),
        );
        return undefined;
    }

    #addPendingGeneratedImage(
        image: PendingGeneratedImage,
        turnId = this.#activeTurnId,
    ): void {
        this.#add(
            "assistant",
            "",
            true,
            turnId,
            `generated-image-pending:${image.callIndex}`,
            undefined,
            turnId === this.#activeTurnId
                ? this.#activeModelName
                : this.#modelNameForTurn(turnId),
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            image,
        );
    }

    #removePendingGeneratedImage(callIndex: number, turnId = this.#activeTurnId): void {
        this.#messages = this.#messages.filter(message =>
            message.pendingGeneratedImage?.callIndex !== callIndex
            || message.turnId !== turnId);
    }

    #addGeneratedImage(
        image: GeneratedImage,
        turnId?: string,
        modelName?: string,
    ): void {
        this.#add(
            "assistant",
            "",
            false,
            turnId,
            image.itemId,
            undefined,
            modelName,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            image,
        );
    }

    applyCodex(event: CodexLiveEvent, language: ChatLanguage): void {
        const turnId = `codex:${event.turnId}`;
        const stableItemId = event.summaryIndex >= 0
            ? `${event.itemId}:${event.summaryIndex}`
            : event.itemId;
        const activityKey = `${event.threadId}:${event.turnId}:${stableItemId}`;
        const copy = codexText(language);
        switch (event.kind) {
            case "reasoning_summary": {
                let message = this.#codexActivity.get(activityKey);
                if (message === undefined) {
                    message = this.#add(
                        "tool",
                        "",
                        true,
                        turnId,
                        stableItemId,
                        undefined,
                        copy.label,
                        undefined,
                        { ...codexToolIndicator("", stableItemId) },
                    );
                    message.presentationSequence = event.sequence;
                    this.#codexActivity.set(activityKey, message);
                }
                if (event.operation === "delta")
                    message.text += event.text;
                if (event.operation === "finish") {
                    message.pending = false;
                    this.#codexActivity.delete(activityKey);
                }
                message.tool = { ...message.tool!, message: message.text };
                this.#markActivity();
                return;
            }
            case "tool": {
                const text = event.name === "file_change"
                    ? copy.fileChange
                    : copy.command(event.text);
                let message = this.#messages.find(candidate =>
                    candidate.turnId === turnId && candidate.itemId === stableItemId);
                if (message === undefined) {
                    message = this.#add(
                        "tool", text, event.operation !== "finish", turnId,
                        stableItemId, undefined, copy.label, undefined,
                        { ...codexToolIndicator(text, stableItemId) },
                    );
                    message.presentationSequence = event.sequence;
                }
                if (event.operation === "finish") {
                    message.pending = false;
                    message.tool = {
                        ...message.tool!,
                        status: event.status === "failed" ? "failed" : "succeeded",
                    };
                }
                this.#markActivity();
                return;
            }
            case "final": {
                const message = this.#add(
                    "assistant", event.text.trim() || copy.completed, false,
                    turnId, stableItemId, event.timestamp, copy.label,
                );
                message.presentationSequence = event.sequence;
                return;
            }
            case "error": {
                const message = this.#add(
                    "assistant", event.text.trim() || copy.failedGeneric, false,
                    turnId, stableItemId, event.timestamp, copy.label,
                );
                message.presentationSequence = event.sequence;
                return;
            }
            case "steer":
                return;
        }
    }

    #addTool(
        indicator: ToolIndicator,
        turnId?: string,
        itemId?: string,
        modelName?: string,
        activityDurationMs?: number,
    ): MutableChatMessage {
        return this.#add(
            "tool",
            indicator.message,
            false,
            turnId,
            itemId,
            undefined,
            modelName,
            undefined,
            indicator,
            undefined,
            undefined,
            activityDurationMs,
        );
    }

    #moveToTurnStart(message: MutableChatMessage): void {
        const messageIndex = this.#messages.indexOf(message);
        const turnStart = this.#messages.findIndex(candidate =>
            candidate !== message && candidate.turnId === message.turnId);
        if (turnStart < 0 || messageIndex < turnStart)
            return;
        this.#messages.splice(messageIndex, 1);
        this.#messages.splice(turnStart, 0, message);
    }

    finishTurn(result: TextTurnResult): void {
        const active = this.#activeTurnId === result.turnId;
        let assistant = active ? this.#assistant : [...this.#messages].reverse().find(message =>
            message.turnId === result.turnId && message.role === "assistant"
                && message.tool === undefined && message.failure === undefined);
        if (assistant === undefined && result.assistantText.length > 0)
            assistant = this.#add("assistant", "", true, result.turnId);
        if (assistant !== undefined) {
            const streamed = active ? this.#streamedAssistantText : assistant.text;
            if (result.assistantText.startsWith(streamed))
                assistant.text += result.assistantText.slice(streamed.length);
            else if (streamed.length === 0)
                assistant.text = result.assistantText;
            assistant.pending = false;
            if (assistant.text.length === 0)
                this.#messages.splice(this.#messages.indexOf(assistant), 1);
        }
        if (active) {
            this.#finishReasoningSegment();
            if (this.#activitySinceAssistant)
                this.#updateActivityDuration();
        }
        for (const message of this.#messages) {
            if (message.turnId === result.turnId) {
                message.turnId = result.turnId;
                message.modelName = result.modelName;
                if (message.role === "user") {
                    message.timestamp = result.startedAt;
                    if (result.userAudioUrl !== undefined)
                        message.userAudioUrl = result.userAudioUrl;
                    if (result.userImage !== undefined)
                        message.userImage = result.userImage;
                } else if (message === assistant) {
                    message.timestamp = result.completedAt;
                    message.turnMetrics = result.metrics;
                } else if (message.tool?.name === "model_context") {
                    message.turnMetrics = result.metrics;
                }
            }
        }
        this.updateQueueState(
            result.turnId,
            "completed",
        );
        if (!active) return;
        this.#assistant = undefined;
        this.#reasoning = undefined;
        this.#streamedAssistantText = "";
        this.#activeTurnId = undefined;
        this.#activeModelName = undefined;
        this.#activeStartedMono = undefined;
        this.#activitySinceAssistant = false;
    }

    failTurn(
        turnId = this.#activeTurnId,
        queueState: "failed" | "interrupted" = "failed",
    ): void {
        if (turnId !== undefined)
            this.updateQueueState(turnId, queueState);
        if (turnId !== this.#activeTurnId) {
            for (const message of this.#messages) {
                if (message.turnId === turnId)
                    message.pending = false;
            }
            this.#messages = this.#messages.filter(message =>
                message.turnId !== turnId
                || message.pendingGeneratedImage === undefined);
            return;
        }
        this.#finishAssistantSegment();
        this.#finishReasoningSegment();
        if (this.#activitySinceAssistant)
            this.#updateActivityDuration();
        this.#messages = this.#messages.filter(message =>
            message.turnId !== this.#activeTurnId
            || message.pendingGeneratedImage === undefined);
        this.#assistant = undefined;
        this.#reasoning = undefined;
        this.#streamedAssistantText = "";
        this.#activeTurnId = undefined;
        this.#activeModelName = undefined;
        this.#activeStartedMono = undefined;
        this.#activitySinceAssistant = false;
    }

    addFailure(
        turnId: string,
        text: string,
        code: string,
        detail: string,
        detailsLabel: string,
        timestamp?: string,
        presentationSequence?: number,
    ): void {
        const existing = this.#messages.find(message =>
            message.turnId === turnId && message.failure !== undefined);
        if (existing !== undefined) {
            existing.text = text;
            existing.failure = { code, detail, detailsLabel };
            if (timestamp === undefined) delete existing.timestamp;
            else existing.timestamp = timestamp;
            if (presentationSequence === undefined) delete existing.presentationSequence;
            else existing.presentationSequence = presentationSequence;
            return;
        }
        this.#messages.push({
            id: `message:${this.#nextMessageId++}`,
            role: "assistant",
            text,
            pending: false,
            turnId,
            ...(timestamp === undefined ? {} : { timestamp }),
            ...(presentationSequence === undefined ? {} : { presentationSequence }),
            failure: { code, detail, detailsLabel },
        });
    }

    #activeAssistant(itemId?: string): MutableChatMessage {
        if (this.#assistant !== undefined
            && itemId !== undefined
            && this.#assistant.itemId !== undefined
            && this.#assistant.itemId !== itemId)
            this.#finishAssistantSegment();
        if (this.#assistant === undefined)
            this.#assistant = this.#add(
                "assistant",
                "",
                true,
                this.#activeTurnId,
                itemId,
                undefined,
                this.#activeModelName,
            );
        else if (itemId !== undefined && this.#assistant.itemId === undefined)
            this.#assistant.itemId = itemId;
        return this.#assistant;
    }

    #finishAssistantSegment(): void {
        const assistant = this.#assistant;
        if (assistant === undefined)
            return;
        assistant.pending = false;
        if (assistant.text.length === 0)
            this.#messages.splice(this.#messages.indexOf(assistant), 1);
        this.#assistant = undefined;
    }

    #beginReasoningSegment(itemId: string, durationMs: number): MutableChatMessage {
        this.#finishAssistantSegment();
        if (this.#reasoning !== undefined && this.#reasoning.itemId !== itemId)
            this.#finishReasoningSegment();
        if (this.#reasoning === undefined) {
            this.#reasoning = this.#add(
                "reasoning",
                "",
                true,
                this.#activeTurnId,
                itemId,
                undefined,
                this.#activeModelName,
            );
        }
        this.#reasoning.reasoningDurationMs = durationMs;
        this.#reasoning.pending = true;
        return this.#reasoning;
    }

    #finishReasoningSegment(itemId?: string, durationMs?: number): void {
        const reasoning = this.#reasoning;
        if (reasoning === undefined || (itemId !== undefined && reasoning.itemId !== itemId))
            return;
        if (durationMs !== undefined)
            reasoning.reasoningDurationMs = durationMs;
        reasoning.pending = false;
        if (reasoning.text.length === 0)
            this.#messages.splice(this.#messages.indexOf(reasoning), 1);
        this.#reasoning = undefined;
    }

    #addText(
        role: ChatMessageRole,
        text: string,
        turnId?: string,
        timestamp?: string,
        userAudioUrl?: string,
        userImage?: UserImage,
        itemId?: string,
        modelName?: string,
        scheduledTask = false,
    ): MutableChatMessage | undefined {
        const clean = text.trim();
        if (clean.length > 0 || userImage !== undefined)
            return this.#add(role, clean, false, turnId, itemId, timestamp, modelName,
                userAudioUrl, undefined, undefined, undefined, undefined, userImage,
                undefined, undefined, scheduledTask);
        return undefined;
    }

    #add(
        role: ChatMessageRole,
        text: string,
        pending = false,
        turnId?: string,
        itemId?: string,
        timestamp?: string,
        modelName?: string,
        userAudioUrl?: string,
        tool?: ToolIndicator,
        reasoningTruncated?: boolean,
        reasoningDurationMs?: number,
        activityDurationMs?: number,
        userImage?: UserImage,
        generatedImage?: GeneratedImage,
        pendingGeneratedImage?: PendingGeneratedImage,
        scheduledTask = false,
    ): MutableChatMessage {
        const reasoningMode = turnId === undefined
            ? undefined
            : this.#reasoningModes.get(turnId);
        const message = {
            id: `message:${this.#nextMessageId++}`,
            role,
            text,
            pending,
            ...(turnId === undefined ? {} : { turnId }),
            ...(itemId === undefined ? {} : { itemId }),
            ...(timestamp === undefined ? {} : { timestamp }),
            ...(modelName === undefined ? {} : { modelName }),
            ...(reasoningMode === undefined ? {} : { reasoningMode }),
            ...(userAudioUrl === undefined ? {} : { userAudioUrl }),
            ...(userImage === undefined ? {} : { userImage }),
            ...(generatedImage === undefined ? {} : { generatedImage }),
            ...(pendingGeneratedImage === undefined ? {} : { pendingGeneratedImage }),
            ...(tool === undefined ? {} : { tool }),
            ...(reasoningTruncated === undefined ? {} : { reasoningTruncated }),
            ...(reasoningDurationMs === undefined ? {} : { reasoningDurationMs }),
            ...(activityDurationMs === undefined ? {} : { activityDurationMs }),
            ...(scheduledTask ? { scheduledTask: true } : {}),
        } satisfies MutableChatMessage;
        if (isQueuedUser(message)) {
            const draft = this.#draftUser === undefined
                ? -1
                : this.#messages.indexOf(this.#draftUser);
            if (draft < 0) this.#messages.push(message);
            else this.#messages.splice(draft, 0, message);
        } else {
            const sameTurn = turnId === undefined
                ? -1
                : this.#messages.findLastIndex(existing => existing.turnId === turnId);
            if (sameTurn >= 0) {
                this.#messages.splice(sameTurn + 1, 0, message);
            } else {
                const queued = this.#messages.findIndex(isQueuedUser);
                if (queued < 0) this.#messages.push(message);
                else this.#messages.splice(queued, 0, message);
            }
        }
        return message;
    }

    #setQueueFields(
        message: MutableChatMessage,
        queueItemId?: string,
        queueState?: SessionQueueItemState,
        queueSequence?: number,
    ): void {
        if (queueItemId !== undefined) message.queueItemId = queueItemId;
        if (queueState !== undefined) message.queueState = queueState;
        if (queueSequence !== undefined) message.queueSequence = queueSequence;
    }

    #markActivity(): void {
        this.#activitySinceAssistant = true;
        this.#updateActivityDuration();
    }

    #markResponseStart(): void {
        if (!this.#activitySinceAssistant)
            return;
        this.#updateActivityDuration();
        this.#activitySinceAssistant = false;
    }

    #updateActivityDuration(): void {
        if (this.#activeStartedMono === undefined)
            return;
        const duration = performance.now() - this.#activeStartedMono;
        for (const message of this.#messages) {
            if (
                message.turnId === this.#activeTurnId
                && (message.role === "reasoning" || message.role === "tool")
            ) {
                message.activityDurationMs = duration;
            }
        }
    }
}

function isQueuedUser(message: MutableChatMessage): boolean {
    return message.role === "user" && message.pending;
}

function queueVoicePlaceholder(language: ChatLanguage): string {
    switch (language) {
        case "en": return "Voice message…";
        case "sk": return "Hlasová správa…";
        case "de": return "Sprachnachricht…";
        default: return Er.internal("Unsupported chat language.");
    }
}

function codexToolIndicator(message: string, itemId = ""): ToolIndicator {
    return {
        message,
        spokenMessage: "",
        itemId,
        callIndex: 0,
        name: "codex",
        stage: "start",
        status: "running",
    };
}

function isModelContextItem(item: StoredTurnItem): boolean {
    return item.kind === "tool" && item.indicator.name === "model_context";
}
